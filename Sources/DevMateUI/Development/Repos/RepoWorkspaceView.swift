import AppKit
import DevMateCore
import DevMateGit
import SwiftUI

// MARK: - Left pane

/// The Repos sidebar: the workspace's mode (Changes, History, Files) on top,
/// then the registry's repositories in its sections, with a filter and sort.
/// Status refreshes on appear and every 30 seconds while shown; fetch is on
/// demand. Sort, grouping, filter and collapsed sections persist.
struct ReposListView: View {
    @ObservedObject var model: RepoWorkspaceModel
    @AppStorage("devmate.repos.sort") private var sort: RepoSidebarSort = .name
    @AppStorage("devmate.repos.grouped") private var grouped = true
    @AppStorage("devmate.repos.filter") private var filter = ""
    /// Collapsed sections, newline-separated, so a new section starts open.
    @AppStorage("devmate.repos.collapsed") private var collapsedStorage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelPicker
            Divider()
            filterBar
            Divider()
            if let banner = model.registryBanner {
                Label(banner, systemImage: "exclamationmark.triangle")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
            }
            if model.allRepos.isEmpty {
                ContentUnavailableView("No repositories", systemImage: "folder",
                                       description: Text("This app's repository list is empty."))
                    .frame(maxHeight: .infinity)
            } else {
                repositoryList
            }
        }
        .task {
            model.reloadRecords()
            await model.refreshStatuses()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                model.reloadRecords()
                await model.refreshStatuses()
            }
        }
    }

    /// A segmented control cannot shrink below its labels, so a narrow
    /// sidebar falls back to a pop-up menu.
    private var panelPicker: some View {
        ViewThatFits(in: .horizontal) {
            panelPicker(segmented: true)
            panelPicker(segmented: false)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .help("Changes, History or Files for the selected repository (keys 1–3)")
    }

    @ViewBuilder
    private func panelPicker(segmented: Bool) -> some View {
        let picker = Picker("View", selection: Bindable(model.git).focusedPanel) {
            ForEach(GitPaneState.Panel.allCases, id: \.self) { panel in
                Text(panel.title).tag(panel)
            }
        }
        .labelsHidden()
        if segmented {
            picker.pickerStyle(.segmented).frame(maxWidth: .infinity)
        } else {
            picker.pickerStyle(.menu).frame(maxWidth: .infinity)
        }
    }

    private func matches(_ repo: DevRepo) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || repo.name.lowercased().contains(needle) || repo.localPath.lowercased().contains(needle)
    }

    private var repositoryList: some View {
        let filtering = !filter.trimmingCharacters(in: .whitespaces).isEmpty
        let visible = Set(model.listed.filter(matches).map(\.id))
        return List(selection: $model.selectedId) {
            if grouped {
                ForEach(model.sections, id: \.name) { section in
                    let repos = sort.sorted(section.repos.filter { visible.contains($0.id) }, statuses: model.statuses)
                    if !repos.isEmpty {
                        Section(isExpanded: expansion(section.name, forcedOpen: filtering)) {
                            ForEach(repos) { row($0) }
                        } header: {
                            Text(section.name)
                        }
                    }
                }
            } else {
                ForEach(sort.sorted(model.listed.filter(matches), statuses: model.statuses)) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if filtering, visible.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else if model.listed.isEmpty {
                ContentUnavailableView {
                    Label("Every repository is hidden", systemImage: "eye.slash")
                } description: {
                    Text("Click Edit to show some again.")
                }
            }
        }
    }

    private func row(_ repo: DevRepo) -> some View {
        let hidden = model.hiddenIDs.contains(repo.id)
        return HStack(spacing: 6) {
            RepoListRow(repo: repo, status: model.statuses[repo.id], isFetching: model.isFetching.contains(repo.id))
                .opacity(model.isEditing && hidden ? 0.5 : 1)
            if model.isEditing {
                Button {
                    model.setHidden(repo, !hidden)
                } label: {
                    Image(systemName: hidden ? "eye.slash" : "eye").frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(hidden ? "Show \(repo.name) in the sidebar" : "Hide \(repo.name) from the sidebar")
                .accessibilityLabel(hidden ? "Show in Sidebar" : "Hide from Sidebar")
            }
        }
        .tag(repo.id)
        .contextMenu { rowMenu(repo, hidden: hidden) }
    }

    @ViewBuilder
    private func rowMenu(_ repo: DevRepo, hidden: Bool) -> some View {
        model.slots.repositoryMenu(repo)
        Divider()
        Button("Fetch") { Task { await model.fetch([repo.id]) } }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.localPath)])
        }
        Button("Copy Path") { copy(repo.localPath) }
        Button("Copy Name") { copy(repo.name) }
        if let error = model.statuses[repo.id]?.error {
            Button("Copy Error") { copy(error) }
        }
        Divider()
        Button(hidden ? "Show in Sidebar" : "Hide from Sidebar") { model.setHidden(repo, !hidden) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var collapsed: Set<String> {
        Set(collapsedStorage.split(separator: "\n").map(String.init))
    }

    /// While a filter is typed every section is open, so a match is never
    /// hidden; the stored state returns when the filter is cleared.
    private func expansion(_ id: String, forcedOpen: Bool) -> Binding<Bool> {
        Binding(
            get: { forcedOpen || !collapsed.contains(id) },
            set: { open in
                guard !forcedOpen else { return }
                var set = collapsed
                if open { set.remove(id) } else { set.insert(id) }
                collapsedStorage = set.sorted().joined(separator: "\n")
            }
        )
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField("Filter", text: $filter).textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear the filter")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.35)))

            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(RepoSidebarSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Group by Section", isOn: $grouped)
                if grouped {
                    Divider()
                    Button("Expand All") { collapsedStorage = "" }
                    Button("Collapse All") {
                        collapsedStorage = model.sections.map(\.name).sorted().joined(separator: "\n")
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort by \(sort.title.lowercased())")
            .accessibilityLabel("Sort and Group")

            if model.isRefreshing || !model.isFetching.isEmpty { ProgressView().controlSize(.small) }
            Button {
                Task { await model.fetch(model.tracked.map(\.id)) }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(model.tracked.isEmpty || !model.isFetching.isEmpty)
            .help("Fetch every listed repository from its remote")
            .accessibilityLabel("Fetch All")

            Button(model.isEditing ? "Done" : "Edit") { model.isEditing.toggle() }
                .buttonStyle(.borderless)
                .disabled(model.allRepos.isEmpty)
                .help(model.isEditing ? "Finish editing the list" : "Hide or show repositories")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct RepoListRow: View {
    let repo: DevRepo
    let status: RepoStatus?
    let isFetching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let icon = repo.icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
                    Image(systemName: icon).imageScale(.small).foregroundStyle(.secondary)
                }
                Text(repo.name).appFont(.body, weight: .medium).lineLimit(1)
                Spacer(minLength: 4)
                if isFetching { ProgressView().controlSize(.mini) }
            }
            metadata
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .help(repoAbbreviatedPath(repo.localPath))
    }

    @ViewBuilder
    private var metadata: some View {
        if let error = status?.error, let summary = status?.errorSummary {
            Label(summary, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(error)
                .accessibilityHint(error)
        } else if let status {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch").imageScale(.small)
                    Text(status.branch ?? "detached").truncationMode(.middle)
                }
                if status.ahead > 0 || status.behind > 0 {
                    Text(syncText(status)).monospacedDigit()
                        .help("\(status.ahead) ahead, \(status.behind) behind \(status.upstream ?? "upstream")")
                }
                if status.changedCount > 0 {
                    Text("\(status.changedCount) changed").monospacedDigit()
                } else if status.isClean {
                    Text("clean")
                }
            }
            .layoutPriority(1)
        } else {
            Text(repoAbbreviatedPath(repo.localPath)).truncationMode(.middle)
        }
    }

    private func syncText(_ status: RepoStatus) -> String {
        [status.ahead > 0 ? "↑\(status.ahead)" : nil, status.behind > 0 ? "↓\(status.behind)" : nil]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

func repoAbbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

// MARK: Files

struct RepoFilesPane: View {
    @ObservedObject var model: RepoWorkspaceModel
    let searchText: String

    private var filtering: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader
            Divider()
            if let query = model.grepQuery {
                grepResults(query)
            } else {
                tree
            }
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 6) {
            Text(model.grepQuery == nil ? "Files" : "Search").appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            if model.isSearching { ProgressView().controlSize(.mini) }
            Spacer()
            if model.grepQuery != nil {
                Button("Show Files") { model.clearGrep() }
                    .buttonStyle(.borderless)
                    .appFont(.caption)
            } else if filtering {
                Text("Press Return to search contents").appFont(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var tree: some View {
        let nodes = RepoFileTree.filter(model.tree, matching: searchText)
        let expanded = filtering ? RepoFileTree.folderPaths(nodes) : model.expandedFolders
        let rows = RepoFileTree.visibleRows(nodes, expanded: expanded)
        let openPath = model.document?.path
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    FileTreeRow(
                        row: row,
                        isOpen: row.node.path == openPath,
                        isUnsaved: !row.node.isFolder && model.hasUnsavedEdits(row.node.path)
                    ) {
                        if row.node.isFolder {
                            guard !filtering else { return }
                            if model.expandedFolders.contains(row.node.path) {
                                model.expandedFolders.remove(row.node.path)
                            } else {
                                model.expandedFolders.insert(row.node.path)
                            }
                        } else {
                            model.open(row.node.path)
                        }
                    }
                    .contextMenu { if let repo = model.selected { model.slots.fileMenu(repo, row.node.path) } }
                }
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if rows.isEmpty {
                Text(model.tree.isEmpty ? "Loading…" : "No file names match")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func grepResults(_ query: String) -> some View {
        List {
            if model.grepResults.isEmpty, !model.isSearching {
                Text("Nothing in this repository contains “\(query)”.")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            let grouped = Dictionary(grouping: model.grepResults, by: \.path)
            ForEach(grouped.keys.sorted(), id: \.self) { path in
                Section {
                    ForEach(grouped[path] ?? [], id: \.self) { match in
                        Button {
                            model.open(match.path, line: match.line)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(match.line)")
                                    .appFont(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(minWidth: 28, alignment: .trailing)
                                Text(match.text.trimmingCharacters(in: .whitespaces))
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(path).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct FileTreeRow: View {
    let row: RepoFileRow
    let isOpen: Bool
    let isUnsaved: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                .appFont(fixed: 9, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .opacity(row.node.isFolder ? 1 : 0)
            Image(systemName: row.node.isFolder ? "folder" : "doc")
                .appFont(fixed: 11)
                .foregroundStyle(row.node.isFolder ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 14)
            Text(row.node.name).appFont(fixed: 12).lineLimit(1)
            if isUnsaved {
                Circle().fill(.secondary).frame(width: 6, height: 6).help("Unsaved edits")
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 8)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(isOpen ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.node.isFolder ? "Folder \(row.node.name)" : row.node.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

// MARK: Editor

/// The Files panel's right side: the open file in the editor.
struct RepoEditorPane: View {
    @ObservedObject var model: RepoWorkspaceModel
    @State private var confirmRevert = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let document = model.document {
                CodeEditorView(document: document, revealToken: model.revealToken) { model.editorTextChanged() }
            } else {
                ContentUnavailableView(
                    "No file open",
                    systemImage: "doc.text",
                    description: Text("Pick a file on the left. Filter with the toolbar search field; press Return to search every file's contents.")
                )
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let document = model.document {
                GitFileGlyph(relativePath: document.path)
                Text(document.path).lineLimit(1).truncationMode(.middle)
                if model.isDirty { Text("Edited").foregroundStyle(.secondary) }
                if document.isReadOnly { Text("Read only").foregroundStyle(.secondary) }
                Spacer()
                Button("Revert") { confirmRevert = true }
                    .disabled(!model.isDirty)
                Button("Close") { model.closeEditor() }
            } else {
                Text("Editor").foregroundStyle(.secondary)
                Spacer()
            }
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.isDirty)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
        .confirmationDialog("Discard your unsaved edits?", isPresented: $confirmRevert, titleVisibility: .visible) {
            Button("Discard Edits", role: .destructive) { model.revert() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file goes back to what is saved on disk.")
        }
    }
}

// MARK: Workspace

/// The whole Repos segment: the sidebar, the graphs when shown, and the
/// selected repository's Git client.
public struct RepoWorkspaceView: View {
    @ObservedObject private var model: RepoWorkspaceModel
    private let searchText: String

    public init(model: RepoWorkspaceModel, searchText: String = "") {
        self.model = model
        self.searchText = searchText
    }

    public var body: some View {
        HSplitView {
            ReposListView(model: model)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 440)
            VStack(spacing: 0) {
                RepoInsightsWidgets(model: model, maxHeight: 340)
                RepoGitView(model: model, searchText: searchText)
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Text(notice)
                    .appFont(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }

    /// Searches every file's contents, for an app's search field.
    public static func submitSearch(_ text: String, model: RepoWorkspaceModel) {
        model.git.focusedPanel = .browse
        Task { await model.grep(text) }
    }
}
