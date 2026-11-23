import DevMateCore
import Foundation

/// GitHub issues and Projects (v2), for the Projects view.
public struct GitHubProjectsProvider: ProjectsProvider {
    public let gh: GitHubCLI

    public init(gh: GitHubCLI) {
        self.gh = gh
    }

    public var vocabulary: ProjectsVocabulary {
        ProjectsVocabulary(container: "Repository", containerPlural: "Repositories", tag: "Label", person: "Assignee",
                           plan: "Milestone", itemNoun: "Issue", siteName: "GitHub",
                           imagePolicyNote: "Images load only from GitHub's own upload hosts")
    }

    public var features: ProjectFeatures {
        [.create, .edit, .comment, .tags, .people, .plans, .closeReopen, .linkedPullRequests, .boards]
    }

    public var closeReasons: [WorkCloseReason] {
        [WorkCloseReason(id: GitHubCLI.CloseReason.completed.rawValue, title: "Completed", resolution: .completed),
         WorkCloseReason(id: GitHubCLI.CloseReason.notPlanned.rawValue, title: "Not Planned", resolution: .notPlanned)]
    }

    public var laneProvider: LaneItemProvider? { .gitHub }

    public func allowsImage(_ url: URL?) -> Bool { MarkdownImagePolicy.allows(url) }

    public func reference(for item: WorkItem) -> String { "\(gh.owner)/\(item.container)#\(item.number)" }

