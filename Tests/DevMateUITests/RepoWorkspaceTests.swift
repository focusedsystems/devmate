import DevMateCore
import DevMateGit
@testable import DevMateUI
import XCTest

@MainActor
final class RepoWorkspaceTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devmate-workspace-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "devmate-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: String..., in folder: URL) throws -> String {
        let result = ProcessRunner.run("/usr/bin/env", ["git"] + arguments, directory: folder, timeout: 30)
        guard let result, result.status == 0 else {
            throw RepoError.gitFailed(command: arguments.joined(separator: " "), message: result?.error ?? "did not run")
        }
        return result.output
    }

    private func makeClone(branch: String = "main") throws -> URL {
        let clone = root.appendingPathComponent("widget")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try git("init", "-q", "-b", branch, in: clone)
        try git("config", "user.email", "person@example.com", in: clone)
        try git("config", "user.name", "Example Person", in: clone)
        try Data("one\n".utf8).write(to: clone.appendingPathComponent("a.txt"))
        try git("add", "a.txt", in: clone)
        try git("commit", "-q", "-m", "First", in: clone)
        return clone
    }

    private func model(_ repos: [DevRepo]) -> RepoWorkspaceModel {
        let source = RegistryRepoSource(
            bundleID: "com.example.devmate-sample",
            fallback: RepoCatalog(sections: [RepoSection(name: "Apps", repos: repos)]),
            directory: root.appendingPathComponent("registry", isDirectory: true),
            lastGoodFile: root.appendingPathComponent("cache/last-good.json")
        )
        return RepoWorkspaceModel(source: source, defaults: defaults)
    }

    private func repo(_ name: String, path: String? = nil, development: Bool = true) -> DevRepo {
        DevRepo(id: "example/\(name)", name: name, path: path ?? "/tmp/\(name)", provider: .github,
                surfaces: RepoSurfaces(development: development))
    }

    func testListsOnlyDevelopmentRepositories() {
        let workspace = model([repo("shown"), repo("elsewhere", development: false)])
        workspace.reloadRecords()
        XCTAssertEqual(workspace.allRepos.map(\.name), ["shown"])
    }

    private func names(_ workspace: RepoWorkspaceModel, _ sort: RepoSidebarSort = .custom) -> [String] {
        workspace.arranged(workspace.allRepos, sort: sort).map(\.name)
    }

    func testCustomOrderFallsBackToNameWithoutAnAppOrder() {
        let workspace = model([repo("charlie"), repo("alpha"), repo("bravo")])
        workspace.reloadRecords()
        XCTAssertEqual(names(workspace), ["alpha", "bravo", "charlie"])
        XCTAssertFalse(workspace.hasCustomOrder)
    }

    func testAppOrderLeadsAndUnnamedRepositoriesFollowByName() {
        let workspace = model([repo("alpha"), repo("bravo"), repo("charlie"), repo("delta")])
        workspace.preferredOrder = ["/tmp/charlie/", "example/alpha", "/tmp/missing"]
        workspace.reloadRecords()
        XCTAssertEqual(names(workspace), ["charlie", "alpha", "bravo", "delta"])
        XCTAssertEqual(names(workspace, .name), ["alpha", "bravo", "charlie", "delta"])
    }

    func testDraggingSavesAnOrderThatReplacesTheAppOrder() {
        let workspace = model([repo("alpha"), repo("bravo"), repo("charlie")])
        workspace.preferredOrder = ["/tmp/charlie", "/tmp/bravo", "/tmp/alpha"]
        workspace.reloadRecords()
        let shown = workspace.arranged(workspace.allRepos, sort: .custom).map(\.id)
        workspace.move(shown, fromOffsets: IndexSet(integer: 2), toOffset: 0, sort: .custom)
        XCTAssertEqual(names(workspace), ["alpha", "charlie", "bravo"])
        XCTAssertEqual(defaults.stringArray(forKey: "devmate.repos.order"),
                       ["example/alpha", "example/charlie", "example/bravo"])

        workspace.preferredOrder = ["/tmp/bravo"]
        XCTAssertEqual(names(workspace), ["alpha", "charlie", "bravo"])

        let reopened = model([repo("alpha"), repo("bravo"), repo("charlie")])
        reopened.reloadRecords()
        XCTAssertEqual(names(reopened), ["alpha", "charlie", "bravo"])

        reopened.preferredOrder = ["/tmp/bravo"]
        reopened.resetOrder()
        XCTAssertEqual(names(reopened), ["bravo", "alpha", "charlie"])
        XCTAssertNil(defaults.stringArray(forKey: "devmate.repos.order"))
    }

    func testMoveUpAndDownStayWithinTheShownRun() {
        let workspace = model([repo("alpha"), repo("bravo"), repo("charlie"), repo("delta")])
        workspace.reloadRecords()
        let run = ["example/bravo", "example/delta"]
        XCTAssertFalse(workspace.canMove("example/bravo", by: -1, in: run))
        XCTAssertTrue(workspace.canMove("example/bravo", by: 1, in: run))
        workspace.move("example/bravo", by: 1, in: run, sort: .custom)
        XCTAssertEqual(names(workspace), ["alpha", "delta", "charlie", "bravo"])
        workspace.move("example/bravo", by: -1, in: run.reversed(), sort: .custom)
        XCTAssertEqual(names(workspace), ["alpha", "bravo", "charlie", "delta"])
    }

    func testReorderingUnderAnotherSortStartsFromWhatIsShown() {
        let workspace = model([repo("charlie"), repo("alpha"), repo("bravo")])
        workspace.preferredOrder = ["/tmp/charlie"]
        workspace.reloadRecords()
        let shown = workspace.arranged(workspace.allRepos, sort: .name).map(\.id)
        workspace.move("example/alpha", by: 1, in: shown, sort: .name)
        XCTAssertEqual(names(workspace), ["bravo", "alpha", "charlie"])
    }

    func testHidingIsAPreferenceAndNeverWritesTheRegistry() {
        let shown = repo("shown")
        let workspace = model([shown, repo("other")])
        workspace.reloadRecords()
        workspace.setHidden(shown, true)
        XCTAssertEqual(workspace.tracked.map(\.name), ["other"])
        XCTAssertEqual(defaults.stringArray(forKey: "devmate.repos.hidden"), [shown.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("registry").path))

        let reopened = model([shown, repo("other")])
        reopened.reloadRecords()
        XCTAssertEqual(reopened.tracked.map(\.name), ["other"])
    }

    func testAmendAsksFirstAndChangesNothingUntilConfirmed() async throws {
        let clone = try makeClone()
        let state = GitPaneState()
        state.attach(GitWorkingCopy(path: clone.path), protectedBranches: [])
        let before = try git("rev-parse", "HEAD", in: clone)
        state.commitSubject = "Rewritten"
        state.amend = true

        await state.requestCommit(thenPush: false)
        XCTAssertNotNil(state.amendRequest)
        let unchanged = try git("rev-parse", "HEAD", in: clone)
        XCTAssertEqual(unchanged, before)

        let request = try XCTUnwrap(state.amendRequest)
        state.amendRequest = nil
        await state.performAmend(request)
        let after = try git("rev-parse", "HEAD", in: clone)
        XCTAssertNotEqual(after, before)
    }

    func testPushRefusesTheRepositoryDefaultBranchEvenWhenNotListed() async throws {
        let clone = try makeClone(branch: "trunk")
        let remote = root.appendingPathComponent("remote.git")
        try git("init", "-q", "--bare", "-b", "trunk", remote.path, in: root)
        try git("remote", "add", "origin", remote.path, in: clone)
        try git("update-ref", "refs/remotes/origin/trunk", "HEAD", in: clone)
        try git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk", in: clone)

        let state = GitPaneState()
        var refused: String?
        state.onError = { title, _ in refused = title }
        state.attach(GitWorkingCopy(path: clone.path), protectedBranches: [])
        await state.runPush()
        XCTAssertEqual(refused, "Push refused")
        let refs = try git("for-each-ref", in: remote)
        XCTAssertTrue(refs.isEmpty)
    }

    func testStashDropWaitsForItsRequestAndKeepsOthers() async throws {
        let clone = try makeClone()
        let copy = GitWorkingCopy(path: clone.path)
        try Data("two\n".utf8).write(to: clone.appendingPathComponent("a.txt"))
        try await copy.stashPush(message: "First", includeUntracked: false)
        try Data("three\n".utf8).write(to: clone.appendingPathComponent("a.txt"))
        try await copy.stashPush(message: "Second", includeUntracked: false)

        let state = GitPaneState()
        state.attach(copy, protectedBranches: [])
        await state.refresh()
        XCTAssertEqual(state.stashes.count, 2)
        await state.perform(GitPaneState.StashRequest(action: .drop, stash: state.stashes[0]))
        XCTAssertEqual(state.stashes.count, 1)
        XCTAssertTrue(state.stashes[0].message.contains("First"))
    }

    func testOpenWithIsAnAllowlistThatChecksSymlinkTargets() throws {
        func file(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data("x\n".utf8).write(to: url)
            return url
        }
        XCTAssertTrue(GitOpenWithPolicy.allows(try file("notes.txt")))
        XCTAssertTrue(GitOpenWithPolicy.allows(try file("picture.png")))
        for name in ["run.command", "run.terminal", "run.tool", "go.fileloc", "go.webloc", "go.inetloc", "page.html",
                     "art.svg", "script.sh", "script.py", "noextension", "thing.unknownkind"] {
            XCTAssertFalse(GitOpenWithPolicy.allows(try file(name)), name)
        }
        let executable = try file("tool.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertFalse(GitOpenWithPolicy.allows(executable))

        let hidden = root.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(at: hidden, withDestinationURL: try file("target.command"))
        XCTAssertFalse(GitOpenWithPolicy.allows(hidden))
        let renamed = root.appendingPathComponent("link.command")
        try FileManager.default.createSymbolicLink(at: renamed, withDestinationURL: try file("plain.txt"))
        XCTAssertFalse(GitOpenWithPolicy.allows(renamed))
        let folder = root.appendingPathComponent("folder.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(GitOpenWithPolicy.allows(folder))
    }

    // MARK: Withheld paths

    private func withholdingModel(_ clone: URL) -> RepoWorkspaceModel {
        let repo = DevRepo(id: "example/widget", name: "widget", path: clone.path, provider: .github)
        let source = RegistryRepoSource(
            bundleID: "com.example.devmate-sample",
            fallback: RepoCatalog(sections: [RepoSection(name: "Apps", repos: [repo])]),
            directory: root.appendingPathComponent("registry", isDirectory: true),
            lastGoodFile: root.appendingPathComponent("cache/last-good.json")
        )
        let slots = RepoWorkspaceSlots(withheld: WithheldPaths(folderNames: ["private-data"]))
        return RepoWorkspaceModel(source: source, slots: slots, defaults: defaults)
    }

    private func addPrivateFile(_ clone: URL) throws {
        let folder = clone.appendingPathComponent("private-data")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("needle secret\n".utf8).write(to: folder.appendingPathComponent("a.csv"))
    }

    func testWithheldFilesAreNotListedSearchedOrOpened() async throws {
        let clone = try makeClone()
        try addPrivateFile(clone)
        try Data("needle public\n".utf8).write(to: clone.appendingPathComponent("b.txt"))
        try FileManager.default.createSymbolicLink(at: clone.appendingPathComponent("link.csv"),
                                                   withDestinationURL: clone.appendingPathComponent("private-data/a.csv"))
        let workspace = withholdingModel(clone)
        workspace.reloadRecords()
        await workspace.loadSelected()
        await workspace.git.refresh()

        XCTAssertFalse(workspace.files.contains { $0.hasPrefix("private-data/") })
        XCTAssertFalse(workspace.git.files.contains { $0.relativePath.hasPrefix("private-data/") })
        XCTAssertFalse(workspace.git.files.contains { $0.relativePath == "link.csv" })
        XCTAssertGreaterThan(workspace.git.withheldCount, 0)

        await workspace.grep("needle")
        XCTAssertEqual(workspace.grepResults.map(\.path), ["b.txt"])

        workspace.open("private-data/a.csv")
        XCTAssertNil(workspace.document)
        workspace.open("link.csv")
        XCTAssertNil(workspace.document)
    }

    func testStashAndCommitRefuseWithheldChanges() async throws {
        let clone = try makeClone()
        try addPrivateFile(clone)
        let workspace = withholdingModel(clone)
        workspace.reloadRecords()
        await workspace.loadSelected()
        var refused: [String] = []
        workspace.git.onError = { title, _ in refused.append(title) }

        await workspace.git.saveStash(message: "All", includeUntracked: true)
        XCTAssertEqual(refused.last, "Stash refused")
        let stashes = try git("stash", "list", in: clone)
        XCTAssertTrue(stashes.isEmpty)

        try git("checkout", "-q", "-b", "work", in: clone)
        try git("add", "private-data/a.csv", in: clone)
        let before = try git("rev-parse", "HEAD", in: clone)
        workspace.git.commitSubject = "Add"
        let committed = await workspace.git.runCommit()
        XCTAssertFalse(committed)
        XCTAssertEqual(refused.last, "Commit refused")
        let after = try git("rev-parse", "HEAD", in: clone)
        XCTAssertEqual(after, before)
    }
}
