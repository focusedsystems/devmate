import DevMateCore
import SwiftUI

/// One item in full: its body as Markdown, comments, tags, people, plan and
/// linked pull requests, with every change its provider declares.
struct WorkItemDetailView: View {
    @ObservedObject var model: ProjectsModel

    private var words: ProjectsVocabulary { model.vocabulary }
    private var features: ProjectFeatures { model.features }

    var body: some View {
        if let item = model.selectedFullItem {
            VStack(alignment: .leading, spacing: 0) {
                header(item)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        metadata(item)
                        if let error = model.detailError {
                            Label(error, systemImage: "exclamationmark.triangle").devFont(.callout).foregroundStyle(.orange)
                        }
                        Divider()
                        if model.detail?.id != item.id && model.isLoadingDetail {
                            ProgressView("Reading the \(words.itemNoun.lowercased())…").frame(maxWidth: .infinity)
                        } else {
                            WorkMarkdown(content: item.body ?? "", provider: model.provider)
                            comments(item.comments ?? [])
                            if features.contains(.comment) { CommentComposer(model: model, item: item) }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ContentUnavailableView("No \(words.itemNoun) Selected", systemImage: "list.bullet.rectangle",
                                   description: Text("Choose one in the list."))
        }
    }

    // MARK: Header

    private func header(_ item: WorkItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                WorkStateIcon(item: item)
                Text(item.title).devFont(.title3, weight: .semibold).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.isWorking || model.isLoadingDetail { ProgressView().controlSize(.small) }
            }
            Text(subtitle(item)).devFont(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if model.canOpenLane {
                    Button {
                        model.openLane(on: item)
                    } label: {
                        Label("Open Lane on This \(words.itemNoun)", systemImage: "terminal")
                    }
                    .help("Start a lane in \(item.container) with this \(words.itemNoun.lowercased()) pasted as its prompt. Read it, then press Return (⌘L)")
                }
                if features.contains(.edit) {
                    Button("Edit…") { model.editingItem = true }
                        .disabled(model.detail?.id != item.id)
                        .help("Edit the title and description (⌘E)")
                }
                if features.contains(.closeReopen) { closeControl(item) }
                Spacer(minLength: 0)
                Button {
                    WorkLinks.open(item.url)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .labelStyle(.iconOnly)
                .help("Open on \(words.siteName) (⇧⌘O)")
                Button {
                    model.selectedItemID = nil
                } label: {
                    Label("Close Detail", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .help("Hide the detail")
            }
            .controlSize(.small)
            .disabled(model.isWorking)
        }
        .padding(12)
    }

    @ViewBuilder
    private func closeControl(_ item: WorkItem) -> some View {
        if !item.isOpen {
            Button("Reopen") { model.reopen(item) }
        } else if model.provider.closeReasons.isEmpty {
            Button("Close") { model.close(item, reason: nil) }
        } else {
            Menu("Close") {
                ForEach(model.provider.closeReasons) { reason in
                    Button("Close as \(reason.title)") { model.close(item, reason: reason) }
                }
            }
            .fixedSize()
        }
    }

    private func subtitle(_ item: WorkItem) -> String {
        var parts = ["\(item.container) #\(item.number)"]
        if let author = item.author { parts.append("opened by \(author.id)") }
        if let created = item.createdAt { parts.append(created.formatted(date: .abbreviated, time: .omitted)) }
        if !item.isOpen, let closed = item.closedAt { parts.append("closed \(WorkTime.relative(closed))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Metadata

    private func metadata(_ item: WorkItem) -> some View {
        let known = model.metadata[item.container] ?? WorkMetadata()
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            if features.contains(.tags) { tagsRow(item, known: known) }
            if features.contains(.people) { peopleRow(item, known: known) }
            if features.contains(.plans) { planRow(item, known: known) }
            if features.contains(.linkedPullRequests) { linksRow }
        }
        .disabled(model.isWorking)
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text).devFont(.callout).foregroundStyle(.secondary)
    }

    private func tagsRow(_ item: WorkItem, known: WorkMetadata) -> some View {
        GridRow {
            rowTitle(words.tag + "s")
            HStack(spacing: 6) {
                TagFlow(tags: item.tags)
                Menu {
                    ForEach(known.tags) { tag in
                        Toggle(tag.name, isOn: Binding(get: { item.tags.contains { $0.name == tag.name } },
                                                       set: { _ in model.toggleTag(tag.name, on: item) }))
                    }
                    if known.tags.isEmpty { Text("No \(words.tag.lowercased())s in \(item.container)") }
                } label: {
                    Label("Edit \(words.tag)s", systemImage: "tag")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add or remove \(words.tag.lowercased())s")
            }
        }
    }

    private func peopleRow(_ item: WorkItem, known: WorkMetadata) -> some View {
        GridRow {
            rowTitle(words.person + "s")
            HStack(spacing: 6) {
                Text(item.people.isEmpty ? "No one" : item.people.map(\.id).joined(separator: ", "))
                    .devFont(.body).foregroundStyle(item.people.isEmpty ? .secondary : .primary)
                Menu {
                    ForEach(known.people) { person in
                        Toggle(person.id, isOn: Binding(get: { item.people.contains { $0.id == person.id } },
                                                        set: { _ in model.togglePerson(person.id, on: item) }))
                    }
                    if known.people.isEmpty { Text("No one can be assigned") }
                } label: {
                    Label("Assign", systemImage: "person.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Assign or unassign people")
            }
        }
    }

    private func planRow(_ item: WorkItem, known: WorkMetadata) -> some View {
        GridRow {
            rowTitle(words.plan)
            Picker(words.plan, selection: Binding(get: { item.plan?.id }, set: { model.setPlan($0, on: item) })) {
                Text("None").tag(String?.none)
                if let current = item.plan, !known.plans.contains(where: { $0.id == current.id }) {
                    Text(current.title).tag(Optional(current.id))
                }
                ForEach(known.plans) { Text($0.title).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var linksRow: some View {
        GridRow {
            rowTitle("Pull Requests")
            if model.links.isEmpty {
                Text("None linked").devFont(.body).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.links) { link in
                        Button {
                            WorkLinks.open(link.url)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.pull")
                                    .foregroundStyle(link.state == "MERGED" ? .purple : link.state == "OPEN" ? .green : .secondary)
                                Text("\(link.container) #\(link.number) \(link.title)").devFont(.body).lineLimit(1)
                                Text(link.state.capitalized + (link.closesItem ? ", closes" : ""))
                                    .devFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.link)
                        .help(link.url)
                    }
                }
            }
        }
    }

    // MARK: Comments

    @ViewBuilder
    private func comments(_ comments: [WorkComment]) -> some View {
        if !comments.isEmpty {
            Text("\(comments.count) Comment\(comments.count == 1 ? "" : "s")").devFont(.headline)
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(comment.author?.id ?? "unknown").devFont(.callout, weight: .semibold)
                        Text(WorkTime.relative(comment.createdAt)).devFont(.caption).foregroundStyle(.secondary)
                            .help(comment.createdAt?.formatted() ?? "")
                        Spacer()
                        if let url = comment.url {
                            Button("Copy Link") { WorkLinks.copy(url, url: url) }
                                .buttonStyle(.link).devFont(.caption)
                        }
                    }
                    WorkMarkdown(content: comment.body, provider: model.provider)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
    }
}

/// The comment box. Each item keeps its own draft, and a draft is cleared only
/// once it has posted.
private struct CommentComposer: View {
    @ObservedObject var model: ProjectsModel
    let item: WorkItem

    private var draft: Binding<String> {
        Binding(get: { model.commentDraft(for: item.id) }, set: { model.setCommentDraft($0, for: item.id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add a Comment").devFont(.headline)
            TextEditor(text: draft)
                .devFont(.body)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Comment")
            HStack {
                Text("Markdown. ⌘Return comments.").devFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Comment") {
                    Task { await model.postComment(on: item) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
            }
        }
    }
}

/// Tags that wrap onto more lines when there are many.
private struct TagFlow: View {
    let tags: [WorkTag]

    var body: some View {
        if tags.isEmpty {
            Text("None").devFont(.body).foregroundStyle(.secondary)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { ForEach(tags) { TagChip(tag: $0) } }
                VStack(alignment: .leading, spacing: 4) { ForEach(tags) { TagChip(tag: $0) } }
            }
        }
    }
}

// MARK: - New and edit

/// A sheet for a new item or for editing an item's title and body. It stays
/// open with the text intact when the provider refuses.
struct WorkItemEditorSheet: View {
    enum Mode {
        case create(container: String)
        case edit(WorkItem)
    }

    @ObservedObject var model: ProjectsModel
    let mode: Mode
    @Environment(\.dismiss) private var dismiss

    @State private var container = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var tags: Set<String> = []
    @State private var people: Set<String> = []
    @State private var plan: String?
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var titleFocused: Bool

    private var isCreate: Bool { if case .create = mode { return true } else { return false } }
    private var words: ProjectsVocabulary { model.vocabulary }

    var body: some View {
        let known = model.metadata[container] ?? WorkMetadata()
        VStack(alignment: .leading, spacing: 12) {
            Text(isCreate ? "New \(words.itemNoun)" : "Edit \(words.itemNoun)").devFont(.title3, weight: .semibold)
            Form {
                if isCreate {
                    Picker(words.container, selection: $container) {
                        ForEach(model.configuration.containers, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Title", text: $title)
                    .focused($titleFocused)
                LabeledContent("Description") {
                    TextEditor(text: $bodyText)
                        .devFont(.body)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Description")
                }
                if isCreate { createFields(known) }
            }
            .formStyle(.grouped)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").devFont(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCreate ? "Create \(words.itemNoun)" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear {
            switch mode {
            case .create(let initial):
                container = initial
            case .edit(let item):
                container = item.container
                title = item.title
                bodyText = item.body ?? ""
            }
            model.loadMetadata(container)
            titleFocused = true
        }
        .onChange(of: container) { old, new in
            guard !old.isEmpty else { return }
            tags = []
            people = []
            plan = nil
            model.loadMetadata(new)
        }
    }

    @ViewBuilder
    private func createFields(_ known: WorkMetadata) -> some View {
        if model.features.contains(.tags) {
            LabeledContent(words.tag + "s") {
                Menu(tags.isEmpty ? "None" : tags.sorted().joined(separator: ", ")) {
                    ForEach(known.tags) { tag in
                        Toggle(tag.name, isOn: Binding(get: { tags.contains(tag.name) }, set: { on in
                            if on { tags.insert(tag.name) } else { tags.remove(tag.name) }
                        }))
                    }
                }
                .fixedSize()
            }
        }
        if model.features.contains(.people) {
            LabeledContent(words.person + "s") {
                Menu(people.isEmpty ? "No one" : people.sorted().joined(separator: ", ")) {
                    ForEach(known.people) { person in
                        Toggle(person.id, isOn: Binding(get: { people.contains(person.id) }, set: { on in
                            if on { people.insert(person.id) } else { people.remove(person.id) }
                        }))
                    }
                }
                .fixedSize()
            }
        }
        if model.features.contains(.plans) {
            Picker(words.plan, selection: $plan) {
                Text("None").tag(String?.none)
                ForEach(known.plans) { Text($0.title).tag(Optional($0.id)) }
            }
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        failure = nil
        // The model's error line sits behind this sheet, so the sheet shows it.
        let earlier = model.actionError
        model.actionError = nil
        Task {
            let done: Bool
            switch mode {
            case .create:
                done = await model.create(WorkItemDraft(container: container, title: cleanTitle, body: bodyText,
                                                        tags: tags.sorted(), people: people.sorted(), plan: plan))
            case .edit(let item):
                done = await model.saveEdit(item, title: cleanTitle, body: bodyText)
            }
            saving = false
            if done {
                model.actionError = earlier
                dismiss()
            } else {
                failure = model.actionError ?? "That did not save."
                model.actionError = earlier
            }
        }
    }
}
