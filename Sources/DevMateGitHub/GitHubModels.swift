import Foundation

// What `gh` returns, decoded. Every type is Codable both ways, so a loaded
// list can be cached on disk and shown at the next launch before `gh` answers.

public struct GitHubUser: Codable, Hashable, Sendable {
    public var login: String
    public var name: String?

    public init(login: String, name: String? = nil) {
        self.login = login
        self.name = name
    }

    public var display: String { (name?.isEmpty == false ? name : nil) ?? login }
}

public struct GitHubLabel: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    /// Six hex digits, no `#`.
    public var color: String?
    public var description: String?

    public var id: String { name }

    public init(name: String, color: String? = nil, description: String? = nil) {
        self.name = name
        self.color = color
        self.description = description
    }
}

public struct GitHubMilestone: Codable, Hashable, Sendable, Identifiable {
    public var number: Int?
    public var title: String
    public var dueOn: Date?
    public var state: String?

    public var id: String { title }

    public init(number: Int? = nil, title: String, dueOn: Date? = nil, state: String? = nil) {
        self.number = number
        self.title = title
        self.dueOn = dueOn
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case number, title, dueOn, state
        case dueOnREST = "due_on"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        dueOn = (try? c.decodeIfPresent(Date.self, forKey: .dueOn)) ?? (try? c.decodeIfPresent(Date.self, forKey: .dueOnREST))
        state = try c.decodeIfPresent(String.self, forKey: .state)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(number, forKey: .number)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(dueOn, forKey: .dueOn)
        try c.encodeIfPresent(state, forKey: .state)
    }
}

// MARK: Commits

public struct GitHubCommit: Codable, Hashable, Sendable, Identifiable {
    public var repo: String
    public var sha: String
    public var message: String
    public var authorName: String?
    public var authorLogin: String?
    public var date: Date?
    public var url: String

    public var id: String { repo + "@" + sha }
    public var shortSHA: String { String(sha.prefix(7)) }
    /// The first line.
    public var subject: String { message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message }

    public init(repo: String, sha: String, message: String, authorName: String?, authorLogin: String?,
                date: Date?, url: String) {
        self.repo = repo
        self.sha = sha
        self.message = message
        self.authorName = authorName
        self.authorLogin = authorLogin
        self.date = date
        self.url = url
    }
}

/// The REST shape of `GET /repos/{owner}/{repo}/commits`.
struct RESTCommit: Decodable {
    struct Inner: Decodable {
        struct Person: Decodable { var name: String?; var date: Date? }
        var message: String
        var author: Person?
    }
    struct Login: Decodable { var login: String }
    var sha: String
    var html_url: String
    var commit: Inner
    var author: Login?
}

// MARK: Workflow runs

public struct WorkflowRun: Codable, Hashable, Sendable, Identifiable {
    public var repo: String = ""
    public var databaseId: Int
    public var displayTitle: String
    public var workflowName: String
    public var headBranch: String?
    public var event: String?
    /// queued, in_progress, completed, waiting, requested, pending.
    public var status: String
    /// success, failure, cancelled, skipped, neutral, timed_out,
    /// action_required, startup_failure, or empty while running.
    public var conclusion: String?
    public var createdAt: Date?
    public var startedAt: Date?
    public var updatedAt: Date?
    public var url: String
    public var number: Int?
    public var attempt: Int?

    public var id: String { "\(repo)/\(databaseId)" }

    public init(repo: String, databaseId: Int, displayTitle: String, workflowName: String, headBranch: String? = nil,
                event: String? = nil, status: String, conclusion: String? = nil, createdAt: Date? = nil,
                startedAt: Date? = nil, updatedAt: Date? = nil, url: String, number: Int? = nil, attempt: Int? = nil) {
        self.repo = repo
        self.databaseId = databaseId
        self.displayTitle = displayTitle
        self.workflowName = workflowName
        self.headBranch = headBranch
        self.event = event
        self.status = status
        self.conclusion = conclusion
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.url = url
        self.number = number
        self.attempt = attempt
    }

    enum CodingKeys: String, CodingKey {
        case repo, databaseId, displayTitle, workflowName, headBranch, event, status, conclusion
        case createdAt, startedAt, updatedAt, url, number, attempt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        databaseId = try c.decode(Int.self, forKey: .databaseId)
        displayTitle = try c.decodeIfPresent(String.self, forKey: .displayTitle) ?? ""
        workflowName = try c.decodeIfPresent(String.self, forKey: .workflowName) ?? ""
        headBranch = try c.decodeIfPresent(String.self, forKey: .headBranch)
        event = try c.decodeIfPresent(String.self, forKey: .event)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt)
    }

    /// One word for the run's state.
    public var state: RunState {
        if status != "completed" {
            return ["queued", "waiting", "requested", "pending"].contains(status) ? .queued : .running
        }
        switch conclusion ?? "" {
        case "success": return .succeeded
        case "failure", "timed_out", "startup_failure": return .failed
        case "cancelled": return .cancelled
        case "action_required": return .needsAction
        default: return .skipped
        }
    }

    public var isFinished: Bool { status == "completed" }

    /// How long it ran, or has been running.
    public func duration(now: Date = Date()) -> TimeInterval? {
        guard let start = startedAt ?? createdAt else { return nil }
        let end = isFinished ? (updatedAt ?? now) : now
        return max(0, end.timeIntervalSince(start))
    }

    public enum RunState: String, CaseIterable, Sendable {
        case running = "Running"
        case queued = "Queued"
        case succeeded = "Succeeded"
        case failed = "Failed"
        case cancelled = "Cancelled"
        case needsAction = "Needs Action"
        case skipped = "Skipped"
    }
}

