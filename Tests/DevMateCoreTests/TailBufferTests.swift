import DevMateCore
import XCTest

final class TailBufferTests: XCTestCase {
    func testShortInputIsKeptWhole() {
        var buffer = TailBuffer(limit: 100)
        buffer.append(contentsOf: Array("one\ntwo\n".utf8))
        XCTAssertEqual(buffer.text, "one\ntwo\n")
        XCTAssertFalse(buffer.isTruncated)
    }

    func testOversizedInputKeepsOnlyTheTailFromAWholeLine() {
        var buffer = TailBuffer(limit: 50)
        for number in 0..<10_000 { buffer.append(contentsOf: Array("line \(number)\n".utf8)) }
        let text = buffer.text
        XCTAssertLessThanOrEqual(text.utf8.count, 50)
        XCTAssertTrue(buffer.isTruncated)
        XCTAssertTrue(text.hasPrefix("line "), "starts at a whole line: \(text)")
        XCTAssertTrue(text.hasSuffix("line 9999\n"))
    }

    func testByteAtATimeAppendsStayBounded() {
        var buffer = TailBuffer(limit: 64)
        for index in 0..<1_000_000 { buffer.append(UInt8(index % 26) + 97) }
        XCTAssertLessThanOrEqual(buffer.text.utf8.count, 64)
    }

    func testACutNeverStartsInsideACharacter() {
        var buffer = TailBuffer(limit: 10)
        buffer.append(contentsOf: Array(String(repeating: "\u{00E9}", count: 500).utf8))
        let text = buffer.text
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.unicodeScalars.contains("\u{FFFD}"))
    }

    func testTailOfATextInMemory() {
        let text = (0..<5_000).map { "row \($0)" }.joined(separator: "\n")
        let tail = TailBuffer.tail(of: text, limit: 100)
        XCTAssertLessThanOrEqual(tail.utf8.count, 100)
        XCTAssertTrue(tail.hasSuffix("row 4999"))
        XCTAssertEqual(TailBuffer.tail(of: "small", limit: 100), "small")
    }
}
