import Foundation

/// A colour an ANSI escape asked for.
public enum RunLogColor: Hashable, Sendable {
    /// One of the eight standard colours, 0 black through 7 white.
    case standard(Int, bright: Bool)
    case rgb(UInt8, UInt8, UInt8)
}

/// How a stretch of a line is drawn.
public struct RunLogStyle: Hashable, Sendable {
    public var color: RunLogColor?
    public var bold = false
    public var underline = false
    public init(color: RunLogColor? = nil, bold: Bool = false, underline: Bool = false) {
        self.color = color
        self.bold = bold
        self.underline = underline
    }
}

public struct RunLogSpan: Hashable, Sendable {
    /// UTF-16 offsets into the line's text.
    public var location: Int
    public var length: Int
    public var style: RunLogStyle
}

/// One line of a log, as the web page shows it.
public struct RunLogLine: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case plain, section, command, warning, error, debug, notice
        /// Opens a collapsible group; `text` is its title.
        case group
    }

    /// The line's number in the log as the host sent it, counting from 1.
    public var number: Int
    public var kind: Kind
    public var text: String
    public var spans: [RunLogSpan]
    /// For a `group` line, the group it opens.
    public var opens: Int?
    /// Every group this line sits inside, outermost first.
    public var inside: [Int]
    /// True when the text is a `Starting:` or `Finishing:` marker.
    public var isMarker: Bool
}

/// Reads a host's log text: Azure DevOps and GitHub Actions `##[command]`
/// markers, groups, ANSI colours and the timestamp each line starts with.
public enum RunLogParser {
    public struct Parsed: Sendable {
        public var lines: [RunLogLine]
        /// Every group, in the order it opens.
        public var groups: [Int]
        public init(lines: [RunLogLine], groups: [Int]) {
            self.lines = lines
            self.groups = groups
        }
    }

    public static func parse(_ text: String) -> Parsed {
        var lines: [RunLogLine] = []
        var groups: [Int] = []
        var stack: [Int] = []
        var number = 0
        var nextGroup = 0
        text.enumerateLines { raw, _ in
            number += 1
            var line = stripTimestamp(raw)
            var kind = RunLogLine.Kind.plain
            var opens: Int?
            if line.hasPrefix("##[") , let close = line.firstIndex(of: "]") {
                let name = String(line[line.index(line.startIndex, offsetBy: 3)..<close])
                let rest = String(line[line.index(after: close)...])
                switch name {
                case "group":
                    kind = .group
                    line = rest
                    opens = nextGroup
                case "endgroup":
                    if !stack.isEmpty { stack.removeLast() }
                    return
                case "section": kind = .section; line = rest
                case "command": kind = .command; line = rest
                case "warning": kind = .warning; line = rest
                case "error": kind = .error; line = rest
                case "debug": kind = .debug; line = rest
                case "notice": kind = .notice; line = rest
                default: break
                }
            }
            let (plain, spans) = ansi(line)
            let marker = kind == .section && (plain.hasPrefix("Starting:") || plain.hasPrefix("Finishing:"))
            lines.append(RunLogLine(number: number, kind: kind, text: plain, spans: spans, opens: opens,
                                    inside: stack, isMarker: marker))
            if let opens {
                groups.append(opens)
                stack.append(opens)
                nextGroup += 1
            }
        }
        return Parsed(lines: lines, groups: groups)
    }

    /// Drops the `2026-01-02T03:04:05.1234567Z ` an Azure DevOps or GitHub log
    /// puts on every line.
    static func stripTimestamp(_ line: String) -> String {
        let scalars = Array(line.utf8)
        guard scalars.count > 21, scalars[4] == 45, scalars[7] == 45, scalars[10] == 84, scalars[13] == 58,
              scalars[16] == 58 else { return line }
        var index = 19
        if index < scalars.count, scalars[index] == 46 {
            index += 1
            while index < scalars.count, scalars[index] >= 48, scalars[index] <= 57 { index += 1 }
        }
        guard index < scalars.count, scalars[index] == 90 else { return line }
        index += 1
        if index < scalars.count, scalars[index] == 32 { index += 1 }
        return String(decoding: scalars[index...], as: UTF8.self)
    }

    /// The text without escape sequences, and the stretches they coloured.
    static func ansi(_ line: String) -> (String, [RunLogSpan]) {
        guard line.contains("\u{1B}[") else { return (line, []) }
        var plain = ""
        var spans: [RunLogSpan] = []
        var style = RunLogStyle()
        var spanStart = 0
        var length = 0
        func close() {
            if length > spanStart, style != RunLogStyle() {
                spans.append(RunLogSpan(location: spanStart, length: length - spanStart, style: style))
            }
            spanStart = length
        }
        let characters = Array(line.unicodeScalars)
        var i = 0
        while i < characters.count {
            if characters[i] == "\u{1B}", i + 1 < characters.count, characters[i + 1] == "[" {
                var j = i + 2
                var body = ""
                while j < characters.count, !(characters[j].value >= 0x40 && characters[j].value <= 0x7E) {
                    body.unicodeScalars.append(characters[j])
                    j += 1
                }
                if j < characters.count, characters[j] == "m" {
                    close()
                    apply(body, to: &style)
                }
                i = j + 1
                continue
            }
            plain.unicodeScalars.append(characters[i])
            length += characters[i].utf16.count
            i += 1
        }
        close()
        return (plain, spans)
    }

    private static func apply(_ body: String, to style: inout RunLogStyle) {
        let codes = body.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        let list = codes.isEmpty ? [0] : codes
        while i < list.count {
            let code = list[i]
            switch code {
            case 0: style = RunLogStyle()
            case 1: style.bold = true
            case 22: style.bold = false
            case 4: style.underline = true
            case 24: style.underline = false
            case 30...37: style.color = .standard(code - 30, bright: false)
            case 90...97: style.color = .standard(code - 90, bright: true)
            case 39: style.color = nil
            case 38:
                if i + 2 < list.count, list[i + 1] == 5 {
                    style.color = palette(list[i + 2])
                    i += 2
                } else if i + 4 < list.count, list[i + 1] == 2 {
                    style.color = .rgb(UInt8(clamping: list[i + 2]), UInt8(clamping: list[i + 3]), UInt8(clamping: list[i + 4]))
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    private static func palette(_ n: Int) -> RunLogColor? {
        switch n {
        case 0...7: return .standard(n, bright: false)
        case 8...15: return .standard(n - 8, bright: true)
        case 16...231:
            let v = n - 16
            func level(_ x: Int) -> UInt8 { x == 0 ? 0 : UInt8(55 + x * 40) }
            return .rgb(level(v / 36), level((v / 6) % 6), level(v % 6))
        case 232...255:
            let g = UInt8(8 + (n - 232) * 10)
            return .rgb(g, g, g)
        default: return nil
        }
    }

    /// Web addresses in a line, as UTF-16 ranges.
    public static func links(in text: String) -> [(range: NSRange, url: URL)] {
        guard text.contains("http") else { return [] }
        let ns = text as NSString
        let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'`)\]}]+"#)
        return (regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []).compactMap { match in
            var range = match.range
            while range.length > 1, ".,;:!?".contains(ns.substring(with: NSRange(location: range.location + range.length - 1, length: 1))) {
                range.length -= 1
            }
            return URL(string: ns.substring(with: range)).map { (range, $0) }
        }
    }
}
