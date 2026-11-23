import DevMateCore
import DevMateGit
import SwiftUI

/// Open pull requests across the repositories, with their checks and review
/// state, beside a viewer for the selected one.
struct DevPullsView: View {
    @ObservedObject var model: DevelopmentModel
    @AppStorage("devmate.development.pullsFraction") private var fraction = 0.5

    var body: some View {
        DetailSplitView(fraction: $fraction, showsDetail: model.pull != nil, minLeading: 380, minTrailing: 460) {
            table
        } trailing: {
            if let pull = model.pull { DevPullDetailView(model: model, pull: pull).id(pull.id) }
        }
        .alert(pendingTitle, isPresented: pendingPresented, presenting: model.pendingCheckout) { pending in
            Button("Check Out in a Shell Lane") { model.confirmPendingCheckout() }
            Button("Open in Browser") { DevWeb.open(pending.pull.url) }
            Button("Cancel", role: .cancel) { model.pendingCheckout = nil }
        } message: { pending in
            Text(Self.reviewMessage(pull: pending.pull, risk: pending.risk, withheld: model.repos.slots.withheld))
        }
    }

    private var pendingPresented: Binding<Bool> {
        Binding(get: { model.pendingCheckout != nil }, set: { if !$0 { model.pendingCheckout = nil } })
    }

    private var pendingTitle: String {
        model.pendingCheckout.map { "Review #\($0.pull.number) Before Checking It Out" } ?? ""
    }

