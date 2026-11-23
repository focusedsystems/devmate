import SwiftUI
import Observation
import DevMateCore
import DevMateGit

// Modified from the original for DevMate.
// Ported from MunkiStudio (Apache-2.0),
// Sources/App/Features/Git/GitState.swift, with the async actions of
// GitView.swift and GitPanels.swift moved in beside the state so every view
// of the pane shares one implementation. Git runs through DevMate's
// `GitWorkingCopy` instead of MunkiStudio's GitService. Deliberate differences,
// not omissions: commit and push refuse protected branches
// and the GUI never overrides that; pull is fast-forward only; failures go to
// the view's error banner, and only destructive steps ask for confirmation.

/// All the live state of one repository's git pane — changes, branches,
/// commits, selection in each, focused panel, commit composer fields.
@Observable
@MainActor
final class GitPaneState {
    enum Panel: String, Hashable, CaseIterable {
        case files, history, browse

        var title: String {
            switch self {
            case .files: "Changes"
            case .history: "History"
            case .browse: "Files"
            }
        }

        /// The key that selects the panel while the git pane has focus.
        var key: String {
            switch self {
            case .files: "1"
            case .history: "2"
            case .browse: "3"
            }
        }
    }

    /// The checkout this pane shows, nil when no repository is selected.
    var copy: GitWorkingCopy?
    var protectedBranches: Set<String> = []

    var currentBranch: String?
    var aheadCount = 0
    var behindCount = 0

    var files: [GitStatusEntry] = []
    var branches: [GitBranch] = []
    var commits: [GitCommit] = []

    /// Native multi-select: ⌘-click toggles, ⇧-click extends. Ids are
    /// `GitStatusEntry.id` (side plus path).
    var fileSelection: Set<String> = []
    var commitSelection: String?

    var primaryFileSelection: String? { fileSelection.sorted().first }
    var primaryEntry: GitStatusEntry? { files.first { $0.id == primaryFileSelection } }

    /// Remembered across launches: the workspace reopens in the mode it was left in.
    var focusedPanel: Panel = Panel(rawValue: UserDefaults.standard.string(forKey: GitPaneState.panelDefaultsKey) ?? "") ?? .files {
        didSet { UserDefaults.standard.set(focusedPanel.rawValue, forKey: GitPaneState.panelDefaultsKey) }
    }
    static let panelDefaultsKey = "repos.panel"
    var diffText: String = ""

    var commitSubject: String = ""
    var commitBody: String = ""
    var amend: Bool = false
    var skipHooks: Bool = false

    var statusMessage: String?
    var statusKind: StatusKind = .info
    var processOutput: String = ""
    var lastRefreshedAt: Date?
    var isBusy = false

    var helpVisible: Bool = false
    var filterVisible: Bool = false
    var filter: String = ""

    /// Changed files left out of the list because the app withholds them.
    var withheldCount = 0

    var stashes: [GitStash] = []
    /// Drives the popover that saves a new stash.
    var stashComposerVisible = false
    /// Drives the confirmation for applying, popping or dropping a stash.
    var stashRequest: StashRequest?
    /// Drives the confirmation for rewriting the last commit.
    var amendRequest: AmendRequest?

    /// Drives the confirmation for a destructive discard.
    var discardRequest: DiscardRequest?
    /// Drives the confirmation for deleting a stale `.git/index.lock`.
    var indexLockRequest: IndexLockRequest?

    /// Runs after each refresh, so the workspace can follow the working tree.
    var onRefreshed: () async -> Void = {}
    /// Unsaved editor buffers in this checkout; a branch switch waits for none.
    var unsavedEdits: () -> Int = { 0 }

    /// Where failures go: the workspace's error banner.
    var onError: (_ title: String, _ message: String) -> Void = { _, _ in }

    enum StatusKind { case info, success, error }

    struct DiscardRequest: Identifiable {
        let id = UUID()
        let paths: [String]
        /// A single chunk instead of whole files.
        var hunkPatch: String?
    }

    struct StashRequest: Identifiable {
        enum Action { case apply, pop, drop }
        let id = UUID()
        let action: Action
        let stash: GitStash
    }

    struct AmendRequest: Identifiable {
        let id = UUID()
        let thenPush: Bool
    }

    struct IndexLockRequest: Identifiable {
        let id = UUID()
        let lockPath: String
        let holders: String
        let action: String
        let retry: () async -> Void
    }

    // MARK: Filtered views

