import DevMateCore
import Foundation

/// The Development tab over the `az` command. Each repository is read under
/// the project in its registry `remote` (`Project/Repo`); the app supplies the
/// organisation and a default project.
///
/// Not offered, because Azure DevOps has no equivalent through the CLI: the
/// result of each branch policy on a pull request (its checks column stays
/// empty), and re-running only the failed jobs of a run.
public struct AzureDevelopmentProvider: DevelopmentProvider {
    public let cli: AzureCLI
    /// Signs the run view's requests in. Defaults to the `az` login; an app
    /// with its own sign-in passes its token here.
    public let token: AzureTokenProvider

    /// The most diff or log text read into the viewer.
    static let textLimit = 2_000_000

    public init(cli: AzureCLI, token: AzureTokenProvider? = nil) {
        self.cli = cli
        let tokens = AzureCLITokens(executable: cli.executable)
        self.token = token ?? { try await tokens.token() }
    }

    public init(organization: String, defaultProject: String? = nil, token: AzureTokenProvider? = nil) {
        self.init(cli: AzureCLI(organization: organization, defaultProject: defaultProject), token: token)
    }

    public func runDetail(for run: DevPipelineRun, in repo: DevRepo) -> (any RunDetailProvider)? {
        guard let (project, _) = try? cli.address(of: repo) else { return nil }
        return AzureRunDetail(organization: cli.organization, project: project, buildID: run.runID, token: token)
    }

    public var kind: RepoProviderKind { .azureDevOps }
    public var capabilities: ProviderCapabilities { [.pullRequests, .commits, .pipelines] }
    /// Images in Azure DevOps need its sign-in, so none load.
    public func allowsImage(_ url: URL?) -> Bool { false }

    private func repoPath(_ name: String) -> String { "git/repositories/\(AzureCLI.encode(name))" }

    /// An item is acted on only in the repository it was read from.
    private func require(_ repoID: String, in repo: DevRepo) throws {
        guard repoID == repo.id else {
            throw AzureCLIError("This item belongs to a different repository from \(repo.name).")
        }
    }

    // MARK: Commits and runs

    public func commits(in repo: DevRepo) throws -> [DevCommit] {
        let (project, name) = try cli.address(of: repo)
        let rows = try cli.decode(AzList<AzCommit>.self, project: project, path: repoPath(name) + "/commits",
                                  query: [("searchCriteria.$top", "30")]).value
        return rows.map {
            DevCommit(repoID: repo.id, repo: repo.name, sha: $0.commitId, message: $0.comment ?? "",
                      author: $0.author?.name, date: $0.author?.date,
                      url: cli.webURL(project: project, repo: name, suffix: "commit/\($0.commitId)"))
        }
    }

    private func repository(_ name: String, project: String) throws -> AzRepository {
        try cli.decode(AzRepository.self, project: project, path: repoPath(name))
    }

    public func runs(in repo: DevRepo) throws -> [DevPipelineRun] {
        let (project, name) = try cli.address(of: repo)
        let id = try repository(name, project: project).id
        let builds = try cli.decode(AzList<AzBuild>.self, project: project, path: "build/builds",
                                    query: [("repositoryId", id), ("repositoryType", "TfsGit"), ("$top", "20"),
                                            ("queryOrder", "queueTimeDescending")]).value
        return builds.map { AzureMapping.run($0, repo: repo, project: project, cli: cli) }
    }

    public func rerun(_ run: DevPipelineRun, in repo: DevRepo, failedOnly: Bool) throws {
        try require(run.repoID, in: repo)
        guard !failedOnly else {
            throw AzureCLIError("Azure DevOps cannot re-run only the failed jobs from here. Run it again in full.")
        }
        let (project, _) = try cli.address(of: repo)
        let build = try cli.decode(AzBuild.self, project: project, path: "build/builds/\(run.runID)")
        guard let definition = build.definition?.id else { throw AzureCLIError("The run has no pipeline to queue.") }
        try cli.request(method: "POST", project: project, path: "build/builds",
                        body: Self.queueBody(definition: definition, branch: build.sourceBranch,
                                             version: build.sourceVersion),
                        contentType: "application/json", timeout: 60)
    }

