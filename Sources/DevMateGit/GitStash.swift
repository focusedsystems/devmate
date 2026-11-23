import Foundation

/// One entry of `git stash list`.
public struct GitStash: Sendable, Hashable, Identifiable {
    /// Position in the stash list; 0 is the newest.
    public let index: Int
    public let sha: String
    public let date: Date?
    /// Git's description, such as `On main: half-done refactor`.
    public let message: String

    public var id: String { sha }
    public var name: String { "stash@{\(index)}" }

    public init(index: Int, sha: String, date: Date?, message: String) {
        self.index = index
        self.sha = sha
        self.date = date
        self.message = message
    }

    static let listFormat = "--format=%H%x00%ct%x00%gs"

    static func parse(_ output: String) -> [GitStash] {
        output.split(separator: "\n").enumerated().compactMap { index, line in
            let fields = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, !fields[0].isEmpty else { return nil }
            return GitStash(index: index, sha: fields[0],
                            date: TimeInterval(fields[1]).map(Date.init(timeIntervalSince1970:)),
                            message: fields[2])
        }
    }
}

extension GitWorkingCopy {
    public func stashes() async throws -> [GitStash] {
        GitStash.parse(try await stash(["list", GitStash.listFormat]))
    }

    /// Saves the working tree and index to a new stash. Returns false when
    /// there was nothing to save.
    @discardableResult
    public func stashPush(message: String?, includeUntracked: Bool) async throws -> Bool {
        try await refuseWithheldChanges(stagedOnly: false)
        let before = try await stashes().first?.sha
        var args = ["push"]
        if includeUntracked { args.append("--include-untracked") }
        if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            args += ["--message", message]
        }
        _ = try await stash(args)
        return try await stashes().first?.sha != before
    }

    /// Applies a stash and keeps it.
    public func stashApply(_ stash: GitStash) async throws {
        let name = try await verified(stash)
        _ = try await self.stash(["apply", "--index", name])
    }

    /// Applies a stash and removes it. Git keeps the stash when applying
    /// conflicts.
    public func stashPop(_ stash: GitStash) async throws {
        let name = try await verified(stash)
        _ = try await self.stash(["pop", "--index", name])
    }

    /// Deletes a stash. Its changes are gone from the stash list afterwards.
    public func stashDrop(_ stash: GitStash) async throws {
        let name = try await verified(stash)
        _ = try await self.stash(["drop", name])
    }

    /// Runs `git stash`. It takes no paths from here, and internally cleans
    /// with the pathspec `:/`, which literal pathspecs would turn into a file
    /// name, leaving untracked files behind after they were saved.
    private func stash(_ arguments: [String]) async throws -> String {
        let result = await git(["stash"] + arguments, extraEnvironment: ["GIT_LITERAL_PATHSPECS": "0"])
        guard result.succeeded else {
            let message = result.stderr.trimmed.isEmpty ? result.stdout.trimmed : result.stderr.trimmed
            throw RepoError.gitFailed(command: "stash", message: message)
        }
        return result.stdout
    }

    /// The stash's current name, after checking its position still holds the
    /// same commit: another stash in a terminal shifts every index, and a
    /// drop must never land on a different stash from the one chosen.
    private func verified(_ stash: GitStash) async throws -> String {
        let current = try await stashes()
        guard current.indices.contains(stash.index), current[stash.index].sha == stash.sha else {
            throw RepoError.stashMoved(stash.name)
        }
        return stash.name
    }
}
