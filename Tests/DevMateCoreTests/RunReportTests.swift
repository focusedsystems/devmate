import XCTest
@testable import DevMateCore

final class RunReportTests: XCTestCase {
    private func run() -> DevPipelineRun {
        DevPipelineRun(repoID: "example/app", repo: "app", runID: 9, title: "Build", pipeline: "CI", branch: "main",
                       event: nil, state: .failed, isFinished: true, detail: "", startedAt: nil, updatedAt: nil,
                       url: "https://example.invalid/runs/9")
    }

    func testHeaderAndPrompt() {
        XCTAssertEqual(RunReport.header(run()), "Pipeline: CI | Run: Build (#9) | Repository: app | Branch: main | Result: Failed")
        let prompt = RunReport.prompt(run(), log: "a\n##[error]x\nb", fullLog: "/tmp/f.log")
        XCTAssertTrue(prompt.contains("https://example.invalid/runs/9"))
        XCTAssertTrue(prompt.hasSuffix("The full log is in /tmp/f.log."))
    }

    func testExcerptAroundError() {
        let lines = (0..<500).map { $0 == 300 ? "##[error]bad" : "l\($0)" }
        let cut = RunReport.excerpt(lines.joined(separator: "\n"), limit: 100)
        XCTAssertTrue(cut.trimmed)
        XCTAssertTrue(cut.text.contains("##[error]bad"))
        XCTAssertEqual(cut.text.components(separatedBy: "\n").last, "l320")
    }
}
