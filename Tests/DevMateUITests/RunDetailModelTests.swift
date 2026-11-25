import DevMateCore
import XCTest
@testable import DevMateUI

private struct StubRun: RunDetailProvider {
    var steps: [RunStep]
    var approvalList: [RunApproval] = []
    func timeline() async throws -> RunTimeline {
        RunTimeline(stages: [RunStage(id: "s", name: "Stage", state: .running,
                                      jobs: [RunJob(id: "j", name: "Job", state: .running, logID: "job", steps: steps)])])
    }
    func log(job: RunJob, step: RunStep?) async throws -> String { "log of \(step?.name ?? job.name)" }
    func approvals() async throws -> [RunApproval] { approvalList }
}

@MainActor
final class RunDetailModelTests: XCTestCase {
    private func steps() -> [RunStep] {
        [RunStep(id: "1", name: "One", state: .succeeded, logID: "1"),
         RunStep(id: "2", name: "Two", state: .failed, logID: "2"),
         RunStep(id: "3", name: "Three", state: .pending)]
    }

    private func settle(_ model: RunDetailModel) async {
        await model.reload()
        for _ in 0..<50 where model.log.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testFirstReadOpensTheFailedStepAndItsJob() async {
        let model = RunDetailModel(provider: StubRun(steps: steps()), runName: "Run 1")
        await settle(model)
        XCTAssertEqual(model.selection, .step(job: "j", step: "2"))
        XCTAssertTrue(model.expanded.contains("j"))
        XCTAssertEqual(model.log.text, "log of Two")
    }

    func testBackAndForwardWalkTheChoices() async {
        let model = RunDetailModel(provider: StubRun(steps: steps()), runName: "Run 1")
        await settle(model)
        model.choose(.step(job: "j", step: "1"))
        model.choose(.job("j"))
        XCTAssertTrue(model.canGoBack)
        XCTAssertFalse(model.canGoForward)
        model.goBack()
        XCTAssertEqual(model.selection, .step(job: "j", step: "1"))
        model.goBack()
        XCTAssertEqual(model.selection, .step(job: "j", step: "2"))
        XCTAssertFalse(model.canGoBack)
        model.goForward()
        XCTAssertEqual(model.selection, .step(job: "j", step: "1"))
        model.choose(.step(job: "j", step: "3"))
        XCTAssertFalse(model.canGoForward)
    }

    func testCollapseMovesFromStepToJobThenClosesIt() async {
        let model = RunDetailModel(provider: StubRun(steps: steps()), runName: "Run 1")
        await settle(model)
        model.collapse()
        XCTAssertEqual(model.selection, .job("j"))
        XCTAssertFalse(model.expanded.contains("j"))
        model.expand()
        XCTAssertTrue(model.expanded.contains("j"))
    }

    func testWaitingApprovalMarksItsStepAndCardShows() async {
        var list = steps()
        list[2] = RunStep(id: "3", name: "Gate", state: .running, identifier: "AB-1")
        let approval = RunApproval(id: "ab-1", kind: .manualValidation, stepName: "Gate")
        let model = RunDetailModel(provider: StubRun(steps: list, approvalList: [approval]), runName: "Run 1")
        await settle(model)
        XCTAssertEqual(model.selection, .step(job: "j", step: "3"))
        XCTAssertEqual(model.state(of: model.selection), .waiting)
        XCTAssertEqual(model.approvalForSelection?.id, "ab-1")
    }

    func testApprovalWithoutAStepGetsOne() async {
        let approval = RunApproval(id: "env-1", kind: .environment, stageName: "Stage")
        let model = RunDetailModel(provider: StubRun(steps: steps(), approvalList: [approval]), runName: "Run 1")
        await settle(model)
        let held = model.timeline.stages[0].jobs.flatMap(\.steps).filter { $0.state == .waiting }
        XCTAssertEqual(held.map(\.name), ["Environment approval"])
        XCTAssertEqual(model.selection?.jobID, "approvals-s")
    }
}
