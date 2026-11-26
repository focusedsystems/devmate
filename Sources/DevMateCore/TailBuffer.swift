import Foundation

/// Keeps the last `limit` bytes of a stream that may be far larger, so a log
/// of any size is read in bounded memory. Bytes are held up to twice the limit
/// before the front is dropped, so appending stays cheap.
public struct TailBuffer: Sendable {
    public let limit: Int
    private var bytes: [UInt8] = []
    /// True once any byte has been dropped from the front.
    public private(set) var isTruncated = false

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public mutating func append(_ byte: UInt8) {
        bytes.append(byte)
        trimIfNeeded()
    }

    public mutating func append(contentsOf chunk: some Sequence<UInt8>) {
        bytes.append(contentsOf: chunk)
        trimIfNeeded()
    }

    private mutating func trimIfNeeded() {
        guard bytes.count > limit * 2 else { return }
        bytes.removeFirst(bytes.count - limit)
        isTruncated = true
    }

    /// The tail as text, at most `limit` bytes. A cut tail starts at a whole
    /// line, never part of a character or of a line.
    public var text: String {
        var tail = bytes.count > limit ? Array(bytes.suffix(limit)) : bytes
        if isTruncated || bytes.count > limit {
            if let newline = tail.firstIndex(of: 0x0A), newline + 1 < tail.count {
                tail = Array(tail[(newline + 1)...])
            } else {
                while let first = tail.first, first & 0xC0 == 0x80 { tail.removeFirst() }
            }
        }
        return String(decoding: tail, as: UTF8.self)
    }

    /// The tail of a text that is already in memory.
    public static func tail(of text: String, limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var buffer = TailBuffer(limit: limit)
        buffer.append(contentsOf: text.utf8.suffix(limit * 2))
        buffer.isTruncated = true
        return buffer.text
    }
}
