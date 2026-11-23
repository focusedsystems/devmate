import Foundation

// The Projects view's models. They name no provider: a provider maps its own
// issues, tags, people and plans onto these and says what to call them.

public struct WorkPerson: Codable, Hashable, Sendable, Identifiable {
    /// What the provider assigns by: a login or an account name.
    public var id: String
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }

    public var display: String { (name?.isEmpty == false ? name : nil) ?? id }
}

public struct WorkTag: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    /// Six hex digits, no `#`.
    public var color: String?
    public var description: String?

    public var id: String { name }

    public init(name: String, color: String? = nil, description: String? = nil) {
        self.name = name
        self.color = color
        self.description = description
    }
}

/// A milestone, an iteration or the like.
public struct WorkPlan: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var dueOn: Date?

    public init(id: String, title: String, dueOn: Date? = nil) {
        self.id = id
        self.title = title
        self.dueOn = dueOn
    }
}

public struct WorkComment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var author: WorkPerson?
    public var body: String
    public var createdAt: Date?
    public var url: String?

    public init(id: String, author: WorkPerson?, body: String, createdAt: Date?, url: String?) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.url = url
    }
}

/// A pull request linked to a work item.
public struct WorkLink: Codable, Hashable, Sendable, Identifiable {
    public var container: String
    public var number: Int
    public var title: String
    public var url: String
    /// OPEN, CLOSED or MERGED.
    public var state: String
    /// True when merging it closes the item.
    public var closesItem: Bool

    public var id: String { "\(container)#\(number)" }

    public init(container: String, number: Int, title: String, url: String, state: String, closesItem: Bool) {
        self.container = container
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.closesItem = closesItem
    }
}

public struct WorkItem: Codable, Hashable, Sendable, Identifiable {
    public enum Resolution: String, Codable, Hashable, Sendable {
        case completed, notPlanned
    }

    public var container: String
    public var number: Int
    public var title: String
    public var isOpen: Bool
    /// The provider's own name for the state.
    public var stateName: String
    /// Why a closed item closed.
    public var resolution: Resolution?
    public var author: WorkPerson?
    public var tags: [WorkTag]
    public var people: [WorkPerson]
    public var plan: WorkPlan?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var closedAt: Date?
    public var url: String
    /// Only once the item has been read in full.
    public var body: String?
    public var comments: [WorkComment]?

    public var id: String { "\(container)#\(number)" }

    public init(container: String, number: Int, title: String, isOpen: Bool = true, stateName: String? = nil,
                resolution: Resolution? = nil, author: WorkPerson? = nil, tags: [WorkTag] = [],
                people: [WorkPerson] = [], plan: WorkPlan? = nil, createdAt: Date? = nil, updatedAt: Date? = nil,
                closedAt: Date? = nil, url: String = "", body: String? = nil, comments: [WorkComment]? = nil) {
        self.container = container
        self.number = number
        self.title = title
        self.isOpen = isOpen
        self.stateName = stateName ?? (isOpen ? "Open" : "Closed")
        self.resolution = resolution
        self.author = author
        self.tags = tags
        self.people = people
        self.plan = plan
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.url = url
        self.body = body
        self.comments = comments
    }

    /// The item without its body and comments, as lists hold it.
    public var summary: WorkItem {
        var copy = self
        copy.body = nil
        copy.comments = nil
        return copy
    }

    /// The item as untrusted text for the lane safety layer.
    public func untrustedIssue(provider: LaneItemProvider) -> UntrustedIssue {
        UntrustedIssue(provider: provider, repo: container, number: number, url: url, title: title,
                       labels: tags.map(\.name), plan: plan?.title, body: body)
    }

    /// What the item will look like once `change` lands, for an optimistic
    /// update. `metadata` supplies colours and titles for what is added.
    public func applying(_ change: WorkItemChange, metadata: WorkMetadata = .init()) -> WorkItem {
        var item = self
        if let title = change.title { item.title = title }
        if let body = change.body { item.body = body }
        item.tags.removeAll { change.removeTags.contains($0.name) }
        for name in change.addTags where !item.tags.contains(where: { $0.name == name }) {
            item.tags.append(metadata.tags.first { $0.name == name } ?? WorkTag(name: name))
        }
        item.people.removeAll { change.removePeople.contains($0.id) }
        for id in change.addPeople where !item.people.contains(where: { $0.id == id }) {
            item.people.append(metadata.people.first { $0.id == id } ?? WorkPerson(id: id))
        }
        switch change.plan {
        case .set(let id): item.plan = metadata.plans.first { $0.id == id } ?? WorkPlan(id: id, title: id)
        case .remove: item.plan = nil
        case nil: break
        }
        switch change.state {
        case .close(let reason):
            item.isOpen = false
            item.stateName = "Closed"
            item.resolution = reason?.resolution ?? .completed
        case .reopen:
            item.isOpen = true
            item.stateName = "Open"
            item.resolution = nil
            item.closedAt = nil
        case nil: break
        }
        return item
    }
}

