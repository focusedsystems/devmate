import AppKit
import DevMateCore
import DevMateGit
@preconcurrency import MarkdownUI
import SwiftUI

/// The Development tab: a segment switch in the toolbar over Repos, Pulls,
/// Commits, Pipelines and Skills, showing what the provider declares.
public struct DevelopmentView: View {
    @ObservedObject private var model: DevelopmentModel
    private let onRefresh: (() -> Void)?
    private let showsNavigation: Bool

    /// `onRefresh` replaces the toolbar's default refresh, for an app that
    /// refreshes more than this tab. `showsNavigation: false` leaves out the
    /// refresh button and the segment bar, for an app that supplies its own
    /// control for both and sets `model.segment` itself.
    public init(model: DevelopmentModel, onRefresh: (() -> Void)? = nil, showsNavigation: Bool = true) {
        self.model = model
        self.onRefresh = onRefresh
        self.showsNavigation = showsNavigation
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .actionErrorBanner($model.actionError)
            .toolbar { toolbar }
            .searchable(text: $model.search, placement: .toolbar, prompt: searchPrompt)
            .onSubmit(of: .search) {
                if model.segment == .repos { RepoWorkspaceView.submitSearch(model.search, model: model.repos) }
            }
            .onAppear { model.load() }
            .onChange(of: model.segment) { _, segment in model.load(segment) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.segment {
        case .repos: RepoWorkspaceView(model: model.repos, searchText: model.search)
        case .pullRequests: DevPullsView(model: model)
        case .commits: DevCommitsView(model: model)
        case .pipelines: DevPipelinesView(model: model)
        case .skills: DevSkillsView(model: model)
        }
    }

    private var searchPrompt: String {
        switch model.segment {
        case .repos: return "Filter files, Return searches contents"
        case .pullRequests: return "Filter pull requests"
        case .commits: return "Filter commits"
        case .pipelines: return "Filter runs"
        case .skills: return "Filter skills"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Refresh leads, then the views, always shown rather than in a menu.
        if showsNavigation {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    if let onRefresh { onRefresh() } else { model.load(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read the list again")
                DevSegmentBar(selection: $model.segment, segments: model.segments)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if [.commits, .pipelines, .pullRequests].contains(model.segment) { repoFilterMenu }
            if model.segment == .repos { DevelopmentGraphsButton() }
            model.slots.toolbar()
        }
    }

    private var repoFilterMenu: some View {
        Menu {
            Picker("Repository", selection: $model.repoFilter) {
                Text("All Repositories").tag(String?.none)
                Divider()
                ForEach(model.hostedRepos) { Text($0.remote ?? $0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(model.hostedRepos.first { $0.id == model.repoFilter }?.name ?? "All Repositories",
                  systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Show one repository or all")
    }
}

// MARK: - Shared

enum DevWeb {
    /// Opens only http(s), since addresses come from the host.
    static func open(_ address: String?) {
        guard let address, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }
}

/// How much was read, when, and what failed, in the corner of a list.
struct DevLoadFooter: View {
    let isLoading: Bool
    let loadedAt: Date?
    let errors: [String]
    let count: String

    var body: some View {
        HStack(spacing: 6) {
            if isLoading { ProgressView().controlSize(.mini) }
            if !errors.isEmpty {
                Label("\(errors.count) failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(errors.joined(separator: "\n"))
            }
            Text(count)
            if let loadedAt { Text("· \(DevWeb.relative(loadedAt))") }
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .padding(8)
    }
}

/// Markdown from a host. A link opens only when it is http(s), and an image
/// loads only when the provider allows its address.
struct DevMarkdown: View {
    let content: String
    let provider: any DevelopmentProvider
    var emptyText = "No description."

    var body: some View {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(emptyText).appFont(.body).foregroundStyle(.secondary)
        } else {
            let allows: @Sendable (URL?) -> Bool = { [provider] in provider.allowsImage($0) }
            Markdown(content)
                .markdownTheme(.basic)
                .markdownImageProvider(AllowlistedImageProvider(allows: allows, note: "Images load only from the host's own upload addresses."))
                .markdownInlineImageProvider(AllowlistedInlineImageProvider(allows: allows))
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction(url) : .discarded
                })
        }
    }
}

/// Long read-only text, such as a run's log, in a native text view.
struct DevLogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textContainerInset = NSSize(width: 8, height: 8)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.scrollToEndOfDocument(nil)
    }
}

// MARK: - Commits

/// Recent commits on each repository's default branch, newest first.
struct DevCommitsView: View {
    @ObservedObject var model: DevelopmentModel

    var body: some View {
        let rows = model.visibleCommits
        Table(rows, selection: $model.selectedCommit) {
            TableColumn("Repository") { (commit: DevCommit) in
                Text(commit.repo).appFont(.body).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Commit") { (commit: DevCommit) in
                Text(commit.shortSHA).appFont(.body, design: .monospaced)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Message") { (commit: DevCommit) in
                Text(commit.subject).appFont(.body).lineLimit(1).help(commit.message)
            }
            .width(min: 200, ideal: 420)
            TableColumn("Author") { (commit: DevCommit) in
                Text(commit.author ?? "").appFont(.body).lineLimit(1)
            }
            .width(min: 90, ideal: 140)
            TableColumn("Date") { (commit: DevCommit) in
                Text(DevWeb.relative(commit.date)).appFont(.body).foregroundStyle(.secondary)
                    .help(commit.date?.formatted() ?? "")
            }
            .width(min: 60, ideal: 90)
        }
        .contextMenu(forSelectionType: DevCommit.ID.self) { ids in
            if let commit = rows.first(where: { ids.contains($0.id) }) {
                Button("Open in Browser") { DevWeb.open(commit.url) }
                Button("Copy SHA") { DevWeb.copy(commit.sha) }
                Button("Copy Link") { DevWeb.copy(commit.url) }
            }
        } primaryAction: { ids in
            if let commit = rows.first(where: { ids.contains($0.id) }) { DevWeb.open(commit.url) }
        }
        .onCopyCommand {
            guard let commit = model.commit else { return [] }
            return [NSItemProvider(object: "\(commit.shortSHA) \(commit.subject)" as NSString)]
        }
        .overlay { if rows.isEmpty { emptyState } }
        .overlay(alignment: .bottomTrailing) {
            DevLoadFooter(isLoading: model.commits.isLoading, loadedAt: model.commits.loadedAt,
                          errors: model.commits.errors, count: "\(rows.count) commits")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.commits.isLoading {
            ProgressView("Reading commits…")
        } else {
            ContentUnavailableView("No Commits", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text(model.search.isEmpty ? "Nothing read yet." : "Nothing matches the filter."))
        }
    }
}

// MARK: - Skills

/// The agent skills in each repository and in the person's own folder, beside
/// the selected one's SKILL.md.
struct DevSkillsView: View {
    @ObservedObject var model: DevelopmentModel
    @AppStorage("devmate.development.skillsFraction") private var fraction = 0.5

    var body: some View {
        DetailSplitView(fraction: $fraction, showsDetail: model.skill != nil, minLeading: 320, minTrailing: 320) {
            list
        } trailing: {
            if let skill = model.skill { DevSkillDetail(skill: skill, provider: model.provider) }
        }
    }

    private var list: some View {
        let rows = model.visibleSkills
        return Table(rows, selection: $model.selectedSkill) {
            TableColumn("Name") { (skill: SkillCatalog.Skill) in
                Text(skill.name).appFont(.body, weight: .medium).lineLimit(1)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Description") { (skill: SkillCatalog.Skill) in
                Text(skill.description).appFont(.body).lineLimit(2).help(skill.description)
            }
            .width(min: 180, ideal: 360)
            TableColumn("Repository") { (skill: SkillCatalog.Skill) in
                Text(skill.source).appFont(.body).foregroundStyle(.secondary).help(skill.location)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: SkillCatalog.Skill.ID.self) { ids in
            if let skill = rows.first(where: { ids.contains($0.id) }) {
                Button("Open SKILL.md") { GitFilesPanel.openInTextEditor(skill.file) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([skill.file]) }
                Divider()
                Button("Copy Path") { DevWeb.copy(skill.file.path) }
            }
        } primaryAction: { ids in
            if let skill = rows.first(where: { ids.contains($0.id) }) { GitFilesPanel.openInTextEditor(skill.file) }
        }
        .onCopyCommand {
            guard let skill = model.skill else { return [] }
            return [NSItemProvider(object: skill.file.path as NSString)]
        }
        .overlay {
            if rows.isEmpty, !model.skills.isLoading {
                ContentUnavailableView("No Skills", systemImage: "wand.and.stars",
                                       description: Text("No SKILL.md in the repositories' .claude/skills or .agents/skills, or in ~/.claude/skills."))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            DevLoadFooter(isLoading: model.skills.isLoading, loadedAt: model.skills.loadedAt, errors: [],
                          count: "\(rows.count) skills")
        }
    }
}

private struct DevSkillDetail: View {
    let skill: SkillCatalog.Skill
    let provider: any DevelopmentProvider
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).appFont(.title3, weight: .semibold)
                    Text("\(skill.source) · \(skill.location)").appFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open") { GitFilesPanel.openInTextEditor(skill.file) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([skill.file]) }
            }
            .padding(12)
            Divider()
            ScrollView {
                DevMarkdown(content: text, provider: provider, emptyText: "SKILL.md is empty.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .task(id: skill.id) {
            let file = skill.file
            text = await DevelopmentModel.offMain {
                SkillCatalog.body(of: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
            }
        }
    }
}
