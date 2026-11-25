import DevMateCore
import XCTest

final class RunTimelineTests: XCTestCase {
    private func timeline() -> RunTimeline {
        let ok = RunStep(id: "a", name: "Initialize job", state: .succeeded)
        let bad = RunStep(id: "b", name: "Test", state: .failed)
        let later = RunStep(id: "c", name: "Publish", state: .pending)
        let running = RunStep(id: "d", name: "Wait", state: .running, identifier: "ABC")
        return RunTimeline(stages: [
            RunStage(id: "s1", name: "Build", state: .failed, jobs: [RunJob(id: "j1", name: "Build", state: .failed, steps: [ok, bad, later])]),
            RunStage(id: "s2", name: "Ship", state: .running, jobs: [RunJob(id: "j2", name: "Ship", state: .running, steps: [running])]),
        ])
    }

    func testSelectsWaitingThenFailedThenRunning() {
        var t = timeline()
        XCTAssertEqual(t.activeSelection, .step(job: "j1", step: "b"))
        t = t.marking(waiting: ["abc"])
        XCTAssertEqual(t.activeSelection, .step(job: "j2", step: "d"))
        XCTAssertEqual(t.stages[1].jobs[0].state, .waiting)
        XCTAssertEqual(t.stages[1].state, .waiting)
    }

    func testSelectsLastStepThatRanWhenNothingFailed() {
        let t = RunTimeline(stages: [RunStage(id: "s", name: "", state: .succeeded, jobs: [
            RunJob(id: "j", name: "Job", state: .succeeded, steps: [
                RunStep(id: "1", name: "One", state: .succeeded), RunStep(id: "2", name: "Two", state: .succeeded),
                RunStep(id: "3", name: "Three", state: .skipped),
            ]),
        ])])
        XCTAssertEqual(t.activeSelection, .step(job: "j", step: "2"))
        XCTAssertFalse(t.isActive)
    }

    func testApprovalWording() {
        let approval = RunApproval(id: "x", kind: .manualValidation, stageName: "Ship", stepName: "Wait")
        XCTAssertEqual(approval.approveVerb, "Resume")
        XCTAssertEqual(approval.confirmationTitle(approve: false, runName: "Pipeline 1"),
                       "Reject \u{201C}Wait\u{201D} in stage Ship of Pipeline 1?")
    }
}
