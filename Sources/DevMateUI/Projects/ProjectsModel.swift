import DevMateCore
import Foundation
import SwiftUI

/// What an app configures about its Projects view.
public struct ProjectsConfiguration: Sendable {
    /// The repositories, projects or areas to read, in menu order.
    public var containers: [String]
    /// Where a new item goes when no filter says otherwise.
    public var defaultContainer: String?
    /// The prefix on every saved setting.
    public var defaultsPrefix: String
    /// Keeps the last list, to show at launch. Nil keeps nothing.
    public var cache: DiskCache?
    /// Nil hides "Open Lane".
    public var lanePolicy: LanePromptPolicy?

    public init(containers: [String], defaultContainer: String? = nil, defaultsPrefix: String = "projects.",
                cache: DiskCache? = nil, lanePolicy: LanePromptPolicy? = nil) {
        self.containers = containers
        self.defaultContainer = defaultContainer
        self.defaultsPrefix = defaultsPrefix
        self.cache = cache
        self.lanePolicy = lanePolicy
    }
}

/// A card move that failed and was put back, for the banner and Try Again.
public struct BoardMoveFailure: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public var cardID: String
    public var title: String
    public var destination: String
    public var message: String
    let retry: BoardMoveIntent

    public static func == (lhs: BoardMoveFailure, rhs: BoardMoveFailure) -> Bool { lhs.id == rhs.id }
}

enum BoardMoveIntent: Equatable, Sendable {
    case card(boardID: String, cardID: String, columnID: String)
    case grouped(grouping: IssueGrouping, itemID: String, from: String?, to: String?)
}

/// A place a card can go, for the "Move to" menu.
public struct BoardMoveTarget: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isCurrent: Bool
}

/// The Projects view's state. An app owns one, so switching tabs keeps what
/// was read and what was selected.
@MainActor
public final class ProjectsModel: ObservableObject {
    public enum Mode: String, CaseIterable, Hashable, Sendable {
        case mine = "Mine"
        case recent = "Recent"
        case all = "All"
        case queries = "Queries"
        case board = "Board"
    }

    /// How long Recent looks back.
    public static let recentWindow: TimeInterval = 14 * 24 * 3600
    /// Older than this, showing the list reads it again.
    static let freshness: TimeInterval = 5 * 60
    /// How many containers are read at once.
    nonisolated static let readLimit = 6

    public let provider: any ProjectsProvider
    public let configuration: ProjectsConfiguration
    private let defaults: UserDefaults

    /// Opens a lane. The only thing it receives is a request the safety layer
    /// built, whose prompt is pasted for the person to read and send.
    public var onOpenLane: ((SafeLaneRequest) -> Void)?

    @Published public private(set) var items: [WorkItem] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var loadedAt: Date?
    @Published public private(set) var loadErrors: [String] = []
    @Published public private(set) var currentPerson: String?

