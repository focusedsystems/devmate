import DevMateCore
@testable import DevMateUI
import XCTest

private final class FakeDevelopmentProvider: DevelopmentProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _checkOuts = 0
    private var _actions: [DevPullAction] = []
    var capabilities: ProviderCapabilities = [.pullRequests, .commits, .pipelines]
    var failing: Set<String> = []
    var risky = false

    var kind: RepoProviderKind { .github }
    var checkOuts: Int { lock.withLock { _checkOuts } }
    var actions: [DevPullAction] { lock.withLock { _actions } }

    func allowsImage(_ url: URL?) -> Bool { false }

    func commits(in repo: DevRepo) throws -> [DevCommit] {
        if failing.contains(repo.name) { throw RepoFailure() }
        return [DevCommit(repoID: repo.id, repo: repo.name, sha: "abc1234", message: "Change \(repo.name)", author: "example",
                          date: Date(), url: "https://example.com/c")]
    }

    func runs(in repo: DevRepo) throws -> [DevPipelineRun] { [] }
    func rerun(_ run: DevPipelineRun, in repo: DevRepo, failedOnly: Bool) throws {}
    func cancel(_ run: DevPipelineRun, in repo: DevRepo) throws { lock.withLock { _actions.append(.close) } }
    func log(of run: DevPipelineRun, in repo: DevRepo) throws -> String { "" }

    func pullRequests(in repo: DevRepo) throws -> [DevPullRequest] { [Self.pull(repo.name, id: repo.id)] }

    static func pull(_ repo: String, id: String? = nil) -> DevPullRequest {
        DevPullRequest(repoID: id ?? "example/\(repo)", repo: repo, number: 7, title: "Change", author: "example", headBranch: "work", baseBranch: "main",
                       isDraft: false, checks: DevChecks(passed: 1), review: .none, updatedAt: Date(),
                       url: "https://example.com/pull/7")
    }

    func detail(of pull: DevPullRequest, in repo: DevRepo) throws -> DevPullDetail {
        DevPullDetail(body: "", headSHA: "abc", baseRef: "main", baseSHA: "def", commits: [], comments: [], diff: "", truncated: false)
    }

    func perform(_ action: DevPullAction, on pull: DevPullRequest, in repo: DevRepo) throws {
        lock.withLock { _actions.append(action) }
    }

    func risk(of pull: DevPullRequest, in repo: DevRepo) throws -> PullRequestRisk {
        let subject = LaneItemReference(provider: .gitHub, owner: "example", repo: pull.repo, number: pull.number, url: pull.url)
        return PullRequestRisk(subject: subject, authorAssociation: risky ? "NONE" : "OWNER", sensitiveFiles: [],
                               headSHA: String(repeating: "a", count: 40), filesComplete: true, symlinks: [])
    }

    func checkOut(_ request: SafeLaneRequest, in repo: DevRepo) throws -> URL {
        lock.withLock { _checkOuts += 1 }
        return URL(fileURLWithPath: repo.path)
    }

    struct RepoFailure: Error {}
}

