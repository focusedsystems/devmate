import Foundation

/// Lists last read from a provider, kept in the user's Caches folder so an app
/// can show them at launch while fresh ones load. Keep only what a provider
/// returned here: never tokens or credentials.
public struct DiskCache: Sendable {
    public let folder: URL

    /// `namespace` is one folder name, usually the app's bundle id. `base`
    /// defaults to the user's Caches folder.
    public init(namespace: String, base: URL? = nil) {
        precondition(Self.isSafeName(namespace), "A cache namespace is a single folder name.")
        let root = base ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folder = root.appendingPathComponent(namespace, isDirectory: true)
    }

    public struct Entry<Value: Codable>: Codable {
        public var savedAt: Date
        public var value: Value
    }

    /// One path component, so a key can never leave the cache folder.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private func file(_ key: String) -> URL? {
        guard Self.isSafeName(key) else { return nil }
        return folder.appendingPathComponent(key + ".json")
    }

    public func load<Value: Codable>(_ type: Value.Type, key: String) -> Entry<Value>? {
        guard let file = file(key), let data = try? Data(contentsOf: file) else { return nil }
        return try? DevMateJSON.decoder.decode(Entry<Value>.self, from: data)
    }

    public func save<Value: Codable>(_ value: Value, key: String) {
        guard let file = file(key) else { return }
        let entry = Entry(savedAt: Date(), value: value)
        guard let data = try? DevMateJSON.encoder.encode(entry) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
    }

    public func remove(key: String) {
        guard let file = file(key) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
