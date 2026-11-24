import DevMateCore
import Foundation

struct AzCommit: Decodable {
    struct Author: Decodable {
        var name: String?
        var date: Date?
    }

    var commitId: String
    var comment: String?
    var author: Author?
}

struct AzPull: Decodable {
    struct Commit: Decodable { var commitId: String }
    struct Reviewer: Decodable { var vote: Int? }
    struct Repository: Decodable { var id: String?; var name: String? }

    var pullRequestId: Int
    var title: String
    var description: String?
    var status: String?
    var createdBy: AzIdentity?
    var sourceRefName: String?
    var targetRefName: String?
    var isDraft: Bool?
    var reviewers: [Reviewer]?
    var creationDate: Date?
    var lastMergeSourceCommit: Commit?
    var lastMergeTargetCommit: Commit?
    var repository: Repository?
    var forkSource: AzForkSource?
}

struct AzForkSource: Decodable {
    var name: String?
}

struct AzComment: Decodable {
    var id: Int
    var content: String?
    var author: AzIdentity?
    var publishedDate: Date?
    var commentType: String?
    var isDeleted: Bool?
}

struct AzThread: Decodable {
    var id: Int
    var comments: [AzComment]?
    var isDeleted: Bool?
}

struct AzBuild: Decodable {
    struct Definition: Decodable { var id: Int?; var name: String? }
    struct Links: Decodable {
        struct Link: Decodable { var href: String? }
        var web: Link?
    }

    var id: Int
    var buildNumber: String?
    var status: String?
    var result: String?
    var definition: Definition?
    var sourceBranch: String?
    var sourceVersion: String?
    var reason: String?
    var queueTime: Date?
    var startTime: Date?
    var finishTime: Date?
    var triggerInfo: [String: String]?
    var _links: Links?
}

struct AzRepository: Decodable {
    var id: String
    var name: String
    var defaultBranch: String?
}

struct AzIterationChanges: Decodable {
    struct Entry: Decodable {
        struct Item: Decodable { var path: String? }
        var changeType: String?
        var item: Item?
        var originalPath: String?
    }

    var changeEntries: [Entry]
    var nextSkip: Int?
}

struct AzIterations: Decodable {
    struct Iteration: Decodable { var id: Int }
    var value: [Iteration]
}

struct AzTimeline: Decodable {
    struct Record: Decodable {
        struct Log: Decodable { var id: Int }
        var type: String?
        var result: String?
        var log: Log?
        var order: Int?
    }

    var records: [Record]
}

struct AzConnection: Decodable {
    struct User: Decodable {
        struct Account: Decodable { var value: String? }
        struct Properties: Decodable {
            var Account: Account?
            enum CodingKeys: String, CodingKey { case Account }
        }

        var id: String?
        var properties: Properties?
    }

    var authenticatedUser: User?
}

/// How Azure DevOps words things, in DevMate's terms.
enum AzureMapping {
    static func review(_ reviewers: [AzPull.Reviewer]?) -> DevReviewState {
        let votes = (reviewers ?? []).map { $0.vote ?? 0 }
        guard !votes.isEmpty else { return .none }
        if votes.contains(where: { $0 < 0 }) { return .changesRequested }
        if votes.contains(where: { $0 > 0 }) { return .approved }
        return .required
    }

    static func state(status: String?, result: String?) -> DevPipelineRun.State {
        switch (status ?? "").lowercased() {
        case "notstarted", "postponed": return .queued
        case "inprogress", "cancelling": return .running
        case "completed":
            switch (result ?? "").lowercased() {
            case "succeeded": return .succeeded
            case "failed": return .failed
            case "canceled": return .cancelled
            case "partiallysucceeded": return .needsAction
            default: return .skipped
            }
        default: return .skipped
        }
    }

    static func run(_ build: AzBuild, repo: DevRepo, project: String, cli: AzureCLI) -> DevPipelineRun {
        let message = build.triggerInfo?["ci.message"].flatMap { $0.split(separator: "\n").first }.map { LanePrompt.oneLine(String($0)) }
        let title = (message?.isEmpty == false ? message : nil) ?? build.buildNumber ?? "Run \(build.id)"
        let detail = [build.status, build.result].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return DevPipelineRun(repoID: repo.id, repo: repo.name, runID: build.id, title: title,
                              pipeline: build.definition?.name ?? "", branch: AzureJSON.branch(build.sourceBranch),
                              event: build.reason,
                              state: state(status: build.status, result: build.result),
                              isFinished: (build.status ?? "").lowercased() == "completed", detail: detail,
                              startedAt: build.startTime ?? build.queueTime, updatedAt: build.finishTime,
                              url: build._links?.web?.href
                                  ?? "\(cli.organization)/\(AzureCLI.encode(project))/_build/results?buildId=\(build.id)")
    }

    static func pull(_ pull: AzPull, repo: DevRepo, project: String, name: String, cli: AzureCLI) -> DevPullRequest {
        DevPullRequest(repoID: repo.id, repo: repo.name, number: pull.pullRequestId, title: pull.title,
                       author: pull.createdBy?.displayName ?? pull.createdBy?.uniqueName,
                       headBranch: AzureJSON.branch(pull.sourceRefName), baseBranch: AzureJSON.branch(pull.targetRefName),
                       isDraft: pull.isDraft == true, checks: DevChecks(), review: review(pull.reviewers),
                       updatedAt: pull.creationDate,
                       url: cli.webURL(project: project, repo: name, suffix: "pullrequest/\(pull.pullRequestId)"))
    }

    /// Azure DevOps' vote values.
    enum Vote {
        static let approved = 10
        static let waitingForAuthor = -5
    }
}
