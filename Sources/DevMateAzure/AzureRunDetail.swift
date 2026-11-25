import DevMateCore
import Foundation

/// Signs one request in. The app decides how: a token its own sign-in holds,
/// or `AzureCLITokens` for an app that uses the person's `az` login.
public typealias AzureTokenProvider = @Sendable () async throws -> String

/// A token from the `az` the person is signed in to. DevMate keeps no token
/// of its own; this asks `az` each time it is needed and remembers the answer
/// until shortly before it expires.
public final class AzureCLITokens: @unchecked Sendable {
    private let executable: String?
    private let lock = NSLock()
    private var cached: (token: String, expires: Date)?

    public init(executable: String? = ProcessRunner.find("az")) {
        self.executable = executable
    }

    public func token() async throws -> String {
        if let cached = lock.withLock({ cached }), cached.expires > Date().addingTimeInterval(120) { return cached.token }
        guard let executable else { throw AzureCLIError("The Azure CLI (az) is not installed.") }
        let arguments = ["account", "get-access-token", "--resource", AzureCLI.resource, "--output", "json"]
        let result = await ProcessRunner.runAsync(executable, arguments, timeout: 40)
        guard let result, result.status == 0 else {
            let message = result?.error.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AzureCLIError(message.isEmpty ? "az could not give a token." : message)
        }
        struct Answer: Decodable { var accessToken: String; var expiresOn: String? }
        let answer = try JSONDecoder().decode(Answer.self, from: Data(result.output.utf8))
        let expires = answer.expiresOn.flatMap { text -> Date? in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
            return formatter.date(from: text)
        } ?? Date().addingTimeInterval(1800)
        lock.withLock { cached = (answer.accessToken, expires) }
        return answer.accessToken
    }
}

/// One Azure DevOps build read as stages, jobs and steps, over the REST API.
/// The organisation, project and sign-in are the app's; nothing is built in.
public struct AzureRunDetail: RunDetailProvider {
    public var organization: String
    public var project: String
    public var buildID: Int
    private let token: AzureTokenProvider
    private let session: URLSession

    /// A single log read stops here; the tail is kept.
    static let logLimit = 4_000_000

    public init(organization: String, project: String, buildID: Int, token: @escaping AzureTokenProvider,
                session: URLSession = .shared) {
        self.organization = AzureCLI.normalized(organization)
        self.project = project
        self.buildID = buildID
        self.token = token
        self.session = session
    }

    private var cli: AzureCLI { AzureCLI(organization: organization, executable: nil) }

