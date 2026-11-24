import DevMateCore
import Foundation
import Testing
@testable import DevMateAzure

@Suite struct AzureProjectsProviderTests {
    let cli = AzureCLI(organization: "https://devops.example.com/example", executable: nil)
    let workflow = AzureWorkflow()

    @Test func workItemMapsFields() throws {
        let json = """
        {"id":12,"fields":{"System.Title":"Fix the widget","System.State":"Active","System.TeamProject":"Widgets",
        "System.AssignedTo":{"displayName":"Example User","uniqueName":"user@example.com"},
        "System.Tags":"alpha; beta","System.IterationPath":"Widgets\\\\Sprint 1","System.ChangedDate":"2026-01-02T03:04:05.123456+00:00",
        "System.Description":"<div>First line</div><div>Second &amp; third</div>"}}
        """
        let raw = try AzureJSON.decode(AzWorkItem.self, from: json)
        let item = AzureProjectsProvider.workItem(raw, workflow: workflow, cli: cli, project: "Widgets")
        #expect(item.number == 12 && item.container == "Widgets" && item.isOpen)
        #expect(item.tags.map(\.name) == ["alpha", "beta"])
        #expect(item.people.first?.id == "user@example.com" && item.people.first?.name == "Example User")
        #expect(item.plan?.title == "Sprint 1" && item.plan?.id == "Widgets\\Sprint 1")
        #expect(item.body == "First line\nSecond & third")
        #expect(item.url == "https://devops.example.com/example/Widgets/_workitems/edit/12")
        #expect(item.updatedAt != nil)
    }

