import DevMateCore
import Foundation

extension GitHubCLI: CommitProviding, PipelineProviding, PullRequestProviding, WorkItemProviding, BoardProviding {
    public var kind: RepoProviderKind { .github }

    public var capabilities: ProviderCapabilities {
        [.pullRequests, .commits, .pipelines, .workItems, .boards, .labels, .milestones]
    }

    public func workItems(repo: String, state: String, limit: Int) throws -> [GitHubIssue] {
        try issues(repo: repo, state: state, limit: limit)
    }

    public func workItem(repo: String, number: Int) throws -> GitHubIssue {
        try issue(repo: repo, number: number)
    }
}

extension LaneSafety {
    /// The safe first prompt for a GitHub issue.
    public static func issueRequest(for issue: GitHubIssue, policy: LanePromptPolicy) -> SafeLaneRequest {
        issueRequest(for: UntrustedIssue(provider: .gitHub, repo: issue.repo, number: issue.number, url: issue.url,
                                         title: issue.title, labels: issue.labels.map(\.name),
                                         plan: issue.milestone?.title, body: issue.body),
                     policy: policy)
    }
}

/// Which images Markdown from GitHub may load: only GitHub's own upload
/// hosts, so an issue cannot plant a tracking pixel.
public enum MarkdownImagePolicy {
    public static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        switch host {
        case "user-images.githubusercontent.com", "private-user-images.githubusercontent.com":
            return true
        case "github.com":
            return url.path.hasPrefix("/user-attachments/")
        default:
            return false
        }
    }
}
