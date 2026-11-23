import DevMateCore
import Foundation

// Adapted from MunkiStudio's IndexLockRecovery (Apache-2.0,
// Sources/App/Features/Git/IndexLockRecovery.swift). Modified from the
// original: a lock is kept when its holders cannot be determined.

/// A `.git/index.lock` left behind by a crashed or interrupted git process
/// is the most common reason staging or committing fails out of nowhere.
/// This finds the lock, says whether any process still holds it, and removes
/// it only when none does.
public enum GitIndexLock {
    /// Whether a git error is an index-lock conflict.
    public static func matches(message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("index.lock") || lower.contains("another git process")
    }

    /// The lock file of the checkout at `path`, resolving a linked worktree's
    /// `.git` file to its real git directory.
    public static func lockPath(checkout path: String) -> String {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory), !isDirectory.boolValue,
           let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
           let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            if !gitDir.hasPrefix("/") { gitDir = (path as NSString).appendingPathComponent(gitDir) }
            return (gitDir as NSString).appendingPathComponent("index.lock")
        }
        return (dotGit as NSString).appendingPathComponent("index.lock")
    }

    /// Processes that have the lock open, as `lsof` reports them; empty when
    /// none does and the lock is stale. Nil when `lsof` could not answer.
    public static func holders(of lockPath: String) async -> String? {
        guard let result = await ProcessRunner.runAsync("/usr/sbin/lsof", [lockPath], timeout: 15) else { return nil }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // lsof exits 1 with no output when nothing has the file open.
        guard result.status == 0 || (result.status == 1 && output.isEmpty) else { return nil }
        return output
    }

    /// Removes a stale lock. Refuses while a process still holds it, or when
    /// that cannot be determined.
    public static func removeStale(at lockPath: String) async throws {
        guard let holders = await holders(of: lockPath) else {
            throw RepoError.invalidArgument("Could not check whether a git process holds \(lockPath).")
        }
        guard holders.isEmpty else {
            throw RepoError.invalidArgument("A git process still holds \(lockPath):\n\(holders)")
        }
        do {
            try FileManager.default.removeItem(atPath: lockPath)
        } catch CocoaError.fileNoSuchFile {
            // Already gone: the retry can run.
        }
    }
}
