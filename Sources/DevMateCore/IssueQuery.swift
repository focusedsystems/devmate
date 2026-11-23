import Foundation

/// The Projects view's filters, applied to the loaded work items. The stored
/// keys stay `repo`, `label`, `assignee` and `milestone`, so a filter an app
/// has already saved keeps working.
public struct IssueQuery: Equatable, Sendable, Codable {
    public enum StateFilter: String, CaseIterable, Sendable, Codable {
        case open = "Open"
        case closed = "Closed"
        case all = "All"
    }

    public var container: String?
    public var tag: String?
    /// A person's id, or `IssueQuery.unassigned`.
    public var person: String?
    /// A plan's title, or `IssueQuery.noPlan`.
    public var plan: String?
    public var state: StateFilter = .open
    public var search: String = ""

    public static let unassigned = "\u{0}unassigned"
    public static let noPlan = "\u{0}none"

    enum CodingKeys: String, CodingKey {
        case container = "repo"
        case tag = "label"
        case person = "assignee"
        case plan = "milestone"
        case state, search
    }

    public init(container: String? = nil, tag: String? = nil, person: String? = nil, plan: String? = nil,
                state: StateFilter = .open, search: String = "") {
        self.container = container
        self.tag = tag
        self.person = person
        self.plan = plan
        self.state = state
        self.search = search
    }

    public var isFiltered: Bool { container != nil || tag != nil || person != nil || plan != nil || !search.isEmpty }

    public func matches(_ item: WorkItem) -> Bool {
        switch state {
        case .open where !item.isOpen: return false
        case .closed where item.isOpen: return false
        default: break
        }
        if let container, item.container != container { return false }
        if let tag, !item.tags.contains(where: { $0.name == tag }) { return false }
        if let person {
            if person == Self.unassigned {
                if !item.people.isEmpty { return false }
            } else if !item.people.contains(where: { $0.id == person }) {
                return false
            }
        }
        if let plan {
            if plan == Self.noPlan {
                if item.plan != nil { return false }
            } else if item.plan?.title != plan {
                return false
            }
        }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            let number = needle.hasPrefix("#") ? String(needle.dropFirst()) : needle
            let haystack = [item.title, item.container, item.author?.id ?? "",
                            item.tags.map(\.name).joined(separator: " "),
                            item.people.map(\.id).joined(separator: " "),
                            item.plan?.title ?? ""].joined(separator: " ").lowercased()
            if !haystack.contains(needle) && "\(item.number)" != number { return false }
        }
        return true
    }

    public func apply(_ items: [WorkItem]) -> [WorkItem] { items.filter(matches) }
}

/// One column of a grouped board. `key` is nil for the "None" column, so a tag
/// actually called "None" stays a column of its own.
public struct WorkItemColumn: Identifiable, Sendable {
    public var key: String?
    public var name: String
    public var items: [WorkItem]

    public var id: String { key.map { "key:" + $0 } ?? "none" }

    public init(key: String?, name: String, items: [WorkItem]) {
        self.key = key
        self.name = name
        self.items = items
    }
}

/// How the board groups work items when no provider board is in use.
public enum IssueGrouping: String, CaseIterable, Sendable, Codable {
    case plan = "Milestone"
    case tag = "Label"
    case person = "Assignee"
    case container = "Repository"
    case state = "State"

    public static let noneTitle = "None"
    public static let openKey = "open"
    public static let closedKey = "closed"

    /// Columns in order: named groups alphabetically (plans by due date), then
    /// "None" last. An item with two tags shows in both tag columns.
    public func columns(for items: [WorkItem], vocabulary: ProjectsVocabulary = .generic) -> [WorkItemColumn] {
        var groups: [String: [WorkItem]] = [:]
        var none: [WorkItem] = []
        var dueDates: [String: Date] = [:]
        for item in items {
            let found = keys(item)
            if found.isEmpty { none.append(item) }
            for key in found { groups[key, default: []].append(item) }
            if let plan = item.plan, let due = plan.dueOn { dueDates[plan.title] = due }
        }
        let names = groups.keys.sorted { lhs, rhs in
            if self == .state { return lhs == Self.openKey }
            if self == .plan {
                switch (dueDates[lhs], dueDates[rhs]) {
                case let (left?, right?) where left != right: return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        var result = names.map { key in
            WorkItemColumn(key: key, name: columnName(key, vocabulary: vocabulary), items: groups[key] ?? [])
        }
        if !none.isEmpty { result.append(WorkItemColumn(key: nil, name: Self.noneTitle, items: none)) }
        return result
    }

    private func columnName(_ key: String, vocabulary: ProjectsVocabulary) -> String {
        guard self == .state else { return key }
        return key == Self.openKey ? vocabulary.openTitle : vocabulary.closedTitle
    }

    func keys(_ item: WorkItem) -> [String] {
        switch self {
        case .plan: return item.plan.map { [$0.title] } ?? []
        case .tag: return item.tags.map(\.name)
        case .person: return item.people.map(\.id)
        case .container: return [item.container]
        case .state: return [item.isOpen ? Self.openKey : Self.closedKey]
        }
    }

    /// The change that moves `item` from one column to another, or nil when
    /// the move means nothing. Moving between tag or person columns swaps that
    /// one value and leaves the item's others alone.
    public func change(moving item: WorkItem, from: String?, to: String?,
                       closeReason: WorkCloseReason? = nil, plans: [WorkPlan] = []) -> WorkItemChange? {
        guard from != to else { return nil }
        switch self {
        case .container:
            return nil
        case .state:
            if to == Self.openKey, !item.isOpen { return WorkItemChange(state: .reopen) }
            if to == Self.closedKey, item.isOpen { return WorkItemChange(state: .close(closeReason)) }
            return nil
        case .plan:
            guard let to else { return item.plan == nil ? nil : WorkItemChange(plan: .remove) }
            guard item.plan?.title != to else { return nil }
            return WorkItemChange(plan: .set(plans.first { $0.title == to }?.id ?? to))
        case .tag:
            let has = item.tags.contains { $0.name == to }
            let add = to.flatMap { has ? nil : [$0] } ?? []
            let remove = from.flatMap { name in item.tags.contains { $0.name == name } ? [name] : nil } ?? []
            return add.isEmpty && remove.isEmpty ? nil : WorkItemChange(addTags: add, removeTags: remove)
        case .person:
            let has = item.people.contains { $0.id == to }
            let add = to.flatMap { has ? nil : [$0] } ?? []
            let remove = from.flatMap { id in item.people.contains { $0.id == id } ? [id] : nil } ?? []
            return add.isEmpty && remove.isEmpty ? nil : WorkItemChange(addPeople: add, removePeople: remove)
        }
    }

    /// Whether a card can be dragged between this grouping's columns.
    public func isMovable(features: ProjectFeatures) -> Bool {
        switch self {
        case .container: return false
        case .state: return features.contains(.closeReopen)
        case .plan: return features.contains(.plans)
        case .tag: return features.contains(.tags)
        case .person: return features.contains(.people)
        }
    }

    public func title(vocabulary: ProjectsVocabulary) -> String {
        switch self {
        case .plan: return vocabulary.plan
        case .tag: return vocabulary.tag
        case .person: return vocabulary.person
        case .container: return vocabulary.container
        case .state: return vocabulary.state
        }
    }

    /// The groupings a provider's features support.
    public static func available(features: ProjectFeatures) -> [IssueGrouping] {
        allCases.filter { grouping in
            switch grouping {
            case .plan: return features.contains(.plans)
            case .tag: return features.contains(.tags)
            case .person: return features.contains(.people)
            case .container, .state: return true
            }
        }
    }
}
