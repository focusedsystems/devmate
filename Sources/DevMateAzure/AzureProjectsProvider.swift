import DevMateCore
import Foundation

/// How a process names its states. Azure DevOps lets each project choose, so
/// the app says what closing and reopening mean for it.
public struct AzureWorkflow: Equatable, Sendable {
    /// Set on an item when it is closed.
    public var closedState: String
    /// Set on an item when it is reopened.
    public var reopenState: String
    /// States that count as closed, case-insensitively.
    public var closedStates: Set<String>
    /// The type of an item created from the Projects view.
    public var newItemType: String

    public init(closedState: String = "Closed", reopenState: String = "Active",
                closedStates: Set<String> = ["Closed", "Done", "Removed", "Completed", "Resolved", "Cut"],
                newItemType: String = "Task") {
        self.closedState = closedState
        self.reopenState = reopenState
        self.closedStates = Set(closedStates.map { $0.lowercased() })
        self.newItemType = newItemType
    }

    func isClosed(_ state: String) -> Bool { closedStates.contains(state.lowercased()) }
}

/// Azure DevOps work items, boards and saved queries, for the Projects view.
/// A container is a project: `containers` lists the projects to read.
public struct AzureProjectsProvider: ProjectsProvider {
    public let cli: AzureCLI
    public let workflow: AzureWorkflow
    /// The team whose boards are listed. When nil, each project's default team.
    public let team: String?
    /// The projects whose boards and saved queries are offered.
    public let projects: [String]

    public init(cli: AzureCLI, projects: [String], workflow: AzureWorkflow = AzureWorkflow(), team: String? = nil) {
        self.cli = cli
        self.projects = projects
        self.workflow = workflow
        self.team = team
    }

    public init(organization: String, projects: [String], workflow: AzureWorkflow = AzureWorkflow(),
                team: String? = nil) {
        self.init(cli: AzureCLI(organization: organization), projects: projects, workflow: workflow, team: team)
    }

    /// The projects a registry's Azure DevOps repositories live in, in order,
    /// for `ProjectsConfiguration.containers`.
    public static func containers(in catalog: RepoCatalog) -> [String] {
        var seen = Set<String>()
        return catalog.repos.filter { $0.provider == .azureDevOps && $0.surfaces.projects }.compactMap { repo in
            let parts = (repo.remote ?? "").split(separator: "/")
            return parts.count >= 2 ? String(parts[parts.count - 2]) : nil
        }.filter { seen.insert($0).inserted }
    }

    public var vocabulary: ProjectsVocabulary {
        ProjectsVocabulary(container: "Project", containerPlural: "Projects", tag: "Tag", person: "Assigned To",
                           plan: "Iteration", itemNoun: "Work Item", siteName: "Azure DevOps",
                           imagePolicyNote: "Images are not loaded, because Azure DevOps needs its sign-in")
    }

    public var features: ProjectFeatures {
        [.create, .edit, .comment, .tags, .people, .plans, .closeReopen, .boards, .queries]
    }

    public var closeReasons: [WorkCloseReason] {
        [WorkCloseReason(id: "completed", title: "Completed", resolution: .completed)]
    }

    public var laneProvider: LaneItemProvider? { .azureDevOps }

    public func reference(for item: WorkItem) -> String { "AB#\(item.number)" }

