import Foundation

public enum RepoProviderKind: String, Codable, Hashable, Sendable {
    case github
    case azureDevOps = "azure-devops"
    case local
}

public enum RepoEntryKind: String, Codable, Hashable, Sendable {
    case repo
    case folder
}

/// Which tabs show a repo.
public struct RepoSurfaces: Codable, Hashable, Sendable {
    public var agents: Bool
    public var development: Bool
    public var projects: Bool

    public init(agents: Bool = true, development: Bool = true, projects: Bool = true) {
        self.agents = agents
        self.development = development
        self.projects = projects
    }
}

/// One repo or folder an app works with. `id` is stable and is what a reader
/// keys on.
public struct DevRepo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    /// `owner/repo` on GitHub, `Project/Repo` on Azure DevOps.
    public var remote: String?
    public var provider: RepoProviderKind
    public var kind: RepoEntryKind
    public var icon: String?
    public var host: String?
    public var surfaces: RepoSurfaces
    public var shared: Bool
    public var fork: Bool
    /// `owner/repo` when `fork` is true.
    public var upstream: String?

    public init(id: String, name: String, path: String, remote: String? = nil, provider: RepoProviderKind,
                kind: RepoEntryKind = .repo, icon: String? = nil, host: String? = nil,
                surfaces: RepoSurfaces = RepoSurfaces(), shared: Bool = false, fork: Bool = false,
                upstream: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.remote = remote
        self.provider = provider
        self.kind = kind
        self.icon = icon
        self.host = host
        self.surfaces = surfaces
        self.shared = shared
        self.fork = fork
        self.upstream = upstream
    }
}

public struct RepoSection: Codable, Hashable, Sendable {
    public var name: String
    public var repos: [DevRepo]

    public init(name: String, repos: [DevRepo]) {
        self.name = name
        self.repos = repos
    }
}

public struct RepoSettings: Codable, Hashable, Sendable {
    public var scanRoots: [String]?
    public var scanDepth: Int?
    public var skipDirectories: [String]?
    public var cloneRoot: String?
    public var gitHubOwners: [String]?
    public var protectedBranches: [String]?
    public var concurrency: Int?

    public init(scanRoots: [String]? = nil, scanDepth: Int? = nil, skipDirectories: [String]? = nil,
                cloneRoot: String? = nil, gitHubOwners: [String]? = nil, protectedBranches: [String]? = nil,
                concurrency: Int? = nil) {
        self.scanRoots = scanRoots
        self.scanDepth = scanDepth
        self.skipDirectories = skipDirectories
        self.cloneRoot = cloneRoot
        self.gitHubOwners = gitHubOwners
        self.protectedBranches = protectedBranches
        self.concurrency = concurrency
    }
}

/// The repos an app shows, in its sections.
public struct RepoCatalog: Codable, Hashable, Sendable {
    public var settings: RepoSettings
    public var sections: [RepoSection]

    public init(settings: RepoSettings = RepoSettings(), sections: [RepoSection]) {
        self.settings = settings
        self.sections = sections
    }

    public var repos: [DevRepo] { sections.flatMap(\.repos) }
}

/// The rendered registry file, schema 1.
struct RepoRegistryFile: Decodable {
    struct App: Decodable {
        var id: String
    }

    var schema_version: Int
    var app: App
    var settings: RepoSettings
    var sections: [RepoSection]
}

/// Why a registry file was not used.
public enum RegistryProblem: Equatable, Sendable {
    case newerSchema(found: Int)
    case unknownSchema(found: Int)
    case wrongApp(found: String)
    case malformed
    case emptyList
    case unreadable

    public var message: String {
        switch self {
        case .newerSchema(let found):
            return "The repo registry is in a newer format (version \(found)) than this app reads. Update the app."
        case .unknownSchema(let found):
            return "The repo registry is in a format this app does not know (version \(found))."
        case .wrongApp:
            return "The repo registry file belongs to another app."
        case .malformed:
            return "The repo registry file could not be read as a valid list."
        case .emptyList:
            return "The repo registry file lists no repos."
        case .unreadable:
            return "The repo registry file could not be opened."
        }
    }
}

/// Where the current list came from.
public enum RegistryState: Equatable, Sendable {
    /// The registry file, read just now.
    case registry
    /// No registry file, so the app's own list.
    case fallback
    /// The file is unusable, so the last good list stays.
    case keptLastGood(RegistryProblem)
    /// The file is unusable and no good list was ever read, so the app's own.
    case fallbackAfterProblem(RegistryProblem)

    /// Text for a banner, when the person should know the list may be stale.
    public var banner: String? {
        switch self {
        case .registry, .fallback:
            return nil
        case .keptLastGood(let problem):
            return problem.message + " Showing the last good list."
        case .fallbackAfterProblem(let problem):
            return problem.message + " Showing this app's built-in list."
        }
    }
}

