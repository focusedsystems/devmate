@testable import DevMateUI
import XCTest

final class QuietRefreshTests: XCTestCase {
    func testAnUnchangedReadKeepsTheRowsAndEndsLoading() {
        var loaded = DevLoaded(value: [1, 2, 3], loadedAt: Date(timeIntervalSince1970: 0), errors: [])
        loaded.isLoading = true
        let next = loaded.finished(with: [1, 2, 3], errors: [])
        XCTAssertEqual(next.value, [1, 2, 3])
        XCTAssertFalse(next.isLoading)
        XCTAssertGreaterThan(next.loadedAt ?? .distantPast, Date(timeIntervalSince1970: 1))
    }

    func testAChangedReadReplacesTheRowsAndKeepsTheErrors() {
        let loaded = DevLoaded(value: [1], loadedAt: nil, errors: [])
        let next = loaded.finished(with: [1, 2], errors: ["repo: failed"])
        XCTAssertEqual(next.value, [1, 2])
        XCTAssertEqual(next.errors, ["repo: failed"])
    }
}
