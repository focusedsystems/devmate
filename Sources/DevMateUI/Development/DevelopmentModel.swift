import AppKit
import DevMateCore
import DevMateGit
import SwiftUI

/// A list read from the provider, with when it was read and what failed.
public struct DevLoaded<Value: Sendable>: Sendable {
    public var value: Value
    public var loadedAt: Date?
    public var isLoading = false
    public var errors: [String] = []

    /// Older than this, showing the list reads it again.
    static var freshness: TimeInterval { 5 * 60 }
    var isStale: Bool { loadedAt.map { Date().timeIntervalSince($0) > Self.freshness } ?? true }

    init(value: Value, loadedAt: Date? = nil, errors: [String] = []) {
        self.value = value
        self.loadedAt = loadedAt
        self.errors = errors
    }
}

extension DevLoaded where Value: Equatable {
    /// The state after a read finished. The rows are replaced only when they
    /// differ, so an unchanged background read leaves the list as it was.
    func finished(with rows: Value, errors: [String]) -> DevLoaded {
        var next = self
        if next.value != rows { next.value = rows }
        next.errors = errors
        next.loadedAt = Date()
        next.isLoading = false
        return next
    }
}

/// Rows and failures collected from several threads.
private final class Gathered<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [T] = []
    private var errors: [String] = []

    func add(_ result: Result<[T], Error>, from repo: String) {
        lock.withLock {
            switch result {
            case .success(let found): rows += found
            case .failure(let error): errors.append("\(repo): \(error.localizedDescription)")
            }
        }
    }

    var result: ([T], [String]) { lock.withLock { (rows, errors.sorted()) } }
}

/// Views an app adds to the Development tab. DevMate knows nothing about
/// what they do.
@MainActor
public struct DevelopmentSlots {
    /// Toolbar items after the repository filter, such as a status button.
    public var toolbar: () -> AnyView
    /// Shown in the pull request viewer, under the overview.
    public var pullDetail: (DevPullRequest) -> AnyView
    /// Hands a run to the agent working in its repository, with a prompt
    /// DevMate built from the run and its log. Nil hides Send to Agent.
    public var sendRunToAgent: (@MainActor (DevPipelineRun, String) -> Void)?

    public init(toolbar: @escaping () -> AnyView = { AnyView(EmptyView()) },
                pullDetail: @escaping (DevPullRequest) -> AnyView = { _ in AnyView(EmptyView()) },
                sendRunToAgent: (@MainActor (DevPipelineRun, String) -> Void)? = nil) {
        self.sendRunToAgent = sendRunToAgent
        self.toolbar = toolbar
        self.pullDetail = pullDetail
    }
}

/// The Development tab: Repos, Pulls, Commits, Pipelines and Skills. An app
/// keeps one for its lifetime, so switching tabs keeps what was read.
@MainActor
public final class DevelopmentModel: ObservableObject {
    public enum Segment: String, CaseIterable, Hashable, Sendable {
        case repos = "Repos"
        case pullRequests = "Pulls"
        case commits = "Commits"
        case pipelines = "Pipelines"
        case skills = "Skills"

        public var title: String { rawValue }
    }

    /// A pull request waiting for the person to confirm its checkout, and why.
    public struct PendingCheckout: Identifiable {
        public let pull: DevPullRequest
        public let risk: PullRequestRisk
        let request: SafeLaneRequest
        public var id: String { pull.id }
    }

    public let repos: RepoWorkspaceModel
    public let provider: any DevelopmentProvider
    let slots: DevelopmentSlots
    private let cache: DiskCache?
    private let defaults: UserDefaults
    private let home: URL

    /// Opens a plain shell lane in a pull request's checkout.
    public var onOpenCheckout: ((DevRepo, SafeLaneRequest, URL) -> Void)?

    @Published public var segment: Segment {
        didSet { defaults.set(segment.rawValue, forKey: Self.segmentKey) }
    }
    /// Commits, Pipelines and Pulls show one repository, by registry id, or all.
    @Published public var repoFilter: String? {
        didSet { defaults.set(repoFilter, forKey: Self.filterKey) }
    }
    @Published public var search = ""
    @Published var runStateFilter: DevPipelineRun.State?

    @Published private(set) var commits = DevLoaded<[DevCommit]>(value: [])
    @Published private(set) var runs = DevLoaded<[DevPipelineRun]>(value: [])
    @Published private(set) var pulls = DevLoaded<[DevPullRequest]>(value: [])
    @Published private(set) var skills = DevLoaded<[SkillCatalog.Skill]>(value: [])

