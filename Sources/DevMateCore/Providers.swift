import Foundation

/// What a provider can do. The UI shows only what its provider declares.
public struct ProviderCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let pullRequests = ProviderCapabilities(rawValue: 1 << 0)
    public static let commits = ProviderCapabilities(rawValue: 1 << 1)
    public static let pipelines = ProviderCapabilities(rawValue: 1 << 2)
    public static let workItems = ProviderCapabilities(rawValue: 1 << 3)
    public static let boards = ProviderCapabilities(rawValue: 1 << 4)
    public static let queries = ProviderCapabilities(rawValue: 1 << 5)
    public static let forks = ProviderCapabilities(rawValue: 1 << 6)
    public static let labels = ProviderCapabilities(rawValue: 1 << 7)
    public static let milestones = ProviderCapabilities(rawValue: 1 << 8)
    public static let iterations = ProviderCapabilities(rawValue: 1 << 9)
}

public protocol DevProvider: Sendable {
    var kind: RepoProviderKind { get }
    var capabilities: ProviderCapabilities { get }
}

public protocol CommitProviding: DevProvider {
    associatedtype Commit: Sendable
    func commits(repo: String, limit: Int) throws -> [Commit]
}

public protocol PipelineProviding: DevProvider {
    associatedtype PipelineRun: Sendable
    func runs(repo: String, limit: Int) throws -> [PipelineRun]
    func rerun(repo: String, runID: Int, failedOnly: Bool) throws
    func cancel(repo: String, runID: Int) throws
}

public protocol PullRequestProviding: DevProvider {
    associatedtype PullRequest: Sendable
    func pullRequests(repo: String) throws -> [PullRequest]
    /// Judges the pull request as it stands now.
    func risk(repo: String, number: Int) throws -> PullRequestRisk
    /// Checks out exactly the commit the request was judged at.
    func checkOut(_ request: SafeLaneRequest, in folder: URL) throws -> URL
}

public protocol WorkItemProviding: DevProvider {
    associatedtype WorkItem: Sendable
    func workItems(repo: String, state: String, limit: Int) throws -> [WorkItem]
    func workItem(repo: String, number: Int) throws -> WorkItem
}

public protocol BoardProviding: DevProvider {
    associatedtype Project: Sendable
    associatedtype Board: Sendable
    func projects() throws -> [Project]
    func board(for project: Project) throws -> Board
}

public protocol QueryProviding: DevProvider {
    associatedtype SavedQuery: Sendable
    associatedtype QueryResult: Sendable
    func savedQueries() throws -> [SavedQuery]
    func run(_ query: SavedQuery) throws -> [QueryResult]
}

/// How far a fork has moved from its upstream.
public struct ForkStatus: Hashable, Sendable {
    public var upstream: String
    public var ahead: Int
    public var behind: Int

    public init(upstream: String, ahead: Int, behind: Int) {
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}

public protocol ForkProviding: DevProvider {
    func forkStatus(repo: String) throws -> ForkStatus
}
