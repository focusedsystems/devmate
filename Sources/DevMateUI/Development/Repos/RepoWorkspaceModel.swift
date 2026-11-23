import AppKit
import DevMateCore
import DevMateGit
import SwiftUI

/// A file open in the editor. A reference type so typing does not publish a
/// model change per keystroke: the editor writes `text` and the model only
/// hears that the document became dirty.
final class RepoEditorDocument: Identifiable {
    let id = UUID()
    let path: String
    /// What is on disk, as last read or saved.
    var savedText: String
    /// What the editor holds now.
    var text: String
    /// Too large or not text: shown, never written.
    let isReadOnly: Bool
    /// Line to scroll to and select when the editor next shows this document.
    var revealLine: Int?

    init(path: String, text: String, isReadOnly: Bool, revealLine: Int? = nil) {
        self.path = path
        self.savedText = text
        self.text = text
        self.isReadOnly = isReadOnly
        self.revealLine = revealLine
    }
}

/// How the sidebar orders repositories.
enum RepoSidebarSort: String, CaseIterable {
    case name, recentlyChanged, mostChanges, mostBehind

    var title: String {
        switch self {
        case .name: "Name"
        case .recentlyChanged: "Recently Changed"
        case .mostChanges: "Most Changes"
        case .mostBehind: "Most Behind"
        }
    }

    func sorted(_ repos: [DevRepo], statuses: [String: RepoStatus]) -> [DevRepo] {
        func byName(_ a: DevRepo, _ b: DevRepo) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return repos.sorted { a, b in
            let (x, y) = (statuses[a.id], statuses[b.id])
            switch self {
            case .name: return byName(a, b)
            case .recentlyChanged:
                let (p, q) = (x?.lastCommitAt ?? .distantPast, y?.lastCommitAt ?? .distantPast)
                return p != q ? p > q : byName(a, b)
            case .mostChanges:
                let (p, q) = (x?.changedCount ?? 0, y?.changedCount ?? 0)
                return p != q ? p > q : byName(a, b)
            case .mostBehind:
                let (p, q) = (x?.behind ?? 0, y?.behind ?? 0)
                return p != q ? p > q : byName(a, b)
            }
        }
    }
}

/// The Repos segment: the registry's checkouts on the left; for the selected
/// one, the git pane plus a file browser and editor. The list comes from the
/// registry and is never written back. Hiding a row is a preference of this
/// app alone.
@MainActor
public final class RepoWorkspaceModel: ObservableObject {
    /// The selected repository's git pane.
    let git = GitPaneState()
    /// The Insights panel's period, scope and statistics.
    let insights = RepoInsightsModel()
    let slots: RepoWorkspaceSlots

    private let source: RegistryRepoSource
    private let defaults: UserDefaults
    private let fallbackProtected: Set<String>
    private static let hiddenKey = "devmate.repos.hidden"

    public init(source: RegistryRepoSource, protectedBranches: Set<String> = ["main", "master"],
                slots: RepoWorkspaceSlots = RepoWorkspaceSlots(), defaults: UserDefaults = .standard) {
        self.source = source
        self.fallbackProtected = protectedBranches
        self.slots = slots
        self.defaults = defaults
        hiddenIDs = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
        git.onError = { [weak self] title, message in self?.report(title: title, message) }
        git.onRefreshed = { [weak self] in await self?.workingTreeChanged() }
        git.unsavedEdits = { [weak self] in
            guard let self, let root = self.selectedPath else { return 0 }
            return self.unsavedCount(under: root)
        }
    }

    // Repository list
    /// Registry sections, keeping their order, with only Development repos.
    @Published private(set) var sections: [RepoSection] = []
    /// Set when the registry could not be read and the last good list shows.
    @Published private(set) var registryBanner: String?
    @Published private(set) var hiddenIDs: Set<String>
    /// The sidebar's Edit mode: visibility toggles on each row.
    @Published var isEditing = false
    @Published private(set) var statuses: [String: RepoStatus] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isFetching: Set<String> = []
    @Published var selectedId: String? {
        willSet { lastRoot = selectedPath }
        didSet { if selectedId != oldValue { selectionChanged() } }
    }

    // Selected repository
    @Published private(set) var files: [String] = []
    @Published private(set) var tree: [RepoFileNode] = []
    @Published var expandedFolders: Set<String> = []
    @Published private(set) var grepQuery: String?
    @Published private(set) var grepResults: [RepoGrepMatch] = []
    @Published private(set) var isSearching = false

