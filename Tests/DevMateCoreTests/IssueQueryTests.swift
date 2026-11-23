import XCTest
@testable import DevMateCore

final class IssueQueryTests: XCTestCase {
    let items = [
        WorkItem(container: "alpha", number: 1, title: "Login page", tags: [WorkTag(name: "bug")],
                 people: [WorkPerson(id: "ann")], plan: WorkPlan(id: "M1", title: "M1")),
        WorkItem(container: "beta", number: 2, title: "Dashboard", isOpen: false),
        WorkItem(container: "beta", number: 3, title: "Upload", tags: [WorkTag(name: "bug"), WorkTag(name: "ui")]),
    ]

    func testFilters() {
        XCTAssertEqual(IssueQuery().apply(items).map(\.number), [1, 3])
        XCTAssertEqual(IssueQuery(state: .all).apply(items).map(\.number), [1, 2, 3])
        XCTAssertEqual(IssueQuery(state: .closed).apply(items).map(\.number), [2])
        XCTAssertEqual(IssueQuery(container: "beta", state: .all).apply(items).map(\.number), [2, 3])
        XCTAssertEqual(IssueQuery(tag: "ui").apply(items).map(\.number), [3])
        XCTAssertEqual(IssueQuery(person: IssueQuery.unassigned).apply(items).map(\.number), [3])
        XCTAssertEqual(IssueQuery(plan: "M1").apply(items).map(\.number), [1])
        XCTAssertEqual(IssueQuery(plan: IssueQuery.noPlan).apply(items).map(\.number), [3])
        XCTAssertEqual(IssueQuery(search: "#3").apply(items).map(\.number), [3])
        XCTAssertEqual(IssueQuery(search: "login").apply(items).map(\.number), [1])
    }

    func testReadsAFilterSavedUnderTheOldKeys() throws {
        let json = #"{"repo":"beta","label":"ui","assignee":"ann","milestone":"M1","state":"All","search":""}"#
        let query = try JSONDecoder().decode(IssueQuery.self, from: Data(json.utf8))
        XCTAssertEqual(query, IssueQuery(container: "beta", tag: "ui", person: "ann", plan: "M1", state: .all))
        let again = try JSONDecoder().decode(IssueQuery.self, from: JSONEncoder().encode(query))
        XCTAssertEqual(again, query)
    }

    func testGrouping() {
        let byTag = IssueGrouping.tag.columns(for: items)
        XCTAssertEqual(byTag.map(\.name), ["bug", "ui", IssueGrouping.noneTitle])
        XCTAssertEqual(byTag[0].items.map(\.number), [1, 3])
        XCTAssertNil(byTag[2].key)
        XCTAssertEqual(IssueGrouping.state.columns(for: items).map(\.name), ["Open", "Closed"])
        XCTAssertEqual(IssueGrouping.plan.columns(for: items).map(\.name), ["M1", IssueGrouping.noneTitle])
    }

    func testATagCalledNoneIsNotTheNoneColumn() {
        let rows = [WorkItem(container: "a", number: 1, title: "x", tags: [WorkTag(name: "None")]),
                    WorkItem(container: "a", number: 2, title: "y")]
        let columns = IssueGrouping.tag.columns(for: rows)
        XCTAssertEqual(columns.map(\.key), ["None", nil])
        XCTAssertEqual(Set(columns.map(\.id)).count, 2)
    }

    func testPlansSortByDueDateThenName() {
        let soon = Date(timeIntervalSince1970: 1_000), later = Date(timeIntervalSince1970: 2_000)
        let rows = [WorkItem(container: "a", number: 1, title: "x", plan: WorkPlan(id: "Z", title: "Z", dueOn: soon)),
                    WorkItem(container: "a", number: 2, title: "y", plan: WorkPlan(id: "A", title: "A", dueOn: later)),
                    WorkItem(container: "a", number: 3, title: "z", plan: WorkPlan(id: "B", title: "B"))]
        XCTAssertEqual(IssueGrouping.plan.columns(for: rows).map(\.name), ["Z", "A", "B"])
    }

