import DevMateCore
import XCTest

final class RunLogParserTests: XCTestCase {
    func testStripsTimestampAndReadsMarkers() {
        let parsed = RunLogParser.parse("""
        2026-01-01T10:00:00.1234567Z ##[section]Starting: Build it
        2026-01-01T10:00:01.0000000Z ##[command]/usr/bin/make
        2026-01-01T10:00:02.0000000Z ##[warning]careful
        2026-01-01T10:00:03.0000000Z ##[error]broke
        2026-01-01T10:00:04Z plain text
        """)
        XCTAssertEqual(parsed.lines.map(\.text), ["Starting: Build it", "/usr/bin/make", "careful", "broke", "plain text"])
        XCTAssertEqual(parsed.lines.map(\.kind), [.section, .command, .warning, .error, .plain])
        XCTAssertTrue(parsed.lines[0].isMarker)
        XCTAssertFalse(parsed.lines[1].isMarker)
        XCTAssertEqual(parsed.lines.map(\.number), [1, 2, 3, 4, 5])
    }

    func testGroupsNestAndKeepOriginalLineNumbers() {
        let parsed = RunLogParser.parse("""
        ##[group]Outer
        inside outer
        ##[group]Inner
        deep
        ##[endgroup]
        back in outer
        ##[endgroup]
        after
        """)
        XCTAssertEqual(parsed.groups, [0, 1])
        XCTAssertEqual(parsed.lines.map(\.text), ["Outer", "inside outer", "Inner", "deep", "back in outer", "after"])
        XCTAssertEqual(parsed.lines.map(\.number), [1, 2, 3, 4, 6, 8])
        XCTAssertEqual(parsed.lines[0].opens, 0)
        XCTAssertEqual(parsed.lines[1].inside, [0])
        XCTAssertEqual(parsed.lines[3].inside, [0, 1])
        XCTAssertEqual(parsed.lines[5].inside, [])
    }

    func testAnsiColoursBecomeSpans() {
        let parsed = RunLogParser.parse("\u{1B}[32mok\u{1B}[0m done \u{1B}[1;31mfail\u{1B}[0m")
        let line = parsed.lines[0]
        XCTAssertEqual(line.text, "ok done fail")
        XCTAssertEqual(line.spans.count, 2)
        XCTAssertEqual(line.spans[0].location, 0)
        XCTAssertEqual(line.spans[0].length, 2)
        XCTAssertEqual(line.spans[0].style.color, .standard(2, bright: false))
        XCTAssertEqual(line.spans[1].location, 8)
        XCTAssertTrue(line.spans[1].style.bold)
    }

    func testExtendedColoursAndUnknownEscapes() {
        let parsed = RunLogParser.parse("\u{1B}[38;5;196mred\u{1B}[0m \u{1B}[38;2;1;2;3mrgb\u{1B}[0m \u{1B}[2Kcleared")
        let line = parsed.lines[0]
        XCTAssertEqual(line.text, "red rgb cleared")
        XCTAssertEqual(line.spans[0].style.color, .rgb(255, 0, 0))
        XCTAssertEqual(line.spans[1].style.color, .rgb(1, 2, 3))
    }

    func testLinksDropTrailingPunctuation() {
        let links = RunLogParser.links(in: "see https://docs.example.com/a/b. and (https://example.org/x)")
        XCTAssertEqual(links.map(\.url.absoluteString), ["https://docs.example.com/a/b", "https://example.org/x"])
    }
}