    private var table: some View {
        let rows = model.visiblePulls
        return Table(rows, selection: $model.selectedPull) {
            TableColumn("#") { (pull: DevPullRequest) in
                Text("\(pull.number)").appFont(.body).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 50)
            TableColumn("Title") { (pull: DevPullRequest) in titleCell(pull) }
                .width(min: 200, ideal: 380)
            TableColumn("Repository") { (pull: DevPullRequest) in
                Text(pull.repo).appFont(.body).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Author") { (pull: DevPullRequest) in
                Text(pull.author ?? "").appFont(.body).lineLimit(1)
            }
            .width(min: 80, ideal: 120)
            TableColumn("Checks") { (pull: DevPullRequest) in DevChecksLabel(checks: pull.checks) }
                .width(min: 80, ideal: 110)
            TableColumn("Review") { (pull: DevPullRequest) in DevReviewLabel(state: pull.review) }
                .width(min: 90, ideal: 130)
            TableColumn("Updated") { (pull: DevPullRequest) in
                Text(DevWeb.relative(pull.updatedAt)).appFont(.body).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: DevPullRequest.ID.self) { ids in
            if let pull = rows.first(where: { ids.contains($0.id) }) {
                Button("Open in Browser") { DevWeb.open(pull.url) }
                Button("Check Out in Lane") { model.checkOutInLane(pull) }
                    .disabled(model.isCheckingOut(pull))
                Divider()
                Button("Copy Link") { DevWeb.copy(pull.url) }
                Button("Copy Branch Name") { DevWeb.copy(pull.headBranch ?? "") }
                    .disabled(pull.headBranch == nil)
            }
        } primaryAction: { ids in
            if let pull = rows.first(where: { ids.contains($0.id) }) { DevWeb.open(pull.url) }
        }
        .onCopyCommand {
            guard let pull = model.pull else { return [] }
            return [NSItemProvider(object: pull.url as NSString)]
        }
        .overlay { if rows.isEmpty { emptyState } }
        .overlay(alignment: .bottomTrailing) {
            DevLoadFooter(isLoading: model.pulls.isLoading, loadedAt: model.pulls.loadedAt,
                          errors: model.pulls.errors, count: "\(rows.count) open")
        }
    }

    private func titleCell(_ pull: DevPullRequest) -> some View {
        HStack(spacing: 6) {
            if pull.isDraft {
                Text("Draft").appFont(.caption, weight: .medium)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
            }
            Text(pull.title).appFont(.body).lineLimit(1).help(pull.title)
            if model.isCheckingOut(pull) { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.pulls.isLoading {
            ProgressView("Reading pull requests…")
        } else {
            ContentUnavailableView("No Open Pull Requests", systemImage: "arrow.triangle.pull",
                                   description: Text("Nothing open matches."))
        }
    }

    /// Why the pull request needs a look, naming the files.
    static func reviewMessage(pull: DevPullRequest, risk: PullRequestRisk, withheld: WithheldPaths = .none) -> String {
        func listed(_ all: [String]) -> String {
            let files = all.filter { !withheld.withholds($0) }
            let hidden = all.count - files.count
            var text = files.prefix(12).joined(separator: "\n")
            if files.count > 12 { text += "\n…and \(files.count - 12) more" }
            if hidden > 0 { text += (text.isEmpty ? "" : "\n") + "\(hidden) withheld by this app" }
            return text
        }
        var parts: [String] = []
        if !risk.isTrustedAuthor {
            let role = risk.authorAssociation.isEmpty ? "unknown" : risk.authorAssociation.lowercased()
            parts.append("\(pull.author ?? "Its author") is not an owner, member or collaborator of \(pull.repo) (\(role)).")
        }
        if risk.isFromFork {
            parts.append("Its branch is in another repository, so someone other than its author may control it.")
        }
        if !risk.targetsDefaultBranch {
            let base = risk.baseBranch.isEmpty ? "an unknown branch" : risk.baseBranch
            parts.append("It merges into \(base), not the default branch, so its file list leaves out what that branch already changes.")
        }
        if !risk.sensitiveFiles.isEmpty {
            parts.append("It changes files that configure agents or hooks:\n\(listed(risk.sensitiveFiles))")
        }
        if !risk.symlinks.isEmpty {
            parts.append("It adds or changes symbolic links:\n\(listed(risk.symlinks))")
        }
        if !risk.filesComplete {
            parts.append("The host could not list every file it changes, so others may configure agents or hooks.")
        }
        parts.append("An agent started in this checkout would run with those changes. The lane opens as a shell, with no agent started.")
        return parts.joined(separator: "\n\n")
    }
}

struct DevChecksLabel: View {
    let checks: DevChecks

    var body: some View {
        Label {
            Text(text).appFont(.body)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .help("\(checks.passed) passed, \(checks.failed) failed, \(checks.pending) pending, \(checks.skipped) skipped")
    }

    private var text: String {
        switch checks.overall {
        case .none: return "None"
        case .passing: return "\(checks.passed) passed"
        case .failing: return "\(checks.failed) failed"
        case .pending: return "\(checks.pending) pending"
        }
    }

    private var symbol: String {
        switch checks.overall {
        case .none: return "minus.circle"
        case .passing: return "checkmark.circle.fill"
        case .failing: return "xmark.circle.fill"
        case .pending: return "circle.dotted.circle"
        }
    }

    private var color: Color {
        switch checks.overall {
        case .none: return .secondary
        case .passing: return .green
        case .failing: return .red
        case .pending: return .orange
        }
    }
}

struct DevReviewLabel: View {
    let state: DevReviewState

    var body: some View {
        Text(state.rawValue).appFont(.body).foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .approved: return .green
        case .changesRequested: return .red
        case .required: return .orange
        case .none: return .secondary
        }
    }
}

// MARK: - Viewer

/// One pull request: its description, commits, files and conversation, with
/// the day-to-day actions. Every action that changes it asks first or takes
/// its text in a sheet.
struct DevPullDetailView: View {
    enum Pane: String, CaseIterable { case overview = "Overview", commits = "Commits", files = "Files", comments = "Comments" }

    private enum Pending: Identifiable {
        case approve, ready, draft, close, merge(DevMergeMethod)

        var id: String {
            switch self {
            case .approve: "approve"
            case .ready: "ready"
            case .draft: "draft"
            case .close: "close"
            case .merge(let method): "merge-\(method.rawValue)"
            }
        }

        var title: String {
            switch self {
            case .approve: "Approve"
            case .ready: "Mark Ready"
            case .draft: "Convert to Draft"
            case .close: "Close"
            case .merge(let method): method == .merge ? "Merge" : "\(method.rawValue) and Merge"
            }
        }
    }

    private enum Composer: String, Identifiable {
        case comment = "Comment", requestChanges = "Request Changes"
        var id: String { rawValue }
    }

    @ObservedObject var model: DevelopmentModel
    let pull: DevPullRequest

    @AppStorage("devmate.development.pullPane") private var paneName = Pane.overview.rawValue
    @AppStorage("devmate.development.mergeMethod") private var mergeName = DevMergeMethod.squash.rawValue
    @State private var detail: DevPullDetail?
    @State private var problem: String?
    @State private var pending: Pending?
    @State private var composer: Composer?
    @State private var isRunning = false

    private var pane: Binding<Pane> {
        Binding(get: { Pane(rawValue: paneName) ?? .overview }, set: { paneName = $0.rawValue })
    }

    private var mergeMethod: DevMergeMethod { DevMergeMethod(rawValue: mergeName) ?? .squash }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            actions
            Divider()
            Picker("View", selection: pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            content
        }
        .task { await reload() }
        .confirmationDialog(pending.map { "\($0.title) #\(pull.number)?" } ?? "", isPresented: pendingPresented,
                            titleVisibility: .visible, presenting: pending) { item in
            Button(item.title, role: isDestructive(item) ? .destructive : nil) { confirm(item) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { item in
            Text(message(for: item))
        }
        .sheet(item: $composer) { kind in
            DevPullComposer(title: kind.rawValue, requiresText: true) { text in
                if kind == .comment {
                    await run(.comment(text))
                } else if let detail {
                    await run(.requestChanges(text, headSHA: detail.headSHA, baseRef: detail.baseRef))
                }
            }
        }
    }

    private var pendingPresented: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pull.title).appFont(.title3, weight: .semibold).lineLimit(2).textSelection(.enabled)
            Text("\(pull.repo) #\(pull.number) · \(pull.author ?? "unknown") · \(pull.headBranch ?? "?") → \(detail?.baseRef ?? pull.baseBranch ?? "?")")
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(detail.map { "Head \($0.headSHA.prefix(8)), compared with \($0.baseRef) at \($0.baseSHA.prefix(8))" } ?? "")
            HStack(spacing: 12) {
                DevChecksLabel(checks: pull.checks)
                DevReviewLabel(state: pull.review)
                if pull.isDraft { Text("Draft").appFont(.caption, weight: .medium) }
            }
        }
        .padding(12)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Approve") { pending = .approve }
                .disabled(detail == nil)
                .help("Approve exactly the commit shown here")
            Button("Request Changes…") { composer = .requestChanges }
                .disabled(detail == nil)
            Button("Comment…") { composer = .comment }
            Button(pull.isDraft ? "Mark Ready" : "Convert to Draft") { pending = pull.isDraft ? .ready : .draft }
            Spacer(minLength: 4)
            if isRunning { ProgressView().controlSize(.small) }
            Button("Check Out in Lane") { model.checkOutInLane(pull) }
                .disabled(model.isCheckingOut(pull))
                .help("Open this exact commit in a plain shell lane. No agent starts.")
            Menu("Merge") {
                ForEach(DevMergeMethod.allCases, id: \.self) { method in
                    Button(method.rawValue + "…") {
                        mergeName = method.rawValue
                        pending = .merge(method)
                    }
                }
            } primaryAction: {
                pending = .merge(mergeMethod)
            }
            .fixedSize()
            .disabled(pull.isDraft || detail == nil)
            .help(detail == nil ? "Waiting to read the pull request" : "Merge exactly the commit shown here")
            Button("Close…") { pending = .close }
        }
        .controlSize(.small)
        .disabled(isRunning)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if let detail {
            switch pane.wrappedValue {
            case .overview:
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        DevMarkdown(content: detail.body, provider: model.provider)
                        model.slots.pullDetail(pull)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
            case .commits: commitsList(detail)
            case .files: filesPane(detail)
            case .comments: commentsList(detail)
            }
        } else if let problem {
            ContentUnavailableView {
                Label("Could Not Read It", systemImage: "exclamationmark.triangle")
            } description: {
                Text(problem)
            } actions: {
                Button("Try Again") { Task { await reload() } }
            }
            .frame(maxHeight: .infinity)
        } else {
            ProgressView("Reading the pull request…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func commitsList(_ detail: DevPullDetail) -> some View {
        List(detail.commits) { commit in
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject).appFont(.body).lineLimit(2)
                Text("\(commit.shortSHA) · \(commit.author ?? "unknown") · \(DevWeb.relative(commit.date))")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            .contextMenu {
                Button("Open in Browser") { DevWeb.open(commit.url) }
                Button("Copy SHA") { DevWeb.copy(commit.sha) }
            }
        }
    }

    @ViewBuilder
    private func filesPane(_ detail: DevPullDetail) -> some View {
        VStack(spacing: 0) {
            if detail.truncated {
                Label("This diff is too large to show in full. Open it in the browser for the rest.",
                      systemImage: "exclamationmark.triangle")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
                    .padding(6)
                Divider()
            }
            if detail.withheldFiles > 0 {
                Label("\(detail.withheldFiles) \(detail.withheldFiles == 1 ? "file" : "files") withheld by this app.",
                      systemImage: "eye.slash")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                Divider()
            }
            if detail.diffIsWithheld {
                ContentUnavailableView("Diff Withheld", systemImage: "eye.slash",
                                       description: Text("This app withholds some paths and could not read every file name in this diff, so none of it is shown."))
                    .frame(maxHeight: .infinity)
            } else {
                GitDiffView(text: detail.diff, mode: .commit)
            }
        }
    }

    private func commentsList(_ detail: DevPullDetail) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if detail.comments.isEmpty {
                    Text("No comments yet.").appFont(.body).foregroundStyle(.secondary)
                }
                ForEach(detail.comments) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(comment.author).appFont(.callout, weight: .semibold)
                            Text(DevWeb.relative(comment.date)).appFont(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let url = comment.url {
                                Button("Open") { DevWeb.open(url) }.buttonStyle(.borderless).appFont(.caption)
                            }
                        }
                        DevMarkdown(content: comment.body, provider: model.provider, emptyText: "No text.")
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private func isDestructive(_ item: Pending) -> Bool {
        switch item {
        case .close, .merge: return true
        default: return false
        }
    }

    private func message(for item: Pending) -> String {
        switch item {
        case .approve:
            let head = detail.map { String($0.headSHA.prefix(8)) } ?? "the commit shown"
            let base = detail?.baseRef ?? pull.baseBranch ?? "its base"
            return "Your approval is recorded for \(head) into \(base). If either has changed since, it is not sent."
        case .ready: return "Reviewers are notified that it is ready."
        case .draft: return "It goes back to draft and cannot be merged until it is ready."
        case .close: return "It closes without merging. It can be reopened."
        case .merge:
            let head = detail.map { String($0.headSHA.prefix(8)) } ?? "the commit shown"
            return "\(pull.headBranch ?? "This branch") merges into \(detail?.baseRef ?? pull.baseBranch ?? "its base") at \(head). If the branch has moved or the base branch was changed since, the merge is refused. Branch protection and required checks still apply."
        }
    }

    private func confirm(_ item: Pending) {
        pending = nil
        Task {
            switch item {
            case .approve:
                guard let detail else { return }
                await run(.approve(headSHA: detail.headSHA, baseRef: detail.baseRef))
            case .ready: await run(.markReady)
            case .draft: await run(.convertToDraft)
            case .close: await run(.close)
            case .merge(let method):
                guard let detail else { return }
                await run(.merge(method, headSHA: detail.headSHA, baseRef: detail.baseRef))
            }
        }
    }

    private func run(_ action: DevPullAction) async {
        isRunning = true
        defer { isRunning = false }
        do {
            try await model.perform(action, on: pull)
            await reload()
        } catch {
            model.actionError = "#\(pull.number): \(error.localizedDescription)"
        }
    }

    private func reload() async {
        do {
            detail = try await model.detail(of: pull)
            problem = nil
        } catch {
            detail = nil
            problem = error.localizedDescription
        }
    }
}

private struct DevPullComposer: View {
    let title: String
    let requiresText: Bool
    let send: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).appFont(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.35)))
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if isSending { ProgressView().controlSize(.small) }
                Button("Send") {
                    Task {
                        isSending = true
                        await send(text)
                        isSending = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isSending || (requiresText && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