    static func queueBody(definition: Int, branch: String?, version: String?) -> String {
        var body: [String: Any] = ["definition": ["id": definition]]
        if let branch { body["sourceBranch"] = branch }
        if let version { body["sourceVersion"] = version }
        return AzureJSON.text(body)
    }

    public func cancel(_ run: DevPipelineRun, in repo: DevRepo) throws {
        try require(run.repoID, in: repo)
        let (project, _) = try cli.address(of: repo)
        try cli.request(method: "PATCH", project: project, path: "build/builds/\(run.runID)",
                        body: AzureJSON.text(["status": "cancelling"]), contentType: "application/json")
    }

    public func log(of run: DevPipelineRun, in repo: DevRepo) throws -> String {
        try require(run.repoID, in: repo)
        let (project, _) = try cli.address(of: repo)
        let timeline = try cli.decode(AzTimeline.self, project: project, path: "build/builds/\(run.runID)/timeline")
        var ids = timeline.records.filter { run.state == .failed ? $0.result == "failed" : true }
            .sorted { ($0.order ?? 0) < ($1.order ?? 0) }.compactMap { $0.log?.id }
        if ids.isEmpty { ids = timeline.records.compactMap { $0.log?.id } }
        var text = ""
        for id in ids.prefix(60) {
            let part = try cli.request(project: project, path: "build/builds/\(run.runID)/logs/\(id)", timeout: 60)
            text += part + "\n"
            if text.count > Self.textLimit { break }
        }
        return String(text.suffix(Self.textLimit))
    }

    // MARK: Pull requests

    public func pullRequests(in repo: DevRepo) throws -> [DevPullRequest] {
        let (project, name) = try cli.address(of: repo)
        let rows = try cli.decode(AzList<AzPull>.self, project: project, path: repoPath(name) + "/pullrequests",
                                  query: [("searchCriteria.status", "active"), ("$top", "100")]).value
        return rows.map { AzureMapping.pull($0, repo: repo, project: project, name: name, cli: cli) }
    }

    func pull(_ number: Int, project: String, name: String) throws -> AzPull {
        try cli.decode(AzPull.self, project: project, path: repoPath(name) + "/pullrequests/\(number)")
    }

    static let detailAttempts = 3

    public func detail(of pull: DevPullRequest, in repo: DevRepo) throws -> DevPullDetail {
        try require(pull.repoID, in: repo)
        let (project, name) = try cli.address(of: repo)
        let base = repoPath(name) + "/pullrequests/\(pull.number)"
        for _ in 0..<Self.detailAttempts {
            let before = try self.pull(pull.number, project: project, name: name)
            guard let head = before.lastMergeSourceCommit?.commitId, let baseSHA = before.lastMergeTargetCommit?.commitId,
                  let baseRef = AzureJSON.branch(before.targetRefName) else {
                throw AzureCLIError("#\(pull.number) has no merge commit yet, so there is nothing to show.")
            }
            let commits = try cli.decode(AzList<AzCommit>.self, project: project, path: base + "/commits").value.map {
                DevCommit(repoID: repo.id, repo: repo.name, sha: $0.commitId, message: $0.comment ?? "",
                          author: $0.author?.name, date: $0.author?.date,
                          url: cli.webURL(project: project, repo: name, suffix: "commit/\($0.commitId)"))
            }
            let threads = try cli.decode(AzList<AzThread>.self, project: project, path: base + "/threads").value
            let comments = Self.comments(threads)
            let diff = Self.localDiff(in: repo, base: baseSHA, head: head)
            let after = try self.pull(pull.number, project: project, name: name)
            guard after.lastMergeSourceCommit?.commitId == head else { continue }
            let text = diff ?? ""
            return DevPullDetail(body: before.description ?? "", headSHA: head, baseRef: baseRef, baseSHA: baseSHA,
                                 commits: commits, comments: comments, diff: String(text.prefix(Self.textLimit)),
                                 truncated: diff == nil || text.count > Self.textLimit)
        }
        throw AzureCLIError("#\(pull.number) kept changing while it was being read. Try again.")
    }