    // Editor
    @Published private(set) var document: RepoEditorDocument?
    @Published private(set) var isDirty = false
    /// Bumped to scroll the open document to its `revealLine` again.
    @Published private(set) var revealToken = 0

    // Feedback
    @Published var actionError: String?
    @Published private(set) var actionErrorTitle = "Action failed"
    @Published private(set) var notice: String?

    var allRepos: [DevRepo] { sections.flatMap(\.repos) }
    var tracked: [DevRepo] { allRepos.filter { !hiddenIDs.contains($0.id) } }
    /// What the sidebar lists: everything while editing, otherwise only what
    /// is not hidden.
    var listed: [DevRepo] { isEditing ? allRepos : tracked }
    var selected: DevRepo? { allRepos.first { $0.id == selectedId } }
    /// The repository selected in the sidebar, for an app's own commands.
    public var selectedRepository: DevRepo? { selected }
    var selectedPath: String? { selected?.localPath }
    var selectedStatus: RepoStatus? { selectedId.flatMap { statuses[$0] } }

    private var copy: GitWorkingCopy? { selectedPath.map { GitWorkingCopy(path: $0, withheld: slots.withheld) } }

    // MARK: - List

    /// Rereads the registry. A bad file keeps the last good list and raises
    /// the banner.
    public func reloadRecords() {
        let snapshot = source.reload()
        registryBanner = snapshot.state.banner
        sections = snapshot.catalog.sections.compactMap { section in
            let repos = section.repos.filter(\.surfaces.development)
            return repos.isEmpty ? nil : RepoSection(name: section.name, repos: repos)
        }
        protectedBranches = snapshot.catalog.settings.protectedBranches.map(Set.init) ?? fallbackProtected
        git.protectedBranches = protectedBranches
        if allRepos.isEmpty { isEditing = false }
        if let selectedId, !listed.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
        if selectedId == nil { selectedId = tracked.first?.id }
    }

    private var protectedBranches: Set<String> = []

    func setHidden(_ repo: DevRepo, _ hidden: Bool) {
        if hidden { hiddenIDs.insert(repo.id) } else { hiddenIDs.remove(repo.id) }
        defaults.set(hiddenIDs.sorted(), forKey: Self.hiddenKey)
        if !isEditing, selectedId == repo.id, hidden { selectedId = tracked.first?.id }
    }

    /// Local status of every listed repository: no network.
    func refreshStatuses() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let withheld = slots.withheld
        let results = await boundedMap(allRepos.map { $0.checkout(withheld) }, limit: 4) { await $0.status() }
        statuses = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func fetch(_ ids: [String]) async {
        let withheld = slots.withheld
        let checkouts = allRepos.filter { ids.contains($0.id) }.map { $0.checkout(withheld) }
        isFetching.formUnion(ids)
        let failures = await boundedMap(checkouts, limit: 4) { checkout -> String? in
            do {
                _ = try await checkout.workingCopy.fetch()
                return nil
            } catch {
                return "\(checkout.displayName): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }.compactMap { $0 }
        isFetching.subtract(ids)
        if !failures.isEmpty { report(title: "Fetch failed", failures.joined(separator: "\n")) }
        await refreshStatuses()
    }

    // MARK: - Selection

    private func selectionChanged() {
        files = []
        tree = []
        expandedFolders = []
        clearGrep()
        parkCurrentDocument(root: lastRoot)
        document = nil
        isDirty = false
        git.attach(copy, protectedBranches: protectedBranches)
        Task {
            await loadSelected()
            await git.refresh()
        }
    }

    /// The selected repository's file list, for the Files panel.
    func loadSelected() async {
        guard let copy, let id = selectedId else { return }
        do {
            let paths = try await copy.listFiles()
            guard id == selectedId else { return }
            files = paths
            tree = RepoFileTree.build(paths)
        } catch {
            report(error)
        }
    }

    /// After git changed the working tree (commit, discard, pull, branch
    /// switch): the file list, an unedited open file, and the list row.
    func workingTreeChanged() async {
        guard let copy else { return }
        if let paths = try? await copy.listFiles() {
            files = paths
            tree = RepoFileTree.build(paths)
            reloadOpenDocumentFromDisk()
        }
        if let repo = selected {
            statuses[repo.id] = await repo.checkout(slots.withheld).status()
        }
    }

    // MARK: - Search

    func grep(_ query: String) async {
        let pattern = query.trimmingCharacters(in: .whitespaces)
        guard let copy, !pattern.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            grepResults = try await copy.grep(pattern, ignoreCase: true, fixedStrings: true, limit: 500)
                .filter { !copy.isWithheld($0.path) }
            grepQuery = pattern
        } catch {
            report(title: "Search failed", error)
        }
    }

    func clearGrep() {
        grepQuery = nil
        grepResults = []
    }

    // MARK: - Editor

    func open(_ path: String, line: Int? = nil) {
        guard let copy else { return }
        guard !copy.isWithheld(path) else {
            report(title: "Could not open \(path)", "This app does not show that file.")
            return
        }
        if let document, document.path == path {
            document.revealLine = line
            revealToken += 1
            return
        }
        parkCurrentDocument(root: copy.path)
        let absolute = (copy.path as NSString).appendingPathComponent(path)
        if let parked = unsaved.removeValue(forKey: absolute) {
            parked.revealLine = line
            document = parked
            isDirty = true
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: absolute)[.size] as? Int) ?? 0
        do {
            let data = try copy.readFile(path)
            if let text = RepoTextFile.decode(data) {
                document = RepoEditorDocument(path: path, text: text, isReadOnly: size > RepoTextFile.editableLimit, revealLine: line)
            } else {
                document = RepoEditorDocument(path: path, text: "This file is not text (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))). Reveal it in Finder to open it with another app.", isReadOnly: true)
            }
            isDirty = false
        } catch {
            report(title: "Could not open \(path)", error)
        }
    }