    @Test func closedStatesFollowTheWorkflow() throws {
        let raw = try AzureJSON.decode(AzWorkItem.self, from: #"{"id":1,"fields":{"System.Title":"t","System.State":"Done"}}"#)
        #expect(!AzureProjectsProvider.workItem(raw, workflow: workflow, cli: cli, project: "p").isOpen)
        let custom = AzureWorkflow(closedStates: ["Shipped"])
        #expect(AzureProjectsProvider.workItem(raw, workflow: custom, cli: cli, project: "p").isOpen)
    }

    @Test func queriesEscapeQuotes() {
        let query = AzureProjectsProvider.itemsQuery(project: "Owner's Project")
        #expect(query.contains("'Owner''s Project'"))
        let board = AzureProjectsProvider.boardQuery(project: "Widgets", types: ["User Story", "Bug"], workflow: workflow)
        #expect(board.contains("IN ('User Story', 'Bug')"))
        #expect(board.contains("NOT IN ("))
        #expect(board.contains("'Closed'"))
    }

    @Test func wiqlResultsFlatOrTree() throws {
        let flat = try AzureJSON.decode(AzWiqlResult.self, from: #"{"workItems":[{"id":1},{"id":2}]}"#)
        #expect(flat.ids == [1, 2])
        let tree = try AzureJSON.decode(AzWiqlResult.self,
                                        from: #"{"workItemRelations":[{"target":{"id":3}},{"target":{"id":4}},{"target":{"id":3}}]}"#)
        #expect(tree.ids == [3, 4])
    }

    @Test func createOperationsSetFields() {
        let draft = WorkItemDraft(container: "Widgets", title: "New", body: "Text", tags: ["a", "b"], people: ["user@example.com"],
                                  plan: "Widgets\\Sprint 1")
        let operations = AzureProjectsProvider.createOperations(draft)
        let paths = operations.compactMap { $0["path"] as? String }
        #expect(paths == ["/fields/System.Title", "/fields/System.Description", "/fields/System.Tags",
                          "/fields/System.AssignedTo", "/fields/System.IterationPath"])
        #expect(operations[2]["value"] as? String == "a; b")
    }

    @Test func changesComputeTagsAndAssignee() {
        let item = WorkItem(container: "Widgets", number: 1, title: "t", tags: [WorkTag(name: "a"), WorkTag(name: "b")],
                            people: [WorkPerson(id: "old@example.com")])
        let change = WorkItemChange(addTags: ["c"], removeTags: ["a"], addPeople: ["new@example.com"],
                                    state: .close(nil))
        let operations = AzureProjectsProvider.changeOperations(change, current: item, workflow: workflow)
        func value(_ field: String) -> String? {
            operations.first { $0["path"] as? String == "/fields/" + field }?["value"] as? String
        }
        #expect(value("System.Tags") == "b; c")
        #expect(value("System.AssignedTo") == "new@example.com")
        #expect(value("System.State") == "Closed")
        let clear = AzureProjectsProvider.changeOperations(WorkItemChange(removePeople: ["old@example.com"], state: .reopen),
                                                           current: item, workflow: workflow)
        #expect(clear.contains { $0["value"] as? String == "" })
        #expect(clear.contains { $0["value"] as? String == "Active" })
        #expect(AzureProjectsProvider.changeOperations(WorkItemChange(), current: item, workflow: workflow).isEmpty)
    }

    @Test func iterationsDropTheClassificationLevel() throws {
        #expect(AzureProjectsProvider.iterationPath("\\Widgets\\Iteration\\Sprint 1") == "Widgets\\Sprint 1")
        let json = """
        {"name":"Widgets","path":"\\\\Widgets\\\\Iteration","children":[{"name":"Sprint 1","path":"\\\\Widgets\\\\Iteration\\\\Sprint 1",
        "attributes":{"finishDate":"2026-02-01T00:00:00Z"}}]}
        """
        let plans = AzureProjectsProvider.plans(from: try AzureJSON.decode(AzClassificationNode.self, from: json))
        #expect(plans.map(\.id) == ["Widgets\\Sprint 1"])
        #expect(plans[0].dueOn != nil)
    }

    @Test func boardPlacesCardsByColumnField() throws {
        let board = try AzureJSON.decode(AzBoard.self, from: """
        {"id":"b1","name":"Stories","columns":[{"name":"New"},{"name":"Active"}],
        "fields":{"columnField":{"referenceName":"Example.Kanban.Column"}},"allowedMappings":{"Incoming":{"User Story":["New"]}}}
        """)
        let rows = try AzureJSON.decode(AzList<AzWorkItem>.self, from: """
        {"value":[{"id":1,"fields":{"System.Title":"One","Example.Kanban.Column":"Active","System.WorkItemType":"User Story"}},
        {"id":2,"fields":{"System.Title":"Two","System.WorkItemType":"User Story"}}]}
        """).value
        let result = AzureProjectsProvider.workBoard(board, project: "Widgets", field: "Example.Kanban.Column", rows: rows, cli: cli)
        #expect(result.id == "Widgets|b1")
        #expect(result.cards(in: "Active").map(\.id) == ["1"])
        #expect(result.cards(in: "New").map(\.id) == ["2"])
        #expect(result.context["columnField"] == "Example.Kanban.Column")
    }

    @Test func queryTreeFlattensFolders() throws {
        let roots = try AzureJSON.decode(AzList<AzQuery>.self, from: """
        {"value":[{"id":"f","name":"Shared Queries","isFolder":true,"children":[{"id":"q1","name":"Active","path":"Shared Queries/Active"}]},
        {"id":"q2","name":"Mine","path":"My Queries/Mine"}]}
        """).value
        #expect(AzureProjectsProvider.flatten(roots).map(\.id) == ["q1", "q2"])
    }

    @Test func idsCarryTheirProject() throws {
        let (project, rest) = try AzureProjectsProvider.split("Widgets|abc")
        #expect(project == "Widgets" && rest == "abc")
        #expect(throws: AzureCLIError.self) { try AzureProjectsProvider.split("abc") }
    }

    @Test func plainTextKeepsLinesAndLists() {
        let text = AzureProjectsProvider.plainText("<p>One</p><ul><li>a</li><li>b</li></ul>&lt;tag&gt;")
        #expect(text == "One\n- a\n- b\n<tag>")
    }

    @Test func containersComeFromTheRegistry() {
        func repo(_ id: String, _ remote: String?, _ provider: RepoProviderKind) -> DevRepo {
            DevRepo(id: id, name: id, path: "/tmp/" + id, remote: remote, provider: provider, kind: .repo)
        }
        let catalog = RepoCatalog(sections: [RepoSection(name: "All", repos: [
            repo("a", "Widgets/a", .azureDevOps), repo("b", "Widgets/b", .azureDevOps),
            repo("c", "Gadgets/c", .azureDevOps), repo("d", "example/d", .github),
        ])])
        #expect(AzureProjectsProvider.containers(in: catalog) == ["Widgets", "Gadgets"])
    }

    @Test func declaresItsFeatures() {
        let provider = AzureProjectsProvider(cli: cli, projects: ["Widgets"])
        #expect(provider.features.contains(.boards) && provider.features.contains(.queries))
        #expect(!provider.features.contains(.linkedPullRequests))
        #expect(provider.laneProvider == .azureDevOps)
        #expect(provider.vocabulary.plan == "Iteration")
    }
}