@MainActor
final class DevelopmentModelTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("devmate-dev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "devmate-dev-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func model(_ provider: FakeDevelopmentProvider, names: [String] = ["one", "two"]) -> DevelopmentModel {
        let repos = names.map {
            DevRepo(id: "example/\($0)", name: $0, path: root.path, remote: "example/\($0)", provider: .github)
        }
        let source = RegistryRepoSource(
            bundleID: "com.example.devmate-sample",
            fallback: RepoCatalog(sections: [RepoSection(name: "Apps", repos: repos)]),
            directory: root.appendingPathComponent("registry", isDirectory: true),
            lastGoodFile: root.appendingPathComponent("cache/last-good.json")
        )
        return DevelopmentModel(provider: provider, source: source, defaults: defaults, home: root)
    }

    private func wait(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testSegmentsKeepTheirOrderAndFollowCapabilities() {
        let provider = FakeDevelopmentProvider()
        XCTAssertEqual(model(provider).segments.map(\.title), ["Repos", "Pulls", "Commits", "Pipelines", "Skills"])
        provider.capabilities = [.commits]
        XCTAssertEqual(model(provider).segments.map(\.title), ["Repos", "Commits", "Skills"])
    }

    func testASavedSegmentTheProviderLacksFallsBackToRepos() {
        defaults.set("Pipelines", forKey: "devmate.development.segment")
        let provider = FakeDevelopmentProvider()
        provider.capabilities = [.commits]
        XCTAssertEqual(model(provider).segment, .repos)
    }

    func testOneFailingRepositoryDoesNotHideTheOthers() async {
        let provider = FakeDevelopmentProvider()
        provider.failing = ["two"]
        let development = model(provider)
        development.loadCommits(force: true)
        await wait { development.commits.loadedAt != nil }
        XCTAssertEqual(development.commits.value.map(\.repo), ["one"])
        XCTAssertEqual(development.commits.errors.count, 1)
        XCTAssertTrue(development.commits.errors[0].hasPrefix("two:"))
    }

    func testRiskyCheckoutWaitsForConfirmation() async {
        let provider = FakeDevelopmentProvider()
        provider.risky = true
        let development = model(provider)
        var opened: SafeLaneRequest?
        development.onOpenCheckout = { _, request, _ in opened = request }
        development.checkOutInLane(FakeDevelopmentProvider.pull("one"))
        await wait { development.pendingCheckout != nil }
        XCTAssertNotNil(development.pendingCheckout)
        XCTAssertEqual(provider.checkOuts, 0)

        development.confirmPendingCheckout()
        await wait { opened != nil }
        XCTAssertEqual(provider.checkOuts, 1)
        XCTAssertEqual(opened?.start, .shell)
        XCTAssertNil(opened?.prompt)
    }

    func testTrustedCheckoutOpensAShellLane() async {
        let development = model(FakeDevelopmentProvider())
        var opened: SafeLaneRequest?
        development.onOpenCheckout = { _, request, _ in opened = request }
        development.checkOutInLane(FakeDevelopmentProvider.pull("one"))
        await wait { opened != nil }
        XCTAssertEqual(opened?.start, .shell)
    }

    func testCancelWaitsForConfirmation() async {
        let provider = FakeDevelopmentProvider()
        let development = model(provider)
        let run = DevPipelineRun(repoID: "example/one", repo: "one", runID: 1, title: "Build", pipeline: "ci", branch: nil, event: nil,
                                 state: .running, isFinished: false, detail: "", startedAt: nil, updatedAt: nil,
                                 url: "https://example.com/run")
        development.requestCancel(run)
        XCTAssertEqual(development.pendingCancel, run)
        XCTAssertTrue(provider.actions.isEmpty)
        development.confirmCancel()
        await wait { !provider.actions.isEmpty }
        XCTAssertEqual(provider.actions.count, 1)
    }

    func testSameNameUnderTwoOwnersStaysTwoRepositories() async throws {
        let provider = FakeDevelopmentProvider()
        let first = DevRepo(id: "first/app", name: "app", path: root.path, remote: "first/app", provider: .github)
        let second = DevRepo(id: "second/app", name: "app", path: root.path, remote: "second/app", provider: .github)
        let source = RegistryRepoSource(
            bundleID: "com.example.devmate-sample",
            fallback: RepoCatalog(sections: [RepoSection(name: "Apps", repos: [first, second])]),
            directory: root.appendingPathComponent("registry", isDirectory: true),
            lastGoodFile: root.appendingPathComponent("cache/last-good.json")
        )
        let development = DevelopmentModel(provider: provider, source: source, defaults: defaults, home: root)
        XCTAssertEqual(try development.resolve("second/app").remote, "second/app")
        development.loadCommits(force: true)
        await wait { development.commits.loadedAt != nil }
        XCTAssertEqual(Set(development.commits.value.map(\.id)).count, 2)
        development.repoFilter = "second/app"
        XCTAssertEqual(development.visibleCommits.map(\.repoID), ["second/app"])
    }

    func testARepeatedOrMissingIdIsRefused() throws {
        let provider = FakeDevelopmentProvider()
        let twin = DevRepo(id: "example/app", name: "app", path: root.path, remote: "example/app", provider: .github)
        let source = RegistryRepoSource(
            bundleID: "com.example.devmate-sample",
            fallback: RepoCatalog(sections: [RepoSection(name: "Apps", repos: [twin, twin])]),
            directory: root.appendingPathComponent("registry", isDirectory: true),
            lastGoodFile: root.appendingPathComponent("cache/last-good.json")
        )
        let development = DevelopmentModel(provider: provider, source: source, defaults: defaults, home: root)
        XCTAssertThrowsError(try development.resolve("example/app"))
        XCTAssertThrowsError(try development.resolve("example/missing"))
    }
}
