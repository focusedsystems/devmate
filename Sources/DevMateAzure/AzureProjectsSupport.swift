import DevMateCore
import Foundation

struct AzProject: Decodable {
    struct Team: Decodable { var name: String? }
    var defaultTeam: Team?
}

struct AzTag: Decodable { var name: String }

struct AzTeamMember: Decodable {
    var identity: AzIdentity?
}

struct AzComments: Decodable {
    struct Comment: Decodable {
        var id: Int
        var text: String?
        var createdBy: AzIdentity?
        var createdDate: Date?
    }

    var comments: [Comment]
}

struct AzClassificationNode: Decodable {
    struct Attributes: Decodable {
        var finishDate: Date?
    }

    var name: String
    var path: String?
    var attributes: Attributes?
    var children: [AzClassificationNode]?
}

struct AzBoardSummary: Decodable {
    var id: String
    var name: String
}

struct AzBoard: Decodable {
    struct Column: Decodable {
        var id: String?
        var name: String
    }

    struct Fields: Decodable {
        struct Field: Decodable { var referenceName: String? }
        var columnField: Field?
    }

    var id: String
    var name: String
    var columns: [Column]?
    var fields: Fields?
    var allowedMappings: [String: [String: [String]]]?
}

struct AzQuery: Decodable {
    var id: String
    var name: String
    var path: String?
    var isFolder: Bool?
    var children: [AzQuery]?
}

struct AzWiqlResult: Decodable {
    struct Ref: Decodable { var id: Int }
    struct Relation: Decodable { var target: Ref? }
    var workItems: [Ref]?
    var workItemRelations: [Relation]?

    /// A flat query lists items; a tree query lists links between them.
    var ids: [Int] {
        var seen = Set<Int>()
        let all = (workItems ?? []).map(\.id) + (workItemRelations ?? []).compactMap { $0.target?.id }
        return all.filter { seen.insert($0).inserted }
    }
}

/// A field's value: text, a number, a person, or something this reader ignores.
enum AzValue: Decodable {
    case text(String)
    case number(Double)
    case person(AzIdentity)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { self = .text(text) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else if let person = try? container.decode(AzIdentity.self) { self = .person(person) }
        else { self = .other }
    }
}

struct AzWorkItem: Decodable {
    var id: Int
    var fields: [String: AzValue]

    func text(_ name: String) -> String? {
        if case .text(let value)? = fields[name] { return value }
        return nil
    }

    func person(_ name: String) -> AzIdentity? {
        if case .person(let value)? = fields[name] { return value }
        return nil
    }

    func date(_ name: String) -> Date? { text(name).flatMap(AzureJSON.parseDate) }
}

extension AzureProjectsProvider {
    static let listFields = ["System.Id", "System.Title", "System.State", "System.WorkItemType", "System.AssignedTo",
                             "System.Tags", "System.IterationPath", "System.CreatedDate", "System.ChangedDate",
                             "System.CreatedBy", "System.TeamProject", "Microsoft.VSTS.Common.ClosedDate"]

    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

    static func itemsQuery(project: String) -> String {
        "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = \(quoted(project)) "
            + "AND [System.State] <> 'Removed' ORDER BY [System.ChangedDate] DESC"
    }

    static func boardQuery(project: String, types: [String], workflow: AzureWorkflow) -> String {
        let closed = workflow.closedStates.map { quoted($0.prefix(1).uppercased() + $0.dropFirst()) }.sorted()
        return "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = \(quoted(project)) "
            + "AND [System.WorkItemType] IN (\(types.map(quoted).joined(separator: ", "))) "
            + "AND [System.State] NOT IN (\(closed.joined(separator: ", "))) ORDER BY [System.ChangedDate] DESC"
    }

    /// The most items one list reads.
    static let listLimit = 200

    static func wiql(_ query: String, project: String, cli: AzureCLI) throws -> [Int] {
        try cli.decode(AzWiqlResult.self, project: project, path: "wit/wiql", query: [("$top", "\(listLimit)")],
                       method: "POST", body: AzureJSON.text(["query": query]), contentType: "application/json").ids
    }

