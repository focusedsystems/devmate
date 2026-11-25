import Foundation

/// Where a stage, job or step is in its life. One vocabulary for every host.
public enum RunNodeState: String, Codable, CaseIterable, Sendable {
    case pending, running, succeeded, partial, failed, cancelled, skipped
    /// Held by an approval or check that is waiting for a person.
    case waiting

    public var label: String {
        switch self {
        case .pending: return "Not started"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .partial: return "Succeeded with issues"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        case .waiting: return "Waiting"
        }
    }

    /// Whether the node is still to run or running, so its log can grow.
    public var isActive: Bool { self == .running || self == .waiting }
    public var isFinished: Bool { !(self == .pending || isActive) }
}

/// One step of a job, with its own log.
public struct RunStep: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var state: RunNodeState
    public var startedAt: Date?
    public var finishedAt: Date?
    /// The host's own handle for this step's log; nil until it has one.
    public var logID: String?
    /// The host's identifier for the step, such as the id an approval carries.
    public var identifier: String?
    /// The task or action the step runs, such as `ManualValidation@0`.
    public var task: String?
    public var issues: [String]

    public init(id: String, name: String, state: RunNodeState, startedAt: Date? = nil, finishedAt: Date? = nil,
                logID: String? = nil, identifier: String? = nil, task: String? = nil, issues: [String] = []) {
        self.id = id
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.logID = logID
        self.identifier = identifier
        self.task = task
        self.issues = issues
    }

    public func duration(now: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (finishedAt ?? (state.isActive ? now : startedAt)).timeIntervalSince(startedAt))
    }
}

public struct RunJob: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var state: RunNodeState
    public var startedAt: Date?
    public var finishedAt: Date?
    /// The job's whole log, when the host keeps one.
    public var logID: String?
    public var steps: [RunStep]

    public init(id: String, name: String, state: RunNodeState, startedAt: Date? = nil, finishedAt: Date? = nil,
                logID: String? = nil, steps: [RunStep] = []) {
        self.id = id
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.logID = logID
        self.steps = steps
    }

    public func duration(now: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (finishedAt ?? (state.isActive ? now : startedAt)).timeIntervalSince(startedAt))
    }
}

public struct RunStage: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var state: RunNodeState
    public var startedAt: Date?
    public var finishedAt: Date?
    public var jobs: [RunJob]

    public init(id: String, name: String, state: RunNodeState, startedAt: Date? = nil, finishedAt: Date? = nil,
                jobs: [RunJob] = []) {
        self.id = id
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.jobs = jobs
    }
}

/// A run's stages, jobs and steps as one snapshot. A host with no stages, such
/// as GitHub Actions, puts every job in one stage whose name is empty.
public struct RunTimeline: Hashable, Sendable {
    public var stages: [RunStage]

    public init(stages: [RunStage] = []) { self.stages = stages }

    public var isEmpty: Bool { stages.allSatisfy { $0.jobs.isEmpty } && stages.count <= 1 }
    public var jobs: [RunJob] { stages.flatMap(\.jobs) }
    /// True while anything is still to run or running.
    public var isActive: Bool {
        stages.contains { $0.state.isActive || $0.jobs.contains { $0.state.isActive || $0.steps.contains { $0.state.isActive } } }
    }

    /// Marks the steps in `waiting` as waiting, and the jobs and stages that
    /// hold them. `waiting` holds lowercased approval identifiers.
    public func marking(waiting identifiers: Set<String>) -> RunTimeline {
        guard !identifiers.isEmpty else { return self }
        var copy = self
        for s in copy.stages.indices {
            for j in copy.stages[s].jobs.indices {
                var held = false
                for k in copy.stages[s].jobs[j].steps.indices {
                    let step = copy.stages[s].jobs[j].steps[k]
                    if let identifier = step.identifier?.lowercased(), identifiers.contains(identifier), !step.state.isFinished {
                        copy.stages[s].jobs[j].steps[k].state = .waiting
                        held = true
                    }
                }
                if held { copy.stages[s].jobs[j].state = .waiting }
            }
            if copy.stages[s].jobs.contains(where: { $0.state == .waiting }) { copy.stages[s].state = .waiting }
        }
        return copy
    }

    /// The step the web page would have open: the one waiting, else the first
    /// that failed, else the one running, else the last that ran.
    public var activeSelection: RunSelection? {
        func pick(_ states: [RunNodeState]) -> RunSelection? {
            for stage in stages {
                for job in stage.jobs {
                    for step in job.steps where states.contains(step.state) { return .step(job: job.id, step: step.id) }
                    if job.steps.isEmpty, states.contains(job.state) { return .job(job.id) }
                }
            }
            return nil
        }
        if let waiting = pick([.waiting]) { return waiting }
        if let failed = pick([.failed]) { return failed }
        if let running = pick([.running]) { return running }
        for stage in stages.reversed() {
            for job in stage.jobs.reversed() {
                if let step = job.steps.last(where: { $0.state != .pending && $0.state != .skipped }) {
                    return .step(job: job.id, step: step.id)
                }
                if job.state != .pending { return .job(job.id) }
            }
        }
        return stages.first.map { .stage($0.id) }
    }

