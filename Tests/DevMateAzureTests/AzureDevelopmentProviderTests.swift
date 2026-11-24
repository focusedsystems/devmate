import DevMateCore
import Foundation
import Testing
@testable import DevMateAzure

@Suite struct AzureCLITests {
    let cli = AzureCLI(organization: "https://devops.example.com/example", defaultProject: "Widgets", executable: nil)

    @Test func organizationBecomesAnAddress() {
        #expect(AzureCLI(organization: "example", executable: nil).organization == "https://" + AzureCLI.defaultHost + "/example")
        #expect(AzureCLI(organization: "https://devops.example.com/example/", executable: nil).organization == "https://devops.example.com/example")
    }

    @Test func urlEncodesProjectAndKeepsDollarQueries() {
        let url = cli.url(project: "Example Project", path: "git/repositories/widget/commits",
                          query: [("searchCriteria.$top", "30")])
        #expect(url == "https://devops.example.com/example/Example%20Project/_apis/git/repositories/widget/commits?searchCriteria.$top=30&api-version=7.1")
    }

    @Test func teamSitsAfterProject() {
        let url = cli.url(project: "Widgets", team: "Widgets Team", path: "work/boards")
        #expect(url == "https://devops.example.com/example/Widgets/Widgets%20Team/_apis/work/boards?api-version=7.1")
    }

    @Test func argumentsUseAzRestWithTheDevOpsResource() {
        let arguments = AzureCLI.arguments(method: "PATCH", url: "https://devops.example.com/example/_apis/x", body: "{}",
                                           contentType: "application/json")
        #expect(arguments.prefix(2) == ["rest", "--method"])
        #expect(arguments.contains("patch"))
        #expect(arguments.contains(AzureCLI.resource))
        #expect(arguments.suffix(2) == ["--headers", "Content-Type=application/json"])
        #expect(arguments.contains("--body"))
    }

    @Test func addressComesFromTheRemoteOrTheDefaultProject() throws {
        func repo(_ remote: String?) -> DevRepo {
            DevRepo(id: "r", name: "widget", path: "/tmp/widget", remote: remote, provider: .azureDevOps, kind: .repo)
        }
        let (project, name) = try cli.address(of: repo("Gadgets/widget"))
        #expect(project == "Gadgets" && name == "widget")
        #expect(try cli.address(of: repo(nil)).project == "Widgets")
        #expect(throws: AzureCLIError.self) {
            try AzureCLI(organization: "https://devops.example.com/example", executable: nil).address(of: repo(nil))
        }
    }

    @Test func sevenDigitFractionsParse() {
        #expect(AzureJSON.parseDate("2026-01-02T03:04:05.1234567+00:00") != nil)
        #expect(AzureJSON.parseDate("2026-01-02T03:04:05Z") != nil)
        #expect(AzureJSON.parseDate("2026-01-02T03:04:05.12+00:00") != nil)
    }

    @Test func missingExecutableIsNamed() {
        #expect(throws: AzureCLIError.self) { try cli.request(project: nil, path: "connectionData") }
    }
}

@Suite struct AzureDevelopmentMappingTests {
    @Test func pullRequestsDecodeAndMap() throws {
        let json = """
        {"value":[{"pullRequestId":7,"title":"Add widget","createdBy":{"displayName":"Example User","uniqueName":"user@example.com"},
        "sourceRefName":"refs/heads/feature","targetRefName":"refs/heads/main","isDraft":true,
        "reviewers":[{"vote":10},{"vote":0}],"creationDate":"2026-01-02T03:04:05.1234567+00:00",
        "lastMergeSourceCommit":{"commitId":"aaaa"},"repository":{"id":"1","name":"widget"}}]}
        """
        let rows = try AzureJSON.decode(AzList<AzPull>.self, from: json).value
        let repo = DevRepo(id: "r", name: "widget", path: "/tmp/widget", remote: "Widgets/widget", provider: .azureDevOps, kind: .repo)
        let cli = AzureCLI(organization: "https://devops.example.com/example", executable: nil)
        let pull = AzureMapping.pull(rows[0], repo: repo, project: "Widgets", name: "widget", cli: cli)
        #expect(pull.number == 7 && pull.isDraft)
        #expect(pull.headBranch == "feature" && pull.baseBranch == "main")
        #expect(pull.review == .approved)
        #expect(pull.author == "Example User")
        #expect(pull.url == "https://devops.example.com/example/Widgets/_git/widget/pullrequest/7")
    }