    private func address(_ path: String, query: [(String, String)] = [], apiVersion: String = AzureCLI.apiVersion) throws -> URL {
        guard let url = URL(string: cli.url(project: project, path: path, query: query, apiVersion: apiVersion)) else {
            throw RunDetailError("The address for this run is not valid.")
        }
        return url
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RunDetailError("No answer from Azure DevOps.") }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 203: throw RunDetailError("Azure DevOps did not accept the sign-in. Sign in again.")
            case 403: throw RunDetailError("This sign-in may not read that run.")
            case 404: throw RunDetailError("Azure DevOps has no such run or log.")
            default: throw RunDetailError("Azure DevOps answered \(http.statusCode).")
            }
        }
        return data
    }

    // MARK: Timeline

    public func timeline() async throws -> RunTimeline {
        var request = URLRequest(url: try address("build/builds/\(buildID)/timeline"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await send(request)
        return try Self.timeline(from: data)
    }

    public static func timeline(from data: Data) throws -> RunTimeline {
        let decoded: Timeline
        do { decoded = try AzureJSON.decoder.decode(Timeline.self, from: data) } catch {
            throw RunDetailError("Could not read the run's timeline: \(error.localizedDescription)")
        }
        return map(decoded.records ?? [])
    }

    struct Timeline: Decodable { var records: [Record]? }

    struct Record: Decodable {
        struct Log: Decodable { var id: Int? }
        struct Task: Decodable { var name: String?; var version: String? }
        struct Issue: Decodable { var type: String?; var message: String? }
        var id: String
        var parentId: String?
        var type: String?
        var name: String?
        var state: String?
        var result: String?
        var startTime: Date?
        var finishTime: Date?
        var order: Int?
        var log: Log?
        var identifier: String?
        var task: Task?
        var issues: [Issue]?
    }

    static func state(_ record: Record) -> RunNodeState {
        switch (record.state ?? "").lowercased() {
        case "pending", "notstarted": return .pending
        case "inprogress": return .running
        default:
            switch (record.result ?? "").lowercased() {
            case "succeeded": return .succeeded
            case "succeededwithissues": return .partial
            case "failed": return .failed
            case "canceled", "cancelled", "abandoned": return .cancelled
            case "skipped": return .skipped
            default: return record.state == nil ? .pending : .succeeded
            }
        }
    }

    /// Stage, then phase, then job, then task: a stage's jobs are its job
    /// records, and approval checks on the stage show as a job of their own.
    static func map(_ records: [Record]) -> RunTimeline {
        let ordered = records.sorted { ($0.order ?? 0, $0.name ?? "") < ($1.order ?? 0, $1.name ?? "") }
        let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func kind(_ record: Record) -> String { (record.type ?? "").lowercased() }

        func step(_ record: Record) -> RunStep {
            var task: String?
            if let name = record.task?.name, !name.isEmpty {
                task = record.task?.version.map { "\(name)@\($0.split(separator: ".").first.map(String.init) ?? $0)" } ?? name
            }
            return RunStep(id: record.id, name: record.name ?? "Step", state: state(record),
                           startedAt: record.startTime, finishedAt: record.finishTime,
                           logID: record.log?.id.map(String.init), identifier: record.identifier, task: task,
                           issues: (record.issues ?? []).compactMap { $0.message })
        }

        func stageID(of record: Record) -> String? {
            var current = record.parentId.flatMap { byID[$0] }
            var hops = 0
            while let node = current, hops < 6 {
                if kind(node) == "stage" { return node.id }
                current = node.parentId.flatMap { byID[$0] }
                hops += 1
            }
            return nil
        }

        let stages = ordered.filter { kind($0) == "stage" }
        var result: [RunStage] = []
        func build(stage: Record?, id: String) -> RunStage {
            let inStage = ordered.filter { stageID(of: $0) == stage?.id }
            var jobs: [RunJob] = []
            for job in inStage where kind(job) == "job" {
                let steps = ordered.filter { $0.parentId == job.id && kind($0) == "task" }.map(step)
                jobs.append(RunJob(id: job.id, name: job.name ?? "Job", state: state(job), startedAt: job.startTime,
                                   finishedAt: job.finishTime, logID: job.log?.id.map(String.init), steps: steps))
            }
            for check in inStage where kind(check) == "checkpoint" {
                var steps = ordered.filter { $0.parentId == check.id }.map(step)
                if steps.isEmpty { steps = [step(check)] }
                jobs.append(RunJob(id: check.id, name: check.name ?? "Checks", state: state(check),
                                   startedAt: check.startTime, finishedAt: check.finishTime, logID: check.log?.id.map(String.init),
                                   steps: steps))
            }
            return RunStage(id: id, name: stage?.name ?? "", state: stage.map(state) ?? .pending,
                            startedAt: stage?.startTime, finishedAt: stage?.finishTime, jobs: jobs)
        }
        for stage in stages { result.append(build(stage: stage, id: stage.id)) }
        if stages.isEmpty || ordered.contains(where: { kind($0) == "job" && stageID(of: $0) == nil }) {
            let loose = build(stage: nil, id: "run")
            if !loose.jobs.isEmpty { result.append(loose) }
        }
        return RunTimeline(stages: result)
    }

    // MARK: Logs

    public func log(job: RunJob, step: RunStep?) async throws -> String {
        guard let logID = step?.logID ?? (step == nil ? job.logID : nil), !logID.isEmpty else { return "" }
        var request = URLRequest(url: try address("build/builds/\(buildID)/logs/\(logID)", apiVersion: "7.0"))
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let data = try await send(request)
        let text = String(decoding: data, as: UTF8.self)
        return text.utf8.count > Self.logLimit ? String(decoding: data.suffix(Self.logLimit), as: UTF8.self) : text
    }

    public func taskDetails(job: RunJob, step: RunStep) async throws -> [(name: String, value: String)] {
        var rows: [(String, String)] = [("Step", step.name)]
        if let task = step.task { rows.append(("Task", task)) }
        rows.append(("Result", step.state.label))
        if let started = step.startedAt { rows.append(("Started", started.formatted(date: .abbreviated, time: .standard))) }
        if let finished = step.finishedAt { rows.append(("Finished", finished.formatted(date: .abbreviated, time: .standard))) }
        rows.append(("Job", job.name))
        if let identifier = step.identifier { rows.append(("Identifier", identifier)) }
        for issue in step.issues { rows.append(("Issue", issue)) }
        return rows
    }

    // MARK: Approvals

    public func approvals() async throws -> [RunApproval] {
        var request = URLRequest(url: try address("pipelines/approvals",
                                                  query: [("state", "pending"), ("$expand", "steps")], apiVersion: "7.1"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let pending = try AzureJSON.decoder.decode(Approvals.self, from: try await send(request)).value ?? []
        guard !pending.isEmpty else { return [] }
        var timelineRequest = URLRequest(url: try address("build/builds/\(buildID)/timeline"))
        timelineRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let records = (try? AzureJSON.decoder.decode(Timeline.self, from: try await send(timelineRequest)))?.records ?? []
        return Self.approvals(pending, in: records, buildID: buildID)
    }

    struct Approvals: Decodable { var value: [Approval]? }
    struct Approval: Decodable {
        struct Owner: Decodable { var id: Int? }
        struct Pipeline: Decodable { var owner: Owner? }
        struct Step: Decodable { struct Identity: Decodable { var displayName: String? }; var assignedApprover: Identity? }
        var id: String
        var status: String?
        var instructions: String?
        var createdOn: Date?
        var pipeline: Pipeline?
        var steps: [Step]?
        var minRequiredApprovers: Int?
    }

    /// The pending approvals that hold this build: an environment check names
    /// the build, a ManualValidation step is found by its timeline record.
    static func approvals(_ pending: [Approval], in records: [Record], buildID: Int) -> [RunApproval] {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [RunApproval] = []
        for approval in pending {
            let record = records.first { $0.identifier?.lowercased() == approval.id.lowercased() }
            let owned = approval.pipeline?.owner?.id == buildID
            guard owned || record != nil else { continue }
            var stageName: String?
            var current = record
            var hops = 0
            while let node = current, hops < 6 {
                if (node.type ?? "").lowercased() == "stage" { stageName = node.name; break }
                current = node.parentId.flatMap { byID[$0] }
                hops += 1
            }
            found.append(RunApproval(id: approval.id, kind: owned ? .environment : .manualValidation,
                                     instructions: approval.instructions ?? "", createdAt: approval.createdOn,
                                     approvers: (approval.steps ?? []).compactMap { $0.assignedApprover?.displayName },
                                     minRequiredApprovers: approval.minRequiredApprovers, stageName: stageName,
                                     stepName: record?.name, startedAt: record?.startTime))
        }
        return found
    }

    /// Answers one approval as the signed-in person. This writes to a live
    /// run; callers confirm first.
    public func respond(to approval: RunApproval, approve: Bool, comment: String) async throws {
        var request = URLRequest(url: try address("pipelines/approvals", apiVersion: "7.1"))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(AzureJSON.text([["approvalId": approval.id, "status": approve ? "approved" : "rejected",
                                                  "comment": comment]]).utf8)
        let page = try AzureJSON.decoder.decode(Approvals.self, from: try await send(request))
        let expected = approve ? "approved" : "rejected"
        if let status = page.value?.first(where: { $0.id.lowercased() == approval.id.lowercased() })?.status?.lowercased(),
           status != expected {
            throw RunDetailError("Azure DevOps kept this approval \(status); you may not be one of its approvers.")
        }
    }
}