// MARK: Pull requests

public struct CheckSummary: Codable, Hashable, Sendable {
    public var passed = 0
    public var failed = 0
    public var pending = 0
    public var skipped = 0

    public init(passed: Int = 0, failed: Int = 0, pending: Int = 0, skipped: Int = 0) {
        self.passed = passed
        self.failed = failed
        self.pending = pending
        self.skipped = skipped
    }

    public var total: Int { passed + failed + pending + skipped }

    public enum Overall: String, Sendable { case none = "No checks", passing = "Passing", failing = "Failing", pending = "Pending" }

    public var overall: Overall {
        if total == 0 { return .none }
        if failed > 0 { return .failing }
        if pending > 0 { return .pending }
        return .passing
    }

    /// Counts `statusCheckRollup` entries: check runs by status and
    /// conclusion, commit statuses by state.
    public static func from(rollup: [CheckRollupEntry]) -> CheckSummary {
        var s = CheckSummary()
        for entry in rollup {
            if let state = entry.state?.uppercased() {
                switch state {
                case "SUCCESS": s.passed += 1
                case "FAILURE", "ERROR": s.failed += 1
                default: s.pending += 1
                }
                continue
            }
            if (entry.status ?? "").uppercased() != "COMPLETED" { s.pending += 1; continue }
            switch (entry.conclusion ?? "").uppercased() {
            case "SUCCESS": s.passed += 1
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": s.failed += 1
            case "SKIPPED", "NEUTRAL", "STALE": s.skipped += 1
            default: s.pending += 1
            }
        }
        return s
    }
}

/// One entry of a pull request's `statusCheckRollup`: a CheckRun (status,
/// conclusion, name) or a StatusContext (state, context).
public struct CheckRollupEntry: Codable, Hashable, Sendable {
    public var name: String?
    public var context: String?
    public var status: String?
    public var conclusion: String?
    public var state: String?
    public var detailsUrl: String?
    public var targetUrl: String?

    public init(name: String? = nil, context: String? = nil, status: String? = nil, conclusion: String? = nil,
                state: String? = nil, detailsUrl: String? = nil, targetUrl: String? = nil) {
        self.name = name
        self.context = context
        self.status = status
        self.conclusion = conclusion
        self.state = state
        self.detailsUrl = detailsUrl
        self.targetUrl = targetUrl
    }

    public var title: String { name ?? context ?? "Check" }
}

public struct GitHubPullRequest: Codable, Hashable, Sendable, Identifiable {
    public var repo: String = ""
    public var number: Int
    public var title: String
    public var author: GitHubUser?
    public var headRefName: String?
    public var baseRefName: String?
    public var isDraft: Bool?
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or empty.
    public var reviewDecision: String?
    public var statusCheckRollup: [CheckRollupEntry]?
    public var url: String
    public var createdAt: Date?
    public var updatedAt: Date?
    public var labels: [GitHubLabel]?

    public var id: String { "\(repo)#\(number)" }

    public init(repo: String, number: Int, title: String, author: GitHubUser? = nil, headRefName: String? = nil,
                baseRefName: String? = nil, isDraft: Bool? = nil, reviewDecision: String? = nil,
                statusCheckRollup: [CheckRollupEntry]? = nil, url: String, createdAt: Date? = nil,
                updatedAt: Date? = nil, labels: [GitHubLabel]? = nil) {
        self.repo = repo
        self.number = number
        self.title = title
        self.author = author
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.statusCheckRollup = statusCheckRollup
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.labels = labels
    }

    enum CodingKeys: String, CodingKey {
        case repo, number, title, author, headRefName, baseRefName, isDraft, reviewDecision
        case statusCheckRollup, url, createdAt, updatedAt, labels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        author = try? c.decodeIfPresent(GitHubUser.self, forKey: .author)
        headRefName = try c.decodeIfPresent(String.self, forKey: .headRefName)
        baseRefName = try c.decodeIfPresent(String.self, forKey: .baseRefName)
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft)
        reviewDecision = try c.decodeIfPresent(String.self, forKey: .reviewDecision)
        statusCheckRollup = try? c.decodeIfPresent([CheckRollupEntry].self, forKey: .statusCheckRollup)
        url = try c.decode(String.self, forKey: .url)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        labels = try? c.decodeIfPresent([GitHubLabel].self, forKey: .labels)
    }

    public var checks: CheckSummary { .from(rollup: statusCheckRollup ?? []) }

    public var review: ReviewState {
        switch (reviewDecision ?? "").uppercased() {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .required
        default: return .none
        }
    }

    public enum ReviewState: String, Sendable {
        case approved = "Approved"
        case changesRequested = "Changes requested"
        case required = "Review required"
        case none = "No review"
    }
}

