import DevMateCore
import Foundation

/// Git operations on one local checkout, through `ProcessRunner` (which
/// closes every pipe it opens). Authentication is left entirely to the user's
/// git setup — credential helpers, `gh auth setup-git`, ssh keys — and no
/// token ever appears in a URL or argument.
///
/// This is the surface the Repos view uses: status and per-file changes, staging, diffs, the file tree, file contents,
/// search, and the network operations.
public struct GitWorkingCopy: Sendable {
    /// Absolute path of the checkout's top level.
    public let path: String
    /// Folders this checkout's reads never emit and its actions never touch.
    public let withheld: WithheldPaths

    public init(path: String, withheld: WithheldPaths = .none) {
        self.path = GitPaths.expand(path)
        self.withheld = withheld
    }

    /// Whether `path` is inside a git work tree.
    public var isRepository: Bool {
        get async { await git(["rev-parse", "--is-inside-work-tree"]).stdout.hasPrefix("true") }
    }

    /// `AGENTS.md` at the top level, when present. Agents read it before
    /// working in the repository.
    public var agentsFile: String? {
        let candidate = (path as NSString).appendingPathComponent("AGENTS.md")
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    // MARK: - Status

    public func statusSnapshot(includeIgnored: Bool = false) async throws -> GitStatusSnapshot {
        try await statusSnapshot(includeIgnored: includeIgnored, includeWithheld: false)
    }

    private func statusSnapshot(includeIgnored: Bool, includeWithheld: Bool) async throws -> GitStatusSnapshot {
        var args = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]
        if includeIgnored { args.append("--ignored") }
        // Optional locks off: a status poll must never take the index lock
        // from under a commit running in a terminal.
        let output = try await checked(args, extraEnvironment: ["GIT_OPTIONAL_LOCKS": "0"],
                                       includeWithheld: includeWithheld)
        return GitOutputParser.status(output)
    }

    /// How many changed files are withheld. Only names are read, to say so
    /// and to refuse an action that would copy them.
    public func withheldChangeCount(stagedOnly: Bool = false) async throws -> Int {
        guard !withheld.isEmpty else { return 0 }
        let snapshot = try await statusSnapshot(includeIgnored: false, includeWithheld: true)
        let changes = snapshot.changes.filter { !stagedOnly || $0.isStaged }
        return Set(changes.filter { change in
            isWithheld(change.path) || change.originalPath.map(isWithheld) == true
        }.map(\.path)).count
    }

    /// Whether a path, or the file a symlink there resolves to, is withheld.
    public func isWithheld(_ relative: String) -> Bool {
        guard !withheld.isEmpty else { return false }
        if withheld.withholds(relative) { return true }
        let root = Self.realPath(URL(fileURLWithPath: path).standardizedFileURL.path)
        let target = URL(fileURLWithPath: (root as NSString).appendingPathComponent(relative)).standardizedFileURL.path
        let resolved = Self.realPath(target)
        return resolved.hasPrefix(root + "/") && withheld.withholds(String(resolved.dropFirst(root.count + 1)))
    }

    func refuseWithheldChanges(stagedOnly: Bool) async throws {
        if try await withheldChangeCount(stagedOnly: stagedOnly) > 0 { throw RepoError.withheldChanges }
    }

    public func worktrees() async -> [RepoWorktree] {
        let result = await git(["worktree", "list", "--porcelain"])
        return result.succeeded ? GitOutputParser.worktrees(result.stdout) : []
    }

