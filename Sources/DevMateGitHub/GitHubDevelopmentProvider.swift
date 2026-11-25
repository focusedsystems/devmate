import DevMateCore
import Foundation

/// The Development tab over the `gh` command. Each repository is read under
/// the owner in its registry `remote`, so one app can list several owners.
public struct GitHubDevelopmentProvider: DevelopmentProvider {
    public let defaultOwner: String
    private let executable: String?

    /// The most diff or log text read into the viewer.
    static let textLimit = 2_000_000

    public init(defaultOwner: String, executable: String? = ProcessRunner.find("gh")) {
        self.defaultOwner = defaultOwner
        self.executable = executable
    }

    public var kind: RepoProviderKind { .github }
    public var capabilities: ProviderCapabilities { [.pullRequests, .commits, .pipelines] }
    public func allowsImage(_ url: URL?) -> Bool { MarkdownImagePolicy.allows(url) }

    /// The owner and repository name from `owner/name`, a GitHub URL, or the
    /// repository's own name.
    static func address(of repo: DevRepo, defaultOwner: String) -> (owner: String, name: String) {
        var remote = (repo.remote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if remote.hasSuffix(".git") { remote.removeLast(4) }
        let parts = remote.replacingOccurrences(of: ":", with: "/").split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return (defaultOwner, parts.last ?? repo.name) }
        return (parts[parts.count - 2], parts[parts.count - 1])
    }

    private func client(_ repo: DevRepo) -> (gh: GitHubCLI, name: String) {
        let address = Self.address(of: repo, defaultOwner: defaultOwner)
        return (GitHubCLI(owner: address.owner, executable: executable), address.name)
    }

    public func commits(in repo: DevRepo) throws -> [DevCommit] {
        let (gh, name) = client(repo)
        return try gh.commits(repo: name).map {
            DevCommit(repoID: repo.id, repo: repo.name, sha: $0.sha, message: $0.message, author: $0.authorName ?? $0.authorLogin,
                      date: $0.date, url: $0.url)
        }
    }

    public func runs(in repo: DevRepo) throws -> [DevPipelineRun] {
        let (gh, name) = client(repo)
        return try gh.runs(repo: name).map { Self.run($0, repo: repo) }
    }

    static func run(_ run: WorkflowRun, repo: DevRepo) -> DevPipelineRun {
        DevPipelineRun(repoID: repo.id, repo: repo.name, runID: run.databaseId, title: run.displayTitle, pipeline: run.workflowName,
                       branch: run.headBranch, event: run.event,
                       state: DevPipelineRun.State(rawValue: run.state.rawValue) ?? .skipped,
                       isFinished: run.isFinished,
                       detail: [run.status, run.conclusion].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "),
                       startedAt: run.startedAt ?? run.createdAt, updatedAt: run.updatedAt, url: run.url)
    }

    /// An item is acted on only in the repository it was read from.
    private func require(_ repoID: String, in repo: DevRepo) throws {
        guard repoID == repo.id else {
            throw GitHubCLIError("This item belongs to a different repository from \(repo.name).")
        }
    }

    public func rerun(_ run: DevPipelineRun, in repo: DevRepo, failedOnly: Bool) throws {
        try require(run.repoID, in: repo)
        let (gh, name) = client(repo)
        try gh.rerun(repo: name, runID: run.runID, failedOnly: failedOnly)
    }

    public func cancel(_ run: DevPipelineRun, in repo: DevRepo) throws {
        try require(run.repoID, in: repo)
        let (gh, name) = client(repo)
        try gh.cancel(repo: name, runID: run.runID)
    }

    public func runDetail(for run: DevPipelineRun, in repo: DevRepo) -> (any RunDetailProvider)? {
        let (gh, name) = client(repo)
        return GitHubRunDetail(gh: gh, repo: name, runID: run.runID)
    }

    public func log(of run: DevPipelineRun, in repo: DevRepo) throws -> String {
        try require(run.repoID, in: repo)
        let (gh, name) = client(repo)
        let text = try gh.run(["run", "view", "\(run.runID)", "-R", gh.slug(name),
                               run.state == .failed ? "--log-failed" : "--log"], timeout: 120)
        return String(text.suffix(Self.textLimit))
    }

