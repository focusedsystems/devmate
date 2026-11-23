import DevMateCore
@testable import DevMateGitHub
import XCTest

final class GitHubDevelopmentProviderTests: XCTestCase {
    private func repo(remote: String?) -> DevRepo {
        DevRepo(id: "example/widget", name: "widget", path: "/tmp/widget", remote: remote, provider: .github)
    }

    func testAddressComesFromTheRemote() {
        let cases: [(String?, String, String)] = [
            ("example/app", "example", "app"),
            ("https://github.com/example/app.git", "example", "app"),
            ("git@example.com:example/app.git", "example", "app"),
            (nil, "fallback", "widget"),
        ]
        for (remote, owner, name) in cases {
            let address = GitHubDevelopmentProvider.address(of: repo(remote: remote), defaultOwner: "fallback")
            XCTAssertEqual(address.owner, owner)
            XCTAssertEqual(address.name, name)
        }
    }

    func testMergeIsPinnedToTheHeadAndNeverAdmin() {
        for method in DevMergeMethod.allCases {
            let arguments = GitHubDevelopmentProvider.arguments(for: .merge(method, headSHA: "abc123", baseRef: "main"), number: 7,
                                                                slug: "example/app")
            XCTAssertEqual(Array(arguments.suffix(2)), ["--match-head-commit", "abc123"])
            XCTAssertFalse(arguments.contains("--admin"))
            XCTAssertFalse(arguments.contains("--auto"))
        }
    }

    func testTextStaysOneArgument() {
        let hostile = "--admin; rm -rf /"
        let arguments = GitHubDevelopmentProvider.arguments(for: .comment(hostile), number: 7, slug: "example/app")
        XCTAssertEqual(Array(arguments.suffix(2)), ["--body", hostile])
    }

    func testDetailDecodesAndMarksAMissingDiffTruncated() throws {
        let json = """
        {"body":"Why","headRefOid":"abc","commits":[{"oid":"abc","messageHeadline":"Subject","messageBody":"Body",
        "authors":[{"name":"Example Person","login":"example"}],"committedDate":"2026-01-02T03:04:05Z"}],
        "comments":[{"id":"c1","author":{"login":"example"},"body":"Looks fine","createdAt":"2026-01-02T03:04:05Z",
        "url":"https://example.com/c1"}]}
        """
        let view = try GitHubJSON.decoder.decode(GitHubDevelopmentProvider.PullView.self, from: Data(json.utf8))
        let detail = GitHubDevelopmentProvider.detail(view, diff: nil, baseRef: "main", baseSHA: "def", repo: repo(remote: "example/app"), url: "https://example.com/pull/7")
        XCTAssertEqual(detail.headSHA, "abc")
        XCTAssertEqual(detail.commits.first?.message, "Subject\n\nBody")
        XCTAssertEqual(detail.comments.first?.author, "example")
        XCTAssertTrue(detail.truncated)
    }

    func testRunStateMapsToTheNeutralState() {
        let run = WorkflowRun(repo: "app", databaseId: 1, displayTitle: "Build", workflowName: "ci", status: "completed",
                              conclusion: "failure", url: "https://example.com/run/1")
        let neutral = GitHubDevelopmentProvider.run(run, repo: repo(remote: "example/app"))
        XCTAssertEqual(neutral.state, .failed)
        XCTAssertTrue(neutral.isFinished)
    }

    // MARK: Pinned to the commit on screen

    private let shown = String(repeating: "a", count: 40)
    private let moved = String(repeating: "b", count: 40)
    private let baseSHA = String(repeating: "c", count: 40)
    private let advanced = String(repeating: "d", count: 40)

