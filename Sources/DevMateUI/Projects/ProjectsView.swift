import AppKit
import DevMateCore
import SwiftUI

/// The Projects view: the filter row, a sortable table or a board, and the
/// selected item's detail beside it. It shows what its provider declares and
/// uses the provider's words.
public struct ProjectsView: View {
    @ObservedObject var model: ProjectsModel
    private let showsRefresh: Bool

    /// `showsRefresh: false` leaves out the toolbar's refresh button, for an
    /// app that supplies its own and calls `model.refresh()`.
    public init(model: ProjectsModel, showsRefresh: Bool = true) {
        self.model = model
        self.showsRefresh = showsRefresh
    }

    public var body: some View {
        VStack(spacing: 0) {
            ProjectsErrorBanner(message: $model.actionError)
            MoveFailureBanner(model: model)
            ProjectsFilterRow(model: model)
            Divider()
            DetailSplitView(fraction: $model.detailFraction, showsDetail: model.selectedItem != nil,
                            minLeading: 360, minTrailing: 400) {
                Group {
                    switch model.mode {
                    case .board: WorkBoardView(model: model)
                    case .queries: QueriesPane(model: model)
                    case .mine, .recent, .all: WorkItemTable(model: model)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    ProjectsLoadFooter(isLoading: model.isLoading, loadedAt: model.loadedAt, errors: model.loadErrors,
                                       count: "\(model.visible.count) \(model.vocabulary.itemNoun.lowercased())s")
                }
            } trailing: {
                WorkItemDetailView(model: model)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.features.contains(.create) {
                    Button {
                        model.showingNewItem = true
                    } label: {
                        Label("New \(model.vocabulary.itemNoun)", systemImage: "square.and.pencil")
                    }
                    .help("New \(model.vocabulary.itemNoun) (⌘N)")
                }
                if showsRefresh {
                    Button {
                        model.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Read the \(model.vocabulary.itemNoun.lowercased())s again (⌘R)")
                }
            }
        }
        .searchable(text: $model.query.search, placement: .toolbar,
                    prompt: "Filter \(model.vocabulary.itemNoun.lowercased())s")
        .onAppear { model.load() }
        .sheet(isPresented: $model.showingNewItem) {
            WorkItemEditorSheet(model: model, mode: .create(container: model.newItemContainer))
        }
        .sheet(isPresented: $model.editingItem) {
            if let item = model.detail { WorkItemEditorSheet(model: model, mode: .edit(item)) }
        }
    }
}

// MARK: - Filter row

/// Container, Tag, Person, Plan and State, in the provider's words. On a
/// narrow window it wraps onto two lines rather than clip.
struct ProjectsFilterRow: View {
    @ObservedObject var model: ProjectsModel

    private var words: ProjectsVocabulary { model.vocabulary }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                modePicker
                filters
                statePicker
                clearButton
                Spacer(minLength: 0)
                if model.mode == .board { boardSource }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    modePicker
                    statePicker
                    Spacer(minLength: 0)
                    if model.mode == .board { boardSource }
                }
                HStack(spacing: 10) {
                    filters
                    clearButton
                    Spacer(minLength: 0)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var modePicker: some View {
        Picker("View", selection: $model.mode) {
            ForEach(model.availableModes, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("View")
    }

    @ViewBuilder
    private var filters: some View {
        Picker(words.container, selection: $model.query.container) {
            Text("All \(words.containerPlural)").tag(String?.none)
            Divider()
            ForEach(model.configuration.containers, id: \.self) { Text($0).tag(Optional($0)) }
        }
        .frame(maxWidth: 210)
        if model.features.contains(.tags) {
            Picker(words.tag, selection: $model.query.tag) {
                Text("Any \(words.tag)").tag(String?.none)
                Divider()
                ForEach(model.knownTags, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .frame(maxWidth: 170)
        }
        if model.features.contains(.people) {
            Picker(words.person, selection: $model.query.person) {
                Text("Anyone").tag(String?.none)
                Text("Unassigned").tag(Optional(IssueQuery.unassigned))
                Divider()
                ForEach(model.knownPeople, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .frame(maxWidth: 180)
        }
        if model.features.contains(.plans) {
            Picker(words.plan, selection: $model.query.plan) {
                Text("Any \(words.plan)").tag(String?.none)
                Text("No \(words.plan)").tag(Optional(IssueQuery.noPlan))
                Divider()
                ForEach(model.knownPlans, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .frame(maxWidth: 190)
        }
    }

    private var statePicker: some View {
        Picker(words.state, selection: $model.query.state) {
            ForEach(IssueQuery.StateFilter.allCases, id: \.self) { Text(words.title(for: $0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 170)
        .accessibilityLabel(words.state)
    }

    @ViewBuilder
    private var clearButton: some View {
        if model.query.isFiltered {
            Button("Clear Filters") { model.clearFilters() }
        }
    }

    /// A provider board's columns when there is one, or the items grouped.
    private var boardSource: some View {
        Picker("Board", selection: boardBinding) {
            ForEach(IssueGrouping.available(features: model.features), id: \.self) { grouping in
                Text("By \(grouping.title(vocabulary: words))").tag(BoardSource.group(grouping))
            }
            if !model.boards.isEmpty {
                Divider()
                ForEach(model.boards) { board in
                    Text("Board: \(board.title)").tag(BoardSource.board(board.id))
                }
            }
        }
        .frame(maxWidth: 230)
        .help(model.boards.isEmpty ? "No boards were found, so this groups the \(words.itemNoun.lowercased())s"
            : "Group the \(words.itemNoun.lowercased())s, or show a board's columns")
    }

    private var boardBinding: Binding<BoardSource> {
        Binding {
            model.boardID.map(BoardSource.board) ?? .group(model.grouping)
        } set: { source in
            switch source {
            case .group(let grouping):
                model.boardID = nil
                model.grouping = grouping
            case .board(let id):
                model.boardID = id
            }
        }
    }
}

enum BoardSource: Hashable {
    case group(IssueGrouping)
    case board(String)
}

// MARK: - Table

struct WorkItemTable: View {
    @ObservedObject var model: ProjectsModel
    var emptyTitle: String?

    private var sortBinding: Binding<[KeyPathComparator<WorkItem>]> {
        Binding {
            [model.sort.comparator]
        } set: { order in
            if let first = order.first { model.sort = WorkItemSort(comparator: first) }
        }
    }

    var body: some View {
        let rows = model.visible.sorted(using: model.sort.comparator)
        let words = model.vocabulary
        Table(of: WorkItem.self, selection: $model.selectedItemID, sortOrder: sortBinding,
              columnCustomization: $model.columnCustomization) {
            TableColumn("#", value: \.number) { item in
                Text("\(item.number)").devFont(.body).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 50)
            .customizationID("number")
            TableColumn("Title", value: \.title) { item in
                HStack(spacing: 6) {
                    WorkStateIcon(item: item)
                    Text(item.title).devFont(.body).lineLimit(1).help(item.title)
                    ForEach(item.tags.prefix(3)) { TagChip(tag: $0) }
                }
            }
            .width(min: 220, ideal: 400)
            .customizationID("title")
            TableColumn(words.container, value: \.container) { item in
                Text(item.container).devFont(.body).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            .customizationID("container")
            TableColumn(words.person + "s") { (item: WorkItem) in
                Text(item.people.map(\.id).joined(separator: ", ")).devFont(.body).lineLimit(1)
            }
            .width(min: 80, ideal: 120)
            .customizationID("people")
            TableColumn(words.plan, value: \.sortPlan) { item in
                Text(item.plan?.title ?? "").devFont(.body).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 120)
            .customizationID("plan")
            TableColumn("Updated", value: \.sortUpdated) { item in
                Text(WorkTime.relative(item.updatedAt)).devFont(.body).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            .customizationID("updated")
        } rows: {
            ForEach(rows) { item in
                TableRow(item)
                    .draggable(WorkCardDrag(boardKey: "table", cardID: item.id, columnKey: nil, title: item.title,
                                            url: item.url))
            }
        }
        .contextMenu(forSelectionType: WorkItem.ID.self) { ids in
            if let item = rows.first(where: { ids.contains($0.id) }) {
                WorkItemMenuItems(model: model, item: item)
            }
        } primaryAction: { ids in
            if let item = rows.first(where: { ids.contains($0.id) }) { WorkLinks.open(item.url) }
        }
        .onCopyCommand {
            guard let item = model.selectedItem else { return [] }
            return [NSItemProvider(object: "\(model.provider.reference(for: item)) \(item.title)\n\(item.url)" as NSString)]
        }
        .overlay {
            if rows.isEmpty { emptyState }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let noun = model.vocabulary.itemNoun
        if model.isLoading {
            ProgressView("Reading \(noun.lowercased())s…")
        } else if model.mode == .mine && model.currentPerson == nil {
            ContentUnavailableView("Not Signed In", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("Mine needs to know who you are on \(model.vocabulary.siteName)."))
        } else {
            ContentUnavailableView(emptyTitle ?? "No \(noun)s", systemImage: "list.bullet.rectangle",
                                   description: Text(model.query.isFiltered ? "Nothing matches the filters."
                                       : "Nothing here in this state."))
        }
    }
}

/// What an item's context menu and board card offer.
struct WorkItemMenuItems: View {
    @ObservedObject var model: ProjectsModel
    let item: WorkItem

    var body: some View {
        Button("Open in Browser") { WorkLinks.open(item.url) }
        if model.canOpenLane {
            Button("Open Lane on This \(model.vocabulary.itemNoun)") { model.openLane(on: item) }
        }
        if model.features.contains(.closeReopen) {
            Divider()
            if item.isOpen {
                if model.provider.closeReasons.isEmpty {
                    Button("Close") { model.close(item, reason: nil) }
                }
                ForEach(model.provider.closeReasons) { reason in
                    Button("Close as \(reason.title)") { model.close(item, reason: reason) }
                }
            } else {
                Button("Reopen") { model.reopen(item) }
            }
        }
        Divider()
        Button("Copy Link") { WorkLinks.copy(item.url, url: item.url) }
        Button("Copy Reference") { WorkLinks.copy(model.provider.reference(for: item)) }
    }
}

// MARK: - Queries

/// Saved queries, for a provider that declares them.
struct QueriesPane: View {
    @ObservedObject var model: ProjectsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Query", selection: $model.selectedQueryID) {
                    if model.queries.isEmpty { Text("No Saved Queries").tag(String?.none) }
                    ForEach(model.queries) { Text($0.title).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 320)
                if model.isRunningQuery { ProgressView().controlSize(.small) }
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            WorkItemTable(model: model, emptyTitle: "No Results")
        }
        .onAppear { model.loadQueries() }
    }
}