    @Published public var query: IssueQuery {
        didSet {
            var stored = query
            stored.search = ""
            if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: key("query")) }
        }
    }
    @Published public var mode: Mode {
        didSet {
            defaults.set(mode.rawValue, forKey: key("mode"))
            if mode != .board { lastListMode = mode }
            if mode == .queries { loadQueries() }
        }
    }
    @Published public var grouping: IssueGrouping {
        didSet { defaults.set(grouping.rawValue, forKey: key("grouping")) }
    }
    /// A provider board's id, or nil to group the items.
    @Published public var boardID: String? {
        didSet {
            defaults.set(boardID, forKey: key("board"))
            if let boardID, boardID != oldValue { loadBoard(boardID) }
        }
    }
    @Published public var detailFraction: Double {
        didSet { defaults.set(detailFraction, forKey: key("detailFraction")) }
    }
    @Published var sort: WorkItemSort {
        didSet { defaults.set(sort.stored, forKey: key("sort")) }
    }
    @Published var columnCustomization: TableColumnCustomization<WorkItem> {
        didSet {
            if let data = try? JSONEncoder().encode(columnCustomization) { defaults.set(data, forKey: key("columns")) }
        }
    }

    @Published public var selectedItemID: WorkItem.ID? {
        didSet {
            defaults.set(selectedItemID, forKey: key("selectedIssue"))
            if selectedItemID != oldValue { loadDetail() }
        }
    }
    @Published public private(set) var detail: WorkItem?
    @Published public private(set) var links: [WorkLink] = []
    @Published public private(set) var isLoadingDetail = false
    @Published public private(set) var detailError: String?
    @Published public private(set) var metadata: [String: WorkMetadata] = [:]

    @Published public private(set) var boards: [WorkBoardSummary] = []
    @Published private var loadedBoards: [String: WorkBoard] = [:]
    @Published public private(set) var boardError: String?
    /// Card moves waiting on the provider, by card id.
    @Published private var pendingCards: [String: PendingCardMove] = [:]
    /// Item changes waiting on the provider, by item id.
    @Published private var pendingItems: [String: WorkItem] = [:]
    @Published public var moveFailure: BoardMoveFailure?

    @Published public private(set) var queries: [WorkQuerySummary] = []
    @Published public var selectedQueryID: String? {
        didSet {
            defaults.set(selectedQueryID, forKey: key("query.selected"))
            if selectedQueryID != oldValue { runSelectedQuery() }
        }
    }
    @Published public private(set) var queryResults: [WorkItem] = []
    @Published public private(set) var isRunningQuery = false

    @Published public var actionError: String?
    @Published public private(set) var isWorking = false
    @Published public var showingNewItem = false
    @Published public var editingItem = false
    @Published private var commentDrafts: [String: String] = [:]

    private struct PendingCardMove { var boardID: String; var columnID: String }

    private var lastListMode: Mode = .all
    private var detailTask: Task<Void, Never>?
    private var boardGenerations: [String: Int] = [:]
    private var loadGeneration = 0
    private var queryGeneration = 0
    /// Items changed while a list read was out, whose answer would be older.
    private var changedDuringLoad: Set<String> = []

    public init(provider: any ProjectsProvider, configuration: ProjectsConfiguration,
                defaults: UserDefaults = .standard) {
        self.provider = provider
        self.configuration = configuration
        self.defaults = defaults
        let prefix = configuration.defaultsPrefix
        query = defaults.data(forKey: prefix + "query").flatMap { try? JSONDecoder().decode(IssueQuery.self, from: $0) }
            ?? IssueQuery()
        // An app that saved List or Board before the views existed.
        let legacyLayout = defaults.string(forKey: prefix + "layout")
        let savedMode = Mode(rawValue: defaults.string(forKey: prefix + "mode") ?? "")
        let initialMode = savedMode ?? (legacyLayout == "Board" ? .board : .all)
        mode = initialMode == .queries && !provider.features.contains(.queries) ? .all : initialMode
        grouping = IssueGrouping(rawValue: defaults.string(forKey: prefix + "grouping") ?? "") ?? .plan
        boardID = defaults.string(forKey: prefix + "board")
            ?? (defaults.object(forKey: prefix + "boardProject") as? Int).map(String.init)
        detailFraction = defaults.object(forKey: prefix + "detailFraction") as? Double ?? 0.5
        sort = WorkItemSort(stored: defaults.string(forKey: prefix + "sort"))
        columnCustomization = defaults.data(forKey: prefix + "columns")
            .flatMap { try? JSONDecoder().decode(TableColumnCustomization<WorkItem>.self, from: $0) } ?? .init()
        selectedQueryID = defaults.string(forKey: prefix + "query.selected")
        if let data = defaults.data(forKey: prefix + "commentDrafts"),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            commentDrafts = saved
        }
        if let cached = configuration.cache?.load([WorkItem].self, key: Self.cacheKey) { items = cached.value }
        selectedItemID = defaults.string(forKey: prefix + "selectedIssue")
        // A single draft from before drafts were kept per item belongs to the
        // item that was open, which is the one it would have been sent to.
        if let old = defaults.string(forKey: prefix + "commentDraft") {
            if !old.isEmpty, let id = selectedItemID, commentDrafts[id] == nil { setCommentDraft(old, for: id) }
            defaults.removeObject(forKey: prefix + "commentDraft")
        }
        if mode != .board { lastListMode = mode }
    }

    static let cacheKey = "projects.items"

    private func key(_ name: String) -> String { configuration.defaultsPrefix + name }

    // MARK: What shows

    public var vocabulary: ProjectsVocabulary { provider.vocabulary }
    public var features: ProjectFeatures { provider.features }

    public var availableModes: [Mode] {
        Mode.allCases.filter { $0 != .queries || features.contains(.queries) }
    }

    /// Every item, with changes still on their way shown as if landed.
    var displayedItems: [WorkItem] {
        guard !pendingItems.isEmpty else { return items }
        return items.map { pendingItems[$0.id] ?? $0 }
    }

    /// The items the open view and the filters leave.
    public var visible: [WorkItem] { visible(now: Date()) }

    func visible(now: Date) -> [WorkItem] {
        let base: [WorkItem]
        switch mode {
        case .mine:
            guard let me = currentPerson else { return [] }
            base = displayedItems.filter { $0.people.contains { $0.id == me } }
        case .recent:
            let cutoff = now.addingTimeInterval(-Self.recentWindow)
            base = displayedItems.filter { ($0.updatedAt ?? .distantPast) >= cutoff }
        case .queries:
            base = queryResults
        case .all, .board:
            base = displayedItems
        }
        return query.apply(base)
    }

    public var selectedItem: WorkItem? {
        guard let id = selectedItemID else { return nil }
        return pendingItems[id] ?? items.first { $0.id == id } ?? queryResults.first { $0.id == id }
    }

    /// The selected item with its body and comments when they have been read.
    public var selectedFullItem: WorkItem? {
        guard let summary = selectedItem else { return nil }
        guard var full = detail, full.id == summary.id else { return summary }
        if pendingItems[summary.id] != nil {
            full.tags = summary.tags
            full.people = summary.people
            full.plan = summary.plan
            full.isOpen = summary.isOpen
            full.stateName = summary.stateName
            full.resolution = summary.resolution
        }
        return full
    }

    public var knownTags: [String] {
        Set(items.flatMap { $0.tags.map(\.name) }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public var knownPeople: [String] { Set(items.flatMap { $0.people.map(\.id) }).sorted() }

    public var knownPlans: [String] {
        Set(items.compactMap { $0.plan?.title }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public var newItemContainer: String {
        query.container ?? selectedItem?.container ?? configuration.defaultContainer
            ?? configuration.containers.first ?? ""
    }

    /// The open board with moves still on their way shown as if landed.
    var displayedBoard: WorkBoard? {
        guard let boardID, var board = loadedBoards[boardID] else { return nil }
        for (cardID, move) in pendingCards where move.boardID == boardID {
            board = board.moving(cardID, to: move.columnID)
        }
        return board
    }

    func isPending(cardID: String) -> Bool { pendingCards[cardID] != nil || pendingItems[cardID] != nil }

    public func commentDraft(for id: WorkItem.ID) -> String { commentDrafts[id] ?? "" }

    public func setCommentDraft(_ text: String, for id: WorkItem.ID) {
        if text.isEmpty { commentDrafts[id] = nil } else { commentDrafts[id] = text }
        if let data = try? JSONEncoder().encode(commentDrafts) { defaults.set(data, forKey: key("commentDrafts")) }
    }

    public func clearFilters() { query = IssueQuery(state: query.state) }

    /// Between the board and the list view last open.
    public func toggleBoard() { mode = mode == .board ? lastListMode : .board }

    // MARK: Loading

    public func refresh() {
        load(force: true)
        loadDetail()
        if mode == .queries { loadQueries() }
    }

    /// A quiet read for a cadence or the window becoming key: nothing when the
    /// list was read within `age` seconds, and no change on screen unless the
    /// data changed.
    public func refreshIfOlder(than age: TimeInterval) {
        guard loadedAt.map({ Date().timeIntervalSince($0) > age }) ?? true else { return }
        load(force: true)
        if detail != nil { loadDetail() }
        if mode == .queries { loadQueries() }
    }

    public func load(force: Bool = false) {
        let isStale = loadedAt.map { Date().timeIntervalSince($0) > Self.freshness } ?? true
        guard !isLoading, force || isStale else { return }
        isLoading = true
        loadGeneration += 1
        changedDuringLoad = []
        let generation = loadGeneration
        let provider = provider
        let containers = configuration.containers
        Task {
            let (rows, errors, failed) = await Self.gather(containers, provider: provider)
            guard generation == loadGeneration else { return }
            var merged = rows.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            // What changed while this read was out is newer than its answer.
            for id in changedDuringLoad {
                guard let current = items.first(where: { $0.id == id }) else { continue }
                if let index = merged.firstIndex(where: { $0.id == id }) { merged[index] = current } else { merged.insert(current, at: 0) }
            }
            // A container that failed keeps the items already showing.
            if !failed.isEmpty {
                let read = Set(merged.map(\.id))
                merged += items.filter { failed.contains($0.container) && !read.contains($0.id) }
            }
            if items != merged { items = merged }
            loadedAt = Date()
            if loadErrors != errors { loadErrors = errors }
            isLoading = false
            changedDuringLoad = []
            configuration.cache?.save(merged, key: Self.cacheKey)
            if detail == nil { loadDetail() }
        }
        loadPerson()
        loadBoards()
    }

    /// Reads every container, a few at a time. One that fails is named in
    /// the errors and the rest still show.
    nonisolated static func gather(_ containers: [String], provider: any ProjectsProvider) async
        -> (rows: [WorkItem], errors: [String], failed: Set<String>) {
        await withTaskGroup(of: (String, Result<[WorkItem], Error>).self) { group in
            var rows: [WorkItem] = []
            var errors: [String] = []
            var failed: Set<String> = []
            var pending = containers.makeIterator()
            func addNext() {
                guard let container = pending.next() else { return }
                group.addTask { await read(container, from: provider) }
            }
            for _ in 0..<readLimit { addNext() }
            while let (container, result) = await group.next() {
                switch result {
                case .success(let found):
                    rows += found
                case .failure(let error):
                    errors.append("\(container): \(error.localizedDescription)")
                    failed.insert(container)
                }
                addNext()
            }
            return (rows, errors.sorted(), failed)
        }
    }

    /// One container's items, or why they could not be read. The catch lives
    /// here, not inline in the child task's closure: optimized builds of that
    /// inline form let a child finish after its group was gone, which aborts
    /// the app.
    nonisolated static func read(_ container: String, from provider: any ProjectsProvider) async
        -> (String, Result<[WorkItem], Error>) {
        do { return (container, .success(try await provider.items(in: container))) }
        catch { return (container, .failure(error)) }
    }

    private func loadPerson() {
        guard currentPerson == nil else { return }
        let provider = provider
        Task {
            if let person = try? await provider.currentPerson() { currentPerson = person }
        }
    }

    public func loadBoards() {
        guard features.contains(.boards) else { return }
        let provider = provider
        Task {
            do {
                let found = try await provider.boards()
                if boards != found { boards = found }
                if boardError != nil { boardError = nil }
                if let id = boardID, !found.contains(where: { $0.id == id }) { boardID = nil }
                if let id = boardID { loadBoard(id) }
            } catch {
                boardError = error.localizedDescription
            }
        }
    }

    public func loadBoard(_ id: String) {
        guard features.contains(.boards) else { return }
        let generation = (boardGenerations[id] ?? 0) + 1
        boardGenerations[id] = generation
        let provider = provider
        Task {
            do {
                let board = try await provider.board(id: id)
                guard boardGenerations[id] == generation else { return }
                loadedBoards[id] = board
            } catch {
                guard boardGenerations[id] == generation else { return }
                actionError = error.localizedDescription
            }
        }
    }

    public func loadDetail() {
        detailTask?.cancel()
        guard let item = selectedItem else {
            detail = nil
            links = []
            isLoadingDetail = false
            return
        }
        if detail?.id != item.id {
            detail = nil
            links = []
        }
        isLoadingDetail = true
        detailError = nil
        let container = item.container, number = item.number
        let wantsLinks = features.contains(.linkedPullRequests)
        let provider = provider
        detailTask = Task {
            do {
                async let full = provider.item(container: container, number: number)
                async let found = wantsLinks ? (try? await provider.links(for: item)) ?? [] : []
                let (value, foundLinks) = try await (full, found)
                guard !Task.isCancelled else { return }
                detail = value
                links = foundLinks
                replaceInList(value)
            } catch {
                guard !Task.isCancelled else { return }
                detailError = error.localizedDescription
            }
            if !Task.isCancelled { isLoadingDetail = false }
        }
        loadMetadata(container)
    }

    public func loadMetadata(_ container: String, force: Bool = false) {
        guard force || metadata[container] == nil else { return }
        metadata[container] = metadata[container] ?? WorkMetadata()
        let provider = provider
        Task {
            if let found = try? await provider.metadata(for: container) { metadata[container] = found }
        }
    }

    private func replaceInList(_ value: WorkItem) {
        guard let index = items.firstIndex(where: { $0.id == value.id }) else { return }
        items[index] = value.summary
        if isLoading { changedDuringLoad.insert(value.id) }
    }

    // MARK: Queries

    public func loadQueries() {
        guard features.contains(.queries) else { return }
        let provider = provider
        Task {
            do {
                queries = try await provider.savedQueries()
                if let id = selectedQueryID, !queries.contains(where: { $0.id == id }) {
                    selectedQueryID = nil
                } else if selectedQueryID == nil {
                    selectedQueryID = queries.first?.id
                } else {
                    runSelectedQuery()
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func runSelectedQuery() {
        queryGeneration += 1
        let generation = queryGeneration
        guard let id = selectedQueryID, let selected = queries.first(where: { $0.id == id }) else {
            queryResults = []
            isRunningQuery = false
            return
        }
        isRunningQuery = true
        let provider = provider
        Task {
            do {
                let rows = try await provider.run(selected)
                guard generation == queryGeneration else { return }
                queryResults = rows
            } catch {
                guard generation == queryGeneration else { return }
                actionError = error.localizedDescription
            }
            if generation == queryGeneration { isRunningQuery = false }
        }
    }

    // MARK: Changing items

    /// Sends a change, then reads the item again. Returns false when it failed.
    @discardableResult
    public func change(_ item: WorkItem, _ change: WorkItemChange) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            try await provider.apply(change, to: item)
            await reread(item, fallback: nil)
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    private func reread(_ item: WorkItem, fallback: WorkItem?) async {
        if selectedItemID == item.id {
            loadDetail()
            if let fallback { store(fallback) }
        } else if let fresh = try? await provider.item(container: item.container, number: item.number) {
            store(fresh)
        } else if let fallback {
            store(fallback)
        }
    }

    private func store(_ value: WorkItem) {
        guard let index = items.firstIndex(where: { $0.id == value.id }) else { return }
        items[index] = value.summary
        if isLoading { changedDuringLoad.insert(value.id) }
    }

    public func toggleTag(_ name: String, on item: WorkItem) {
        let has = item.tags.contains { $0.name == name }
        Task { await change(item, WorkItemChange(addTags: has ? [] : [name], removeTags: has ? [name] : [])) }
    }

    public func togglePerson(_ id: String, on item: WorkItem) {
        let has = item.people.contains { $0.id == id }
        Task { await change(item, WorkItemChange(addPeople: has ? [] : [id], removePeople: has ? [id] : [])) }
    }

    public func setPlan(_ id: String?, on item: WorkItem) {
        guard id != item.plan?.id else { return }
        Task { await change(item, WorkItemChange(plan: id.map { .set($0) } ?? .remove)) }
    }

    public func close(_ item: WorkItem, reason: WorkCloseReason?) {
        Task { await change(item, WorkItemChange(state: .close(reason))) }
    }

    public func reopen(_ item: WorkItem) {
        Task { await change(item, WorkItemChange(state: .reopen)) }
    }

    /// Saves a new title and body. Returns false, leaving the sheet open, when
    /// the provider refused.
    public func saveEdit(_ item: WorkItem, title: String, body: String) async -> Bool {
        let newTitle = title == item.title ? nil : title
        let newBody = body == (item.body ?? "") ? nil : body
        guard newTitle != nil || newBody != nil else { return true }
        return await change(item, WorkItemChange(title: newTitle, body: newBody))
    }

    /// Adds a comment, and clears that item's draft only once it has posted.
    @discardableResult
    public func postComment(on item: WorkItem) async -> Bool {
        let text = commentDraft(for: item.id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await provider.comment(text, on: item)
            setCommentDraft("", for: item.id)
            await reread(item, fallback: nil)
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    public func create(_ draft: WorkItemDraft) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            guard let number = try await provider.create(draft),
                  let created = try? await provider.item(container: draft.container, number: number) else {
                // It was created, so it must not look like a failure to retry.
                load(force: true)
                return true
            }
            let summary = created.summary
            items.removeAll { $0.id == summary.id }
            items.insert(summary, at: 0)
            if isLoading { changedDuringLoad.insert(summary.id) }
            if !query.matches(summary) { query = IssueQuery(state: summary.isOpen ? .open : .all) }
            if mode == .mine, !summary.people.contains(where: { $0.id == currentPerson }) { mode = .all }
            if mode == .queries { mode = .all }
            selectedItemID = summary.id
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    // MARK: Lanes

    public var canOpenLane: Bool { provider.laneProvider != nil && configuration.lanePolicy != nil && onOpenLane != nil }

    /// Reads the item in full, has the safety layer build the request, and
    /// hands that to the app. The prompt is pasted and never sent.
    public func openLane(on item: WorkItem) {
        guard let laneProvider = provider.laneProvider, let policy = configuration.lanePolicy,
              let onOpenLane else { return }
        if let detail, detail.id == item.id, detail.body != nil {
            onOpenLane(LaneSafety.issueRequest(for: detail.untrustedIssue(provider: laneProvider), policy: policy))
            return
        }
        let provider = provider
        Task {
            do {
                let full = try await provider.item(container: item.container, number: item.number)
                onOpenLane(LaneSafety.issueRequest(for: full.untrustedIssue(provider: laneProvider), policy: policy))
            } catch {
                actionError = "No lane was opened: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Moving cards

    var dragBoardKey: String {
        if let boardID { return "board:" + boardID }
        return "group:" + grouping.rawValue
    }

    /// Whether the open grouped board's cards can be dragged.
    var canMoveGroupedCards: Bool { boardID == nil && grouping.isMovable(features: features) }

    /// Whether a drag can land in a column. A drag is only ever trusted as far
    /// as naming a card on the open board.
    func canDrop(_ drag: WorkCardDrag, onColumn columnID: String) -> Bool {
        guard drag.boardKey == dragBoardKey, !isPending(cardID: drag.cardID) else { return false }
        if let board = displayedBoard {
            guard let card = board.cards.first(where: { $0.id == drag.cardID }),
                  let column = board.columns.first(where: { $0.id == columnID }) else { return false }
            return column.acceptsDrops && card.columnID != columnID
        }
        guard boardID == nil, canMoveGroupedCards,
              let item = displayedItems.first(where: { $0.id == drag.cardID }) else { return false }
        let columns = grouping.columns(for: visible, vocabulary: vocabulary)
        guard let column = columns.first(where: { $0.id == columnID }) else { return false }
        return grouping.change(moving: item, from: drag.columnKey, to: column.key, closeReason: provider.closeReasons.first,
                               plans: metadata[item.container]?.plans ?? []) != nil
    }

    /// Lands a drag. Returns false when it was not a move this board can make.
    @discardableResult
    func drop(_ drag: WorkCardDrag, onColumn columnID: String) -> Bool {
        guard canDrop(drag, onColumn: columnID) else { return false }
        if let boardID {
            moveCard(drag.cardID, on: boardID, to: columnID)
            return true
        }
        guard let column = grouping.columns(for: visible, vocabulary: vocabulary).first(where: { $0.id == columnID }) else {
            return false
        }
        moveItem(drag.cardID, grouping: grouping, from: drag.columnKey, to: column.key)
        return true
    }

    func moveCard(_ cardID: String, on boardID: String, to columnID: String) {
        guard let board = loadedBoards[boardID], pendingCards[cardID] == nil,
              let card = board.cards.first(where: { $0.id == cardID }),
              let column = board.columns.first(where: { $0.id == columnID }),
              column.acceptsDrops, card.columnID != columnID else { return }
        moveFailure = nil
        pendingCards[cardID] = PendingCardMove(boardID: boardID, columnID: columnID)
        let provider = provider
        Task {
            do {
                try await provider.move(card, on: board, to: column)
                loadedBoards[boardID] = loadedBoards[boardID]?.moving(cardID, to: columnID)
                pendingCards[cardID] = nil
                loadBoard(boardID)
            } catch {
                // Removing the overlay puts the card back where it was.
                pendingCards[cardID] = nil
                moveFailure = BoardMoveFailure(cardID: cardID, title: card.title, destination: column.name,
                                               message: error.localizedDescription,
                                               retry: .card(boardID: boardID, cardID: cardID, columnID: columnID))
            }
        }
    }

    func moveItem(_ itemID: String, grouping: IssueGrouping, from: String?, to: String?) {
        guard pendingItems[itemID] == nil, let item = items.first(where: { $0.id == itemID }) else { return }
        let known = metadata[item.container] ?? WorkMetadata()
        guard let change = grouping.change(moving: item, from: from, to: to, closeReason: provider.closeReasons.first,
                                           plans: known.plans) else { return }
        moveFailure = nil
        let optimistic = item.applying(change, metadata: known)
        pendingItems[itemID] = optimistic
        let provider = provider
        let destination = to.map { grouping == .state ? ($0 == IssueGrouping.openKey ? vocabulary.openTitle : vocabulary.closedTitle) : $0 }
            ?? IssueGrouping.noneTitle
        Task {
            do {
                try await provider.apply(change, to: item)
                if let fresh = try? await provider.item(container: item.container, number: item.number) {
                    store(fresh)
                    if detail?.id == fresh.id { detail = fresh }
                } else {
                    store(optimistic)
                }
                pendingItems[itemID] = nil
                if isLoading { changedDuringLoad.insert(itemID) }
            } catch {
                pendingItems[itemID] = nil
                moveFailure = BoardMoveFailure(cardID: itemID, title: item.title, destination: destination,
                                               message: error.localizedDescription,
                                               retry: .grouped(grouping: grouping, itemID: itemID, from: from, to: to))
            }
        }
    }

    public func retryFailedMove() {
        guard let failure = moveFailure else { return }
        moveFailure = nil
        switch failure.retry {
        case .card(let boardID, let cardID, let columnID):
            moveCard(cardID, on: boardID, to: columnID)
        case .grouped(let grouping, let itemID, let from, let to):
            moveItem(itemID, grouping: grouping, from: from, to: to)
        }
    }

    // MARK: Move to

    /// Where the selected item's card can go on the open board, for the
    /// menu bar and for anyone not using a pointer.
    public var moveTargetsForSelection: [BoardMoveTarget] {
        guard mode == .board, let id = selectedItemID else { return [] }
        if let board = displayedBoard {
            guard let card = board.cards.first(where: { $0.itemID == id }) else { return [] }
            return moveTargets(forCard: card, on: board)
        }
        guard let item = displayedItems.first(where: { $0.id == id }) else { return [] }
        return moveTargets(forItem: item, inColumn: groupedColumnKey(of: item))
    }

    public func moveSelection(to targetID: String) {
        guard mode == .board, let id = selectedItemID else { return }
        if let board = displayedBoard {
            if let card = board.cards.first(where: { $0.itemID == id }) { moveCard(card.id, on: board.id, to: targetID) }
            return
        }
        guard let item = displayedItems.first(where: { $0.id == id }) else { return }
        moveGrouped(item, from: groupedColumnKey(of: item), toColumn: targetID)
    }

    /// The column an item with several values is moved out of: its first.
    private func groupedColumnKey(of item: WorkItem) -> String? {
        switch grouping {
        case .plan: return item.plan?.title
        case .tag: return item.tags.first?.name
        case .person: return item.people.first?.id
        case .container: return item.container
        case .state: return item.isOpen ? IssueGrouping.openKey : IssueGrouping.closedKey
        }
    }

    func moveTargets(forCard card: WorkBoardCard, on board: WorkBoard) -> [BoardMoveTarget] {
        board.columns.filter(\.acceptsDrops).map {
            BoardMoveTarget(id: $0.id, name: $0.name, isCurrent: $0.id == card.columnID)
        }
    }

    func moveTargets(forItem item: WorkItem, inColumn key: String?) -> [BoardMoveTarget] {
        guard canMoveGroupedCards else { return [] }
        return grouping.columns(for: visible, vocabulary: vocabulary).map {
            BoardMoveTarget(id: $0.id, name: $0.name, isCurrent: $0.key == key)
        }
    }

    func moveGrouped(_ item: WorkItem, from key: String?, toColumn columnID: String) {
        guard let column = grouping.columns(for: visible, vocabulary: vocabulary).first(where: { $0.id == columnID }) else {
            return
        }
        moveItem(item.id, grouping: grouping, from: key, to: column.key)
    }

    /// Selection left, right, up or down across the board's columns.
    func moveBoardSelection(_ direction: MoveCommandDirection) {
        let columns: [[String]]
        if let board = displayedBoard {
            let visibleIDs = Set(visible.map(\.id))
            columns = board.columns.map { column in
                board.cards(in: column.id).compactMap { $0.itemID }.filter(visibleIDs.contains)
            }
        } else {
            columns = grouping.columns(for: visible, vocabulary: vocabulary).map { $0.items.map(\.id) }
        }
        let filled = columns.filter { !$0.isEmpty }
        guard let first = filled.first?.first else { return }
        guard let id = selectedItemID,
              let columnIndex = filled.firstIndex(where: { $0.contains(id) }),
              let rowIndex = filled[columnIndex].firstIndex(of: id) else {
            selectedItemID = first
            return
        }
        switch direction {
        case .up: if rowIndex > 0 { selectedItemID = filled[columnIndex][rowIndex - 1] }
        case .down: if rowIndex + 1 < filled[columnIndex].count { selectedItemID = filled[columnIndex][rowIndex + 1] }
        case .left:
            if columnIndex > 0 {
                let target = filled[columnIndex - 1]
                selectedItemID = target[min(rowIndex, target.count - 1)]
            }
        case .right:
            if columnIndex + 1 < filled.count {
                let target = filled[columnIndex + 1]
                selectedItemID = target[min(rowIndex, target.count - 1)]
            }
        default: break
        }
    }

    // MARK: Test support

    func setItemsForTesting(_ rows: [WorkItem]) { items = rows }
    func setBoardForTesting(_ board: WorkBoard) { loadedBoards[board.id] = board }
    func setPersonForTesting(_ person: String?) { currentPerson = person }
}

/// The table's sort, kept as a column name and a direction.
struct WorkItemSort: Equatable, Sendable {
    enum Column: String, CaseIterable, Sendable {
        case number, title, container, plan, updated
    }

    var column: Column = .updated
    var ascending = false

    init(column: Column = .updated, ascending: Bool = false) {
        self.column = column
        self.ascending = ascending
    }

    init(stored: String?) {
        let parts = stored?.split(separator: ":").map(String.init) ?? []
        if parts.count == 2, let column = Column(rawValue: parts[0]) {
            self.column = column
            ascending = parts[1] == "asc"
        }
    }

    var stored: String { "\(column.rawValue):\(ascending ? "asc" : "desc")" }

    var comparator: KeyPathComparator<WorkItem> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch column {
        case .number: return KeyPathComparator(\WorkItem.number, order: order)
        case .title: return KeyPathComparator(\WorkItem.title, order: order)
        case .container: return KeyPathComparator(\WorkItem.container, order: order)
        case .plan: return KeyPathComparator(\WorkItem.sortPlan, order: order)
        case .updated: return KeyPathComparator(\WorkItem.sortUpdated, order: order)
        }
    }

    init(comparator: KeyPathComparator<WorkItem>) {
        ascending = comparator.order == .forward
        switch comparator.keyPath {
        case \WorkItem.number: column = .number
        case \WorkItem.title: column = .title
        case \WorkItem.container: column = .container
        case \WorkItem.sortPlan: column = .plan
        default: column = .updated
        }
    }
}

extension WorkItem {
    var sortUpdated: Date { updatedAt ?? .distantPast }
    var sortPlan: String { plan?.title ?? "" }
}
