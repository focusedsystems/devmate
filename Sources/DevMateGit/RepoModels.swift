import Foundation

// MARK: - Status

/// One changed path, from `git status --porcelain=v2`.
public struct RepoFileChange: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case changed, renamed, unmerged, untracked, ignored
    }

    public let path: String
    /// The source path of a rename or copy.
    public let originalPath: String?
    public let kind: Kind
    /// Index (staged) status letter: `M`, `A`, `D`, `R`, `C`, `T`, `U`, or `.` for none.
    public let indexStatus: Character
    /// Worktree (unstaged) status letter, same alphabet.
    public let worktreeStatus: Character

    public var id: String { path }
    public var isStaged: Bool { kind != .untracked && kind != .ignored && indexStatus != "." }
    public var isUnstaged: Bool { kind != .untracked && kind != .ignored && worktreeStatus != "." }

    public init(path: String, originalPath: String? = nil, kind: Kind, indexStatus: Character, worktreeStatus: Character) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
    }

    enum CodingKeys: String, CodingKey { case path, originalPath, kind, indexStatus, worktreeStatus, staged, unstaged }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(originalPath, forKey: .originalPath)
        try c.encode(kind, forKey: .kind)
        try c.encode(String(indexStatus), forKey: .indexStatus)
        try c.encode(String(worktreeStatus), forKey: .worktreeStatus)
        try c.encode(isStaged, forKey: .staged)
        try c.encode(isUnstaged, forKey: .unstaged)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        originalPath = try c.decodeIfPresent(String.self, forKey: .originalPath)
        kind = try c.decode(Kind.self, forKey: .kind)
        indexStatus = try c.decode(String.self, forKey: .indexStatus).first ?? "."
        worktreeStatus = try c.decode(String.self, forKey: .worktreeStatus).first ?? "."
    }
}

/// One entry of `git worktree list --porcelain`.
public struct RepoWorktree: Codable, Sendable, Hashable {
    public let path: String
    public let head: String?
    /// Short branch name, nil when detached or bare.
    public let branch: String?
    public let isDetached: Bool
    public let isBare: Bool
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(path: String, head: String?, branch: String?, isDetached: Bool, isBare: Bool, isLocked: Bool, isPrunable: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
        self.isBare = isBare
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// Branch header and changes from `git status --porcelain=v2 --branch`.
public struct GitStatusSnapshot: Codable, Sendable, Hashable {
    public var headOid: String?
    /// Nil when HEAD is detached.
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var changes: [RepoFileChange]

    public var stagedCount: Int { changes.filter(\.isStaged).count }
    public var unstagedCount: Int { changes.filter(\.isUnstaged).count }
    public var untrackedCount: Int { changes.filter { $0.kind == .untracked }.count }
    public var conflictedCount: Int { changes.filter { $0.kind == .unmerged }.count }
    public var isClean: Bool { changes.allSatisfy { $0.kind == .ignored } }

    public init(headOid: String? = nil, branch: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, changes: [RepoFileChange] = []) {
        self.headOid = headOid
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
    }
}

/// The state of one repository's checkout.
public struct RepoStatus: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let path: String
    public let branch: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let staged: Int
    public let unstaged: Int
    public let untracked: Int
    public let conflicted: Int
    public let isClean: Bool
    public let changes: [RepoFileChange]
    public let worktrees: [RepoWorktree]
    /// The repository's agent instructions (`AGENTS.md`), when it has one.
    /// Agents read it before working in the repository.
    public let agentsFile: String?
    /// When HEAD was last committed; nil for an empty repository.
    public let lastCommitAt: Date?
    public let error: String?

    /// One line for a sidebar row. Git's own messages run to several lines
    /// with paths and SIDs; the full text stays in `error`.
    public var errorSummary: String? {
        error.map(Self.summarize)
    }

    public static func summarize(_ error: String) -> String {
        let lower = error.lowercased()
        if lower.contains("dubious ownership") { return "Owned by another account. Git won't read it." }
        if lower.contains("not a git repository") { return "Not a Git repository." }
        if lower.contains("index.lock") { return "Another Git process holds the index lock." }
        if lower.contains("permission denied") { return "Permission denied." }
        let firstLine = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
        return firstLine
            .replacingOccurrences(of: "git status failed: ", with: "")
            .replacingOccurrences(of: "fatal: ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    public init(id: String, displayName: String, path: String, snapshot: GitStatusSnapshot?, worktrees: [RepoWorktree], agentsFile: String?, lastCommitAt: Date? = nil, error: String?) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.branch = snapshot?.branch
        self.upstream = snapshot?.upstream
        self.ahead = snapshot?.ahead ?? 0
        self.behind = snapshot?.behind ?? 0
        self.staged = snapshot?.stagedCount ?? 0
        self.unstaged = snapshot?.unstagedCount ?? 0
        self.untracked = snapshot?.untrackedCount ?? 0
        self.conflicted = snapshot?.conflictedCount ?? 0
        self.isClean = snapshot?.isClean ?? false
        self.changes = snapshot?.changes ?? []
        self.worktrees = worktrees
        self.agentsFile = agentsFile
        self.lastCommitAt = lastCommitAt
        self.error = error
    }

    /// Staged, unstaged and untracked paths together.
    public var changedCount: Int { staged + unstaged + untracked }
}

// MARK: - History, search, results

public struct RepoCommit: Codable, Sendable, Hashable {
    public let sha: String
    public let shortSha: String
    public let author: String
    public let email: String
    public let date: Date?
    public let subject: String
}

public struct RepoGrepMatch: Codable, Sendable, Hashable {
    public let path: String
    public let line: Int
    public let column: Int
    public let text: String
}

/// The outcome of one git operation on one repository, for batch commands.
public struct RepoOperationResult: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let operation: String
    public let succeeded: Bool
    public let output: String
    public let error: String?

    public init(id: String, displayName: String, operation: String, succeeded: Bool, output: String, error: String?) {
        self.id = id
        self.displayName = displayName
        self.operation = operation
        self.succeeded = succeeded
        self.output = output
        self.error = error
    }
}

// MARK: - Errors

public enum RepoError: LocalizedError, Equatable {
    case notLocal(String)
    case notAGitRepository(String)
    case protectedBranch(String)
    case pathOutsideRepository(String)
    case destinationExists(String)
    case gitFailed(command: String, message: String)
    case nothingToCommit
    case invalidArgument(String)
    /// The stash at this position is no longer the one that was chosen.
    case stashMoved(String)
    /// The app does not handle this path.
    case withheld(String)
    /// The changes include files the app does not handle.
    case withheldChanges

    public var errorDescription: String? {
        switch self {
        case .notLocal(let name):
            "\(name) has no local checkout."
        case .notAGitRepository(let path):
            "\(path) is not a git checkout."
        case .protectedBranch(let branch):
            "Refusing to commit or push on '\(branch)'. Work on a branch and open a pull request."
        case .pathOutsideRepository(let path):
            "\(path) is outside the repository."
        case .destinationExists(let path):
            "\(path) already exists."
        case .gitFailed(let command, let message):
            "git \(command) failed: \(message)"
        case .nothingToCommit:
            "Nothing to commit."
        case .invalidArgument(let message):
            message
        case .stashMoved(let name):
            "\(name) changed since it was chosen. Refresh and try again."
        case .withheld(let path):
            "This app does not handle \(path)."
        case .withheldChanges:
            "The changes include files this app withholds. Deal with them in a terminal first."
        }
    }
}
