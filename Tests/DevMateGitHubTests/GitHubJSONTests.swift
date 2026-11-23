import XCTest
import DevMateCore
@testable import DevMateGitHub

final class GitHubJSONTests: XCTestCase {
    func testDecodesIssueList() throws {
        let json = """
        [{"assignees":[{"login":"ann","name":"Ann"}],"author":{"login":"bob","name":"Bob"},"closedAt":null,
          "createdAt":"2026-11-18T00:37:19Z","labels":[{"name":"bug","color":"d73a4a"}],
          "milestone":{"number":2,"title":"Round 2","dueOn":"2026-12-01T00:00:00Z"},"number":434,"state":"OPEN",
          "stateReason":"","title":"Fix it","updatedAt":"2026-11-18T00:41:04Z","url":"https://github.com/example/r/issues/434"}]
        """
        let issues = try GitHubJSON.decoder.decode([GitHubIssue].self, from: Data(json.utf8))
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].number, 434)
        XCTAssertTrue(issues[0].isOpen)
        XCTAssertEqual(issues[0].labels.first?.name, "bug")
        XCTAssertEqual(issues[0].milestone?.title, "Round 2")
        XCTAssertNotNil(issues[0].milestone?.dueOn)
        XCTAssertNil(issues[0].closedAt)
    }

    func testCacheRoundTrip() throws {
        let issue = GitHubIssue(repo: "r", number: 1, title: "t", state: "OPEN", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                url: "u")
        let data = try GitHubJSON.encoder.encode([issue])
        let back = try GitHubJSON.decoder.decode([GitHubIssue].self, from: data)
        XCTAssertEqual(back, [issue])
    }

    func testCheckSummary() {
        let rollup = [
            CheckRollupEntry(name: "build", status: "COMPLETED", conclusion: "SUCCESS"),
            CheckRollupEntry(name: "lint", status: "IN_PROGRESS"),
            CheckRollupEntry(context: "ci/x", state: "FAILURE"),
            CheckRollupEntry(name: "docs", status: "COMPLETED", conclusion: "SKIPPED"),
        ]
        let summary = CheckSummary.from(rollup: rollup)
        XCTAssertEqual(summary, CheckSummary(passed: 1, failed: 1, pending: 1, skipped: 1))
        XCTAssertEqual(summary.overall, .failing)
        XCTAssertEqual(CheckSummary.from(rollup: []).overall, .none)
    }

    func testRunState() {
        var run = WorkflowRun(repo: "r", databaseId: 1, displayTitle: "t", workflowName: "ci", status: "completed",
                              conclusion: "failure", url: "u")
        XCTAssertEqual(run.state, .failed)
        run.status = "in_progress"
        XCTAssertEqual(run.state, .running)
        run.status = "queued"
        XCTAssertEqual(run.state, .queued)
    }

    func testLinkedPullRequestsDeduplicates() {
        let json = """
        {"data":{"repository":{"issue":{"closedByPullRequestsReferences":{"nodes":[{"number":473,"title":"A","url":"u","state":"MERGED","repository":{"name":"widget"}}]},
        "timelineItems":{"nodes":[{"__typename":"CrossReferencedEvent","source":{"__typename":"PullRequest","number":473,"title":"A","url":"u","state":"MERGED","repository":{"name":"widget"}}},
        {"__typename":"CrossReferencedEvent","source":{"__typename":"Issue","number":9}},
        {"__typename":"CrossReferencedEvent","source":{"__typename":"PullRequest","number":480,"title":"B","url":"v","state":"OPEN","repository":{"name":"gadget"}}}]}}}}}
        """
        let linked = GitHubJSON.linkedPullRequests(from: Data(json.utf8))
        XCTAssertEqual(linked.map(\.id), ["widget#473", "gadget#480"])
        XCTAssertEqual(linked.map(\.closesIssue), [true, false])
    }

    func testProjectBoardParsing() {
        let fields = """
        {"fields":[{"id":"F1","name":"Title","type":"ProjectV2Field"},
        {"id":"F2","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"a","name":"Todo"},{"id":"b","name":"Done"}]}]}
        """
        let items = """
        {"items":[{"id":"I1","status":"Todo","content":{"type":"Issue","number":3,"title":"X","url":"u","repository":"example/gadget"}},
        {"id":"I2","content":{"type":"DraftIssue","title":"Y"}}]}
        """
        let status = GitHubJSON.statusField(from: Data(fields.utf8))
        XCTAssertEqual(status?.id, "F2")
        XCTAssertEqual(status?.options.map(\.name), ["Todo", "Done"])
        let parsed = GitHubJSON.projectItems(from: Data(items.utf8))
        XCTAssertEqual(parsed.first?.issueID, "gadget#3")
        let board = ProjectBoard(project: GitHubProject(id: "P", number: 1, title: "Plan"), status: status, items: parsed)
        XCTAssertEqual(board.columns, ["Todo", "Done", ProjectBoard.noStatus])
        XCTAssertEqual(board.items(in: ProjectBoard.noStatus).map(\.id), ["I2"])
    }

    func testEditArguments() {
        let arguments = GitHubCLI.editArguments(slug: "o/r", number: 4, title: nil, body: nil,
                                                addLabels: ["a", "b"], removeLabels: [], addAssignees: [],
                                                removeAssignees: ["x"], milestone: .remove)
        XCTAssertEqual(arguments, ["issue", "edit", "4", "-R", "o/r", "--add-label", "a,b", "--remove-assignee", "x",
                                   "--remove-milestone"])
    }

    func testProviderDeclaresWhatItCanDo() {
        let provider = GitHubCLI(owner: "example", executable: nil)
        XCTAssertEqual(provider.kind, .github)
        XCTAssertTrue(provider.capabilities.contains([.pullRequests, .commits, .pipelines, .workItems, .boards]))
        XCTAssertFalse(provider.capabilities.contains(.iterations))
        XCTAssertFalse(provider.capabilities.contains(.forks), "fork tracking is declared when it exists")
    }
}