    @Test func reviewVotes() {
        func review(_ votes: [Int]) -> DevReviewState {
            AzureMapping.review(votes.map { AzPull.Reviewer(vote: $0) })
        }
        #expect(review([]) == .none)
        #expect(review([0]) == .required)
        #expect(review([10, 5]) == .approved)
        #expect(review([10, -5]) == .changesRequested)
        #expect(review([-10]) == .changesRequested)
    }

    @Test func buildStates() {
        #expect(AzureMapping.state(status: "notStarted", result: nil) == .queued)
        #expect(AzureMapping.state(status: "inProgress", result: nil) == .running)
        #expect(AzureMapping.state(status: "completed", result: "succeeded") == .succeeded)
        #expect(AzureMapping.state(status: "completed", result: "failed") == .failed)
        #expect(AzureMapping.state(status: "completed", result: "canceled") == .cancelled)
        #expect(AzureMapping.state(status: "completed", result: "partiallySucceeded") == .needsAction)
    }

    @Test func buildsMapToRuns() throws {
        let json = """
        {"id":42,"buildNumber":"20260102.1","status":"completed","result":"failed","definition":{"id":3,"name":"ci"},
        "sourceBranch":"refs/heads/main","reason":"individualCI","startTime":"2026-01-02T03:04:05Z",
        "finishTime":"2026-01-02T03:09:05Z","triggerInfo":{"ci.message":"Fix the widget\\nlong body"},
        "_links":{"web":{"href":"https://devops.example.com/example/Widgets/_build/results?buildId=42"}}}
        """
        let build = try AzureJSON.decode(AzBuild.self, from: json)
        let repo = DevRepo(id: "r", name: "widget", path: "/tmp/widget", remote: "Widgets/widget", provider: .azureDevOps, kind: .repo)
        let run = AzureMapping.run(build, repo: repo, project: "Widgets", cli: AzureCLI(organization: "https://devops.example.com/example", executable: nil))
        #expect(run.state == .failed && run.isFinished)
        #expect(run.title == "Fix the widget")
        #expect(run.pipeline == "ci" && run.branch == "main")
        #expect(run.duration() == 300)
    }

    @Test func queueBodyNamesTheCommit() {
        let body = AzureDevelopmentProvider.queueBody(definition: 3, branch: "refs/heads/main", version: "abc")
        #expect(body == #"{"definition":{"id":3},"sourceBranch":"refs\/heads\/main","sourceVersion":"abc"}"#)
    }

    @Test func commentsSkipSystemAndDeleted() {
        let threads = [
            AzThread(id: 1, comments: [AzComment(id: 1, content: "Looks good", author: AzIdentity(id: nil, displayName: "Example User", uniqueName: nil),
                                                  publishedDate: nil, commentType: "text", isDeleted: nil),
                                       AzComment(id: 2, content: "voted", author: nil, publishedDate: nil, commentType: "system", isDeleted: nil)],
                     isDeleted: nil),
            AzThread(id: 2, comments: [AzComment(id: 1, content: "gone", author: nil, publishedDate: nil, commentType: "text", isDeleted: true)],
                     isDeleted: nil),
        ]
        let comments = AzureDevelopmentProvider.comments(threads)
        #expect(comments.map(\.body) == ["Looks good"])
        #expect(comments[0].author == "Example User")
    }

