import DevMateCore
import XCTest
@testable import DevMateGitHub

final class GitHubRunDetailTests: XCTestCase {
    private let json = """
    {"jobs":[{"id":77,"name":"build","status":"completed","conclusion":"failure",
      "started_at":"2026-01-01T10:00:00Z","completed_at":"2026-01-01T10:00:30Z",
      "steps":[
        {"number":1,"name":"Set up job","status":"completed","conclusion":"success","started_at":"2026-01-01T10:00:00Z","completed_at":"2026-01-01T10:00:02Z"},
        {"number":2,"name":"Run tests","status":"completed","conclusion":"failure","started_at":"2026-01-01T10:00:02Z","completed_at":"2026-01-01T10:00:20Z"},
        {"number":3,"name":"Upload","status":"completed","conclusion":"skipped","started_at":"2026-01-01T10:00:20Z","completed_at":"2026-01-01T10:00:20Z"}
      ]}]}
    """

    func testMapsJobsAndSteps() throws {
        let timeline = try GitHubRunDetail.timeline(from: Data(json.utf8))
        XCTAssertEqual(timeline.stages.count, 1)
        XCTAssertEqual(timeline.stages[0].name, "")
        let job = timeline.stages[0].jobs[0]
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.steps.map(\.state), [.succeeded, .failed, .skipped])
        XCTAssertEqual(timeline.activeSelection, .step(job: "77", step: "77-2"))
    }

    func testSlicesAJobLogByStepTime() throws {
        let job = try GitHubRunDetail.timeline(from: Data(json.utf8)).stages[0].jobs[0]
        let text = """
        2026-01-01T10:00:00.5000000Z setting up
        2026-01-01T10:00:01.9000000Z still setting up
        2026-01-01T10:00:02.1000000Z ##[group]Run tests
        2026-01-01T10:00:03.0000000Z running
        continued line without a stamp
        2026-01-01T10:00:20.1000000Z uploading
        """
        XCTAssertEqual(GitHubRunDetail.slice(text, step: job.steps[0], of: job).split(separator: "\n").count, 2)
        let tests = GitHubRunDetail.slice(text, step: job.steps[1], of: job)
        XCTAssertTrue(tests.contains("running"))
        XCTAssertTrue(tests.contains("continued line without a stamp"))
        XCTAssertFalse(tests.contains("uploading"))
        XCTAssertFalse(tests.contains("setting up"))
    }

    func testAnOversizedJobLogIsCappedBeforeItIsParsed() async throws {
        let huge = (0..<50_000).map { "2026-01-01T10:00:\(String(format: "%02d", $0 % 60)).0000000Z output line \($0)" }
            .joined(separator: "\n")
        let detail = GitHubRunDetail(repository: "example/app", runID: 1, logLimit: 2_000) { _ in huge }
        let job = RunJob(id: "77", name: "build", state: .succeeded, logID: "77")
        let text = try await detail.log(job: job, step: nil)
        XCTAssertLessThanOrEqual(text.utf8.count, 2_000)
        XCTAssertTrue(text.hasSuffix("output line 49999"))
    }
}
