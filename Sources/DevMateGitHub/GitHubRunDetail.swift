import DevMateCore
import Foundation

/// One GitHub Actions run read as jobs and steps, over the `gh` the person is
/// signed in to. GitHub has no stages, so every job sits in one unnamed stage.
/// GitHub keeps one log per job, so a step's log is the stretch of the job's
/// log from when the step began until the next one did.
public struct GitHubRunDetail: RunDetailProvider {
    /// Reads one REST path, such as `repos/example/app/actions/runs/1/jobs`,
    /// and returns the body. The app decides how the request is signed in.
    public typealias Transport = @Sendable (_ path: String) async throws -> String

    public var repository: String
    public var runID: Int
    private let read: Transport

    /// `repository` is `owner/name`.
    public init(repository: String, runID: Int, transport: @escaping Transport) {
        self.repository = repository
        self.runID = runID
        self.read = transport
    }

    /// Reads through the `gh` the person is signed in to.
    public init(gh: GitHubCLI, repo: String, runID: Int) {
        self.init(repository: gh.slug(repo), runID: runID) { path in
            try await Task.detached { try gh.run(["api", path], timeout: 120) }.value
        }
    }

    public func timeline() async throws -> RunTimeline {
        let text = try await read("repos/\(repository)/actions/runs/\(runID)/jobs?per_page=100")
        return try Self.timeline(from: Data(text.utf8))
    }

    struct Jobs: Decodable { var jobs: [Job] }
    struct Job: Decodable {
        struct Step: Decodable {
            var number: Int
            var name: String
            var status: String?
            var conclusion: String?
            var started_at: Date?
            var completed_at: Date?
        }
        var id: Int
        var name: String
        var status: String?
        var conclusion: String?
        var started_at: Date?
        var completed_at: Date?
        var steps: [Step]?
    }

    static func state(status: String?, conclusion: String?) -> RunNodeState {
        switch (status ?? "").lowercased() {
        case "queued", "waiting", "pending", "requested": return .pending
        case "in_progress": return .running
        default:
            switch (conclusion ?? "").lowercased() {
            case "success", "neutral": return .succeeded
            case "failure", "timed_out", "startup_failure": return .failed
            case "cancelled": return .cancelled
            case "skipped": return .skipped
            case "action_required": return .waiting
            default: return status == nil ? .pending : .succeeded
            }
        }
    }

    public static func timeline(from data: Data) throws -> RunTimeline {
        let decoded: Jobs
        do { decoded = try GitHubJSON.decoder.decode(Jobs.self, from: data) } catch {
            throw RunDetailError("Could not read the run's jobs: \(error.localizedDescription)")
        }
        let jobs = decoded.jobs.map { job in
            RunJob(id: String(job.id), name: job.name, state: state(status: job.status, conclusion: job.conclusion),
                   startedAt: job.started_at, finishedAt: job.completed_at, logID: String(job.id),
                   steps: (job.steps ?? []).map { step in
                       RunStep(id: "\(job.id)-\(step.number)", name: step.name,
                               state: state(status: step.status, conclusion: step.conclusion),
                               startedAt: step.started_at, finishedAt: step.completed_at, logID: String(job.id),
                               identifier: String(step.number))
                   })
        }
        let overall: RunNodeState = jobs.contains { $0.state == .running } ? .running
            : jobs.contains { $0.state == .failed } ? .failed : jobs.allSatisfy { $0.state == .succeeded } ? .succeeded : .pending
        return RunTimeline(stages: [RunStage(id: "run", name: "", state: overall, jobs: jobs)])
    }

    public func log(job: RunJob, step: RunStep?) async throws -> String {
        guard let id = job.logID else { return "" }
        let text = try await read("repos/\(repository)/actions/jobs/\(id)/logs")
        guard let step else { return text }
        return Self.slice(text, step: step, of: job)
    }

    /// The lines whose timestamp falls at or after the step began and before
    /// the next step did. Lines before the first step belong to it.
    static func slice(_ text: String, step: RunStep, of job: RunJob) -> String {
        guard let index = job.steps.firstIndex(where: { $0.id == step.id }), let start = step.startedAt else { return text }
        let upper = job.steps.dropFirst(index + 1).compactMap(\.startedAt).first
        var kept: [Substring] = []
        var inside = index == 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let stamp = timestamp(line) {
                inside = (index == 0 || stamp >= start) && upper.map { stamp < $0 } ?? true
            }
            if inside { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    static func timestamp(_ line: Substring) -> Date? {
        guard line.count > 20, line[line.index(line.startIndex, offsetBy: 10)] == "T" else { return nil }
        let head = String(line.prefix(19)) + "Z"
        return ISO8601DateFormatter().date(from: head)
    }
}