    @Test func actionsMapToVotesAndStatuses() throws {
        func calls(_ action: DevPullAction) throws -> [AzureDevelopmentProvider.Call] {
            try AzureDevelopmentProvider.call(for: action, number: 7, reviewer: "me")
        }
        let approve = try calls(.approve(headSHA: "h", baseRef: "main"))
        #expect(approve == [.init(method: "PUT", path: "pullrequests/7/reviewers/me", body: #"{"vote":10}"#)])
        let changes = try calls(.requestChanges("Please fix", headSHA: "h", baseRef: "main"))
        #expect(changes.count == 2 && changes[0].body == #"{"vote":-5}"#)
        #expect(try calls(.close).first?.body == #"{"status":"abandoned"}"#)
        #expect(try calls(.markReady).first?.body == #"{"isDraft":false}"#)
        let merge = try calls(.merge(.squash, headSHA: "h", baseRef: "main"))
        #expect(merge[0].body.contains(#""mergeStrategy":"squash""#))
        #expect(merge[0].body.contains(#""commitId":"h""#))
        #expect(!merge[0].body.lowercased().contains("bypass"))
    }

    @Test func votingNeedsToKnowWhoIsSignedIn() {
        #expect(throws: AzureCLIError.self) {
            try AzureDevelopmentProvider.call(for: .approve(headSHA: "h", baseRef: "main"), number: 1, reviewer: nil)
        }
    }

    @Test func verifyRefusesAMovedHeadOrSwappedBase() throws {
        let pull = try AzureJSON.decode(AzPull.self, from: #"{"pullRequestId":1,"title":"t","targetRefName":"refs/heads/main","lastMergeSourceCommit":{"commitId":"h"}}"#)
        try AzureDevelopmentProvider.verify(pull, head: "h", baseRef: "main", number: 1)
        #expect(throws: AzureCLIError.self) { try AzureDevelopmentProvider.verify(pull, head: "other", baseRef: "main", number: 1) }
        #expect(throws: AzureCLIError.self) { try AzureDevelopmentProvider.verify(pull, head: "h", baseRef: "release", number: 1) }
    }

    @Test func changedFilesDropTheLeadingSlashAndMarkDeletes() {
        let entries = [
            AzIterationChanges.Entry(changeType: "edit", item: .init(path: "/src/a.swift"), originalPath: nil),
            AzIterationChanges.Entry(changeType: "delete", item: .init(path: "/.claude/settings.json"), originalPath: nil),
            AzIterationChanges.Entry(changeType: "rename", item: .init(path: "/b.txt"), originalPath: "/a.txt"),
        ]
        let files = AzureDevelopmentProvider.files(entries)
        #expect(files.map(\.filename) == ["src/a.swift", ".claude/settings.json", "b.txt"])
        #expect(files[1].status == "removed")
        #expect(files[2].previousFilename == "a.txt")
    }

    @Test func treeParsesModes() {
        let output = "100644 blob aaaa\tsrc/a.swift\0120000 blob bbbb\tlink\0"
        let tree = AzureDevelopmentProvider.parseTree(output)
        #expect(tree.tree.map(\.path) == ["src/a.swift", "link"])
        #expect(tree.tree[1].mode == "120000")
        #expect(!tree.truncated)
    }

    @Test func shaCheck() {
        #expect(AzureDevelopmentProvider.isSHA(String(repeating: "a", count: 40)))
        #expect(!AzureDevelopmentProvider.isSHA("main"))
        #expect(!AzureDevelopmentProvider.isSHA(String(repeating: "A", count: 40)))
    }

    @Test func providerDeclaresWhatItCan() {
        let provider = AzureDevelopmentProvider(organization: "example")
        #expect(provider.kind == .azureDevOps)
        #expect(provider.capabilities == [.pullRequests, .commits, .pipelines])
        #expect(!provider.allowsImage(URL(string: "https://example.com/a.png")))
    }

    @Test func rerunOfOnlyFailedJobsIsRefused() {
        let provider = AzureDevelopmentProvider(cli: AzureCLI(organization: "https://devops.example.com/example", executable: nil))
        let repo = DevRepo(id: "r", name: "widget", path: "/tmp/widget", remote: "Widgets/widget", provider: .azureDevOps, kind: .repo)
        let run = DevPipelineRun(repoID: "r", repo: "widget", runID: 1, title: "t", pipeline: "ci", branch: nil, event: nil,
                                 state: .failed, isFinished: true, detail: "", startedAt: nil, updatedAt: nil, url: "")
        #expect(throws: AzureCLIError.self) { try provider.rerun(run, in: repo, failedOnly: true) }
    }
}