    public func pullRequests(in repo: DevRepo) throws -> [DevPullRequest] {
        let (gh, name) = client(repo)
        return try gh.pullRequests(repo: name).map { Self.pull($0, repo: repo) }
    }

    static func pull(_ pull: GitHubPullRequest, repo: DevRepo) -> DevPullRequest {
        let checks = pull.checks
        let review: DevReviewState = switch pull.review {
        case .approved: .approved
        case .changesRequested: .changesRequested
        case .required: .required
        case .none: .none
        }
        return DevPullRequest(repoID: repo.id, repo: repo.name, number: pull.number, title: pull.title, author: pull.author?.login,
                              headBranch: pull.headRefName, baseBranch: pull.baseRefName,
                              isDraft: pull.isDraft == true,
                              checks: DevChecks(passed: checks.passed, failed: checks.failed, pending: checks.pending,
                                                skipped: checks.skipped),
                              review: review, updatedAt: pull.updatedAt, url: pull.url)
    }

    struct PullView: Decodable {
        struct Person: Decodable {
            var login: String?
            var name: String?
        }

        struct Commit: Decodable {
            var oid: String
            var messageHeadline: String?
            var messageBody: String?
            var authors: [Person]?
            var committedDate: Date?
        }

        struct Comment: Decodable {
            var id: String
            var author: Person?
            var body: String?
            var createdAt: Date?
            var url: String?
        }

        var body: String?
        var headRefOid: String
        var commits: [Commit]?
        var comments: [Comment]?
    }

    static func detail(_ view: PullView, diff: String?, baseRef: String, baseSHA: String, repo: DevRepo,
                       url: String) -> DevPullDetail {
        let commits = (view.commits ?? []).map { commit -> DevCommit in
            let message = [commit.messageHeadline, commit.messageBody].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let person = commit.authors?.first
            return DevCommit(repoID: repo.id, repo: repo.name, sha: commit.oid, message: message, author: person?.name ?? person?.login,
                             date: commit.committedDate, url: url + "/commits/" + commit.oid)
        }
        let comments = (view.comments ?? []).map {
            DevPullComment(id: $0.id, author: $0.author?.login ?? "Unknown", body: $0.body ?? "", date: $0.createdAt,
                           url: $0.url)
        }
        let text = diff ?? ""
        return DevPullDetail(body: view.body ?? "", headSHA: view.headRefOid, baseRef: baseRef, baseSHA: baseSHA,
                             commits: commits, comments: comments,
                             diff: String(text.prefix(textLimit)), truncated: diff == nil || text.count > textLimit)
    }

    public func detail(of pull: DevPullRequest, in repo: DevRepo) throws -> DevPullDetail {
        try require(pull.repoID, in: repo)
        let (gh, name) = client(repo)
        // The commits are read once, and the diff is fetched between those
        // two commits, so it cannot describe anything else.
        for _ in 0..<Self.detailAttempts {
            let state = try Self.currentState(gh: gh, name: name, number: pull.number)
            let output = try gh.run(["pr", "view", "\(pull.number)", "-R", gh.slug(name), "--json",
                                     "body,headRefOid,commits,comments"])
            let view: PullView
            do {
                view = try GitHubJSON.decoder.decode(PullView.self, from: Data(output.utf8))
            } catch {
                throw GitHubCLIError("Could not read gh's answer: \(error.localizedDescription)")
            }
            // The description and commit list must be of the same head.
            guard view.headRefOid == state.head else { continue }
            // GitHub refuses a diff past its size limit; the rest still shows.
            let diff = try? gh.run(Self.compareArguments(slug: gh.slug(name), base: state.baseSHA, head: state.head),
                                   timeout: 60)
            return Self.detail(view, diff: diff, baseRef: state.baseRef, baseSHA: state.baseSHA, repo: repo,
                               url: pull.url)
        }
        throw GitHubCLIError("#\(pull.number) kept changing while it was being read. Try again.")
    }

    static let detailAttempts = 3

    /// The diff between two exact commits.
    static func compareArguments(slug: String, base: String, head: String) -> [String] {
        ["api", "-H", "Accept: application/vnd.github.diff", "repos/\(slug)/compare/\(base)...\(head)"]
    }

