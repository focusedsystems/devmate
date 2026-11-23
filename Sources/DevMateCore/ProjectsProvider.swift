import Foundation

/// What the Projects view may offer for a provider. Anything not declared
/// here does not appear.
public struct ProjectFeatures: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let create = ProjectFeatures(rawValue: 1 << 0)
    public static let edit = ProjectFeatures(rawValue: 1 << 1)
    public static let comment = ProjectFeatures(rawValue: 1 << 2)
    public static let tags = ProjectFeatures(rawValue: 1 << 3)
    public static let people = ProjectFeatures(rawValue: 1 << 4)
    public static let plans = ProjectFeatures(rawValue: 1 << 5)
    public static let closeReopen = ProjectFeatures(rawValue: 1 << 6)
    public static let linkedPullRequests = ProjectFeatures(rawValue: 1 << 7)
    public static let boards = ProjectFeatures(rawValue: 1 << 8)
    public static let queries = ProjectFeatures(rawValue: 1 << 9)
}

/// What a provider calls things in the filter row, the table and the detail.
public struct ProjectsVocabulary: Hashable, Sendable {
    public var container: String
    public var containerPlural: String
    public var tag: String
    public var person: String
    public var plan: String
    public var state: String
    public var openTitle: String
    public var closedTitle: String
    public var allTitle: String
    /// One item, such as "Issue".
    public var itemNoun: String
    /// Where "Open in Browser" goes, such as "the provider's site".
    public var siteName: String
    /// One line saying which images load in Markdown.
    public var imagePolicyNote: String

    public init(container: String, containerPlural: String, tag: String, person: String, plan: String,
                state: String = "State", openTitle: String = "Open", closedTitle: String = "Closed",
                allTitle: String = "All", itemNoun: String, siteName: String, imagePolicyNote: String) {
        self.container = container
        self.containerPlural = containerPlural
        self.tag = tag
        self.person = person
        self.plan = plan
        self.state = state
        self.openTitle = openTitle
        self.closedTitle = closedTitle
        self.allTitle = allTitle
        self.itemNoun = itemNoun
        self.siteName = siteName
        self.imagePolicyNote = imagePolicyNote
    }

    public static let generic = ProjectsVocabulary(container: "Container", containerPlural: "Containers", tag: "Tag",
                                                   person: "Person", plan: "Plan", itemNoun: "Item",
                                                   siteName: "the provider",
                                                   imagePolicyNote: "Images are not loaded")

    public func title(for state: IssueQuery.StateFilter) -> String {
        switch state {
        case .open: return openTitle
        case .closed: return closedTitle
        case .all: return allTitle
        }
    }
}

public struct ProjectsProviderError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The one thing the Projects view talks to. Calls run off the main thread.
public protocol ProjectsProvider: Sendable {
    var vocabulary: ProjectsVocabulary { get }
    var features: ProjectFeatures { get }
    /// The ways to close an item, first as the default.
    var closeReasons: [WorkCloseReason] { get }
    /// Set when lanes can open on this provider's items.
    var laneProvider: LaneItemProvider? { get }

    /// Whether Markdown from this provider may load an image from `url`.
    func allowsImage(_ url: URL?) -> Bool
    /// How to refer to an item in text.
    func reference(for item: WorkItem) -> String

    /// The signed-in person's id, for Mine.
    func currentPerson() async throws -> String?
    func items(in container: String) async throws -> [WorkItem]
    /// One item in full, with its body and comments.
    func item(container: String, number: Int) async throws -> WorkItem
    func links(for item: WorkItem) async throws -> [WorkLink]
    func metadata(for container: String) async throws -> WorkMetadata

    /// Returns the new item's number when it could be read back.
    func create(_ draft: WorkItemDraft) async throws -> Int?
    func apply(_ change: WorkItemChange, to item: WorkItem) async throws
    func comment(_ body: String, on item: WorkItem) async throws

    func boards() async throws -> [WorkBoardSummary]
    func board(id: String) async throws -> WorkBoard
    func move(_ card: WorkBoardCard, on board: WorkBoard, to column: WorkBoardColumn) async throws

    func savedQueries() async throws -> [WorkQuerySummary]
    func run(_ query: WorkQuerySummary) async throws -> [WorkItem]
}

extension ProjectsProvider {
    public var closeReasons: [WorkCloseReason] { [] }
    public var laneProvider: LaneItemProvider? { nil }
    public func allowsImage(_ url: URL?) -> Bool { false }
    public func reference(for item: WorkItem) -> String { item.id }
    public func currentPerson() async throws -> String? { nil }
    public func links(for item: WorkItem) async throws -> [WorkLink] { [] }
    public func metadata(for container: String) async throws -> WorkMetadata { WorkMetadata() }

    public func create(_ draft: WorkItemDraft) async throws -> Int? {
        throw ProjectsProviderError("This provider cannot create items.")
    }

    public func apply(_ change: WorkItemChange, to item: WorkItem) async throws {
        throw ProjectsProviderError("This provider cannot change items.")
    }

    public func comment(_ body: String, on item: WorkItem) async throws {
        throw ProjectsProviderError("This provider cannot add comments.")
    }

    public func boards() async throws -> [WorkBoardSummary] { [] }

    public func board(id: String) async throws -> WorkBoard {
        throw ProjectsProviderError("This provider has no boards.")
    }

    public func move(_ card: WorkBoardCard, on board: WorkBoard, to column: WorkBoardColumn) async throws {
        throw ProjectsProviderError("This provider cannot move cards.")
    }

    public func savedQueries() async throws -> [WorkQuerySummary] { [] }

    public func run(_ query: WorkQuerySummary) async throws -> [WorkItem] {
        throw ProjectsProviderError("This provider has no saved queries.")
    }
}
