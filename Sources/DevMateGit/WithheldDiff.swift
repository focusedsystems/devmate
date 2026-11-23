import Foundation

/// Folders an app must never handle, whatever `.gitignore` says. A folder with
/// one of these names is withheld at any depth, in any letter case, since the
/// default Mac file system ignores case.
public struct WithheldPaths: Hashable, Sendable {
    public let folderNames: Set<String>

    public static let none = WithheldPaths(folderNames: [])

    /// Names are single path components of letters, digits, `.`, `_` and `-`,
    /// so they can never act as a pattern.
    public init(folderNames: Set<String>) {
        precondition(folderNames.allSatisfy(Self.isValidName), "A withheld folder is one plain path component.")
        self.folderNames = Set(folderNames.map { $0.lowercased() })
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
    }

    public var isEmpty: Bool { folderNames.isEmpty }

    public func withholds(_ path: String) -> Bool {
        guard !isEmpty else { return false }
        return path.split(separator: "/").contains { folderNames.contains($0.lowercased()) }
    }

    /// Exclude pathspecs, so git never emits these paths. These are patterns
    /// rather than literal paths because history holds paths no longer on
    /// disk, which cannot be listed ahead of time.
    var excludes: [String] {
        folderNames.sorted().flatMap { [":(exclude,icase,glob)**/\($0)", ":(exclude,icase,glob)**/\($0)/**"] }
    }

    /// `arguments` limited to what is not withheld, or nil when the command
    /// cannot be limited and must not run. Existing paths stay literal,
    /// because pathspec magic has to be on for the excludes.
    func limiting(_ arguments: [String]) -> (arguments: [String], usesMagic: Bool)? {
        guard !isEmpty, let command = arguments.first else { return (arguments, false) }
        var result = arguments
        switch command {
        case "status", "ls-files", "grep":
            break
        case "diff":
            // `--no-index` compares two named files and takes no pathspec;
            // its callers have already refused a withheld path.
            if arguments.contains("--no-index") { return (arguments, false) }
        case "show":
            result.insert("--diff-merges=first-parent", at: 1)
        case "log":
            let output: Set<String> = ["--numstat", "--stat", "--shortstat", "-p", "--patch", "--raw", "--name-only",
                                       "--name-status", "--summary"]
            guard arguments.contains(where: output.contains) else { return (arguments, false) }
        case "add":
            guard arguments.contains("--all") else { return (arguments, false) }
        case "format-patch":
            // With a pathspec, `-1` picks the newest commit touching those
            // paths instead of the one named.
            return nil
        default:
            return (arguments, false)
        }
        if let separator = result.firstIndex(of: "--") {
            let paths = result[(separator + 1)...].map { ":(literal)" + $0 }
            result = Array(result[...separator]) + (paths.isEmpty ? ["."] : paths)
        } else {
            result += ["--", "."]
        }
        return (result + excludes, true)
    }
}

/// Takes withheld files out of diff text from a host, which cannot be limited
/// at the source. It fails closed: a header it cannot read withholds the whole
/// diff.
public enum WithheldDiff {
    public struct Result: Equatable, Sendable {
        public var text: String
        /// Nothing can be shown, because a header could not be read.
        public var isWithheldEntirely: Bool
        public var removedFiles: Int
    }

    public static func filter(_ text: String, withheld: WithheldPaths) -> Result {
        guard !withheld.isEmpty else { return Result(text: text, isWithheldEntirely: false, removedFiles: 0) }
        let blocked = Result(text: "", isWithheldEntirely: true, removedFiles: 0)
        let lines = text.components(separatedBy: "\n")
        var preamble: [String] = []
        var sections: [[String]] = []
        for line in lines {
            if isSectionStart(line) {
                sections.append([line])
            } else if sections.isEmpty {
                // A host diff starts at its first header.
                guard line.isEmpty else { return blocked }
                preamble.append(line)
            } else {
                sections[sections.count - 1].append(line)
            }
        }
        var kept: [[String]] = []
        for section in sections {
            guard let paths = paths(in: section) else { return blocked }
            if !paths.contains(where: withheld.withholds) { kept.append(section) }
        }
        let removed = sections.count - kept.count
        guard removed > 0 else { return Result(text: text, isWithheldEntirely: false, removedFiles: 0) }
        return Result(text: (preamble + kept.flatMap { $0 }).joined(separator: "\n"), isWithheldEntirely: false,
                      removedFiles: removed)
    }

    private static func isSectionStart(_ line: String) -> Bool {
        line.hasPrefix("diff ")
    }

