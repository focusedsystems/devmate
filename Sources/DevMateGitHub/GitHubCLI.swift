import DevMateCore
import Foundation

public struct GitHubCLIError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Everything an app asks GitHub goes through the `gh` the person is signed
/// in to. DevMate keeps no token of its own. Every call blocks, so callers
/// run them off the main thread.
public struct GitHubCLI: Sendable {
    public var owner: String
    public var executable: String?

    public init(owner: String, executable: String? = ProcessRunner.find("gh")) {
        self.owner = owner
        self.executable = executable
    }

    public func slug(_ repo: String) -> String { "\(owner)/\(repo)" }

    // MARK: Running

    @discardableResult
    public func run(_ arguments: [String], directory: URL? = nil, timeout: TimeInterval = 40) throws -> String {
        guard let executable else { throw GitHubCLIError("The GitHub CLI (gh) is not installed.") }
        guard let result = ProcessRunner.run(executable, arguments, directory: directory, timeout: timeout) else {
            throw GitHubCLIError("gh did not answer within \(Int(timeout)) seconds.")
        }
        guard result.status == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubCLIError(message.isEmpty ? "gh failed (exit \(result.status))." : message)
        }
        return result.output
    }

    func decode<T: Decodable>(_ type: T.Type, _ arguments: [String], directory: URL? = nil) throws -> T {
        let output = try run(arguments, directory: directory)
        do {
            return try GitHubJSON.decoder.decode(T.self, from: Data(output.utf8))
        } catch {
            throw GitHubCLIError("Could not read gh's answer: \(error.localizedDescription)")
        }
    }

    // MARK: Development

    public func commits(repo: String, limit: Int = 30) throws -> [GitHubCommit] {
        let rows = try decode([RESTCommit].self, ["api", "repos/\(slug(repo))/commits?per_page=\(limit)"])
        return rows.map {
            GitHubCommit(repo: repo, sha: $0.sha, message: $0.commit.message, authorName: $0.commit.author?.name,
                         authorLogin: $0.author?.login, date: $0.commit.author?.date, url: $0.html_url)
        }
    }

    static let runFields = "databaseId,displayTitle,workflowName,headBranch,event,status,conclusion,createdAt,startedAt,updatedAt,url,number,attempt"

    public func runs(repo: String, limit: Int = 20) throws -> [WorkflowRun] {
        var rows = try decode([WorkflowRun].self, ["run", "list", "-R", slug(repo), "--limit", "\(limit)", "--json", Self.runFields])
        for index in rows.indices { rows[index].repo = repo }
        return rows
    }

    public func rerun(repo: String, runID: Int, failedOnly: Bool) throws {
        var arguments = ["run", "rerun", "\(runID)", "-R", slug(repo)]
        if failedOnly { arguments.append("--failed") }
        try run(arguments)
    }

    public func cancel(repo: String, runID: Int) throws {
        try run(["run", "cancel", "\(runID)", "-R", slug(repo)])
    }

    static let pullFields = "number,title,author,headRefName,baseRefName,isDraft,reviewDecision,statusCheckRollup,url,createdAt,updatedAt,labels"

    public func pullRequests(repo: String) throws -> [GitHubPullRequest] {
        var rows = try decode([GitHubPullRequest].self, ["pr", "list", "-R", slug(repo), "--state", "open",
                                                         "--limit", "100", "--json", Self.pullFields])
        for index in rows.indices { rows[index].repo = repo }
        return rows
    }

    private struct PullSummary: Decodable {
        var association: String?
        var head: String
        var changed: Int
        var headRepo: String?
        var baseRepo: String?
        var baseRef: String?
        var defaultBranch: String?
    }

    static let pullSummaryFilter = "{association: .author_association, head: .head.sha, changed: .changed_files, "
        + "headRepo: .head.repo.full_name, baseRepo: .base.repo.full_name, baseRef: .base.ref, "
        + "defaultBranch: .base.repo.default_branch}"

    /// Whether the head lives anywhere but the base repository. An unknown
    /// repository counts as elsewhere.
    static func isFromFork(headRepo: String?, baseRepo: String?) -> Bool {
        guard let headRepo, let baseRepo, !headRepo.isEmpty else { return true }
        return headRepo.lowercased() != baseRepo.lowercased()
    }

    /// An unknown base or default branch does not count as the default.
    static func targetsDefault(baseRef: String?, defaultBranch: String?) -> Bool {
        guard let baseRef, let defaultBranch, !baseRef.isEmpty else { return false }
        return baseRef == defaultBranch
    }

    /// Who opened the pull request, where its head lives, what it merges
    /// into, and which of its files configure agents or hooks.
    public func risk(repo: String, number: Int) throws -> PullRequestRisk {
        func summary() throws -> PullSummary {
            try decode(PullSummary.self, ["api", "repos/\(slug(repo))/pulls/\(number)", "--jq", Self.pullSummaryFilter])
        }
        let before = try summary()
        // One array per page, decoded as JSON, so a newline in a file name
        // cannot change the count.
        let pages = try decode([[PullRequestFile]].self, ["api", "--paginate", "--slurp",
                                                          "repos/\(slug(repo))/pulls/\(number)/files?per_page=100"])
        let tree = try decode(GitTree.self, ["api", "repos/\(slug(repo))/git/trees/\(before.head)?recursive=1"])
        let after = try summary()
        guard before.head == after.head, before.baseRef == after.baseRef, before.headRepo == after.headRepo else {
            throw GitHubCLIError("#\(number) changed while it was being checked. Try again.")
        }
        let subject = LaneItemReference(provider: .gitHub, owner: owner, repo: repo, number: number,
                                        url: "https://github.com/\(slug(repo))/pull/\(number)")
        return .evaluate(subject: subject, authorAssociation: after.association ?? "", files: pages.flatMap { $0 },
                         headSHA: after.head, changedFiles: after.changed, tree: tree,
                         isFromFork: Self.isFromFork(headRepo: after.headRepo, baseRepo: after.baseRepo),
                         baseBranch: after.baseRef ?? "",
                         targetsDefaultBranch: Self.targetsDefault(baseRef: after.baseRef,
                                                                   defaultBranch: after.defaultBranch))
    }

    /// Checks the pull request out at exactly the commit the risk check read,
    /// in a worktree of its own named for that commit. A worktree is never
    /// updated: a branch that moves gets a new one, so files under a running
    /// lane never change.
    public func checkOut(_ request: SafeLaneRequest, in folder: URL) throws -> URL {
        let reference = request.reference
        guard reference.provider == .gitHub, reference.owner == owner, let head = request.head else {
            throw GitHubCLIError("This lane request is not for a pull request of \(owner).")
        }
        let name = Self.checkoutName(repo: reference.repo, number: reference.number, head: head, reviewed: true)
        return try Self.prepareWorktree(in: folder, name: name, head: head)
    }

    static func checkoutName(repo: String, number: Int, head: String, reviewed: Bool) -> String {
        "\(repo)-pr-\(number)-\(head.prefix(12))" + (reviewed ? "-review" : "")
    }

    /// Checking a branch out must not download anything it names, so Git LFS
    /// leaves pointer files in place.
    static let checkoutEnvironment = ["GIT_LFS_SKIP_SMUDGE": "1"]

    /// How many worktrees one commit may have before asking for a clean-up.
    static let worktreeAttempts = 20

    /// Fetches the exact commit, verifies it, and only then adds a worktree
    /// detached at it. An existing worktree is reused only if it is at that
    /// commit and has no changed, untracked or ignored files; a dirty one is
    /// left alone and the checkout gets a new one. Repository hooks do not run.
    static func prepareWorktree(in folder: URL, name: String, head: String) throws -> URL {
        guard head.count == 40, head.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw GitHubCLIError("GitHub gave an invalid commit for this pull request.")
        }
        func git(_ directory: URL, _ arguments: [String], timeout: TimeInterval = 90) -> ProcessRunner.Result? {
            ProcessRunner.run("/usr/bin/git", ["-C", directory.path, "-c", "core.hooksPath=/dev/null",
                                               "-c", "core.fsmonitor=false"] + arguments,
                              environment: checkoutEnvironment, timeout: timeout)
        }
        func resolved(_ directory: URL, _ revision: String) -> String? {
            guard let result = git(directory, ["rev-parse", "--verify", "--quiet", revision], timeout: 10),
                  result.status == 0 else { return nil }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// The folder is the top of its own worktree, with nothing in it
        /// beyond the commit. Anything uncertain counts as dirty.
        func isClean(_ directory: URL) -> Bool {
            guard let prefix = git(directory, ["rev-parse", "--show-prefix"], timeout: 10), prefix.status == 0,
                  prefix.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let status = git(directory, ["status", "--porcelain", "--ignored", "--untracked-files=all"],
                                   timeout: 30), status.status == 0 else { return false }
            return status.output.isEmpty
        }
        var candidate = name
        var attempt = 1
        var worktree = folder.appendingPathComponent(".worktrees/\(candidate)", isDirectory: true)
        while FileManager.default.fileExists(atPath: worktree.path) {
            guard resolved(worktree, "HEAD") == head else {
                throw GitHubCLIError("The worktree \(candidate) is not at the checked commit, so it was left alone and no lane was opened.")
            }
            if isClean(worktree) { return worktree }
            attempt += 1
            guard attempt <= worktreeAttempts else {
                throw GitHubCLIError("Every worktree for \(name) has local changes. Remove one and try again.")
            }
            candidate = "\(name)-\(attempt)"
            worktree = folder.appendingPathComponent(".worktrees/\(candidate)", isDirectory: true)
        }
        guard let fetch = git(folder, ["fetch", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head",
                                       "origin", head]), fetch.status == 0,
              resolved(folder, head + "^{commit}") == head else {
            throw GitHubCLIError("git could not fetch commit \(head.prefix(12)), so no lane was opened.")
        }
        guard let add = git(folder, ["worktree", "add", "--detach", worktree.path, head]), add.status == 0,
              resolved(worktree, "HEAD") == head else {
            throw GitHubCLIError("git could not add the worktree \(candidate).")
        }
        return worktree
    }

    // MARK: Issues

    static let issueFields = "number,title,state,stateReason,author,labels,assignees,milestone,createdAt,updatedAt,closedAt,url"

    /// `state` is open, closed or all.
    public func issues(repo: String, state: String = "all", limit: Int = 300) throws -> [GitHubIssue] {
        var rows = try decode([GitHubIssue].self, ["issue", "list", "-R", slug(repo), "--state", state,
                                                   "--limit", "\(limit)", "--json", Self.issueFields])
        for index in rows.indices { rows[index].repo = repo }
        return rows
    }

    public func issue(repo: String, number: Int) throws -> GitHubIssue {
        var issue = try decode(GitHubIssue.self, ["issue", "view", "\(number)", "-R", slug(repo), "--json",
                                                  Self.issueFields + ",body,comments"])
        issue.repo = repo
        return issue
    }

    static let linkedQuery = """
    query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){\
    closedByPullRequestsReferences(first:20, includeClosedPrs:true){nodes{number title url state repository{name}}} \
    timelineItems(first:50, itemTypes:[CROSS_REFERENCED_EVENT, CONNECTED_EVENT]){nodes{__typename \
    ... on CrossReferencedEvent{source{__typename ... on PullRequest{number title url state repository{name}}}} \
    ... on ConnectedEvent{subject{__typename ... on PullRequest{number title url state repository{name}}}}}}}}}
    """

    public func linkedPullRequests(repo: String, number: Int) throws -> [LinkedPullRequest] {
        let output = try run(["api", "graphql", "-f", "query=\(Self.linkedQuery)", "-f", "owner=\(owner)",
                              "-f", "name=\(repo)", "-F", "number=\(number)"])
        return GitHubJSON.linkedPullRequests(from: Data(output.utf8))
    }

    public func labels(repo: String) throws -> [GitHubLabel] {
        try decode([GitHubLabel].self, ["label", "list", "-R", slug(repo), "--limit", "200",
                                        "--json", "name,color,description"])
    }

    public func milestones(repo: String) throws -> [GitHubMilestone] {
        try decode([GitHubMilestone].self, ["api", "repos/\(slug(repo))/milestones?state=open&per_page=100"])
    }

    public func assignableUsers(repo: String) throws -> [GitHubUser] {
        try decode([GitHubUser].self, ["api", "repos/\(slug(repo))/assignees?per_page=100"])
    }

    /// Returns the new issue's address.
    public func createIssue(repo: String, title: String, body: String, labels: [String], assignees: [String],
                            milestone: String?) throws -> String {
        var arguments = ["issue", "create", "-R", slug(repo), "--title", title, "--body", body]
        for label in labels { arguments += ["--label", label] }
        for login in assignees { arguments += ["--assignee", login] }
        if let milestone { arguments += ["--milestone", milestone] }
        return try run(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum MilestoneChange: Sendable, Equatable { case set(String), remove }

    public func editIssue(repo: String, number: Int, title: String? = nil, body: String? = nil,
                          addLabels: [String] = [], removeLabels: [String] = [],
                          addAssignees: [String] = [], removeAssignees: [String] = [],
                          milestone: MilestoneChange? = nil) throws {
        let arguments = Self.editArguments(slug: slug(repo), number: number, title: title, body: body,
                                           addLabels: addLabels, removeLabels: removeLabels,
                                           addAssignees: addAssignees, removeAssignees: removeAssignees,
                                           milestone: milestone)
        guard arguments.count > 5 else { return }
        try run(arguments)
    }

    static func editArguments(slug: String, number: Int, title: String?, body: String?,
                              addLabels: [String], removeLabels: [String],
                              addAssignees: [String], removeAssignees: [String],
                              milestone: MilestoneChange?) -> [String] {
        var arguments = ["issue", "edit", "\(number)", "-R", slug]
        if let title { arguments += ["--title", title] }
        if let body { arguments += ["--body", body] }
        if !addLabels.isEmpty { arguments += ["--add-label", addLabels.joined(separator: ",")] }
        if !removeLabels.isEmpty { arguments += ["--remove-label", removeLabels.joined(separator: ",")] }
        if !addAssignees.isEmpty { arguments += ["--add-assignee", addAssignees.joined(separator: ",")] }
        if !removeAssignees.isEmpty { arguments += ["--remove-assignee", removeAssignees.joined(separator: ",")] }
        switch milestone {
        case .set(let title): arguments += ["--milestone", title]
        case .remove: arguments.append("--remove-milestone")
        case nil: break
        }
        return arguments
    }

    public func comment(repo: String, number: Int, body: String) throws {
        try run(["issue", "comment", "\(number)", "-R", slug(repo), "--body", body])
    }

    public enum CloseReason: String, Sendable, CaseIterable {
        case completed
        case notPlanned = "not planned"
    }

    public func close(repo: String, number: Int, reason: CloseReason) throws {
        try run(["issue", "close", "\(number)", "-R", slug(repo), "--reason", reason.rawValue])
    }

    public func reopen(repo: String, number: Int) throws {
        try run(["issue", "reopen", "\(number)", "-R", slug(repo)])
    }

    // MARK: Projects (v2)

    public func projects() throws -> [GitHubProject] {
        let output = try run(["project", "list", "--owner", owner, "--format", "json"])
        return GitHubJSON.projects(from: Data(output.utf8))
    }

    public func board(for project: GitHubProject) throws -> ProjectBoard {
        let fields = try run(["project", "field-list", "\(project.number)", "--owner", owner, "--format", "json"])
        let items = try run(["project", "item-list", "\(project.number)", "--owner", owner, "--format", "json",
                             "--limit", "500"])
        return ProjectBoard(project: project, status: GitHubJSON.statusField(from: Data(fields.utf8)),
                            items: GitHubJSON.projectItems(from: Data(items.utf8)))
    }

    public func move(_ item: ProjectItem, on board: ProjectBoard, to option: ProjectStatusField.Option) throws {
        guard let field = board.status else { throw GitHubCLIError("The project has no Status field.") }
        try run(["project", "item-edit", "--id", item.id, "--project-id", board.project.id,
                 "--field-id", field.id, "--single-select-option-id", option.id])
    }
}

/// Decoding for `gh`'s JSON, kept apart from running it so it can be tested.
public enum GitHubJSON {
    public static var decoder: JSONDecoder { DevMateJSON.decoder }
    public static var encoder: JSONEncoder { DevMateJSON.encoder }

    public static func parseDate(_ text: String) -> Date? { DevMateJSON.parseDate(text) }

    static func object(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    /// Pull requests that close the issue first, then ones that mention it,
    /// each once.
    public static func linkedPullRequests(from data: Data) -> [LinkedPullRequest] {
        guard let root = object(data) as? [String: Any],
              let issue = ((root["data"] as? [String: Any])?["repository"] as? [String: Any])?["issue"] as? [String: Any]
        else { return [] }
        var result: [LinkedPullRequest] = []
        func add(_ node: [String: Any]?, closes: Bool) {
            guard let node, let number = node["number"] as? Int else { return }
            let repo = (node["repository"] as? [String: Any])?["name"] as? String ?? ""
            if let index = result.firstIndex(where: { $0.repo == repo && $0.number == number }) {
                if closes { result[index].closesIssue = true }
                return
            }
            result.append(LinkedPullRequest(repo: repo, number: number, title: node["title"] as? String ?? "",
                                            url: node["url"] as? String ?? "", state: node["state"] as? String ?? "",
                                            closesIssue: closes))
        }
        let closing = ((issue["closedByPullRequestsReferences"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        closing.forEach { add($0, closes: true) }
        let timeline = ((issue["timelineItems"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        for node in timeline {
            let pull = (node["source"] as? [String: Any]) ?? (node["subject"] as? [String: Any])
            if pull?["__typename"] as? String == "PullRequest" { add(pull, closes: false) }
        }
        return result
    }

    public static func projects(from data: Data) -> [GitHubProject] {
        guard let root = object(data) as? [String: Any], let rows = root["projects"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let number = row["number"] as? Int else { return nil }
            return GitHubProject(id: id, number: number, title: row["title"] as? String ?? "Project \(number)",
                                 url: row["url"] as? String, closed: row["closed"] as? Bool)
        }
    }

    /// The single-select field named Status, or the first single-select
    /// field when none is.
    public static func statusField(from data: Data) -> ProjectStatusField? {
        guard let root = object(data) as? [String: Any], let rows = root["fields"] as? [[String: Any]] else { return nil }
        let selects = rows.filter { $0["options"] is [[String: Any]] }
        guard let row = selects.first(where: { ($0["name"] as? String)?.lowercased() == "status" }) ?? selects.first,
              let id = row["id"] as? String else { return nil }
        let options = (row["options"] as? [[String: Any]] ?? []).compactMap { option -> ProjectStatusField.Option? in
            guard let id = option["id"] as? String, let name = option["name"] as? String else { return nil }
            return .init(id: id, name: name)
        }
        return ProjectStatusField(id: id, name: row["name"] as? String ?? "Status", options: options)
    }

    public static func projectItems(from data: Data) -> [ProjectItem] {
        guard let root = object(data) as? [String: Any], let rows = root["items"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let content = row["content"] as? [String: Any] ?? [:]
            let repository = (content["repository"] as? String) ?? (row["repository"] as? String)
            let repo = repository.map { ($0 as NSString).lastPathComponent }
            let title = (content["title"] as? String) ?? (row["title"] as? String) ?? "Untitled"
            return ProjectItem(id: id, title: title, status: row["status"] as? String, type: content["type"] as? String,
                               number: content["number"] as? Int, repo: repo, url: content["url"] as? String)
        }
    }
}