    /// A stand-in `gh` that logs its arguments and answers from files.
    private func fakeGH(head: String, baseRef: String = "main",
                        baseSHA: String? = nil) throws -> (provider: GitHubDevelopmentProvider, log: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("devmate-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let view = #"{"body":"Why","headRefOid":"\#(shown)","commits":[],"comments":[]}"#
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        case "$1 $2" in
          "pr view") printf '%s' '\(view)' ;;
          "api -H") printf 'compared diff' ;;
          "api repos/example/app/pulls/7") printf '%s\\t%s\\t%s\\n' '\(head)' '\(baseRef)' '\(baseSHA ?? self.baseSHA)' ;;
        esac
        exit 0
        """
        let executable = folder.appendingPathComponent("gh")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (GitHubDevelopmentProvider(defaultOwner: "example", executable: executable.path), log)
    }

    private func pull() -> DevPullRequest {
        DevPullRequest(repoID: "example/widget", repo: "widget", number: 7, title: "Change", author: "example",
                       headBranch: "work", baseBranch: "main", isDraft: false, checks: DevChecks(), review: .none,
                       updatedAt: nil, url: "https://example.com/pull/7")
    }

    private func log(_ file: URL) throws -> String { String(decoding: try Data(contentsOf: file), as: UTF8.self) }

    private var pinnedActions: [DevPullAction] {
        [.approve(headSHA: shown, baseRef: "main"),
         .requestChanges("Please fix", headSHA: shown, baseRef: "main"),
         .merge(.squash, headSHA: shown, baseRef: "main")]
    }

    func testReviewIsSubmittedForTheCommitShown() throws {
        let (provider, file) = try fakeGH(head: shown)
        try provider.perform(.approve(headSHA: shown, baseRef: "main"), on: pull(), in: repo(remote: "example/app"))
        let text = try log(file)
        XCTAssertTrue(text.contains("repos/example/app/pulls/7/reviews"))
        XCTAssertTrue(text.contains("event=APPROVE"))
        XCTAssertTrue(text.contains("commit_id=\(shown)"))
    }

    func testActionsAreRefusedWhenTheHeadMoved() throws {
        let (provider, file) = try fakeGH(head: moved)
        for action in pinnedActions {
            XCTAssertThrowsError(try provider.perform(action, on: pull(), in: repo(remote: "example/app")))
        }
        let text = try log(file)
        XCTAssertFalse(text.contains("/reviews"))
        XCTAssertFalse(text.contains("pr merge"))
    }

    func testActionsAreRefusedWhenTheBaseBranchChanged() throws {
        let (provider, file) = try fakeGH(head: shown, baseRef: "release")
        for action in pinnedActions {
            XCTAssertThrowsError(try provider.perform(action, on: pull(), in: repo(remote: "example/app")))
        }
        let text = try log(file)
        XCTAssertFalse(text.contains("/reviews"))
        XCTAssertFalse(text.contains("pr merge"))
    }

    func testABaseBranchWithALookalikeNameIsRefused() throws {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        XCTAssertEqual(composed, decomposed)
        let (provider, file) = try fakeGH(head: shown, baseRef: decomposed)
        let action = DevPullAction.approve(headSHA: shown, baseRef: composed)
        XCTAssertThrowsError(try provider.perform(action, on: pull(), in: repo(remote: "example/app")))
        XCTAssertFalse(try log(file).contains("/reviews"))
    }

    func testABaseBranchThatOnlyAdvancedIsNotRefused() throws {
        let (provider, file) = try fakeGH(head: shown, baseSHA: advanced)
        for action in pinnedActions {
            XCTAssertNoThrow(try provider.perform(action, on: pull(), in: repo(remote: "example/app")))
        }
        XCTAssertTrue(try log(file).contains("pr merge"))
    }

    func testDiffIsFetchedBetweenTheTwoExactCommits() throws {
        let (provider, file) = try fakeGH(head: shown)
        let detail = try provider.detail(of: pull(), in: repo(remote: "example/app"))
        XCTAssertEqual(detail.headSHA, shown)
        XCTAssertEqual(detail.baseRef, "main")
        XCTAssertEqual(detail.baseSHA, baseSHA)
        XCTAssertEqual(detail.diff, "compared diff")
        let text = try log(file)
        XCTAssertTrue(text.contains("repos/example/app/compare/\(baseSHA)...\(shown)"))
        XCTAssertTrue(text.contains("Accept: application/vnd.github.diff"))
        XCTAssertFalse(text.contains("pr diff"))
    }

    func testDetailIsRefusedWhenItsCommitsAreOfAnotherHead() throws {
        let (provider, file) = try fakeGH(head: moved)
        XCTAssertThrowsError(try provider.detail(of: pull(), in: repo(remote: "example/app")))
        XCTAssertFalse(try log(file).contains("/compare/"))
    }

    func testStateParsingRejectsAnythingButExactCommits() {
        XCTAssertEqual(GitHubDevelopmentProvider.parseState("\(shown)\tmain\t\(baseSHA)\n")?.baseRef, "main")
        XCTAssertNil(GitHubDevelopmentProvider.parseState("short\tmain\t\(baseSHA)"))
        XCTAssertNil(GitHubDevelopmentProvider.parseState("\(shown)\t\t\(baseSHA)"))
        XCTAssertNil(GitHubDevelopmentProvider.parseState("\(shown)\tmain"))
    }

    func testAnItemFromAnotherRepositoryIsRefused() throws {
        let (provider, file) = try fakeGH(head: shown)
        let other = DevRepo(id: "other/widget", name: "widget", path: "/tmp/widget", remote: "other/widget",
                            provider: .github)
        XCTAssertThrowsError(try provider.perform(.close, on: pull(), in: other))
        XCTAssertTrue(try log(file).isEmpty)
    }
}