    @Published var selectedCommit: DevCommit.ID?
    @Published public var selectedRun: DevPipelineRun.ID?
    @Published public var selectedPull: DevPullRequest.ID?
    @Published var selectedSkill: SkillCatalog.Skill.ID?
    @Published public var actionError: String?
    @Published var pendingCheckout: PendingCheckout?
    /// A run waiting for the person to confirm cancelling it.
    @Published var pendingCancel: DevPipelineRun?
    @Published private(set) var busyRuns: Set<DevPipelineRun.ID> = []
    @Published private(set) var checkingOut: Set<DevPullRequest.ID> = []

    private static let segmentKey = "devmate.development.segment"
    private static let filterKey = "devmate.development.repoFilter"

    public init(provider: any DevelopmentProvider, source: RegistryRepoSource,
                protectedBranches: Set<String> = ["main", "master"], cache: DiskCache? = nil,
                repoSlots: RepoWorkspaceSlots = RepoWorkspaceSlots(), slots: DevelopmentSlots = DevelopmentSlots(),
                repoOrder: [String] = [],
                defaults: UserDefaults = .standard,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.provider = provider
        self.cache = cache
        self.slots = slots
        self.defaults = defaults
        self.home = home
        repos = RepoWorkspaceModel(source: source, protectedBranches: protectedBranches, slots: repoSlots,
                                   preferredOrder: repoOrder, defaults: defaults)
        segment = Segment(rawValue: defaults.string(forKey: Self.segmentKey) ?? "") ?? .repos
        repoFilter = defaults.string(forKey: Self.filterKey)
        if let cached = cache?.load([DevCommit].self, key: "development.commits") { commits.value = cached.value }
        if let cached = cache?.load([DevPipelineRun].self, key: "development.runs") { runs.value = cached.value }
        if let cached = cache?.load([DevPullRequest].self, key: "development.pulls") { pulls.value = cached.value }
        repos.reloadRecords()
        if !segments.contains(segment) { segment = .repos }
    }

    /// The segments this provider supports, in their fixed order.
    public var segments: [Segment] {
        Segment.allCases.filter { segment in
            switch segment {
            case .repos, .skills: return true
            case .pullRequests: return provider.capabilities.contains(.pullRequests)
            case .commits: return provider.capabilities.contains(.commits)
            case .pipelines: return provider.capabilities.contains(.pipelines)
            }
        }
    }

    /// Repositories this provider can read.
    var hostedRepos: [DevRepo] {
        repos.allRepos.filter { $0.provider == provider.kind && $0.kind == .repo && $0.remote != nil }
    }

    /// The one repository with this registry id. Refuses a missing or
    /// repeated id rather than act on a guess.
    func resolve(_ id: String) throws -> DevRepo {
        let found = hostedRepos.filter { $0.id == id }
        guard found.count == 1, let repo = found.first else {
            throw RepoError.invalidArgument(found.isEmpty
                ? "This repository is no longer in the app's list."
                : "More than one repository in the app's list has the id \(id), so nothing was done.")
        }
        return repo
    }

    // MARK: Loading

    /// Reads the open segment's list again when it is older than `age`
    /// seconds. For an app's own cadence and for the window becoming key: it
    /// is quiet, replacing rows only when they changed.
    public func refreshIfOlder(than age: TimeInterval) {
        let loaded: Date?
        switch segment {
        case .commits: loaded = commits.loadedAt
        case .pipelines: loaded = runs.loadedAt
        case .pullRequests: loaded = pulls.loadedAt
        case .skills: loaded = skills.loadedAt
        case .repos:
            // The workspace reads its own status every half minute while shown.
            repos.reloadRecords()
            return
        }
        guard loaded.map({ Date().timeIntervalSince($0) > age }) ?? true else { return }
        load(force: true)
    }

    /// Reads the open segment's list when it is stale, or always with `force`.
    public func load(_ segment: Segment? = nil, force: Bool = false) {
        repos.reloadRecords()
        switch segment ?? self.segment {
        case .repos:
            if force { Task { await repos.refreshStatuses() } }
        case .commits: loadCommits(force: force)
        case .pipelines: loadRuns(force: force)
        case .pullRequests: loadPulls(force: force)
        case .skills: loadSkills(force: force)
        }
    }

    /// One list from every repository. A repository that fails is named in
    /// the errors, and the rest still show.
    private func gather<T: Sendable>(_ read: @escaping @Sendable (any DevelopmentProvider, DevRepo) throws -> [T]) async
        -> ([T], [String]) {
        let provider = self.provider
        let targets = hostedRepos
        return await Self.offMain {
            let gathered = Gathered<T>()
            DispatchQueue.concurrentPerform(iterations: targets.count) { index in
                let repo = targets[index]
                gathered.add(Result { try read(provider, repo) }, from: repo.name)
            }
            return gathered.result
        }
    }