    func editorTextChanged() {
        guard let document else { return }
        let dirty = document.text != document.savedText
        if dirty != isDirty { isDirty = dirty }
    }

    func save() {
        guard let copy, let document, !document.isReadOnly, isDirty else { return }
        do {
            try copy.writeFile(document.path, contents: Data(document.text.utf8))
            document.savedText = document.text
            isDirty = false
            flash("Saved \((document.path as NSString).lastPathComponent)")
            Task { await git.refresh() }
        } catch {
            report(title: "Save failed", error)
        }
    }

    /// After git rewrote the working tree, an open file with no unsaved edits
    /// shows what is now on disk.
    private func reloadOpenDocumentFromDisk() {
        guard let document, !isDirty, let copy else { return }
        let path = document.path
        self.document = nil
        if FileManager.default.fileExists(atPath: (copy.path as NSString).appendingPathComponent(path)) {
            open(path)
        }
    }

    /// Throws away unsaved edits to the open file (after the view confirms).
    func revert() {
        guard let document else { return }
        document.text = document.savedText
        isDirty = false
        self.document = nil
        open(document.path)
    }

    func closeEditor() {
        parkCurrentDocument(root: selectedPath)
        document = nil
        isDirty = false
    }

    /// Whether `path` in the selected repository has edits not yet saved.
    func hasUnsavedEdits(_ path: String) -> Bool {
        if isDirty, document?.path == path { return true }
        guard let root = selectedPath else { return false }
        return unsaved[(root as NSString).appendingPathComponent(path)] != nil
    }

    /// Unsaved edits are never dropped and never block with a prompt: moving
    /// to another file keeps them in memory, and reopening the file brings
    /// them back.
    private func parkCurrentDocument(root: String?) {
        guard isDirty, let document, let root else { return }
        unsaved[(root as NSString).appendingPathComponent(document.path)] = document
        isDirty = false
    }

    /// Unsaved documents by absolute path, across repositories.
    private var unsaved: [String: RepoEditorDocument] = [:]
    /// The selected checkout before the selection changed, so a document
    /// being parked on a switch is filed under the repository it came from.
    private var lastRoot: String?

    func unsavedCount(under root: String) -> Int {
        let parked = unsaved.keys.filter { $0.hasPrefix(root + "/") }.count
        return parked + (isDirty && selectedPath == root ? 1 : 0)
    }

    // MARK: - Feedback

    private func report(title: String = "Action failed", _ error: Error) {
        report(title: title, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func report(title: String, _ message: String) {
        actionErrorTitle = title
        actionError = message
    }

    private func flash(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == message { notice = nil }
        }
    }
}