    var filteredFiles: [GitStatusEntry] {
        guard !filter.isEmpty else { return files }
        let q = filter.lowercased()
        return files.filter { $0.relativePath.lowercased().contains(q) }
    }

    var filteredCommits: [GitCommit] {
        guard !filter.isEmpty else { return commits }
        let q = filter.lowercased()
        return commits.filter { $0.subject.lowercased().contains(q) || $0.sha.lowercased().contains(q) }
    }

    var focusedCommit: GitCommit? {
        guard let sha = commitSelection else { return nil }
        return commits.first { $0.sha == sha }
    }

    var focusedFileStaged: Bool { primaryEntry?.staged == true }

    var isOnProtectedBranch: Bool {
        guard let currentBranch else { return false }
        return protectedBranches.contains(currentBranch)
    }

    // MARK: Nav helpers (j / k)

    func moveSelectionDown() {
        switch focusedPanel {
        case .files:
            fileSelection = nextID(in: filteredFiles.map(\.id), after: primaryFileSelection).map { [$0] } ?? []
        case .history:
            commitSelection = nextID(in: filteredCommits.map(\.sha), after: commitSelection)
        case .browse:
            break
        }
    }

    func moveSelectionUp() {
        switch focusedPanel {
        case .files:
            fileSelection = previousID(in: filteredFiles.map(\.id), before: primaryFileSelection).map { [$0] } ?? []
        case .history:
            commitSelection = previousID(in: filteredCommits.map(\.sha), before: commitSelection)
        case .browse:
            break
        }
    }

