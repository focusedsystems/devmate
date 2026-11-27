import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DevMateCore
import DevMateGit

// Modified from the original for DevMate.
// Ported from MunkiStudio (Apache-2.0),
// Sources/App/Features/Git/GitPanels.swift. "Open" goes to this package's own
// editor (the Files panel) rather than MunkiStudio's pkginfo and manifest
// editors, and the history menu offers the actions this port keeps.

/// Which files from a checkout may be handed to another app. A repository can
/// carry files that run or redirect when opened, so this is an allowlist: a
/// regular, non-executable file whose name and real target are both plain
/// text or an image.
enum GitOpenWithPolicy {
    /// Types that conform to text or image but act when opened.
    static let refusedExtensions: Set<String> = [
        "terminal", "command", "tool", "fileloc", "webloc", "inetloc", "ftploc", "afploc", "url", "desktop",
        "app", "scpt", "scptd", "applescript", "workflow", "action", "shortcut", "mobileconfig", "pkg", "mpkg",
        "dmg", "jar", "prefpane", "kext", "html", "htm", "xhtml", "shtml", "svg", "svgz", "xht", "mht", "mhtml",
        "webarchive", "hta", "plist", "sh", "bash", "zsh", "csh", "ksh", "fish", "py", "rb", "pl", "php", "js",
        "mjs", "cjs", "ts", "lua", "swift",
    ]

    static func allows(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              !FileManager.default.isExecutableFile(atPath: target.path) else { return false }
        return isSafeContent(url) && isSafeContent(target)
    }

    private static func isSafeContent(_ url: URL) -> Bool {
        let name = url.pathExtension.lowercased()
        guard !name.isEmpty, !refusedExtensions.contains(name),
              let type = UTType(filenameExtension: name),
              type.conforms(to: .text) || type.conforms(to: .image) else { return false }
        let active: [UTType] = [.executable, .application, .bundle, .package, .script, .shellScript, .html, .svg]
        return !active.contains { type.conforms(to: $0) }
    }
}