    struct PullState: Equatable {
        var head: String
        var baseRef: String
        var baseSHA: String
    }

    static func parseState(_ output: String) -> PullState? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        func isSHA(_ text: String) -> Bool { text.count == 40 && text.allSatisfy { "0123456789abcdef".contains($0) } }
        guard fields.count == 3, isSHA(fields[0]), !fields[1].isEmpty, isSHA(fields[2]) else { return nil }
        return PullState(head: fields[0], baseRef: fields[1], baseSHA: fields[2])
    }

    /// The pull request's head and base as GitHub has them now.
    static func currentState(gh: GitHubCLI, name: String, number: Int) throws -> PullState {
        let output = try gh.run(["api", "repos/\(gh.slug(name))/pulls/\(number)", "--jq",
                                 "[.head.sha, .base.ref, .base.sha] | @tsv"])
        guard let state = parseState(output) else {
            throw GitHubCLIError("GitHub gave an invalid head or base for #\(number).")
        }
        return state
    }

    /// Refuses an action on anything but what was on screen. A base branch
    /// that advanced is normal; one that was swapped is not.
    static func verify(_ state: PullState, head: String, baseRef: String, number: Int) throws {
        guard state.head == head else {
            throw GitHubCLIError("#\(number) has new commits since it was shown, so nothing was sent. Read it again.")
        }
        // By exact bytes: Swift treats canonically equivalent strings as equal,
        // and Git treats them as different branches.
        guard state.baseRef.utf8.elementsEqual(baseRef.utf8) else {
            throw GitHubCLIError("#\(number) now merges into \(state.baseRef) instead of \(baseRef), so nothing was sent. Read it again.")
        }
    }

    /// The `gh` arguments for an action. A review and a merge name the head
    /// they were made at, and a merge never passes `--admin`. `-f` sends text
    /// as a plain string, so a body starting with `@` is not read as a file.
    static func arguments(for action: DevPullAction, number: Int, slug: String) -> [String] {
        let target = ["\(number)", "-R", slug]
        switch action {
        case .approve(let head, _):
            return ["api", "--method", "POST", "repos/\(slug)/pulls/\(number)/reviews",
                    "-f", "event=APPROVE", "-f", "commit_id=\(head)"]
        case .requestChanges(let text, let head, _):
            return ["api", "--method", "POST", "repos/\(slug)/pulls/\(number)/reviews",
                    "-f", "event=REQUEST_CHANGES", "-f", "commit_id=\(head)", "-f", "body=\(text)"]
        case .comment(let text): return ["pr", "comment"] + target + ["--body", text]
        case .markReady: return ["pr", "ready"] + target
        case .convertToDraft: return ["pr", "ready"] + target + ["--undo"]
        case .close: return ["pr", "close"] + target
        case .merge(let method, let head, _):
            let flag = switch method {
            case .squash: "--squash"
            case .merge: "--merge"
            case .rebase: "--rebase"
            }
            return ["pr", "merge"] + target + [flag, "--match-head-commit", head]
        }
    }

    public func perform(_ action: DevPullAction, on pull: DevPullRequest, in repo: DevRepo) throws {
        try require(pull.repoID, in: repo)
        let (gh, name) = client(repo)
        switch action {
        case .approve(let head, let baseRef), .requestChanges(_, let head, let baseRef), .merge(_, let head, let baseRef):
            try Self.verify(try Self.currentState(gh: gh, name: name, number: pull.number), head: head,
                            baseRef: baseRef, number: pull.number)
        default:
            break
        }
        try gh.run(Self.arguments(for: action, number: pull.number, slug: gh.slug(name)), timeout: 60)
    }

    public func risk(of pull: DevPullRequest, in repo: DevRepo) throws -> PullRequestRisk {
        try require(pull.repoID, in: repo)
        let (gh, name) = client(repo)
        return try gh.risk(repo: name, number: pull.number)
    }

    public func checkOut(_ request: SafeLaneRequest, in repo: DevRepo) throws -> URL {
        let (gh, _) = client(repo)
        return try gh.checkOut(request, in: URL(fileURLWithPath: NSString(string: repo.path).expandingTildeInPath,
                                                isDirectory: true))
    }
}
