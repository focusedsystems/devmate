import Foundation

/// One commit on a repository's default branch.
public struct DevCommit: Codable, Hashable, Identifiable, Sendable {
    /// The registry id of the repository. Names can repeat across owners.
    public var repoID: String
    /// The repository's name, for display.
    public var repo: String
    public var sha: String
    public var message: String
    public var author: String?
    public var date: Date?
    public var url: String

    public var id: String { repoID + "@" + sha }
    public var shortSHA: String { String(sha.prefix(7)) }
    public var subject: String { message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message }

    public init(repoID: String, repo: String, sha: String, message: String, author: String?, date: Date?, url: String) {
        self.repoID = repoID
        self.repo = repo
        self.sha = sha
        self.message = message
        self.author = author
        self.date = date
        self.url = url
    }
}

/// One pipeline or workflow run.
public struct DevPipelineRun: Codable, Hashable, Identifiable, Sendable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case running = "Running"
        case queued = "Queued"
        case succeeded = "Succeeded"
        case failed = "Failed"
        case cancelled = "Cancelled"
        case needsAction = "Needs Action"
        case skipped = "Skipped"
    }

    /// The registry id of the repository. Names can repeat across owners.
    public var repoID: String
    /// The repository's name, for display.
    public var repo: String
    public var runID: Int
    public var title: String
    public var pipeline: String
    public var branch: String?
    public var event: String?
    public var state: State
    public var isFinished: Bool
    /// The provider's own words for the state, for a tooltip.
    public var detail: String
    public var startedAt: Date?
    public var updatedAt: Date?
    public var url: String

    public var id: String { "\(repoID)/\(runID)" }

    public init(repoID: String, repo: String, runID: Int, title: String, pipeline: String, branch: String?,
                event: String?, state: State, isFinished: Bool, detail: String, startedAt: Date?, updatedAt: Date?,
                url: String) {
        self.repoID = repoID
        self.repo = repo
        self.runID = runID
        self.title = title
        self.pipeline = pipeline
        self.branch = branch
        self.event = event
        self.state = state
        self.isFinished = isFinished
        self.detail = detail
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.url = url
    }

    /// How long it ran, or has been running.
    public func duration(now: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (isFinished ? (updatedAt ?? now) : now).timeIntervalSince(startedAt))
    }
}

public struct DevChecks: Codable, Hashable, Sendable {
    public enum Overall: String, Sendable { case none, passing, failing, pending }

    public var passed: Int
    public var failed: Int
    public var pending: Int
    public var skipped: Int

    public init(passed: Int = 0, failed: Int = 0, pending: Int = 0, skipped: Int = 0) {
        self.passed = passed
        self.failed = failed
        self.pending = pending
        self.skipped = skipped
    }

    public var overall: Overall {
        if passed + failed + pending + skipped == 0 { return .none }
        if failed > 0 { return .failing }
        return pending > 0 ? .pending : .passing
    }
}

public enum DevReviewState: String, Codable, Sendable {
    case approved = "Approved"
    case changesRequested = "Changes requested"
    case required = "Review required"
    case none = "No review"
}

public struct DevPullRequest: Codable, Hashable, Identifiable, Sendable {
    /// The registry id of the repository. Names can repeat across owners.
    public var repoID: String
    /// The repository's name, for display.
    public var repo: String
    public var number: Int
    public var title: String
    public var author: String?
    public var headBranch: String?
    public var baseBranch: String?
    public var isDraft: Bool
    public var checks: DevChecks
    public var review: DevReviewState
    public var updatedAt: Date?
    public var url: String

    public var id: String { "\(repoID)#\(number)" }

    public init(repoID: String, repo: String, number: Int, title: String, author: String?, headBranch: String?,
                baseBranch: String?, isDraft: Bool, checks: DevChecks, review: DevReviewState, updatedAt: Date?,
                url: String) {
        self.repoID = repoID
        self.repo = repo
        self.number = number
        self.title = title
        self.author = author
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.isDraft = isDraft
        self.checks = checks
        self.review = review
        self.updatedAt = updatedAt
        self.url = url
    }
}