/// The working-tree change list: checkbox to stage, status chip, glyph, path.
struct GitFilesPanel: View {
    /// Opens a file from a checkout in the default plain-text editor, never in
    /// the app registered for its type: a repository can carry files that run
    /// when opened.
    static func openInTextEditor(_ fileURL: URL) {
        guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else { return }
        NSWorkspace.shared.open([fileURL], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    @Bindable var state: GitPaneState
    /// Opens a repository-relative path in the workspace's editor.
    let openInEditor: (String) -> Void

    var body: some View {
        changes.safeAreaInset(edge: .bottom, spacing: 0) {
            if state.withheldCount > 0 {
                Label("\(state.withheldCount) changed \(state.withheldCount == 1 ? "file" : "files") not shown by this app",
                      systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.bar)
            }
        }
    }

    @ViewBuilder
    private var changes: some View {
        if state.files.isEmpty {
            ContentUnavailableView(
                state.withheldCount > 0 ? "No changes to show" : "Working tree clean",
                systemImage: "checkmark.circle",
                description: Text(state.withheldCount > 0 ? "Only withheld files changed." : "No uncommitted changes.")
            )
            .padding()
            .frame(maxHeight: .infinity)
        } else {
            List(state.filteredFiles, selection: $state.fileSelection) { entry in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { entry.staged },
                        set: { newValue in
                            Task {
                                if newValue {
                                    await state.stage([entry.relativePath])
                                } else {
                                    await state.unstage([entry.relativePath])
                                }
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(entry.staged ? "Unstage \(entry.relativePath)" : "Stage \(entry.relativePath)")
                    GitStatusChip(kind: entry.kind, staged: entry.staged)
                    GitFileGlyph(relativePath: entry.relativePath)
                    Text(entry.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(.rect)
                .onTapGesture(count: 2) { openInEditor(entry.relativePath) }
                .tag(entry.id)
            }
            .contextMenu(forSelectionType: String.self) { selections in
                let targets = selections.isEmpty ? Array(state.fileSelection) : Array(selections)
                if let id = targets.first, let entry = state.files.first(where: { $0.id == id }) {
                    fileContextMenu(entry)
                }
            }
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func fileContextMenu(_ entry: GitStatusEntry) -> some View {
        let relativePath = entry.relativePath
        let fileURL = url(relativePath)
        let exists = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        Button("Open") { openInEditor(relativePath) }
            .disabled(!exists)
        Button("Open in External Editor") { if let fileURL { Self.openInTextEditor(fileURL) } }
            .disabled(!exists)
        // Open With is offered only for plain text and images.
        if let fileURL, exists, GitOpenWithPolicy.allows(fileURL) {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
            if !apps.isEmpty {
                Menu("Open With") {
                    ForEach(apps, id: \.self) { appURL in
                        Button(displayName(for: appURL)) {
                            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
            }
        }
        Button("Show in Finder") { if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) } }
            .disabled(!exists)

        Divider()

        Button("Copy Path") { if let fileURL { state.copyToPasteboard(fileURL.path) } }
        Button("Copy Relative Path") { state.copyToPasteboard(relativePath) }
        Button("Copy Filename") { state.copyToPasteboard((relativePath as NSString).lastPathComponent) }

        Divider()

        if entry.staged {
            Button("Unstage") { Task { await state.unstage([relativePath]) } }
        } else {
            Button("Stage") { Task { await state.stage([relativePath]) } }
        }
        Button("Discard Changes…") {
            state.discardRequest = .init(paths: [relativePath])
        }
        .disabled(entry.staged)
    }

    private func url(_ relativePath: String) -> URL? {
        state.copy.map { URL(fileURLWithPath: $0.path).appendingPathComponent(relativePath) }
    }

    private func displayName(for appURL: URL) -> String {
        if let bundle = Bundle(url: appURL),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return appURL.deletingPathExtension().lastPathComponent
    }
}

/// History: the commit list with its lane graph and per-commit actions.
struct GitCommitsPanel: View {
    @Bindable var state: GitPaneState
    @State private var pendingAction: CommitAction?

    private static let rowHeight: CGFloat = 46

    var body: some View {
        let commits = state.filteredCommits
        let graph = CommitGraphBuilder.build(commits)
        Group {
            if commits.isEmpty {
                ContentUnavailableView("No commits", systemImage: "clock").padding().frame(maxHeight: .infinity)
            } else {
                List(selection: $state.commitSelection) {
                    ForEach(Array(commits.enumerated()), id: \.element.sha) { index, commit in
                        commitRow(
                            commit,
                            graphRow: index < graph.rows.count ? graph.rows[index] : nil,
                            laneCount: graph.laneCount
                        )
                        .tag(commit.sha)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                    }
                }
                .contextMenu(forSelectionType: String.self) { shas in
                    let targets = shas.isEmpty ? [state.commitSelection].compactMap { $0 } : Array(shas)
                    if let sha = targets.first, let commit = state.commits.first(where: { $0.sha == sha }) {
                        commitContextMenu(commit)
                    }
                }
            }
        }
        .transientPopover(item: $pendingAction, arrowEdge: .trailing) { action in
            GitCommitActionSheet(
                action: action,
                currentBranch: state.currentBranch,
                perform: { request in await state.run(request) }
            )
        }
    }

    private func commitRow(_ commit: GitCommit, graphRow: GraphRow?, laneCount: Int) -> some View {
        HStack(spacing: 8) {
            if let graphRow {
                GraphCell(row: graphRow, laneCount: laneCount, rowHeight: Self.rowHeight)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    ForEach(commit.refs, id: \.self) { ref in
                        refBadge(ref)
                    }
                    Text(commit.subject).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(commit.sha.prefix(8))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    Text(commit.author).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(height: Self.rowHeight)
        .contentShape(.rect)
    }

    private func refBadge(_ ref: RepoGitRef) -> some View {
        let tint = badgeColor(ref)
        return HStack(spacing: 3) {
            Image(systemName: icon(for: ref.kind)).imageScale(.small)
            Text(ref.name).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.18), in: .capsule)
        .foregroundStyle(tint)
        .overlay(Capsule().strokeBorder(ref.isHead ? tint : Color.clear, lineWidth: 1))
    }

    private func icon(for kind: RepoGitRef.Kind) -> String {
        switch kind {
        case .head: "circle.fill"
        case .localBranch: "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        }
    }

    private func badgeColor(_ ref: RepoGitRef) -> Color {
        switch ref.kind {
        case .head, .localBranch: .blue
        case .remoteBranch: .purple
        case .tag: .orange
        }
    }

    @ViewBuilder
    private func commitContextMenu(_ commit: GitCommit) -> some View {
        Button("Add Tag…") { pendingAction = .addTag(commit) }
        Button("Create Branch…") { pendingAction = .createBranch(commit) }
        Divider()
        Button("Checkout…") { pendingAction = .checkout(commit) }
        Button("Cherry-Pick…") { pendingAction = .cherryPick(commit) }
        Button("Revert…") { pendingAction = .revert(commit) }
        Divider()
        Button("Copy Commit Hash") { state.copyToPasteboard(commit.sha) }
        Button("Copy Commit Subject") { state.copyToPasteboard(commit.subject) }
        Button("Copy .patch") { Task { await state.copyPatch(for: commit.sha) } }
    }
}