    static func rawItems(_ ids: [Int], project: String, fields: [String], cli: AzureCLI) throws -> [AzWorkItem] {
        var rows: [AzWorkItem] = []
        for start in stride(from: 0, to: ids.count, by: 200) {
            let chunk = ids[start..<min(start + 200, ids.count)]
            rows += try cli.decode(AzList<AzWorkItem>.self, project: project, path: "wit/workitems",
                                   query: [("ids", chunk.map(String.init).joined(separator: ",")),
                                           ("fields", fields.joined(separator: ",")), ("errorPolicy", "omit")]).value
        }
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return rows.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    static func read(_ ids: [Int], project: String, fields: [String], workflow: AzureWorkflow, cli: AzureCLI) throws -> [WorkItem] {
        try rawItems(ids, project: project, fields: fields, cli: cli).map {
            workItem($0, workflow: workflow, cli: cli, project: project)
        }
    }

    // MARK: Mapping

    static func person(_ identity: AzIdentity) -> WorkPerson {
        WorkPerson(id: identity.uniqueName ?? identity.displayName ?? identity.id ?? "", name: identity.displayName)
    }

    static func workItem(_ raw: AzWorkItem, workflow: AzureWorkflow, cli: AzureCLI, project: String) -> WorkItem {
        let state = raw.text("System.State") ?? "New"
        let open = !workflow.isClosed(state)
        let tags = (raw.text("System.Tags") ?? "").split(separator: ";").map {
            WorkTag(name: $0.trimmingCharacters(in: .whitespaces))
        }.filter { !$0.name.isEmpty }
        let plan = raw.text("System.IterationPath").map { path in
            WorkPlan(id: path, title: path.split(separator: "\\").last.map(String.init) ?? path)
        }
        let container = raw.text("System.TeamProject") ?? project
        return WorkItem(container: container, number: raw.id, title: raw.text("System.Title") ?? "", isOpen: open,
                        stateName: state, resolution: open ? nil : .completed,
                        author: raw.person("System.CreatedBy").map(person), tags: tags,
                        people: raw.person("System.AssignedTo").map { [person($0)] } ?? [], plan: plan,
                        createdAt: raw.date("System.CreatedDate"), updatedAt: raw.date("System.ChangedDate"),
                        closedAt: raw.date("Microsoft.VSTS.Common.ClosedDate"),
                        url: "\(cli.organization)/\(AzureCLI.encode(container))/_workitems/edit/\(raw.id)",
                        body: raw.text("System.Description").map(plainText))
    }

    /// An iteration path is the node's path without the `Iteration` level
    /// that Azure DevOps inserts in a classification path.
    static func iterationPath(_ path: String) -> String {
        var parts = path.split(separator: "\\").map(String.init)
        if parts.count >= 2, parts[1].lowercased() == "iteration" { parts.remove(at: 1) }
        return parts.joined(separator: "\\")
    }

    static func plans(from root: AzClassificationNode) -> [WorkPlan] {
        func walk(_ node: AzClassificationNode) -> [WorkPlan] {
            let own = node.path.map { [WorkPlan(id: iterationPath($0), title: node.name, dueOn: node.attributes?.finishDate)] } ?? []
            return own + (node.children ?? []).flatMap(walk)
        }
        return (root.children ?? []).flatMap(walk)
    }

    static func flatten(_ nodes: [AzQuery]) -> [AzQuery] {
        nodes.flatMap { $0.isFolder == true ? flatten($0.children ?? []) : [$0] }
    }

    static func workBoard(_ board: AzBoard, project: String, field: String, rows: [AzWorkItem], cli: AzureCLI) -> WorkBoard {
        let names = (board.columns ?? []).map(\.name)
        let columns = names.map { WorkBoardColumn(id: $0, name: $0) }
        let cards = rows.map { row -> WorkBoardCard in
            let column = row.text(field).flatMap { names.contains($0) ? $0 : nil } ?? names.first ?? ""
            return WorkBoardCard(id: "\(row.id)", title: row.text("System.Title") ?? "", columnID: column,
                                 itemID: "\(project)#\(row.id)", container: project,
                                 subtitle: "\(row.text("System.WorkItemType") ?? "") \(row.id)",
                                 url: "\(cli.organization)/\(AzureCLI.encode(project))/_workitems/edit/\(row.id)")
        }
        return WorkBoard(id: "\(project)|\(board.id)", title: board.name, columns: columns, cards: cards,
                         context: [fieldKey: field, projectKey: project])
    }

    // MARK: Changes

    static func tagText(_ names: [String]) -> String { names.joined(separator: "; ") }

    static func createOperations(_ draft: WorkItemDraft) -> [[String: Any]] {
        var operations: [[String: Any]] = [["op": "add", "path": "/fields/System.Title", "value": draft.title]]
        if !draft.body.isEmpty { operations.append(["op": "add", "path": "/fields/System.Description", "value": draft.body]) }
        if !draft.tags.isEmpty { operations.append(["op": "add", "path": "/fields/System.Tags", "value": tagText(draft.tags)]) }
        if let person = draft.people.first { operations.append(["op": "add", "path": "/fields/System.AssignedTo", "value": person]) }
        if let plan = draft.plan { operations.append(["op": "add", "path": "/fields/System.IterationPath", "value": plan]) }
        return operations
    }

    static func changeOperations(_ change: WorkItemChange, current item: WorkItem, workflow: AzureWorkflow) -> [[String: Any]] {
        var operations: [[String: Any]] = []
        func set(_ field: String, _ value: String) {
            operations.append(["op": "add", "path": "/fields/" + field, "value": value])
        }
        if let title = change.title { set("System.Title", title) }
        if let body = change.body { set("System.Description", body) }
        if !change.addTags.isEmpty || !change.removeTags.isEmpty {
            var names = item.tags.map(\.name).filter { !change.removeTags.contains($0) }
            for name in change.addTags where !names.contains(name) { names.append(name) }
            set("System.Tags", tagText(names))
        }
        // An item has one assignee: adding replaces, removing the current one clears.
        if let person = change.addPeople.first {
            set("System.AssignedTo", person)
        } else if item.people.contains(where: { change.removePeople.contains($0.id) }) {
            set("System.AssignedTo", "")
        }
        switch change.plan {
        case .set(let path): set("System.IterationPath", path)
        case .remove, nil: break
        }
        switch change.state {
        case .close: set("System.State", workflow.closedState)
        case .reopen: set("System.State", workflow.reopenState)
        case nil: break
        }
        return operations
    }

    // MARK: Text

    /// Azure DevOps keeps descriptions and comments as HTML. Lines, lists and
    /// links survive as text; everything else is dropped.
    static func plainText(_ html: String) -> String {
        var text = html
        for (pattern, replacement) in [("<br\\s*/?>", "\n"), ("</(p|div|h[1-6]|tr)>", "\n"), ("<li[^>]*>", "- "),
                                       ("</li>", "\n")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                                    ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