    public func currentBranch() async -> String? {
        let result = await git(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !branch.isEmpty ? branch : nil
    }

    public func originURL() async -> String? {
        let result = await git(["config", "--get", "remote.origin.url"])
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !url.isEmpty ? url : nil
    }

    // MARK: - Network

    public func fetch() async throws -> String {
        try await checked(["fetch", "--prune", "origin"])
    }

    /// Fast-forward only: a pull never creates a merge commit behind the
    /// user's back.
    public func pull() async throws -> String {
        try await checked(["pull", "--ff-only"])
    }

    /// Pushes the current branch to one resolved branch on its remote, with
    /// one explicit refspec and never with force, so configured refspecs
    /// cannot widen it. Sets the upstream on first push. Refuses a protected
    /// branch, as the source or the destination, unless `allowProtected`.
    public func push(protectedBranches: Set<String>, allowProtected: Bool = false) async throws -> String {
        guard let branch = await currentBranch() else {
            throw RepoError.invalidArgument("HEAD is detached; switch to a branch before pushing.")
        }
        try guardBranch(branch, protectedBranches: protectedBranches, allow: allowProtected)
        try await validateFullRef("refs/heads/" + branch)

        let remote = try await pushRemote(branch: branch)
        var inputs = GitSafety.PushInputs(branch: branch)
        inputs.refspecs = await configValues("remote.\(remote).push")
        inputs.pushDefault = await configValues("push.default").last
        let merge = await configValues("branch.\(branch).merge").last
        if await configValues("branch.\(branch).remote").last == remote, let merge, merge.hasPrefix("refs/heads/") {
            inputs.upstream = String(merge.dropFirst("refs/heads/".count))
        }
        let resolved = await git(["rev-parse", "--symbolic-full-name", "refs/heads/\(branch)@{push}"])
        let tracking = "refs/remotes/\(remote)/"
        let pushRef = resolved.stdout.trimmed
        if resolved.succeeded, pushRef.hasPrefix(tracking) {
            inputs.pushTarget = String(pushRef.dropFirst(tracking.count))
        }

        let destination = try GitSafety.pushDestination(inputs, protected: allowProtected ? [] : protectedBranches)
        try await validateFullRef("refs/heads/" + destination)

        var args = ["push", "--no-follow-tags"]
        if try await statusSnapshot().upstream == nil { args.append("--set-upstream") }
        args += [remote, "refs/heads/\(branch):refs/heads/\(destination)"]
        return try await checked(args)
    }

    /// The configured remote this branch pushes to. A URL in its place is
    /// refused, so a push only reaches a remote the clone names.
    private func pushRemote(branch: String) async throws -> String {
        var name = await configValues("branch.\(branch).pushRemote").last
        if name == nil { name = await configValues("remote.pushDefault").last }
        if name == nil { name = await configValues("branch.\(branch).remote").last }
        let remote = name ?? "origin"
        guard !remote.isEmpty, !remote.hasPrefix("-"), remote != ".", !remote.contains("/"), !remote.contains(":"),
              await !configValues("remote.\(remote).url").isEmpty else {
            throw RepoError.invalidArgument("'\(remote)' is not a configured remote.")
        }
        return remote
    }

    private func configValues(_ key: String) async -> [String] {
        let result = await git(["config", "--null", "--get-all", key])
        guard result.succeeded else { return [] }
        return result.stdout.split(separator: "\0").map(String.init)
    }

    private func validateFullRef(_ ref: String) async throws {
        guard !ref.contains("*"), await git(["check-ref-format", ref]).succeeded else {
            throw RepoError.invalidArgument("'\(ref)' is not a valid branch.")
        }
    }

    // MARK: - Branches

    /// Switches to `name`, creating it from `startPoint` (default: HEAD) when
    /// it does not exist locally.
    public func switchBranch(_ name: String, create: Bool? = nil, startPoint: String? = nil) async throws -> String {
        try validateRefName(name)
        let exists = await git(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"]).succeeded
        let shouldCreate = create ?? !exists
        if shouldCreate {
            var args = ["switch", "-c", name]
            if let startPoint {
                guard !startPoint.isEmpty, !startPoint.hasPrefix("-") else {
                    throw RepoError.invalidArgument("'\(startPoint)' is not a valid start point.")
                }
                args.append(startPoint)
            }
            return try await checked(args)
        }
        return try await checked(["switch", name])
    }

    public func localBranches() async throws -> [String] {
        try await checked(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
            .split(separator: "\n").map(String.init)
    }

    // MARK: - Staging and commits

    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await checked(["add", "--"] + confined(paths))
    }

    public func stageAll() async throws {
        _ = try await checked(["add", "--all"])
    }

    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await checked(["restore", "--staged", "--"] + confined(paths))
    }

    /// Throws away local changes to `paths`: tracked files return to the
    /// index's content, untracked files are deleted. Destructive by design, so
    /// it only ever takes explicit paths.
    public func discard(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let safe = try confined(paths)
        let snapshot = try await statusSnapshot()
        let untracked = Set(snapshot.changes.filter { $0.kind == .untracked }.map(\.path))
        let tracked = safe.filter { !untracked.contains($0) }
        let new = safe.filter { untracked.contains($0) }
        if !tracked.isEmpty { _ = try await checked(["restore", "--worktree", "--"] + tracked) }
        if !new.isEmpty { _ = try await checked(["clean", "-f", "--"] + new) }
    }

    /// Commits all changes (`paths` empty) or only `paths`, refusing a
    /// protected branch unless `allowProtected`. Returns the new commit.
    @discardableResult
    public func commit(message: String, paths: [String] = [], protectedBranches: Set<String>, allowProtected: Bool = false) async throws -> RepoCommit {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RepoError.invalidArgument("A commit message is required.") }
        if let branch = await currentBranch() {
            try guardBranch(branch, protectedBranches: protectedBranches, allow: allowProtected)
        }
        if paths.isEmpty {
            try await stageAll()
        } else {
            try await stage(paths)
        }
        let staged = try await statusSnapshot()
        try await refuseWithheldChanges(stagedOnly: true)
        guard staged.stagedCount > 0 else { throw RepoError.nothingToCommit }

        var args = ["commit", "-m", trimmed]
        if !paths.isEmpty { args += ["--"] + (try confined(paths)) }
        _ = try await checked(args)
        guard let head = try await log(limit: 1).first else {
            throw RepoError.gitFailed(command: "log", message: "no commit after commit")
        }
        return head
    }

