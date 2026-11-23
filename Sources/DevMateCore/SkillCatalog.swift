import Foundation

/// Discovers agent skills (`SKILL.md` files) in repositories and the user's home folder.
public enum SkillCatalog {
    public struct Skill: Identifiable, Hashable, Sendable, Codable {
        public var name: String
        public var description: String
        public var source: String
        public var location: String
        public var file: URL
        public var id: String { file.path }

        public init(name: String, description: String, source: String, location: String, file: URL) {
            self.name = name
            self.description = description
            self.source = source
            self.location = location
            self.file = file
        }
    }

    public static let userSource = "User"

    private static let rootPaths = [".claude/skills", ".agents/skills"]
    private static let fileName = "SKILL.md"

    /// Scans each repository's skill roots and the user's skill roots under `home`.
    public static func scan(
        repos: [(name: String, folder: URL)],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Skill] {
        var found: [Skill] = []
        for repo in repos {
            for path in rootPaths {
                let root = repo.folder.appendingPathComponent(path, isDirectory: true)
                found += skills(in: root, source: repo.name, location: path)
            }
        }
        for path in rootPaths {
            let root = home.appendingPathComponent(path, isDirectory: true)
            found += skills(in: root, source: userSource, location: "~/" + path)
        }

        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.file.path).inserted }
        return unique.sorted { a, b in
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            let bySource = a.source.localizedCaseInsensitiveCompare(b.source)
            if bySource != .orderedSame { return bySource == .orderedAscending }
            return a.file.path < b.file.path
        }
    }

    /// The text after a leading front matter block, or everything when there is none.
    public static func body(of text: String) -> String {
        guard let parsed = split(text) else { return text }
        return parsed.body
    }

    /// Top-level `key: value` pairs from a leading `---` block. Indented lines are never keys;
    /// block scalars (`>`, `|`, with optional chomping marks) take their indented lines as the value;
    /// the first occurrence of a repeated key wins.
    public static func frontMatter(_ text: String) -> [String: String] {
        guard let parsed = split(text) else { return [:] }
        let lines = parsed.header
        var result: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.first == " " || line.first == "\t" { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { continue }
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            var value: String
            if isBlockIndicator(raw) {
                var parts: [String] = []
                while index < lines.count {
                    let next = lines[index]
                    if next.first == " " || next.first == "\t" {
                        parts.append(next.trimmingCharacters(in: .whitespaces))
                    } else if next.trimmingCharacters(in: .whitespaces).isEmpty {
                        parts.append("")
                    } else {
                        break
                    }
                    index += 1
                }
                while parts.last == "" { parts.removeLast() }
                value = parts.joined(separator: raw.hasPrefix("|") ? "\n" : " ")
            } else {
                value = unquote(raw)
            }
            if result[key] == nil { result[key] = value }
        }
        return result
    }

    // MARK: Internals

    private static func isBlockIndicator(_ value: String) -> Bool {
        guard let first = value.first, first == ">" || first == "|" else { return false }
        return value.dropFirst().allSatisfy { $0 == "+" || $0 == "-" || $0.isNumber }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              first == last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private static func split(_ text: String) -> (header: [String], body: String)? {
        var lines = text.components(separatedBy: "\n")
        if lines.first == "\u{FEFF}---" { lines[0] = "---" }
        func isFence(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces) == "---" }
        guard let first = lines.first, isFence(first) else { return nil }
        guard let end = lines.indices.dropFirst().first(where: { isFence(lines[$0]) }) else { return nil }
        let header = lines[1..<end].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (header, body)
    }

    private static func skills(in root: URL, source: String, location: String) -> [Skill] {
        let fm = FileManager.default
        guard let realRoot = try? root.resolvingSymlinksInPath().standardizedFileURL,
              let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let rootPrefix = realRoot.path.hasSuffix("/") ? realRoot.path : realRoot.path + "/"

        var out: [Skill] = []
        for entry in entries.sorted() {
            let folder = root.appendingPathComponent(entry, isDirectory: true)
            let file = folder.appendingPathComponent(fileName, isDirectory: false)
            guard let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
                  values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let realFolder = folder.resolvingSymlinksInPath().standardizedFileURL
            let realFile = realFolder.appendingPathComponent(fileName)
            guard realFolder.path.hasPrefix(rootPrefix), realFile.path.hasPrefix(rootPrefix) else { continue }
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }

            let meta = frontMatter(text)
            let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry
            out.append(Skill(name: name, description: meta["description"] ?? "",
                             source: source, location: location, file: file))
        }
        return out
    }
}
