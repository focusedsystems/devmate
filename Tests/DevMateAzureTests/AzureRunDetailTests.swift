import DevMateCore
import XCTest
@testable import DevMateAzure

final class AzureRunDetailTests: XCTestCase {
    private let json = """
    {"records":[
      {"id":"st1","type":"Stage","name":"Build","state":"completed","result":"succeeded","order":1,
       "startTime":"2026-01-01T10:00:00.0000000Z","finishTime":"2026-01-01T10:01:00.0000000Z"},
      {"id":"ph1","parentId":"st1","type":"Phase","name":"Compile","state":"completed","result":"succeeded","order":1},
      {"id":"jb1","parentId":"ph1","type":"Job","name":"Compile","state":"completed","result":"succeeded","order":1,
       "startTime":"2026-01-01T10:00:00.0000000Z","finishTime":"2026-01-01T10:00:40.0000000Z","log":{"id":3}},
      {"id":"t1","parentId":"jb1","type":"Task","name":"Initialize job","state":"completed","result":"succeeded","order":1,
       "startTime":"2026-01-01T10:00:00.0000000Z","finishTime":"2026-01-01T10:00:04.0000000Z","log":{"id":4}},
      {"id":"t2","parentId":"jb1","type":"Task","name":"Run it","state":"completed","result":"failed","order":2,
       "log":{"id":5},"task":{"name":"CmdLine","version":"2.250.0"},"issues":[{"type":"error","message":"exit 1"}]},
      {"id":"t3","parentId":"jb1","type":"Task","name":"Publish","state":"pending","order":3},
      {"id":"st2","type":"Stage","name":"Ship","state":"inProgress","order":2},
      {"id":"cp","parentId":"st2","type":"Checkpoint","name":"Checkpoint","state":"inProgress","order":1},
      {"id":"ap","parentId":"cp","type":"Checkpoint.Approval","name":"Approval","state":"inProgress","order":1,
       "identifier":"APPROVAL-ONE"}
    ]}
    """

    func testMapsStagesJobsAndSteps() throws {
        let timeline = try AzureRunDetail.timeline(from: Data(json.utf8))
        XCTAssertEqual(timeline.stages.map(\.name), ["Build", "Ship"])
        let build = timeline.stages[0]
        XCTAssertEqual(build.jobs.map(\.name), ["Compile"])
        XCTAssertEqual(build.jobs[0].logID, "3")
        XCTAssertEqual(build.jobs[0].steps.map(\.name), ["Initialize job", "Run it", "Publish"])
        XCTAssertEqual(build.jobs[0].steps.map(\.state), [.succeeded, .failed, .pending])
        XCTAssertEqual(build.jobs[0].steps[1].task, "CmdLine@2")
        XCTAssertEqual(build.jobs[0].steps[1].issues, ["exit 1"])
        XCTAssertEqual(build.jobs[0].steps[0].duration(), 4)
        let ship = timeline.stages[1]
        XCTAssertEqual(ship.jobs.first?.steps.first?.identifier, "APPROVAL-ONE")
        XCTAssertTrue(timeline.isActive)
    }

    func testSelectsFailedStepFirst() throws {
        let timeline = try AzureRunDetail.timeline(from: Data(json.utf8))
        XCTAssertEqual(timeline.activeSelection, .step(job: "jb1", step: "t2"))
    }

    func testApprovalsAreMatchedThroughTheTimeline() throws {
        let records = try AzureJSON.decoder.decode(AzureRunDetail.Timeline.self, from: Data(json.utf8)).records ?? []
        let pending = try AzureJSON.decoder.decode(AzureRunDetail.Approvals.self, from: Data("""
        {"value":[
          {"id":"approval-one","instructions":"Check it","createdOn":"2026-01-01T10:00:00Z",
           "steps":[{"assignedApprover":{"displayName":"Sample Team"}}],"minRequiredApprovers":1},
          {"id":"other","pipeline":{"owner":{"id":999}}}
        ]}
        """.utf8)).value ?? []
        let found = AzureRunDetail.approvals(pending, in: records, buildID: 42)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].kind, .manualValidation)
        XCTAssertEqual(found[0].stageName, "Ship")
        XCTAssertEqual(found[0].approvers, ["Sample Team"])
    }

    func testApprovalHoldsItsStepInTheOutline() throws {
        let timeline = try AzureRunDetail.timeline(from: Data(json.utf8)).marking(waiting: ["approval-one"])
        XCTAssertEqual(timeline.stages[1].jobs[0].steps[0].state, .waiting)
        XCTAssertEqual(timeline.activeSelection, .step(job: "cp", step: "ap"))
    }

    func testAnOversizedLogStreamKeepsOnlyItsTail() async throws {
        let line = "2026-01-01T10:00:00.0000000Z a long line of output that repeats\n"
        let stream = AsyncStream<UInt8> { continuation in
            for number in 0..<20_000 {
                for byte in "\(line)final \(number)\n".utf8 { continuation.yield(byte) }
            }
            continuation.finish()
        }
        let text = try await AzureRunDetail.tail(of: stream, limit: 1_000)
        XCTAssertLessThanOrEqual(text.utf8.count, 1_000)
        XCTAssertTrue(text.hasSuffix("final 19999\n"))
    }
}
