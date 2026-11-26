import Foundation

/// Runs a command to completion, with a time limit. Nothing here goes
/// through a shell: arguments reach the program exactly as given.
public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        public var error: String

        public init(status: Int32, output: String, error: String = "") {
            self.status = status
            self.output = output
            self.error = error
        }
    }

    private static let searchFolders = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
    ]

    /// The full path of a program in the usual install folders. An app's own
    /// PATH is bare when launchd starts it.
    public static func find(_ program: String) -> String? {
        searchFolders.map { $0 + "/" + program }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Holds what the stderr reader collected until the group is done.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Runs the program and waits for it. Returns nil when it could not be
    /// started or was stopped at the time limit. With `outputLimit`, only the
    /// last that many bytes of its output are kept.
    public static func run(_ executable: String, _ arguments: [String], directory: URL? = nil,
                           environment extra: [String: String] = [:], timeout: TimeInterval,
                           outputLimit: Int? = nil) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        environment["PATH"] = (searchFolders + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        // Reading to the end does not close these. A poller would otherwise
        // run a GUI app out of file descriptors.
        defer {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Drain stderr beside stdout, so a chatty program never blocks on a
        // full pipe.
        let errorData = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let output: String
        if let outputLimit {
            // Read in pieces and keep only the tail, so a very large answer
            // never sits whole in memory.
            var tail = TailBuffer(limit: outputLimit)
            while true {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                tail.append(contentsOf: chunk)
            }
            output = tail.text
        } else {
            output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        group.wait()
        process.waitUntilExit()
        timer.cancel()
        if process.terminationReason == .uncaughtSignal { return nil }
        return Result(status: process.terminationStatus,
                      output: output,
                      error: String(decoding: errorData.data, as: UTF8.self))
    }

    /// `run` off the calling thread.
    public static func runAsync(_ executable: String, _ arguments: [String], directory: URL? = nil,
                                environment: [String: String] = [:], timeout: TimeInterval) async -> Result? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(executable, arguments, directory: directory, environment: environment,
                                                    timeout: timeout))
            }
        }
    }
}