public struct DevPullComment: Hashable, Identifiable, Sendable {
    public var id: String
    public var author: String
    public var body: String
    public var date: Date?
    public var url: String?

    public init(id: String, author: String, body: String, date: Date?, url: String?) {
        self.id = id
        self.author = author
        self.body = body
        self.date = date
        self.url = url
    }
}

/// What the pull request viewer shows. Never cached: it can hold anything
/// the repository holds.
public struct DevPullDetail: Hashable, Sendable {
    public var body: String
    /// The commit this was read at. Reviews and merges are pinned to it.
    public var headSHA: String
    /// The branch it merges into, when it was read. An action is refused if
    /// the pull request has since been pointed at another one.
    public var baseRef: String
    /// The base commit the diff was read against.
    public var baseSHA: String
    public var commits: [DevCommit]
    public var comments: [DevPullComment]
    /// Unified diff text, of exactly `headSHA`.
    public var diff: String
    /// The diff was too large to read whole.
    public var truncated: Bool
    /// The whole diff is held back, because the app withholds some paths and
    /// one of its headers could not be read.
    public var diffIsWithheld = false
    /// Files taken out of the diff because the app withholds them.
    public var withheldFiles = 0

    public init(body: String, headSHA: String, baseRef: String, baseSHA: String, commits: [DevCommit],
                comments: [DevPullComment], diff: String, truncated: Bool) {
        self.body = body
        self.headSHA = headSHA
        self.baseRef = baseRef
        self.baseSHA = baseSHA
        self.commits = commits
        self.comments = comments
        self.diff = diff
        self.truncated = truncated
    }
}

public enum DevMergeMethod: String, CaseIterable, Hashable, Sendable {
    case squash = "Squash"
    case merge = "Merge Commit"
    case rebase = "Rebase"
}

/// What a person can do to a pull request from the viewer.
public enum DevPullAction: Hashable, Sendable {
    /// Approves `headSHA`. Refused if the head moved or the base branch is no
    /// longer `baseRef`. A base branch that merely advanced is fine.
    case approve(headSHA: String, baseRef: String)
    /// Requests changes on `headSHA`, under the same conditions as approve.
    case requestChanges(String, headSHA: String, baseRef: String)
    case comment(String)
    case markReady
    case convertToDraft
    /// Merges only if the head is still `headSHA` and the base branch is
    /// still `baseRef`. Never bypasses checks.
    case merge(DevMergeMethod, headSHA: String, baseRef: String)
    case close
}

/// The Development tab's view of a host. The tab shows only the segments its
/// `capabilities` declare.
public protocol DevelopmentProvider: Sendable {
    var kind: RepoProviderKind { get }
    var capabilities: ProviderCapabilities { get }
    /// Whether Markdown from this host may load an image from `url`.
    func allowsImage(_ url: URL?) -> Bool

    func commits(in repo: DevRepo) throws -> [DevCommit]
    func runs(in repo: DevRepo) throws -> [DevPipelineRun]
    func rerun(_ run: DevPipelineRun, in repo: DevRepo, failedOnly: Bool) throws
    func cancel(_ run: DevPipelineRun, in repo: DevRepo) throws
    func log(of run: DevPipelineRun, in repo: DevRepo) throws -> String

    func pullRequests(in repo: DevRepo) throws -> [DevPullRequest]
    func detail(of pull: DevPullRequest, in repo: DevRepo) throws -> DevPullDetail
    func perform(_ action: DevPullAction, on pull: DevPullRequest, in repo: DevRepo) throws
    /// Judges the pull request as it stands now.
    func risk(of pull: DevPullRequest, in repo: DevRepo) throws -> PullRequestRisk
    /// Checks out exactly the commit the request was judged at, in a worktree
    /// of `repo`. The lane opened there is always a plain shell.
    func checkOut(_ request: SafeLaneRequest, in repo: DevRepo) throws -> URL
}