    /// `gh` blocks on a process, so each call runs on a dispatch queue: never
    /// on the main actor, and never on a Swift concurrency thread, whose small
    /// pool a few slow reads would otherwise use up.
    private func off<T: Sendable>(_ work: @escaping @Sendable (GitHubCLI) throws -> T) async throws -> T {
        let gh = gh
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work(gh) })
            }
        }
    }

    public func currentPerson() async throws -> String? {
        let login = try await off { try $0.run(["api", "user", "--jq", ".login"]) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty ? nil : login
    }

    public func items(in container: String) async throws -> [WorkItem] {
        try await off { try $0.issues(repo: container) }.map(Self.workItem)
    }

    public func item(container: String, number: Int) async throws -> WorkItem {
        Self.workItem(try await off { try $0.issue(repo: container, number: number) })
    }

    public func links(for item: WorkItem) async throws -> [WorkLink] {
        let repo = item.container, number = item.number
        return try await off { try $0.linkedPullRequests(repo: repo, number: number) }.map {
            WorkLink(container: $0.repo, number: $0.number, title: $0.title, url: $0.url, state: $0.state,
                     closesItem: $0.closesIssue)
        }
    }

    public func metadata(for container: String) async throws -> WorkMetadata {
        async let labels = off { try $0.labels(repo: container) }
        async let milestones = off { try $0.milestones(repo: container) }
        async let people = off { try $0.assignableUsers(repo: container) }
        return WorkMetadata(tags: ((try? await labels) ?? []).map(Self.tag),
                            plans: ((try? await milestones) ?? []).map(Self.plan),
                            people: ((try? await people) ?? []).map(Self.person))
    }

    public func create(_ draft: WorkItemDraft) async throws -> Int? {
        let address = try await off {
            try $0.createIssue(repo: draft.container, title: draft.title, body: draft.body, labels: draft.tags,
                               assignees: draft.people, milestone: draft.plan)
        }
        return Self.issueNumber(fromAddress: address)
    }

    static func issueNumber(fromAddress address: String) -> Int? {
        address.split(separator: "/").last.flatMap { Int($0) }
    }

    public func apply(_ change: WorkItemChange, to item: WorkItem) async throws {
        let repo = item.container, number = item.number
        try await off { gh in
            try gh.editIssue(repo: repo, number: number, title: change.title, body: change.body,
                             addLabels: change.addTags, removeLabels: change.removeTags,
                             addAssignees: change.addPeople, removeAssignees: change.removePeople,
                             milestone: Self.milestoneChange(change.plan))
            switch change.state {
            case .close(let reason):
                try gh.close(repo: repo, number: number, reason: Self.closeReason(reason))
            case .reopen:
                try gh.reopen(repo: repo, number: number)
            case nil:
                break
            }
        }
    }

    static func milestoneChange(_ change: WorkItemChange.PlanChange?) -> GitHubCLI.MilestoneChange? {
        switch change {
        case .set(let id): return .set(id)
        case .remove: return .remove
        case nil: return nil
        }
    }

    static func closeReason(_ reason: WorkCloseReason?) -> GitHubCLI.CloseReason {
        reason?.resolution == .notPlanned ? .notPlanned : .completed
    }

    public func comment(_ body: String, on item: WorkItem) async throws {
        let repo = item.container, number = item.number
        try await off { try $0.comment(repo: repo, number: number, body: body) }
    }

    // MARK: Boards

    public func boards() async throws -> [WorkBoardSummary] {
        try await off { try $0.projects() }.filter { $0.closed != true }.map {
            WorkBoardSummary(id: String($0.number), title: $0.title)
        }
    }

    public func board(id: String) async throws -> WorkBoard {
        guard let number = Int(id) else { throw GitHubCLIError("That is not a GitHub Project.") }
        let board: ProjectBoard = try await off { gh in
            guard let project = try gh.projects().first(where: { $0.number == number }) else {
                throw GitHubCLIError("GitHub Project \(number) was not found.")
            }
            return try gh.board(for: project)
        }
        return Self.workBoard(board)
    }

    public func move(_ card: WorkBoardCard, on board: WorkBoard, to column: WorkBoardColumn) async throws {
        guard column.acceptsDrops else { throw GitHubCLIError("Cards cannot be moved into \(column.name).") }
        guard let projectID = board.context[Self.projectKey], let fieldID = board.context[Self.fieldKey],
              let number = Int(board.id) else {
            throw GitHubCLIError("The project has no Status field.")
        }
        let project = GitHubProject(id: projectID, number: number, title: board.title)
        let option = ProjectStatusField.Option(id: column.id, name: column.name)
        let field = ProjectStatusField(id: fieldID, name: "Status", options: [option])
        let target = ProjectBoard(project: project, status: field, items: [])
        let item = ProjectItem(id: card.id, title: card.title)
        try await off { try $0.move(item, on: target, to: option) }
    }

    // MARK: Mapping

    static let projectKey = "projectID"
    static let fieldKey = "fieldID"

    public static func workItem(_ issue: GitHubIssue) -> WorkItem {
        let resolution: WorkItem.Resolution? = issue.isOpen ? nil
            : (issue.stateReason?.uppercased() == "NOT_PLANNED" ? .notPlanned : .completed)
        return WorkItem(container: issue.repo, number: issue.number, title: issue.title, isOpen: issue.isOpen,
                        resolution: resolution, author: issue.author.map(person), tags: issue.labels.map(tag),
                        people: issue.assignees.map(person), plan: issue.milestone.map(plan),
                        createdAt: issue.createdAt, updatedAt: issue.updatedAt, closedAt: issue.closedAt,
                        url: issue.url, body: issue.body, comments: issue.comments?.map(comment))
    }

    static func person(_ user: GitHubUser) -> WorkPerson { WorkPerson(id: user.login, name: user.name) }

    static func tag(_ label: GitHubLabel) -> WorkTag {
        WorkTag(name: label.name, color: label.color, description: label.description)
    }

    /// `gh` takes a milestone by title, so the title is its id.
    static func plan(_ milestone: GitHubMilestone) -> WorkPlan {
        WorkPlan(id: milestone.title, title: milestone.title, dueOn: milestone.dueOn)
    }

    static func comment(_ comment: GitHubComment) -> WorkComment {
        WorkComment(id: comment.id, author: comment.author.map(person), body: comment.body,
                    createdAt: comment.createdAt, url: comment.url)
    }

    /// One column per Status option, which take drops. A status the field no
    /// longer lists, and "No Status", show but cannot be moved into.
    public static func workBoard(_ board: ProjectBoard) -> WorkBoard {
        let options = board.status?.options ?? []
        func columnID(_ name: String) -> String {
            options.first { $0.name == name }?.id ?? "unlisted:" + name
        }
        let columns = board.columns.map { name in
            WorkBoardColumn(id: columnID(name), name: name, acceptsDrops: options.contains { $0.name == name })
        }
        let cards = board.items.map { item in
            WorkBoardCard(id: item.id, title: item.title, columnID: columnID(item.status ?? ProjectBoard.noStatus),
                          itemID: item.issueID, container: item.repo,
                          subtitle: item.type == "DraftIssue" ? "Draft"
                              : [item.repo, item.number.map { "#\($0)" }].compactMap { $0 }.joined(separator: " "),
                          url: item.url)
        }
        var context = [projectKey: board.project.id]
        if let field = board.status { context[fieldKey] = field.id }
        return WorkBoard(id: String(board.project.number), title: board.project.title, columns: columns, cards: cards,
                         context: context)
    }
}
