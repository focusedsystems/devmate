import DevMateCore
import XCTest
@testable import DevMateGitHub

final class GitHubProjectsProviderTests: XCTestCase {
    let provider = GitHubProjectsProvider(gh: GitHubCLI(owner: "example", executable: nil))

    func testVocabularyAndFeatures() {
        let words = provider.vocabulary
        XCTAssertEqual([words.container, words.tag, words.person, words.plan], ["Repository", "Label", "Assignee", "Milestone"])
        XCTAssertEqual(words.title(for: .all), "All")
        XCTAssertTrue(provider.features.contains([.create, .edit, .comment, .tags, .people, .plans, .closeReopen, .boards]))
        XCTAssertFalse(provider.features.contains(.queries))
        XCTAssertEqual(provider.laneProvider, .gitHub)
    }

    func testMapsAnIssue() {
        let issue = GitHubIssue(repo: "r", number: 4, title: "T", state: "CLOSED", stateReason: "NOT_PLANNED",
                                author: GitHubUser(login: "ann"), labels: [GitHubLabel(name: "bug", color: "ff0000")],
                                assignees: [GitHubUser(login: "bob", name: "Bob")],
                                milestone: GitHubMilestone(title: "M1"), url: "https://example.com/4", body: "B",
                                comments: [GitHubComment(id: "c", author: nil, body: "hi", createdAt: nil, url: nil)])
        let item = GitHubProjectsProvider.workItem(issue)
        XCTAssertEqual(item.id, issue.id)
        XCTAssertFalse(item.isOpen)
        XCTAssertEqual(item.resolution, .notPlanned)
        XCTAssertEqual(item.tags.first?.color, "ff0000")
        XCTAssertEqual(item.people.first?.display, "Bob")
        XCTAssertEqual(item.plan?.id, "M1")
        XCTAssertEqual(item.comments?.first?.body, "hi")
        XCTAssertEqual(provider.reference(for: item), "example/r#4")
    }

    func testMapsABoard() {
        let status = ProjectStatusField(id: "F", name: "Status", options: [.init(id: "o1", name: "Todo"), .init(id: "o2", name: "Done")])
        let items = [ProjectItem(id: "i1", title: "One", status: "Todo", type: "Issue", number: 1, repo: "r"),
                     ProjectItem(id: "i2", title: "Two", status: nil, type: "DraftIssue"),
                     ProjectItem(id: "i3", title: "Three", status: "Removed", type: "Issue", number: 3, repo: "r")]
        let board = GitHubProjectsProvider.workBoard(ProjectBoard(project: GitHubProject(id: "P", number: 7, title: "Plan"),
                                                                  status: status, items: items))
        XCTAssertEqual(board.id, "7")
        XCTAssertEqual(board.columns.map(\.name), ["Todo", "Done", ProjectBoard.noStatus, "Removed"])
        XCTAssertEqual(board.columns.map(\.acceptsDrops), [true, true, false, false])
        XCTAssertEqual(board.cards[0].columnID, "o1")
        XCTAssertEqual(board.cards[0].itemID, "r#1")
        XCTAssertEqual(board.cards[1].subtitle, "Draft")
        XCTAssertEqual(board.context["projectID"], "P")
        XCTAssertEqual(board.context["fieldID"], "F")
    }

    func testRefusesAMoveIntoAColumnThatTakesNoDrops() async {
        let board = WorkBoard(id: "7", title: "Plan", columns: [], cards: [], context: ["projectID": "P", "fieldID": "F"])
        let card = WorkBoardCard(id: "i", title: "t", columnID: "o1")
        do {
            try await provider.move(card, on: board, to: WorkBoardColumn(id: "x", name: "No Status", acceptsDrops: false))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No Status"))
        }
    }

    func testIssueNumberFromAddress() {
        XCTAssertEqual(GitHubProjectsProvider.issueNumber(fromAddress: "https://example.com/o/r/issues/42"), 42)
        XCTAssertNil(GitHubProjectsProvider.issueNumber(fromAddress: "created"))
    }

    func testImagePolicyIsTheAllowlist() {
        XCTAssertTrue(provider.allowsImage(URL(string: "https://user-images.githubusercontent.com/1/a.png")))
        XCTAssertFalse(provider.allowsImage(URL(string: "https://tracker.example/pixel.png")))
        XCTAssertFalse(provider.allowsImage(nil))
    }

    func testCloseReasonMapping() {
        XCTAssertEqual(GitHubProjectsProvider.closeReason(provider.closeReasons[1]), .notPlanned)
        XCTAssertEqual(GitHubProjectsProvider.closeReason(nil), .completed)
    }
}