    /// Provider calls block on a process, so they never run on the main actor
    /// or a Swift concurrency thread.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    nonisolated static func offMainThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await offMain { Result { try work() } }.get()
    }

    func loadCommits(force: Bool = false) {
        guard !commits.isLoading, force || commits.isStale else { return }
        commits.isLoading = true
        Task {
            let (rows, errors) = await gather { provider, repo in try provider.commits(in: repo) }
            let sorted = rows.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            commits = commits.finished(with: sorted, errors: errors)
            cache?.save(sorted, key: "development.commits")
        }
    }

    func loadRuns(force: Bool = false) {
        guard !runs.isLoading, force || runs.isStale else { return }
        runs.isLoading = true
        Task {
            let (rows, errors) = await gather { provider, repo in try provider.runs(in: repo) }
            let sorted = rows.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            runs = runs.finished(with: sorted, errors: errors)
            cache?.save(sorted, key: "development.runs")
        }
    }

    func loadPulls(force: Bool = false) {
        guard !pulls.isLoading, force || pulls.isStale else { return }
        pulls.isLoading = true
        Task {
            let (rows, errors) = await gather { provider, repo in try provider.pullRequests(in: repo) }
            let sorted = rows.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            pulls = pulls.finished(with: sorted, errors: errors)
            cache?.save(sorted, key: "development.pulls")
        }
    }

    func loadSkills(force: Bool = false) {
        guard !skills.isLoading, force || skills.isStale else { return }
        skills.isLoading = true
        let folders = repos.allRepos.map { (name: $0.name, path: $0.localPath) }
        let home = self.home
        Task {
            let found = await Self.offMain {
                SkillCatalog.scan(repos: folders.map { (name: $0.name, folder: URL(fileURLWithPath: $0.path, isDirectory: true)) },
                                  home: home)
            }
            skills = DevLoaded(value: found, loadedAt: Date())
        }
    }

    // MARK: Filtering

    private func matchesRepo(_ repoID: String) -> Bool { repoFilter.map { $0 == repoID } ?? true }
    private var needle: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    var visibleCommits: [DevCommit] {
        commits.value.filter { commit in
            matchesRepo(commit.repoID) && (needle.isEmpty
                || commit.message.lowercased().contains(needle)
                || (commit.author ?? "").lowercased().contains(needle)
                || commit.sha.hasPrefix(needle))
        }
    }

    var visibleRuns: [DevPipelineRun] {
        runs.value.filter { run in
            matchesRepo(run.repoID) && (runStateFilter.map { run.state == $0 } ?? true) && (needle.isEmpty
                || run.title.lowercased().contains(needle)
                || run.pipeline.lowercased().contains(needle)
                || (run.branch ?? "").lowercased().contains(needle))
        }
    }

    var visiblePulls: [DevPullRequest] {
        pulls.value.filter { pull in
            matchesRepo(pull.repoID) && (needle.isEmpty
                || pull.title.lowercased().contains(needle)
                || "\(pull.number)" == needle.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                || (pull.author ?? "").lowercased().contains(needle)
                || (pull.headBranch ?? "").lowercased().contains(needle))
        }
    }

    var visibleSkills: [SkillCatalog.Skill] {
        skills.value.filter { skill in
            needle.isEmpty || skill.name.lowercased().contains(needle)
                || skill.description.lowercased().contains(needle) || skill.source.lowercased().contains(needle)
        }
    }

    var commit: DevCommit? { commits.value.first { $0.id == selectedCommit } }
    public var run: DevPipelineRun? { runs.value.first { $0.id == selectedRun } }
    public var pull: DevPullRequest? { pulls.value.first { $0.id == selectedPull } }
    var skill: SkillCatalog.Skill? { skills.value.first { $0.id == selectedSkill } }

    /// The address of what is selected in the open segment.
    public var selectedURL: String? {
        switch segment {
        case .repos, .skills: return nil
        case .commits: return commit?.url
        case .pipelines: return run?.url
        case .pullRequests: return pull?.url
        }
    }

    // MARK: Pipelines

    public func rerun(_ run: DevPipelineRun, failedOnly: Bool) {
        perform(on: run) { provider, repo in try provider.rerun(run, in: repo, failedOnly: failedOnly) }
    }

    /// Asks first: cancelling stops work that is running.
    public func requestCancel(_ run: DevPipelineRun) { pendingCancel = run }

    func confirmCancel() {
        guard let run = pendingCancel else { return }
        pendingCancel = nil
        perform(on: run) { provider, repo in try provider.cancel(run, in: repo) }
    }

    private func perform(on run: DevPipelineRun,
                         _ work: @escaping @Sendable (any DevelopmentProvider, DevRepo) throws -> Void) {
        let repo: DevRepo
        do {
            repo = try resolve(run.repoID)
        } catch {
            actionError = error.localizedDescription
            return
        }
        let provider = self.provider
        busyRuns.insert(run.id)
        Task {
            defer { busyRuns.remove(run.id) }
            do {
                try await Self.offMainThrowing { try work(provider, repo) }
                // The host takes a moment to queue the new attempt.
                try? await Task.sleep(for: .seconds(2))
                loadRuns(force: true)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Read a run's log, then copy it with its header line, or hand it to
    /// the app's agent with the whole text in a private temporary file.
    func copyLog(of run: DevPipelineRun) {
        Task {
            do { DevWeb.copy(RunReport.copy(run, log: try await log(of: run))) } catch { actionError = error.localizedDescription }
        }
    }

    func sendToAgent(_ run: DevPipelineRun, log known: String? = nil) {
        guard let send = slots.sendRunToAgent else { return }
        Task {
            do {
                let text: String
                if let known { text = known } else { text = try await log(of: run) }
                let file = RunReport.writeFullLog(RunReport.copy(run, log: text), runID: run.runID)
                send(run, RunReport.prompt(run, log: text, fullLog: file))
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func log(of run: DevPipelineRun) async throws -> String {
        let repo = try resolve(run.repoID)
        let provider = self.provider
        return try await Self.offMainThrowing { try provider.log(of: run, in: repo) }
    }

    /// What the run view reads from, or nil when the host cannot show a run's
    /// stages, jobs and steps.
    func runDetailProvider(for run: DevPipelineRun) -> (any RunDetailProvider)? {
        guard let repo = try? resolve(run.repoID) else { return nil }
        return provider.runDetail(for: run, in: repo)
    }

    public func isBusy(_ run: DevPipelineRun) -> Bool { busyRuns.contains(run.id) }

    // MARK: Pull requests

    func detail(of pull: DevPullRequest) async throws -> DevPullDetail {
        let repo = try resolve(pull.repoID)
        let provider = self.provider
        var detail = try await Self.offMainThrowing { try provider.detail(of: pull, in: repo) }
        let filtered = WithheldDiff.filter(detail.diff, withheld: repos.slots.withheld)
        detail.diff = filtered.text
        detail.diffIsWithheld = filtered.isWithheldEntirely
        detail.withheldFiles = filtered.removedFiles
        return detail
    }

    func perform(_ action: DevPullAction, on pull: DevPullRequest) async throws {
        let repo = try resolve(pull.repoID)
        let provider = self.provider
        try await Self.offMainThrowing { try provider.perform(action, on: pull, in: repo) }
        loadPulls(force: true)
    }

    /// Checks the pull request out in its own worktree and opens a shell lane
    /// there, for any author; no agent starts. It first reads who opened it
    /// and what it changes, and anything worth knowing waits for confirmation.
    public func checkOutInLane(_ pull: DevPullRequest) {
        let repo: DevRepo
        do {
            repo = try resolve(pull.repoID)
        } catch {
            actionError = error.localizedDescription
            return
        }
        guard FileManager.default.fileExists(atPath: repo.localPath) else {
            actionError = "\(repo.name) is not cloned on this Mac."
            return
        }
        let provider = self.provider
        checkingOut.insert(pull.id)
        Task {
            do {
                let risk = try await Self.offMainThrowing { try provider.risk(of: pull, in: repo) }
                checkingOut.remove(pull.id)
                let request = LaneSafety.pullRequestRequest(risk, title: pull.title)
                if risk.needsReview {
                    pendingCheckout = PendingCheckout(pull: pull, risk: risk, request: request)
                } else {
                    checkOut(pull, request: request, repo: repo)
                }
            } catch {
                checkingOut.remove(pull.id)
                actionError = "Could not check who opened #\(pull.number) or what it changes, so it was not checked out: \(error.localizedDescription)"
            }
        }
    }

    /// The person has seen the findings: check it out and open its shell lane.
    func confirmPendingCheckout() {
        guard let pending = pendingCheckout else { return }
        pendingCheckout = nil
        do {
            checkOut(pending.pull, request: pending.request, repo: try resolve(pending.pull.repoID))
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func checkOut(_ pull: DevPullRequest, request: SafeLaneRequest, repo: DevRepo) {
        let provider = self.provider
        checkingOut.insert(pull.id)
        Task {
            defer { checkingOut.remove(pull.id) }
            do {
                let worktree = try await Self.offMainThrowing { try provider.checkOut(request, in: repo) }
                onOpenCheckout?(repo, request, worktree)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    public func isCheckingOut(_ pull: DevPullRequest) -> Bool { checkingOut.contains(pull.id) }
}