/// One way to close an item, as its provider offers it.
public struct WorkCloseReason: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var resolution: WorkItem.Resolution

    public init(id: String, title: String, resolution: WorkItem.Resolution) {
        self.id = id
        self.title = title
        self.resolution = resolution
    }
}

/// A change to a work item. Anything left empty stays as it is.
public struct WorkItemChange: Equatable, Sendable {
    public enum PlanChange: Equatable, Sendable { case set(String), remove }
    public enum StateChange: Equatable, Sendable { case close(WorkCloseReason?), reopen }

    public var title: String?
    public var body: String?
    public var addTags: [String]
    public var removeTags: [String]
    public var addPeople: [String]
    public var removePeople: [String]
    public var plan: PlanChange?
    public var state: StateChange?

    public init(title: String? = nil, body: String? = nil, addTags: [String] = [], removeTags: [String] = [],
                addPeople: [String] = [], removePeople: [String] = [], plan: PlanChange? = nil,
                state: StateChange? = nil) {
        self.title = title
        self.body = body
        self.addTags = addTags
        self.removeTags = removeTags
        self.addPeople = addPeople
        self.removePeople = removePeople
        self.plan = plan
        self.state = state
    }
}

/// A new work item.
public struct WorkItemDraft: Equatable, Sendable {
    public var container: String
    public var title: String
    public var body: String
    public var tags: [String]
    public var people: [String]
    public var plan: String?

    public init(container: String, title: String, body: String = "", tags: [String] = [], people: [String] = [],
                plan: String? = nil) {
        self.container = container
        self.title = title
        self.body = body
        self.tags = tags
        self.people = people
        self.plan = plan
    }
}

/// The tags, plans and people an item in one container can have.
public struct WorkMetadata: Equatable, Sendable {
    public var tags: [WorkTag]
    public var plans: [WorkPlan]
    public var people: [WorkPerson]

    public init(tags: [WorkTag] = [], plans: [WorkPlan] = [], people: [WorkPerson] = []) {
        self.tags = tags
        self.plans = plans
        self.people = people
    }
}

// MARK: Boards

public struct WorkBoardSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct WorkBoardColumn: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// False for a column a card cannot be moved into, such as "No Status".
    public var acceptsDrops: Bool

    public init(id: String, name: String, acceptsDrops: Bool = true) {
        self.id = id
        self.name = name
        self.acceptsDrops = acceptsDrops
    }
}

public struct WorkBoardCard: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var columnID: String
    /// The work item this card shows, when it is one in the loaded list.
    public var itemID: String?
    /// The container it belongs to, when it has one.
    public var container: String?
    public var subtitle: String
    public var url: String?

    public init(id: String, title: String, columnID: String, itemID: String? = nil, container: String? = nil,
                subtitle: String = "", url: String? = nil) {
        self.id = id
        self.title = title
        self.columnID = columnID
        self.itemID = itemID
        self.container = container
        self.subtitle = subtitle
        self.url = url
    }
}

public struct WorkBoard: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var columns: [WorkBoardColumn]
    public var cards: [WorkBoardCard]
    /// What the provider needs to move a card. Opaque to everything else.
    public var context: [String: String]

    public init(id: String, title: String, columns: [WorkBoardColumn], cards: [WorkBoardCard],
                context: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.columns = columns
        self.cards = cards
        self.context = context
    }

    public func cards(in columnID: String) -> [WorkBoardCard] {
        cards.filter { $0.columnID == columnID }
    }

    /// The board with one card in another column.
    public func moving(_ cardID: String, to columnID: String) -> WorkBoard {
        var board = self
        if let index = board.cards.firstIndex(where: { $0.id == cardID }) { board.cards[index].columnID = columnID }
        return board
    }
}

/// A saved query, for a provider that has them.
public struct WorkQuerySummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}