// MARK: Issues

public struct GitHubComment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var author: GitHubUser?
    public var body: String
    public var createdAt: Date?
    public var url: String?

    public init(id: String, author: GitHubUser?, body: String, createdAt: Date?, url: String?) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.url = url
    }
}

public struct LinkedPullRequest: Codable, Hashable, Sendable, Identifiable {
    public var repo: String
    public var number: Int
    public var title: String
    public var url: String
    /// OPEN, CLOSED or MERGED.
    public var state: String
    /// True when merging it closes the issue.
    public var closesIssue: Bool

    public var id: String { "\(repo)#\(number)" }

    public init(repo: String, number: Int, title: String, url: String, state: String, closesIssue: Bool) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.closesIssue = closesIssue
    }
}

public struct GitHubIssue: Codable, Hashable, Sendable, Identifiable {
    public var repo: String = ""
    public var number: Int
    public var title: String
    /// OPEN or CLOSED.
    public var state: String
    /// COMPLETED, NOT_PLANNED, REOPENED, DUPLICATE or empty.
    public var stateReason: String?
    public var author: GitHubUser?
    public var labels: [GitHubLabel]
    public var assignees: [GitHubUser]
    public var milestone: GitHubMilestone?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var closedAt: Date?
    public var url: String
    /// Only in the detail view.
    public var body: String?
    public var comments: [GitHubComment]?

    public var id: String { "\(repo)#\(number)" }
    public var isOpen: Bool { state.uppercased() == "OPEN" }

    public init(repo: String, number: Int, title: String, state: String, stateReason: String? = nil,
                author: GitHubUser? = nil, labels: [GitHubLabel] = [], assignees: [GitHubUser] = [],
                milestone: GitHubMilestone? = nil, createdAt: Date? = nil, updatedAt: Date? = nil,
                closedAt: Date? = nil, url: String, body: String? = nil, comments: [GitHubComment]? = nil) {
        self.repo = repo
        self.number = number
        self.title = title
        self.state = state
        self.stateReason = stateReason
        self.author = author
        self.labels = labels
        self.assignees = assignees
        self.milestone = milestone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.url = url
        self.body = body
        self.comments = comments
    }

    enum CodingKeys: String, CodingKey {
        case repo, number, title, state, stateReason, author, labels, assignees, milestone
        case createdAt, updatedAt, closedAt, url, body, comments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "OPEN"
        stateReason = try c.decodeIfPresent(String.self, forKey: .stateReason)
        author = try? c.decodeIfPresent(GitHubUser.self, forKey: .author)
        labels = (try? c.decodeIfPresent([GitHubLabel].self, forKey: .labels)) ?? []
        assignees = (try? c.decodeIfPresent([GitHubUser].self, forKey: .assignees)) ?? []
        milestone = try? c.decodeIfPresent(GitHubMilestone.self, forKey: .milestone)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        closedAt = try? c.decodeIfPresent(Date.self, forKey: .closedAt)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body)
        comments = try? c.decodeIfPresent([GitHubComment].self, forKey: .comments)
    }
}

// MARK: Projects (v2)

public struct GitHubProject: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var number: Int
    public var title: String
    public var url: String?
    public var closed: Bool?

    public init(id: String, number: Int, title: String, url: String? = nil, closed: Bool? = nil) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.closed = closed
    }
}

/// The project's Status field and its columns.
public struct ProjectStatusField: Codable, Hashable, Sendable {
    public struct Option: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    public var id: String
    public var name: String
    public var options: [Option]

    public init(id: String, name: String, options: [Option]) {
        self.id = id
        self.name = name
        self.options = options
    }
}

public struct ProjectItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var status: String?
    /// "Issue", "PullRequest" or "DraftIssue".
    public var type: String?
    public var number: Int?
    /// The repository's name, without the owner.
    public var repo: String?
    public var url: String?

    public init(id: String, title: String, status: String? = nil, type: String? = nil, number: Int? = nil,
                repo: String? = nil, url: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.type = type
        self.number = number
        self.repo = repo
        self.url = url
    }

    /// Matches an issue in the loaded list.
    public var issueID: String? {
        guard let repo, let number else { return nil }
        return "\(repo)#\(number)"
    }
}

public struct ProjectBoard: Codable, Hashable, Sendable {
    public var project: GitHubProject
    public var status: ProjectStatusField?
    public var items: [ProjectItem]

    public init(project: GitHubProject, status: ProjectStatusField?, items: [ProjectItem]) {
        self.project = project
        self.status = status
        self.items = items
    }

    /// Columns in the Status field's order, then "No Status" when any item
    /// has none or a status the field no longer lists.
    public var columns: [String] {
        var names = status?.options.map(\.name) ?? []
        for item in items {
            let name = item.status ?? ProjectBoard.noStatus
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    public func items(in column: String) -> [ProjectItem] {
        items.filter { ($0.status ?? ProjectBoard.noStatus) == column }
    }

    public static let noStatus = "No Status"
}
