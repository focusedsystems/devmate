import DevMateCore
import Foundation

/// The result of running git to completion.
public struct ProcessOutput: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    /// True when git ran and exited 0. A git that never started or hit the
    /// time limit reports `exitCode == -1` with the reason in `stderr`.
    public var succeeded: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Runs git through DevMate's process runner, off the calling thread.
enum GitProcess {
    /// Long enough for a large clone's fetch or push, short enough that a hung
    /// remote cannot hold a button busy forever.
    static let timeout: TimeInterval = 900

    static func run(_ arguments: [String], environment: [String: String]) async -> ProcessOutput {
        let executable = ProcessRunner.find("git") ?? "/usr/bin/git"
        guard let result = await ProcessRunner.runAsync(executable, arguments, environment: environment, timeout: timeout) else {
            return ProcessOutput(stdout: "", stderr: "git could not start or did not finish in time.", exitCode: -1)
        }
        return ProcessOutput(stdout: result.output, stderr: result.error, exitCode: result.status)
    }
}

/// Home-folder handling for paths shown to people or read from settings.
public enum GitPaths {
    public static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    /// `path` with the home folder written as `~`.
    public static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let standard = URL(fileURLWithPath: expand(path)).standardizedFileURL.path
        if standard == home { return "~" }
        return standard.hasPrefix(home + "/") ? "~" + standard.dropFirst(home.count) : standard
    }
}