    private func off<T: Sendable>(_ work: @escaping @Sendable (AzureCLI) throws -> T) async throws -> T {
        let cli = cli
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work(cli) })
            }
        }
    }

    public func currentPerson() async throws -> String? {
        let connection = try await off { try $0.decode(AzConnection.self, project: nil, path: "connectionData",
                                                       apiVersion: "7.1-preview.1") }
        return connection.authenticatedUser?.properties?.Account?.value
    }

    // MARK: Items

    public func items(in container: String) async throws -> [WorkItem] {
        let workflow = workflow
        return try await off { cli in
            let ids = try Self.wiql(Self.itemsQuery(project: container), project: container, cli: cli)
            return try Self.read(ids, project: container, fields: Self.listFields, workflow: workflow, cli: cli)
        }
    }

    public func item(container: String, number: Int) async throws -> WorkItem {
        let workflow = workflow
        return try await off { cli in
            let raw = try cli.decode(AzWorkItem.self, project: container, path: "wit/workitems/\(number)",
                                     query: [("$expand", "none")])
            var item = Self.workItem(raw, workflow: workflow, cli: cli, project: container)
            let comments = try? cli.decode(AzComments.self, project: container, path: "wit/workItems/\(number)/comments",
                                           apiVersion: "7.1-preview.4")
            item.comments = (comments?.comments ?? []).map { comment in
                WorkComment(id: "\(comment.id)", author: comment.createdBy.map(Self.person),
                            body: Self.plainText(comment.text ?? ""), createdAt: comment.createdDate, url: nil)
            }
            return item
        }
    }

    public func metadata(for container: String) async throws -> WorkMetadata {
        async let tags = off { try $0.decode(AzList<AzTag>.self, project: container, path: "wit/tags",
                                             apiVersion: "7.1-preview.1").value }
        async let plans = off { try $0.decode(AzClassificationNode.self, project: container,
                                              path: "wit/classificationnodes/iterations",
                                              query: [("$depth", "5")]) }
        async let people = off { cli in
            let team = try self.team ?? Self.defaultTeam(project: container, cli: cli)
            return try cli.decode(AzList<AzTeamMember>.self, project: nil, path: "projects/\(AzureCLI.encode(container))/teams/\(AzureCLI.encode(team))/members").value
        }
        return WorkMetadata(tags: ((try? await tags) ?? []).map { WorkTag(name: $0.name) },
                            plans: (try? await plans).map { Self.plans(from: $0) } ?? [],
                            people: ((try? await people) ?? []).compactMap { $0.identity }.map(Self.person))
    }

    public func create(_ draft: WorkItemDraft) async throws -> Int? {
        let workflow = workflow
        let body = AzureJSON.text(Self.createOperations(draft))
        let created = try await off { cli in
            try cli.decode(AzWorkItem.self, project: draft.container,
                           path: "wit/workitems/$" + AzureCLI.encode(workflow.newItemType), method: "POST",
                           body: body, contentType: "application/json-patch+json")
        }
        return created.id
    }

    public func apply(_ change: WorkItemChange, to item: WorkItem) async throws {
        let operations = Self.changeOperations(change, current: item, workflow: workflow)
        guard !operations.isEmpty else { return }
        let project = item.container, number = item.number
        let body = AzureJSON.text(operations)
        try await off { cli in
            try cli.request(method: "PATCH", project: project, path: "wit/workitems/\(number)", body: body,
                            contentType: "application/json-patch+json")
        }
    }

    public func comment(_ body: String, on item: WorkItem) async throws {
        let project = item.container, number = item.number
        let text = AzureJSON.text(["text": body])
        try await off { cli in
            try cli.request(method: "POST", project: project, path: "wit/workItems/\(number)/comments", body: text,
                            contentType: "application/json", apiVersion: "7.1-preview.4")
        }
    }

    // MARK: Boards

    static func defaultTeam(project: String, cli: AzureCLI) throws -> String {
        let found = try cli.decode(AzProject.self, project: nil, path: "projects/\(AzureCLI.encode(project))")
        guard let name = found.defaultTeam?.name else { throw AzureCLIError("\(project) has no default team.") }
        return name
    }

    /// Boards belong to a project's team, so an id carries its project:
    /// `Project|Board`.
    static func split(_ id: String) throws -> (project: String, rest: String) {
        guard let bar = id.firstIndex(of: "|") else { throw AzureCLIError("That is not an Azure DevOps id.") }
        return (String(id[..<bar]), String(id[id.index(after: bar)...]))
    }

    public func boards() async throws -> [WorkBoardSummary] {
        let team = team
        let projects = projects
        return await withTaskGroup(of: [WorkBoardSummary].self) { group in
            for project in projects {
                group.addTask {
                    let found = try? await off { cli in
                        let name = try team ?? Self.defaultTeam(project: project, cli: cli)
                        return try cli.decode(AzList<AzBoardSummary>.self, project: project, team: name,
                                              path: "work/boards").value
                    }
                    return (found ?? []).map {
                        WorkBoardSummary(id: "\(project)|\($0.id)",
                                         title: projects.count > 1 ? "\(project): \($0.name)" : $0.name)
                    }
                }
            }
            var all: [WorkBoardSummary] = []
            for await rows in group { all += rows }
            return all.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    public func board(id: String) async throws -> WorkBoard {
        let (project, boardID) = try Self.split(id)
        let team = team, workflow = workflow
        return try await off { cli in
            let name = try team ?? Self.defaultTeam(project: project, cli: cli)
            let board = try cli.decode(AzBoard.self, project: project, team: name,
                                       path: "work/boards/\(AzureCLI.encode(boardID))")
            guard let field = board.fields?.columnField?.referenceName else {
                throw AzureCLIError("\(board.name) has no column field.")
            }
            let types = Set((board.allowedMappings ?? [:]).values.flatMap { $0.keys })
            guard !types.isEmpty else { throw AzureCLIError("\(board.name) lists no work item types.") }
            let ids = try Self.wiql(Self.boardQuery(project: project, types: types.sorted(), workflow: workflow),
                                    project: project, cli: cli)
            let rows = try Self.rawItems(ids, project: project, fields: Self.listFields + [field], cli: cli)
            return Self.workBoard(board, project: project, field: field, rows: rows, cli: cli)
        }
    }

    public func move(_ card: WorkBoardCard, on board: WorkBoard, to column: WorkBoardColumn) async throws {
        guard let field = board.context[Self.fieldKey], let project = board.context[Self.projectKey],
              let number = Int(card.id) else {
            throw AzureCLIError("The board has no column field.")
        }
        guard column.acceptsDrops else { throw AzureCLIError("Cards cannot be moved into \(column.name).") }
        let body = AzureJSON.text([["op": "add", "path": "/fields/" + field, "value": column.name]])
        try await off { cli in
            try cli.request(method: "PATCH", project: project, path: "wit/workitems/\(number)", body: body,
                            contentType: "application/json-patch+json")
        }
    }

    static let fieldKey = "columnField"
    static let projectKey = "project"

    // MARK: Queries

    public func savedQueries() async throws -> [WorkQuerySummary] {
        let projects = projects
        return await withTaskGroup(of: [WorkQuerySummary].self) { group in
            for project in projects {
                group.addTask {
                    let roots = try? await off {
                        try $0.decode(AzList<AzQuery>.self, project: project, path: "wit/queries",
                                      query: [("$depth", "2")]).value
                    }
                    return Self.flatten(roots ?? []).map {
                        WorkQuerySummary(id: "\(project)|\($0.id)",
                                         title: projects.count > 1 ? "\(project): \($0.path ?? $0.name)" : ($0.path ?? $0.name))
                    }
                }
            }
            var all: [WorkQuerySummary] = []
            for await rows in group { all += rows }
            return all.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    public func run(_ query: WorkQuerySummary) async throws -> [WorkItem] {
        let (project, queryID) = try Self.split(query.id)
        let workflow = workflow
        return try await off { cli in
            let result = try cli.decode(AzWiqlResult.self, project: project, path: "wit/wiql/\(AzureCLI.encode(queryID))")
            let ids = result.ids
            return try Self.read(ids, project: project, fields: Self.listFields, workflow: workflow, cli: cli)
        }
    }
}