    /// Comments people wrote, not the system's notes about votes and pushes.
    static func comments(_ threads: [AzThread]) -> [DevPullComment] {
        threads.filter { $0.isDeleted != true }.flatMap { thread in
            (thread.comments ?? []).filter { $0.isDeleted != true && $0.commentType?.lowercased() != "system" }.map {
                DevPullComment(id: "\(thread.id)-\($0.id)", author: $0.author?.displayName ?? "Unknown",
                               body: $0.content ?? "", date: $0.publishedDate, url: nil)
            }
        }
    }

    // MARK: Local Git

    private static func git(_ directory: URL, _ arguments: [String], timeout: TimeInterval = 90) -> ProcessRunner.Result? {
        ProcessRunner.run("/usr/bin/git", ["-C", directory.path, "-c", "core.hooksPath=/dev/null",
                                           "-c", "core.fsmonitor=false"] + arguments,
                          environment: ["GIT_LFS_SKIP_SMUDGE": "1", "GIT_TERMINAL_PROMPT": "0"], timeout: timeout)
    }

    private static func folder(of repo: DevRepo) -> URL {
        URL(fileURLWithPath: NSString(string: repo.path).expandingTildeInPath, isDirectory: true)
    }

    static func isSHA(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Fetches the exact commit and confirms it resolved to itself.
    @discardableResult
    static func fetch(_ sha: String, in folder: URL) -> Bool {
        guard isSHA(sha) else { return false }
        if let have = git(folder, ["rev-parse", "--verify", "--quiet", sha + "^{commit}"], timeout: 10), have.status == 0,
           have.output.trimmingCharacters(in: .whitespacesAndNewlines) == sha { return true }
        guard let fetch = git(folder, ["fetch", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head",
                                       "origin", sha]), fetch.status == 0,
              let found = git(folder, ["rev-parse", "--verify", "--quiet", sha + "^{commit}"], timeout: 10),
              found.status == 0 else { return false }
        return found.output.trimmingCharacters(in: .whitespacesAndNewlines) == sha
    }

    /// Azure DevOps has no unified diff over its API, so the diff comes from
    /// the local clone, between the exact commits. Nil when it cannot be read.
    static func localDiff(in repo: DevRepo, base: String, head: String) -> String? {
        let folder = folder(of: repo)
        guard fetch(base, in: folder), fetch(head, in: folder),
              let result = git(folder, ["diff", "--no-color", "--no-ext-diff", "--no-textconv", base + "..." + head],
                               timeout: 60), result.status == 0 else { return nil }
        return result.output
    }

    /// File modes at a commit, from the local clone.
    static func localTree(in repo: DevRepo, head: String) -> GitTree {
        let folder = folder(of: repo)
        guard fetch(head, in: folder), let result = git(folder, ["ls-tree", "-r", "-z", head], timeout: 60),
              result.status == 0 else { return GitTree(truncated: true, tree: []) }
        return parseTree(result.output)
    }

    static func parseTree(_ output: String) -> GitTree {
        let entries = output.split(separator: "\0").compactMap { record -> GitTree.Entry? in
            guard let tab = record.firstIndex(of: "\t") else { return nil }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3 else { return nil }
            return GitTree.Entry(path: String(record[record.index(after: tab)...]), mode: String(fields[0]))
        }
        return GitTree(truncated: false, tree: entries)
    }

    // MARK: Actions

    /// What Azure DevOps is sent for an action: method, path under the
    /// repository's pull request, and JSON body.
    struct Call: Equatable {
        var method: String
        var path: String
        var body: String
    }

    static func call(for action: DevPullAction, number: Int, reviewer: String?) throws -> [Call] {
        let pull = "pullrequests/\(number)"
        func vote(_ value: Int) throws -> Call {
            guard let reviewer else { throw AzureCLIError("Azure DevOps did not say who is signed in, so no vote was sent.") }
            return Call(method: "PUT", path: "\(pull)/reviewers/\(reviewer)", body: AzureJSON.text(["vote": value]))
        }
        func thread(_ text: String) -> Call {
            Call(method: "POST", path: "\(pull)/threads",
                 body: AzureJSON.text(["comments": [["parentCommentId": 0, "content": text, "commentType": 1]],
                                       "status": 1]))
        }
        switch action {
        case .approve:
            return [try vote(AzureMapping.Vote.approved)]
        case .requestChanges(let text, _, _):
            var calls = [try vote(AzureMapping.Vote.waitingForAuthor)]
            if !text.isEmpty { calls.append(thread(text)) }
            return calls
        case .comment(let text):
            return [thread(text)]
        case .markReady:
            return [Call(method: "PATCH", path: pull, body: AzureJSON.text(["isDraft": false]))]
        case .convertToDraft:
            return [Call(method: "PATCH", path: pull, body: AzureJSON.text(["isDraft": true]))]
        case .close:
            return [Call(method: "PATCH", path: pull, body: AzureJSON.text(["status": "abandoned"]))]
        case .merge(let method, let head, _):
            let strategy = switch method {
            case .squash: "squash"
            case .merge: "noFastForward"
            case .rebase: "rebase"
            }
            // No policy bypass: branch policies decide whether this completes.
            return [Call(method: "PATCH", path: pull,
                         body: AzureJSON.text(["status": "completed", "lastMergeSourceCommit": ["commitId": head],
                                               "completionOptions": ["mergeStrategy": strategy,
                                                                     "deleteSourceBranch": false]]))]
        }
    }

    /// Refuses an action on anything but what was on screen. A base branch
    /// that advanced is normal; one that was swapped is not.
    static func verify(_ pull: AzPull, head: String, baseRef: String, number: Int) throws {
        guard pull.lastMergeSourceCommit?.commitId == head else {
            throw AzureCLIError("#\(number) has new commits since it was shown, so nothing was sent. Read it again.")
        }
        let now = AzureJSON.branch(pull.targetRefName) ?? ""
        guard now.utf8.elementsEqual(baseRef.utf8) else {
            throw AzureCLIError("#\(number) now merges into \(now) instead of \(baseRef), so nothing was sent. Read it again.")
        }
    }

    public func perform(_ action: DevPullAction, on pull: DevPullRequest, in repo: DevRepo) throws {
        try require(pull.repoID, in: repo)
        let (project, name) = try cli.address(of: repo)
        switch action {
        case .approve(let head, let baseRef), .requestChanges(_, let head, let baseRef), .merge(_, let head, let baseRef):
            try Self.verify(try self.pull(pull.number, project: project, name: name), head: head, baseRef: baseRef,
                            number: pull.number)
        default:
            break
        }
        var reviewer: String?
        switch action {
        case .approve, .requestChanges:
            let connection = try cli.decode(AzConnection.self, project: nil, path: "connectionData",
                                            apiVersion: "7.1-preview.1")
            reviewer = connection.authenticatedUser?.id
        default:
            break
        }
        for call in try Self.call(for: action, number: pull.number, reviewer: reviewer) {
            try cli.request(method: call.method, project: project, path: repoPath(name) + "/" + call.path,
                            body: call.body, contentType: "application/json", timeout: 60)
        }
    }

    // MARK: Risk and checkout

    public func risk(of pull: DevPullRequest, in repo: DevRepo) throws -> PullRequestRisk {
        try require(pull.repoID, in: repo)
        let (project, name) = try cli.address(of: repo)
        let before = try self.pull(pull.number, project: project, name: name)
        guard let head = before.lastMergeSourceCommit?.commitId else {
            throw AzureCLIError("#\(pull.number) has no merge commit yet, so it cannot be checked.")
        }
        let base = repoPath(name) + "/pullrequests/\(pull.number)"
        let iterations = try cli.decode(AzIterations.self, project: project, path: base + "/iterations")
        guard let last = iterations.value.map(\.id).max() else {
            throw AzureCLIError("#\(pull.number) has no changes to check.")
        }
        var entries: [AzIterationChanges.Entry] = []
        var skip = 0
        var finished = false
        for _ in 0..<30 {
            let page = try cli.decode(AzIterationChanges.self, project: project,
                                      path: base + "/iterations/\(last)/changes",
                                      query: [("$top", "100"), ("$skip", "\(skip)")])
            entries += page.changeEntries
            guard let next = page.nextSkip, next > 0 else { finished = true; break }
            skip = next
        }
        let files = Self.files(entries)
        let tree = Self.localTree(in: repo, head: head)
        let repository = try repository(name, project: project)
        let after = try self.pull(pull.number, project: project, name: name)
        guard after.lastMergeSourceCommit?.commitId == head, after.targetRefName == before.targetRefName else {
            throw AzureCLIError("#\(pull.number) changed while it was being checked. Try again.")
        }
        let subject = LaneItemReference(provider: .azureDevOps, owner: project, repo: name, number: pull.number,
                                        url: pull.url)
        let fromFork = after.forkSource != nil
        return .evaluate(subject: subject, authorAssociation: fromFork ? "NONE" : "MEMBER", files: files,
                         headSHA: head, changedFiles: finished ? files.count : files.count + 1, tree: tree,
                         isFromFork: fromFork, baseBranch: AzureJSON.branch(after.targetRefName) ?? "",
                         targetsDefaultBranch: after.targetRefName != nil && after.targetRefName == repository.defaultBranch)
    }

    static func files(_ entries: [AzIterationChanges.Entry]) -> [PullRequestFile] {
        entries.compactMap { entry in
            guard let path = entry.item?.path, !path.isEmpty else { return nil }
            func trimmed(_ text: String) -> String { text.hasPrefix("/") ? String(text.dropFirst()) : text }
            let type = (entry.changeType ?? "").lowercased()
            return PullRequestFile(filename: trimmed(path), previousFilename: entry.originalPath.map(trimmed),
                                   status: type.contains("delete") ? "removed" : "modified")
        }
    }

    public func checkOut(_ request: SafeLaneRequest, in repo: DevRepo) throws -> URL {
        let reference = request.reference
        guard reference.provider == .azureDevOps, let head = request.head, Self.isSHA(head) else {
            throw AzureCLIError("This lane request is not for a pull request in Azure DevOps.")
        }
        let folder = Self.folder(of: repo)
        let name = "\(reference.repo)-pr-\(reference.number)-\(head.prefix(12))-review"
        func git(_ directory: URL, _ arguments: [String], timeout: TimeInterval = 90) -> ProcessRunner.Result? {
            Self.git(directory, arguments, timeout: timeout)
        }
        func resolved(_ directory: URL, _ revision: String) -> String? {
            guard let result = git(directory, ["rev-parse", "--verify", "--quiet", revision], timeout: 10),
                  result.status == 0 else { return nil }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
                throw AzureCLIError("The worktree \(candidate) is not at the checked commit, so it was left alone and no lane was opened.")
            }
            if isClean(worktree) { return worktree }
            attempt += 1
            guard attempt <= 20 else {
                throw AzureCLIError("Every worktree for \(name) has local changes. Remove one and try again.")
            }
            candidate = "\(name)-\(attempt)"
            worktree = folder.appendingPathComponent(".worktrees/\(candidate)", isDirectory: true)
        }
        guard Self.fetch(head, in: folder) else {
            throw AzureCLIError("git could not fetch commit \(head.prefix(12)), so no lane was opened.")
        }
        guard let add = git(folder, ["worktree", "add", "--detach", worktree.path, head]), add.status == 0,
              resolved(worktree, "HEAD") == head else {
            throw AzureCLIError("git could not add the worktree \(candidate).")
        }
        return worktree
    }
}