    /// The job and its stage that hold a selection.
    public func job(_ id: String) -> (stage: RunStage, job: RunJob)? {
        for stage in stages { if let job = stage.jobs.first(where: { $0.id == id }) { return (stage, job) } }
        return nil
    }
}

/// What the outline has selected.
public enum RunSelection: Hashable, Sendable {
    case stage(String)
    case job(String)
    case step(job: String, step: String)

    public var jobID: String? {
        switch self {
        case .stage: return nil
        case .job(let id): return id
        case .step(let job, _): return job
        }
    }
}

/// A person or group's answer is awaited by a step or an environment check.
public struct RunApproval: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable { case manualValidation, environment }

    /// The approval's id, also the `identifier` of the step it holds.
    public var id: String
    public var kind: Kind
    public var instructions: String
    public var createdAt: Date?
    public var approvers: [String]
    public var minRequiredApprovers: Int?
    public var stageName: String?
    public var stepName: String?
    public var startedAt: Date?
    public var timeoutMinutes: Int?
    public var resumesOnTimeout: Bool

    public init(id: String, kind: Kind, instructions: String = "", createdAt: Date? = nil, approvers: [String] = [],
                minRequiredApprovers: Int? = nil, stageName: String? = nil, stepName: String? = nil,
                startedAt: Date? = nil, timeoutMinutes: Int? = nil, resumesOnTimeout: Bool = false) {
        self.id = id
        self.kind = kind
        self.instructions = instructions
        self.createdAt = createdAt
        self.approvers = approvers
        self.minRequiredApprovers = minRequiredApprovers
        self.stageName = stageName
        self.stepName = stepName
        self.startedAt = startedAt
        self.timeoutMinutes = timeoutMinutes
        self.resumesOnTimeout = resumesOnTimeout
    }

    public var approveVerb: String { kind == .manualValidation ? "Resume" : "Approve" }
    public var rejectVerb: String { "Reject" }
    public var kindTitle: String { kind == .manualValidation ? "Manual validation" : "Environment approval" }
    public var waitingSince: Date? { startedAt ?? createdAt }

    public func waitingDuration(now: Date = Date()) -> TimeInterval? {
        waitingSince.map { max(0, now.timeIntervalSince($0)) }
    }

    public var deadline: Date? {
        guard let minutes = timeoutMinutes, let waitingSince else { return nil }
        return waitingSince.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    public func timeoutSummary(now: Date = Date()) -> String? {
        guard let deadline else { return nil }
        let outcome = resumesOnTimeout ? "the run resumes" : "the run is rejected"
        let left = deadline.timeIntervalSince(now)
        if left <= 0 { return "Timed out; \(outcome)." }
        return "Times out in \(Self.format(left)); then \(outcome)."
    }

    public func target(runName: String) -> String {
        var parts: [String] = []
        if let stepName, !stepName.isEmpty { parts.append("\u{201C}\(stepName)\u{201D}") }
        if let stageName, !stageName.isEmpty { parts.append("in stage \(stageName)") }
        parts.append(parts.isEmpty ? runName : "of \(runName)")
        return parts.joined(separator: " ")
    }

    public func confirmationTitle(approve: Bool, runName: String) -> String {
        "\(approve ? approveVerb : rejectVerb) \(target(runName: runName))?"
    }

    public func confirmationMessage(approve: Bool) -> String {
        if approve {
            return kind == .manualValidation
                ? "The run continues past this step. This is recorded under your name."
                : "The run is allowed to deploy. This is recorded under your name."
        }
        return "The run stops at this step and is marked failed. This is recorded under your name."
    }

    public static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "under a minute" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}

/// One run's stages, jobs, steps, logs and approvals, read as the person
/// looks at it. A provider is made for one run, so it holds the host's
/// address and sign-in; DevMate holds neither.
public protocol RunDetailProvider: Sendable {
    func timeline() async throws -> RunTimeline
    /// The log of a step, or of a whole job when `step` is nil.
    func log(job: RunJob, step: RunStep?) async throws -> String
    /// Facts about a step's task. Empty when the host reports none.
    func taskDetails(job: RunJob, step: RunStep) async throws -> [(name: String, value: String)]
    /// The approvals holding this run now. Empty for a host without any.
    func approvals() async throws -> [RunApproval]
    /// Answers an approval as the signed-in person. Writes to a live run.
    func respond(to approval: RunApproval, approve: Bool, comment: String) async throws
}

public extension RunDetailProvider {
    func taskDetails(job: RunJob, step: RunStep) async throws -> [(name: String, value: String)] { [] }
    func approvals() async throws -> [RunApproval] { [] }
    func respond(to approval: RunApproval, approve: Bool, comment: String) async throws {
        throw RunDetailError("This host does not take approvals from here.")
    }
}

public struct RunDetailError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