    /// Every path a section's header names, or nil if any cannot be read.
    static func paths(in section: [String]) -> [String]? {
        guard let first = section.first else { return nil }
        var found: [String] = []
        var named = false
        if first.hasPrefix("diff --git ") {
            if let pair = gitHeaderPaths(String(first.dropFirst("diff --git ".count))) {
                found += pair
                named = true
            }
        } else if first.hasPrefix("diff --cc ") || first.hasPrefix("diff --combined ") {
            let prefix = first.hasPrefix("diff --cc ") ? "diff --cc " : "diff --combined "
            guard let path = decodeName(String(first.dropFirst(prefix.count))), !path.isEmpty else { return nil }
            found.append(path)
            named = true
        } else {
            return nil
        }
        for line in section.dropFirst() {
            if line.hasPrefix("@@") { break }
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                var name = String(line.dropFirst(4))
                if let tab = name.firstIndex(of: "\t"), !name.hasPrefix("\"") { name = String(name[..<tab]) }
                guard let path = decodeName(name) else { return nil }
                if path == "/dev/null" { continue }
                guard path.hasPrefix("a/") || path.hasPrefix("b/") else { return nil }
                found.append(String(path.dropFirst(2)))
                named = true
                continue
            }
            for prefix in ["rename from ", "rename to ", "copy from ", "copy to "] where line.hasPrefix(prefix) {
                guard let path = decodeName(String(line.dropFirst(prefix.count))), !path.isEmpty else { return nil }
                found.append(path)
                named = true
            }
        }
        return named ? found : nil
    }

    /// `a/x b/y`, each side possibly C-quoted. An unquoted pair with spaces is
    /// read only when both sides name the same file. A rename's real names
    /// come from its `rename` lines.
    private static func gitHeaderPaths(_ header: String) -> [String]? {
        func strip(_ path: String) -> String? {
            path.hasPrefix("a/") || path.hasPrefix("b/") ? String(path.dropFirst(2)) : nil
        }
        if header.hasPrefix("\"") {
            guard let (old, rest) = quotedPrefix(header), rest.hasPrefix(" "),
                  let new = decodeName(String(rest.dropFirst())),
                  let oldPath = strip(old), let newPath = strip(new) else { return nil }
            return [oldPath, newPath]
        }
        if header.hasSuffix("\""), let open = header.range(of: " \"") {
            guard let new = decodeName(String(header[header.index(after: open.lowerBound)...])),
                  let oldPath = strip(String(header[..<open.lowerBound])), let newPath = strip(new) else { return nil }
            return [oldPath, newPath]
        }
        let bytes = Array(header.utf8)
        guard bytes.count % 2 == 1 else { return nil }
        let middle = bytes.count / 2
        guard bytes[middle] == UInt8(ascii: " "),
              let old = String(bytes: bytes[..<middle], encoding: .utf8),
              let new = String(bytes: bytes[(middle + 1)...], encoding: .utf8),
              let oldPath = strip(old), let newPath = strip(new), oldPath == newPath else { return nil }
        return [oldPath, newPath]
    }

    private static func decodeName(_ raw: String) -> String? {
        guard raw.hasPrefix("\"") else { return raw }
        guard let (name, rest) = quotedPrefix(raw), rest.isEmpty || rest.hasPrefix("\t") else { return nil }
        return name
    }

    /// Decodes a leading C-quoted string, returning it and what follows.
    static func quotedPrefix(_ raw: String) -> (String, Substring)? {
        let scalars = Array(raw.utf8)
        guard scalars.first == UInt8(ascii: "\"") else { return nil }
        var output: [UInt8] = []
        var index = 1
        while index < scalars.count {
            let byte = scalars[index]
            if byte == UInt8(ascii: "\"") {
                guard let name = String(bytes: output, encoding: .utf8),
                      let rest = String(bytes: scalars[(index + 1)...], encoding: .utf8) else { return nil }
                return (name, Substring(rest))
            }
            guard byte == UInt8(ascii: "\\") else {
                output.append(byte)
                index += 1
                continue
            }
            guard index + 1 < scalars.count else { return nil }
            let next = scalars[index + 1]
            let simple: [UInt8: UInt8] = [
                UInt8(ascii: "a"): 7, UInt8(ascii: "b"): 8, UInt8(ascii: "t"): 9, UInt8(ascii: "n"): 10,
                UInt8(ascii: "v"): 11, UInt8(ascii: "f"): 12, UInt8(ascii: "r"): 13,
                UInt8(ascii: "\""): UInt8(ascii: "\""), UInt8(ascii: "\\"): UInt8(ascii: "\\"),
            ]
            if let value = simple[next] {
                output.append(value)
                index += 2
                continue
            }
            guard index + 3 < scalars.count else { return nil }
            let digits = scalars[(index + 1)...(index + 3)]
            guard digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "7") }) else { return nil }
            let value = digits.reduce(0) { $0 * 8 + Int($1 - UInt8(ascii: "0")) }
            guard value <= 255 else { return nil }
            output.append(UInt8(value))
            index += 4
        }
        return nil
    }
}