    private func nextID(in ids: [String], after current: String?) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(index + 1, ids.count - 1)]
    }

    private func previousID(in ids: [String], before current: String?) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[max(index - 1, 0)]
    }

    func focusNextPanel() {
        let all = Panel.allCases
        guard let index = all.firstIndex(of: focusedPanel) else { return }
        focusedPanel = all[(index + 1) % all.count]
    }

    func focusPreviousPanel() {
        let all = Panel.allCases
        guard let index = all.firstIndex(of: focusedPanel) else { return }
        focusedPanel = all[(index - 1 + all.count) % all.count]
    }

    // MARK: Loading

    /// Points the pane at another checkout, clearing everything shown.
    func attach(_ copy: GitWorkingCopy?, protectedBranches: Set<String>) {
        self.copy = copy
        self.protectedBranches = protectedBranches
        files = []
        branches = []
        commits = []
        stashes = []
        withheldCount = 0
        stashRequest = nil
        amendRequest = nil
        fileSelection = []
        commitSelection = nil
        diffText = ""
        commitSubject = ""
        commitBody = ""
        amend = false
        skipHooks = false
        statusMessage = nil
        processOutput = ""
        lastRefreshedAt = nil
        currentBranch = nil
        aheadCount = 0
        behindCount = 0
    }

    func refresh() async {
        guard let copy else { return }
        do {
            async let snapshot = copy.statusSnapshot()
            async let branchList = copy.branchList()
            async let history = copy.history(limit: 200)
            async let stashList = copy.stashes()
            let (snap, names, log, saved) = try await (snapshot, branchList, history, stashList)
            guard copy.path == self.copy?.path else { return }
            // Status already leaves out withheld folders; this catches a
            // symlink elsewhere that points into one.
            files = GitStatusEntry.entries(from: snap).filter { !copy.isWithheld($0.relativePath) }
            withheldCount = (try? await copy.withheldChangeCount()) ?? 0
            currentBranch = snap.branch
            aheadCount = snap.ahead
            behindCount = snap.behind
            branches = names
            commits = log
            stashes = saved
            let ids = Set(files.map(\.id))
            fileSelection = fileSelection.filter(ids.contains)
            if fileSelection.isEmpty, let first = files.first?.id { fileSelection = [first] }
            if commitSelection == nil || !commits.contains(where: { $0.sha == commitSelection }) {
                commitSelection = commits.first?.sha
            }
            await syncDiff()
            lastRefreshedAt = Date()
            await onRefreshed()
        } catch {
            note("Refresh failed", error)
        }
    }

    func syncDiff() async {
        guard let copy else { diffText = ""; return }
        switch focusedPanel {
        case .files:
            guard let entry = primaryEntry else { diffText = ""; return }
            diffText = (try? await copy.combinedDiff(entry.relativePath)) ?? ""
        case .history:
            guard let sha = commitSelection else { diffText = ""; return }
            diffText = (try? await copy.show(sha)) ?? ""
        case .browse:
            break
        }
    }

    // MARK: Staging

    func stage(_ paths: [String]) async {
        await mutate("Stage", retry: { [weak self] in await self?.stage(paths) }) { try await $0.stage(paths) }
    }

    func unstage(_ paths: [String]) async {
        await mutate("Unstage", retry: { [weak self] in await self?.unstage(paths) }) { try await $0.unstage(paths) }
    }

    /// Unstages the selection when all of it is staged, else stages it.
    func toggleStageSelected() async {
        let selected = files.filter { fileSelection.contains($0.id) }
        guard !selected.isEmpty else { return }
        let paths = Array(Set(selected.map(\.relativePath)))
        if selected.allSatisfy(\.staged) { await unstage(paths) } else { await stage(paths) }
    }

    func toggleStageAll() async {
        let paths = Array(Set(files.map(\.relativePath)))
        guard !paths.isEmpty else { return }
        if files.allSatisfy(\.staged) { await unstage(paths) } else { await stage(paths) }
    }

    func unstageAll() async {
        let staged = Array(Set(files.filter(\.staged).map(\.relativePath)))
        guard !staged.isEmpty else { return }
        await unstage(staged)
    }

    /// Stage, unstage or discard one chunk through `git apply`.
    func applyChunk(file: DiffFile, hunk: DiffHunk, cached: Bool, reverse: Bool) async {
        let action = cached ? (reverse ? "Unstage chunk" : "Stage chunk") : "Discard chunk"
        let patch = file.patch(forHunk: hunk)
        await mutate(action) { try await $0.applyPatch(patch, cached: cached, reverse: reverse) }
    }

    func requestDiscardSelected() {
        let paths = Array(Set(files.filter { fileSelection.contains($0.id) && !$0.staged }.map(\.relativePath))).sorted()
        guard !paths.isEmpty else { return }
        discardRequest = DiscardRequest(paths: paths)
    }

    func performDiscard(_ request: DiscardRequest) async {
        statusKind = .info
        if let patch = request.hunkPatch {
            await mutate("Discard chunk") { try await $0.applyPatch(patch, cached: false, reverse: true) }
            return
        }
        let summary = request.paths.count == 1 ? "Discarded \(request.paths[0])" : "Discarded \(request.paths.count) files"
        await mutate("Discard") { try await $0.discard(request.paths) }
        if statusKind != .error { note(summary, kind: .success) }
    }

    // MARK: Commit, branches, network

    /// Commits, first asking when the commit would rewrite the last one.
    func requestCommit(thenPush: Bool) async {
        if amend {
            amendRequest = AmendRequest(thenPush: thenPush)
        } else if thenPush {
            await runCommitAndPush()
        } else {
            _ = await runCommit()
        }
    }

    func performAmend(_ request: AmendRequest) async {
        if request.thenPush { await runCommitAndPush() } else { _ = await runCommit() }
    }

    /// The configured protected branches plus the repository's own default,
    /// read when it is needed so a just-selected clone cannot slip past.
    private func guardedBranches(_ copy: GitWorkingCopy) async -> Set<String> {
        var branches = protectedBranches
        if let main = await copy.defaultBranch() { branches.insert(main) }
        return branches
    }

    func runCommit() async -> Bool {
        guard let copy, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        processOutput = ""
        let protectedBranches = await guardedBranches(copy)
        do {
            let commit = try await copy.commit(
                subject: commitSubject,
                body: commitBody,
                amend: amend,
                runHooks: !skipHooks,
                protectedBranches: protectedBranches
            )
            commitSubject = ""
            commitBody = ""
            amend = false
            skipHooks = false
            note("Committed \(commit.shortSha)", kind: .success)
            await refresh()
            return true
        } catch {
            fail("Commit", error)
            return false
        }
    }

    func runCommitAndPush() async {
        if await runCommit() { await runPush() }
    }

    /// Never passes `allowProtected`: a protected branch is refused, and the
    /// refusal is shown.
    func runPush() async {
        guard let copy else { return }
        let protected = await guardedBranches(copy)
        await network("Push", success: "Pushed") { try await $0.push(protectedBranches: protected) }
    }

    func runPull() async { await network("Pull", success: "Pulled (fast-forward)") { try await $0.pull() } }
    func runFetch() async { await network("Fetch", success: "Fetched") { try await $0.fetch() } }

    func switchBranch(_ name: String) async {
        guard unsavedEdits() == 0 else {
            onError("Switch skipped", "Save or revert your unsaved edits first; switching branches changes the files under them.")
            return
        }
        await network("Switch", success: "Switched to \(name)") { try await $0.switchBranch(name, create: false) }
    }

    func run(_ request: CommitActionRequest) async {
        await mutate("Commit action") { copy in
            switch request {
            case .addTag(let c, let name, let message):
                try await copy.tag(name, at: c.sha, message: message.isEmpty ? nil : message)
            case .createBranch(let c, let name):
                try await copy.createBranch(name, at: c.sha)
            case .checkout(let c):
                guard self.unsavedEdits() == 0 else {
                    throw RepoError.invalidArgument("Save or revert your unsaved edits first.")
                }
                try await copy.checkoutCommit(c.sha)
            case .cherryPick(let c):
                try await copy.cherryPick(c.sha)
            case .revert(let c):
                try await copy.revert(c.sha)
            case .newBranch(_, let name):
                _ = try await copy.switchBranch(name, create: true)
            }
        }
    }

    // MARK: Stash

    func saveStash(message: String, includeUntracked: Bool) async {
        guard unsavedEdits() == 0 else {
            onError("Stash skipped", "Save or revert your unsaved edits first; stashing changes the files under them.")
            return
        }
        var saved = false
        await mutate("Stash") { saved = try await $0.stashPush(message: message, includeUntracked: includeUntracked) }
        if statusKind != .error { note(saved ? "Stashed changes" : "Nothing to stash", kind: saved ? .success : .info) }
    }

    func perform(_ request: StashRequest) async {
        if request.action != .drop, unsavedEdits() > 0 {
            onError("Stash skipped", "Save or revert your unsaved edits first; this changes the files under them.")
            return
        }
        statusKind = .info
        let stash = request.stash
        switch request.action {
        case .apply: await mutate("Apply stash") { try await $0.stashApply(stash) }
        case .pop: await mutate("Pop stash") { try await $0.stashPop(stash) }
        case .drop: await mutate("Drop stash") { try await $0.stashDrop(stash) }
        }
        if statusKind != .error {
            let done = switch request.action { case .apply: "Applied"; case .pop: "Popped"; case .drop: "Dropped" }
            note("\(done) \(stash.name)", kind: .success)
        }
    }

    func copyPatch(for sha: String) async {
        guard let copy else { return }
        if let patch = try? await copy.emailPatch(sha), !patch.isEmpty { copyToPasteboard(patch) }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Index lock

    func deleteLockAndRetry(_ request: IndexLockRequest) async {
        do {
            try await GitIndexLock.removeStale(at: request.lockPath)
            note("Removed index.lock — retrying \(request.action.lowercased())…", kind: .info)
            await request.retry()
        } catch {
            fail(request.action, error)
        }
    }

    // MARK: Plumbing

    /// A local mutation: run it, refresh, and route index-lock failures to
    /// the recovery confirmation.
    private func mutate(_ action: String, retry: (() async -> Void)? = nil, _ body: (GitWorkingCopy) async throws -> Void) async {
        guard let copy else { return }
        do {
            try await body(copy)
            await refresh()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if GitIndexLock.matches(message: message), let retry {
                let lock = GitIndexLock.lockPath(checkout: copy.path)
                indexLockRequest = IndexLockRequest(lockPath: lock, holders: await GitIndexLock.holders(of: lock) ?? "Could not check what holds the lock.", action: action, retry: retry)
            } else {
                fail(action, error)
            }
            await refresh()
        }
    }

    /// A git command whose output is worth showing in the composer.
    private func network(_ action: String, success: String, _ body: (GitWorkingCopy) async throws -> String) async {
        guard let copy, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        processOutput = ""
        do {
            processOutput = try await body(copy).trimmingCharacters(in: .whitespacesAndNewlines)
            note(success, kind: .success)
        } catch {
            fail(action, error)
        }
        await refresh()
    }

    private func fail(_ action: String, _ error: Error) {
        if case .withheldChanges = error as? RepoError {
            onError("\(action) refused", RepoError.withheldChanges.errorDescription ?? "")
        } else if case .protectedBranch(let branch) = error as? RepoError {
            onError("\(action) refused", "'\(branch)' is protected. Create a branch for this work and open a pull request from it.")
        } else {
            onError("\(action) failed", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        statusKind = .error
        statusMessage = nil
    }

    private func note(_ action: String, _ error: Error) { fail(action, error) }

    func note(_ message: String, kind: StatusKind) {
        statusMessage = message
        statusKind = kind
    }
}