    func testMoveChanges() {
        let item = items[2]
        XCTAssertEqual(IssueGrouping.tag.change(moving: item, from: "bug", to: "docs"),
                       WorkItemChange(addTags: ["docs"], removeTags: ["bug"]))
        XCTAssertEqual(IssueGrouping.tag.change(moving: item, from: "bug", to: "ui"),
                       WorkItemChange(removeTags: ["bug"]))
        XCTAssertEqual(IssueGrouping.tag.change(moving: item, from: "bug", to: nil),
                       WorkItemChange(removeTags: ["bug"]))
        XCTAssertNil(IssueGrouping.tag.change(moving: item, from: "bug", to: "bug"))
        XCTAssertNil(IssueGrouping.container.change(moving: item, from: "beta", to: "alpha"))
        XCTAssertEqual(IssueGrouping.person.change(moving: items[0], from: "ann", to: "bob"),
                       WorkItemChange(addPeople: ["bob"], removePeople: ["ann"]))
        XCTAssertEqual(IssueGrouping.plan.change(moving: items[0], from: "M1", to: nil), WorkItemChange(plan: .remove))
        XCTAssertEqual(IssueGrouping.plan.change(moving: items[0], from: "M1", to: "M2",
                                                 plans: [WorkPlan(id: "id-2", title: "M2")]),
                       WorkItemChange(plan: .set("id-2")))
        XCTAssertEqual(IssueGrouping.state.change(moving: items[1], from: "closed", to: "open"),
                       WorkItemChange(state: .reopen))
        XCTAssertNil(IssueGrouping.state.change(moving: items[1], from: "open", to: "closed"))
    }

    func testApplyingAChange() {
        let metadata = WorkMetadata(tags: [WorkTag(name: "docs", color: "00ff00")],
                                    plans: [WorkPlan(id: "M2", title: "Second")],
                                    people: [WorkPerson(id: "bob", name: "Bob")])
        let change = WorkItemChange(title: "New", addTags: ["docs"], removeTags: ["bug"], addPeople: ["bob"],
                                    removePeople: ["ann"], plan: .set("M2"),
                                    state: .close(WorkCloseReason(id: "x", title: "X", resolution: .notPlanned)))
        let result = items[0].applying(change, metadata: metadata)
        XCTAssertEqual(result.title, "New")
        XCTAssertEqual(result.tags, [WorkTag(name: "docs", color: "00ff00")])
        XCTAssertEqual(result.people, [WorkPerson(id: "bob", name: "Bob")])
        XCTAssertEqual(result.plan?.title, "Second")
        XCTAssertFalse(result.isOpen)
        XCTAssertEqual(result.resolution, .notPlanned)
        XCTAssertTrue(items[1].applying(WorkItemChange(state: .reopen)).isOpen)
    }

    func testAvailableGroupingsFollowFeatures() {
        XCTAssertEqual(IssueGrouping.available(features: [.tags]), [.tag, .container, .state])
        XCTAssertFalse(IssueGrouping.plan.isMovable(features: [.tags]))
        XCTAssertFalse(IssueGrouping.container.isMovable(features: [.tags, .plans, .people, .closeReopen]))
    }
}

final class DiskCacheTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testRoundTripAndRemove() {
        let cache = DiskCache(namespace: "com.example.app", base: base)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        cache.save([WorkItem(container: "a", number: 1, title: "t", updatedAt: date)], key: "items")
        let loaded = cache.load([WorkItem].self, key: "items")
        XCTAssertEqual(loaded?.value.first?.updatedAt, date)
        cache.remove(key: "items")
        XCTAssertNil(cache.load([WorkItem].self, key: "items"))
    }

    func testAKeyCannotLeaveTheFolder() throws {
        let cache = DiskCache(namespace: "com.example.app", base: base)
        for key in ["../escape", "a/b", "..", ".", "", "a\nb", "a\\b"] {
            cache.save(["x"], key: key)
            XCTAssertNil(cache.load([String].self, key: key), key)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("escape.json").path))
    }

    func testAMalformedFileReadsAsNothing() throws {
        let cache = DiskCache(namespace: "com.example.app", base: base)
        try FileManager.default.createDirectory(at: cache.folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: cache.folder.appendingPathComponent("items.json"))
        XCTAssertNil(cache.load([WorkItem].self, key: "items"))
    }
}