    /// Commits exactly what is staged, leaving unstaged changes alone. Unlike
    /// `commit(message:paths:)`, a staged rename or deletion commits whole,
    /// since nothing is re-staged by path. Refuses a protected branch unless
    /// `allowProtected`.
    @discardableResult
    public func commitStaged(message: String, protectedBranches: Set<String>, allowProtected: Bool = false) async throws -> RepoCommit {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RepoError.invalidArgument("A commit message is required.") }
        if let branch = await currentBranch() {
            try guardBranch(branch, protectedBranches: protectedBranches, allow: allowProtected)
        }
        try await refuseWithheldChanges(stagedOnly: true)
        guard try await statusSnapshot().stagedCount > 0 else { throw RepoError.nothingToCommit }
        _ = try await checked(["commit", "-m", trimmed])
        guard let head = try await log(limit: 1).first else {
            throw RepoError.gitFailed(command: "log", message: "no commit after commit")
        }
        return head
    }

    // MARK: - Diff and history

    /// `git diff` of the worktree against the index, or of the index against
    /// HEAD when `staged`. Limited to `paths` when given.
    public func diff(staged: Bool = false, stat: Bool = false, paths: [String] = []) async throws -> String {
        var args = ["diff", "--no-color", "--no-ext-diff"]
        if staged { args.append("--cached") }
        if stat { args.append("--stat") }
        if !paths.isEmpty { args += ["--"] + (try confined(paths)) }
        return try await checked(args)
    }

    /// Diff for one file as the Repos view shows it. An untracked file has no
    /// index entry, so it is diffed against an empty file.
    public func fileDiff(_ path: String, staged: Bool = false) async throws -> String {
        let safe = try confined([path])
        let snapshot = try await statusSnapshot()
        if !staged, snapshot.changes.contains(where: { $0.kind == .untracked && $0.path == path }) {
            // --no-index exits 1 when the files differ, which is the expected case.
            let result = await git(["diff", "--no-color", "--no-index", "--", "/dev/null"] + safe)
            return result.stdout
        }
        return try await diff(staged: staged, paths: safe)
    }

    public func log(limit: Int = 20, ref: String? = nil) async throws -> [RepoCommit] {
        var args = ["log", "-n", String(max(1, limit)), "--format=\(GitOutputParser.logFormat)"]
        if let ref { args.append(ref) }
        let result = await git(args)
        // A repository with no commits yet has no log; that is not an error.
        if !result.succeeded, result.stderr.contains("does not have any commits") { return [] }
        guard result.succeeded else { throw RepoError.gitFailed(command: "log", message: result.stderr.trimmed) }
        return GitOutputParser.log(result.stdout)
    }

    // MARK: - Files and search

    /// Every file in the checkout that git would consider: tracked files plus
    /// untracked ones not excluded by `.gitignore`. Paths are relative.
    public func listFiles() async throws -> [String] {
        let output = try await checked(["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
        // Deleted-but-tracked files still appear in --cached; keep only what exists.
        var seen = Set<String>()
        return GitOutputParser.paths(output).filter { relative in
            guard seen.insert(relative).inserted else { return false }
            return FileManager.default.fileExists(atPath: absolute(relative))
        }
    }

    /// `git grep` across tracked files (and untracked, non-ignored ones when
    /// `includeUntracked`). Binary files are skipped.
    public func grep(_ pattern: String, ignoreCase: Bool = false, fixedStrings: Bool = false, includeUntracked: Bool = true, limit: Int = 1000) async throws -> [RepoGrepMatch] {
        guard !pattern.isEmpty else { throw RepoError.invalidArgument("A search pattern is required.") }
        var args = ["grep", "-n", "-z", "--column", "-I", "--no-color"]
        if ignoreCase { args.append("-i") }
        if fixedStrings { args.append("-F") }
        if includeUntracked { args.append("--untracked") }
        args += ["-e", pattern]
        let result = await git(args)
        // Exit 1 means no match.
        if result.exitCode == 1 { return [] }
        guard result.succeeded else { throw RepoError.gitFailed(command: "grep", message: result.stderr.trimmed) }
        return Array(GitOutputParser.grep(result.stdout).prefix(limit))
    }

    public func readFile(_ relative: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: absolute(confinedPath(relative))))
    }

    public func writeFile(_ relative: String, contents: Data) throws {
        let url = URL(fileURLWithPath: absolute(try confinedPath(relative)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, options: .atomic)
    }

    // MARK: - Path safety

    /// Resolves a repository-relative path, rejecting anything that would
    /// land outside the checkout (`..`, absolute paths elsewhere, symlinks out)
    /// or inside `.git` in any letter case. A path that does not exist yet is
    /// checked through its deepest existing ancestor, so a new file under a
    /// symlinked folder cannot escape either.
    public func confinedPath(_ relative: String) throws -> String {
        let root = Self.realPath(URL(fileURLWithPath: path).standardizedFileURL.path)
        let candidate = relative.hasPrefix("/") ? relative : (root as NSString).appendingPathComponent(relative)
        let resolved = Self.realPath(URL(fileURLWithPath: candidate).standardizedFileURL.path)
        guard resolved == root || resolved.hasPrefix(root + "/") else {
            throw RepoError.pathOutsideRepository(relative)
        }
        let inside = String(resolved.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !inside.isEmpty else { throw RepoError.invalidArgument("Expected a file path inside the repository.") }
        // APFS is case-insensitive by default, so `.GIT/hooks` is `.git/hooks`.
        guard !inside.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) else {
            throw RepoError.pathOutsideRepository(relative)
        }
        if withheld.withholds(inside) || withheld.withholds(relative) { throw RepoError.withheld(relative) }
        return inside
    }

    /// The path with every symlink resolved. Components that do not exist yet
    /// are appended to the resolved form of the deepest ancestor that does.
    static func realPath(_ standardized: String) -> String {
        var existing = standardized
        var missing: [String] = []
        while !existing.isEmpty, existing != "/", !FileManager.default.fileExists(atPath: existing) {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let base = realpath(existing, &buffer) != nil ? String(cString: buffer) : existing
        return missing.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// The repository-relative path of a directory entry, for git commands
    /// that act on the entry. The parent folder is resolved and must be inside
    /// the checkout; the last component is not followed, so git acts on a
    /// symlink itself and never on what it points at.
    public func entryPath(_ relative: String) throws -> String {
        let root = Self.realPath(URL(fileURLWithPath: path).standardizedFileURL.path)
        let candidate = relative.hasPrefix("/") ? relative : (root as NSString).appendingPathComponent(relative)
        let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let name = (standardized as NSString).lastPathComponent
        let parent = Self.realPath((standardized as NSString).deletingLastPathComponent)
        guard standardized != root, parent == root || parent.hasPrefix(root + "/") else {
            throw RepoError.pathOutsideRepository(relative)
        }
        let resolved = String((parent as NSString).appendingPathComponent(name).dropFirst(root.count + 1))
        // An absolute path may reach the checkout through an alias of its
        // root, in which case only the resolved form is relative to it.
        let entry = standardized.hasPrefix(root + "/") ? String(standardized.dropFirst(root.count + 1)) : resolved
        guard !entry.isEmpty else { throw RepoError.invalidArgument("Expected a file path inside the repository.") }
        // APFS is case-insensitive by default, so `.GIT/hooks` is `.git/hooks`.
        for form in [entry, resolved] where form.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) {
            throw RepoError.pathOutsideRepository(relative)
        }
        if withheld.withholds(entry) || withheld.withholds(resolved) { throw RepoError.withheld(relative) }
        return entry
    }

    func confined(_ paths: [String]) throws -> [String] {
        try paths.map(entryPath)
    }

    func absolute(_ relative: String) -> String {
        (path as NSString).appendingPathComponent(relative)
    }

    // MARK: - Running git

    /// Runs git in this checkout. Prompts are disabled: with no terminal to
    /// answer them, a credential prompt would otherwise hang the call.
    ///
    /// Reads run automatically, so they turn off everything in the clone's
    /// config that can start a program: `core.fsmonitor`, the pager, hooks,
    /// signature checks, external diff and textconv drivers, filter drivers,
    /// credential helpers, every network transport including a partial clone's
    /// lazy fetch, and submodule status, which would read each submodule's
    /// own config.
    ///
    /// Fetch, pull and push run only when someone asks, and ignore the SSH
    /// command, credential helpers and pack programs a repository sets for
    /// itself. Commit and the other commands people run on purpose keep the
    /// clone's hooks and filters, which they need to work.
    ///
    /// Withheld paths are excluded here, for every command that can emit
    /// them. `includeWithheld` is only for reading the names of changes.
    public func git(_ arguments: [String], extraEnvironment: [String: String] = [:], extraConfig: [String] = [],
                    includeWithheld: Bool = false) async -> ProcessOutput {
        var environment = extraEnvironment
        var command = Self.withSafeDiffOptions(arguments)
        var config = Self.safetyConfig(for: arguments) + extraConfig.flatMap { ["-c", $0] }
        if !includeWithheld {
            guard let limited = withheld.limiting(command) else {
                return ProcessOutput(stdout: "", stderr: "This command cannot be limited to files this app may handle.", exitCode: 1)
            }
            command = limited.arguments
            if limited.usesMagic { environment["GIT_LITERAL_PATHSPECS"] = "0" }
        }
        if GitSafety.isRead(arguments) {
            config += GitSafety.readConfig
            let found = await Self.runGit(["-C", path, "-c", "core.fsmonitor=false", "config", "--includes", "--null",
                                           "--name-only", "--get-regexp", GitSafety.readKeys])
            // Exit 1 means none is configured. Anything else means the
            // settings are unknown, so the read does not run.
            guard found.succeeded || found.exitCode == 1 else {
                return ProcessOutput(stdout: "", stderr: "Could not read this repository's settings: \(found.stderr.trimmed)", exitCode: found.exitCode)
            }
            let keys = found.stdout.split(separator: "\0").map(String.init)
            if !GitSafety.honoursNoLazyFetch(Self.installedVersion), keys.contains(where: GitSafety.isPartialCloneKey) {
                return ProcessOutput(stdout: "", stderr: "This is a partial clone, and this version of git cannot read it without contacting its remote. Update git to 2.45 or later.", exitCode: 1)
            }
            environment.merge(GitSafety.readEnvironment) { _, new in new }
            environment.merge(GitSafety.configEnvironment(GitSafety.readOverrides(keys: keys))) { _, new in new }
        } else if GitSafety.isNetwork(arguments) {
            config += GitSafety.networkConfig
            let found = await Self.runGit(["-C", path, "-c", "core.fsmonitor=false", "config", "--show-scope", "--includes",
                                           "--null", "--get-regexp", GitSafety.networkKeys])
            guard found.succeeded || found.exitCode == 1 else {
                return ProcessOutput(stdout: "", stderr: "Could not read this repository's remote settings: \(found.stderr.trimmed)", exitCode: found.exitCode)
            }
            let plan = GitSafety.networkPlan(GitSafety.parseScoped(found.stdout), inherited: ProcessInfo.processInfo.environment)
            if let refusal = plan.refusal {
                return ProcessOutput(stdout: "", stderr: refusal, exitCode: 1)
            }
            environment.merge(plan.environment) { _, new in new }
            environment.merge(GitSafety.configEnvironment(plan.config)) { _, new in new }
            if plan.overridesUploadPack, arguments.first != "push" {
                command.insert("--upload-pack=git-upload-pack", at: 1)
            }
            if plan.overridesReceivePack, arguments.first == "push" {
                command.insert("--receive-pack=git-receive-pack", at: 1)
            }
        }
        return await GitWorkingCopy.runGit(["-C", path] + config + command, extraEnvironment: environment)
    }

    /// The installed git's version, read once.
    static let installedVersion: (major: Int, minor: Int)? = {
        let executable = ProcessRunner.find("git") ?? "/usr/bin/git"
        return ProcessRunner.run(executable, ["--version"], timeout: 10).flatMap { GitSafety.parseVersion($0.output) }
    }()

    /// Commands that keep the clone's hooks.
    static let hookCommands: Set<String> = ["commit", "push", "pull", "merge", "rebase", "switch", "checkout", "am", "cherry-pick", "revert"]

    /// `-c` options that keep a clone's config from running programs during
    /// reads.
    static func safetyConfig(for arguments: [String]) -> [String] {
        var config = ["-c", "core.fsmonitor=false", "-c", "core.pager=cat"]
        if !hookCommands.contains(arguments.first ?? "") {
            config += ["-c", "core.hooksPath=/dev/null"]
        }
        return config
    }

    /// Reads never run an external diff, a textconv program or a signature
    /// check, and never look inside submodules.
    static func withSafeDiffOptions(_ arguments: [String]) -> [String] {
        guard let command = arguments.first else { return arguments }
        let extra: [String]
        switch command {
        case "diff": extra = ["--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty"]
        case "show", "log": extra = ["--no-ext-diff", "--no-textconv", "--no-show-signature"]
        case "format-patch": extra = ["--no-ext-diff", "--no-textconv"]
        case "status": extra = ["--ignore-submodules=dirty"]
        case "grep": extra = ["--no-textconv"]
        default: return arguments
        }
        return [command] + extra + arguments.dropFirst()
    }

    static func runGit(_ arguments: [String], extraEnvironment: [String: String] = [:]) async -> ProcessOutput {
        var env: [String: String] = [:]
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Paths are file names, never pathspec magic: a file named ":/" must
        // not widen a discard or stage to the whole checkout.
        env["GIT_LITERAL_PATHSPECS"] = "1"
        // Nothing here can answer an editor or a password prompt, and these
        // take precedence over `core.editor` and `core.askPass` in a clone.
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        env["GIT_ASKPASS"] = "/usr/bin/false"
        for (key, value) in extraEnvironment { env[key] = value }
        return await GitProcess.run(arguments, environment: env)
    }

    private func checked(_ arguments: [String], extraEnvironment: [String: String] = [:],
                         includeWithheld: Bool = false) async throws -> String {
        let result = await git(arguments, extraEnvironment: extraEnvironment, includeWithheld: includeWithheld)
        guard result.succeeded else {
            let message = result.stderr.trimmed.isEmpty ? result.stdout.trimmed : result.stderr.trimmed
            if message.contains("not a git repository") { throw RepoError.notAGitRepository(path) }
            throw RepoError.gitFailed(command: arguments.first ?? "", message: message)
        }
        // Network commands report progress on stderr; keep it for the caller.
        return result.stdout.isEmpty ? result.stderr : result.stdout
    }

    private func guardBranch(_ branch: String, protectedBranches: Set<String>, allow: Bool) throws {
        guard !allow else { return }
        if protectedBranches.contains(branch) { throw RepoError.protectedBranch(branch) }
    }

    private func validateRefName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(" "), !name.contains(".."), !name.hasSuffix("/") else {
            throw RepoError.invalidArgument("'\(name)' is not a valid branch name.")
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension GitWorkingCopy {
    /// The branch `origin/HEAD` points at, when the clone recorded one.
    public func defaultBranch() async -> String? {
        let result = await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
        let name = result.stdout.trimmed
        guard result.succeeded, name.hasPrefix("origin/") else { return nil }
        return String(name.dropFirst("origin/".count))
    }
}