/// Reads the rendered registry for one app. It never writes that file. The
/// last good copy it keeps is a separate file in the app's caches, so repos
/// survive a bad registry across launches.
public final class RegistryRepoSource: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var catalog: RepoCatalog
        public var state: RegistryState

        public init(catalog: RepoCatalog, state: RegistryState) {
            self.catalog = catalog
            self.state = state
        }
    }

    public let bundleID: String
    public let fallback: RepoCatalog
    public let registryFile: URL
    private let lastGoodFile: URL?
    private let lock = NSLock()
    private var lastGood: RepoCatalog?
    private var lastGoodData: Data?
    private var current: Snapshot

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-apps/repos", isDirectory: true)
    }

    public static func defaultLastGoodFile(bundleID: String) -> URL? {
        guard isSafeFileName(bundleID),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("devmate-registry-last-good.json")
    }

    /// `lastGoodFile` is ignored if it names the registry file itself.
    public init(bundleID: String, fallback: RepoCatalog, directory: URL = RegistryRepoSource.defaultDirectory,
                lastGoodFile: URL? = nil, usesDefaultLastGoodFile: Bool = true) {
        self.bundleID = bundleID
        self.fallback = fallback
        let registry = directory.appendingPathComponent(bundleID + ".json")
        registryFile = registry
        let keep = lastGoodFile ?? (usesDefaultLastGoodFile ? Self.defaultLastGoodFile(bundleID: bundleID) : nil)
        let isRegistry = keep.map { Self.isSameFile($0, registry) } ?? false
        self.lastGoodFile = isRegistry ? nil : keep
        current = Snapshot(catalog: fallback, state: .fallback)
    }

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Reads the file again and returns what the app should now show.
    @discardableResult
    public func reload() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        current = read()
        return current
    }

    private func read() -> Snapshot {
        guard Self.isSafeFileName(bundleID) else { return unusable(.unreadable) }
        let data: Data
        do {
            data = try Data(contentsOf: registryFile)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Snapshot(catalog: fallback, state: .fallback)
        } catch {
            return unusable(.unreadable)
        }
        switch Self.parse(data, bundleID: bundleID) {
        case .success(let catalog):
            lastGood = catalog
            if data != lastGoodData {
                lastGoodData = data
                persistLastGood(data)
            }
            return Snapshot(catalog: catalog, state: .registry)
        case .failure(let failure):
            return unusable(failure.problem)
        }
    }

    private func unusable(_ problem: RegistryProblem) -> Snapshot {
        if lastGood == nil { loadPersistedLastGood() }
        if let lastGood { return Snapshot(catalog: lastGood, state: .keptLastGood(problem)) }
        return Snapshot(catalog: fallback, state: .fallbackAfterProblem(problem))
    }

    private func loadPersistedLastGood() {
        guard let lastGoodFile, let data = try? Data(contentsOf: lastGoodFile),
              case .success(let catalog) = Self.parse(data, bundleID: bundleID) else { return }
        lastGood = catalog
        lastGoodData = data
    }

    /// Replaces the copy atomically, readable only by this user.
    private func persistLastGood(_ data: Data) {
        guard let lastGoodFile, !Self.isSameFile(lastGoodFile, registryFile) else { return }
        let folder = lastGoodFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".last-good-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, lastGoodFile.path) == 0 else {
                unlink(temporary.path)
                return
            }
        } catch {
            unlink(temporary.path)
        }
    }

    struct ParseFailure: Error {
        var problem: RegistryProblem
    }

    /// Accepts only the schema this version knows, for this app, with every
    /// repo id unique.
    static func parse(_ data: Data, bundleID: String) -> Result<RepoCatalog, ParseFailure> {
        struct Version: Decodable { var schema_version: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: data) else {
            return .failure(ParseFailure(problem: .malformed))
        }
        guard version.schema_version == DevMate.registrySchemaVersion else {
            let found = version.schema_version
            let problem: RegistryProblem = found > DevMate.registrySchemaVersion
                ? .newerSchema(found: found) : .unknownSchema(found: found)
            return .failure(ParseFailure(problem: problem))
        }
        guard let file = try? JSONDecoder().decode(RepoRegistryFile.self, from: data) else {
            return .failure(ParseFailure(problem: .malformed))
        }
        guard file.app.id == bundleID else {
            return .failure(ParseFailure(problem: .wrongApp(found: file.app.id)))
        }
        let catalog = RepoCatalog(settings: file.settings, sections: file.sections)
        guard !catalog.repos.isEmpty else {
            return .failure(ParseFailure(problem: .emptyList))
        }
        let ids = catalog.repos.map(\.id)
        let isBlank = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard Set(ids).count == ids.count,
              !catalog.repos.contains(where: { isBlank($0.id) || isBlank($0.name) || isBlank($0.path) }) else {
            return .failure(ParseFailure(problem: .malformed))
        }
        return .success(catalog)
    }

    /// Compares canonical paths without regard to case or normalization, as
    /// the volume may, and then the files themselves, which catches a hard
    /// link.
    static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        func canonical(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path.decomposedStringWithCanonicalMapping
                .folding(options: .caseInsensitive, locale: nil)
        }
        if canonical(first) == canonical(second) { return true }
        func identifier(_ url: URL) -> NSObject? {
            let fresh = URL(fileURLWithPath: url.path)
            return (try? fresh.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        }
        guard let one = identifier(first), let other = identifier(second) else { return false }
        return one.isEqual(other)
    }

    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
