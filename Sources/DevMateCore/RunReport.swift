import Foundation

/// A pipeline run's log as it is copied or handed to an agent. It carries
/// only what the run and its log show; the provider's masking is kept.
public enum RunReport {
    /// How many lines of a log an agent prompt carries.
    public static let excerptLines = 200

    /// A line naming the run: pipeline, run, repository, branch and result.
    public static func header(_ run: DevPipelineRun) -> String {
        var parts = ["Pipeline: \(run.pipeline)", "Run: \(run.title) (#\(run.runID))", "Repository: \(run.repo)"]
        if let branch = run.branch { parts.append("Branch: \(branch)") }
        parts.append("Result: \(run.state.rawValue)")
        return parts.joined(separator: " | ")
    }

    /// The header line, then the whole log.
    public static func copy(_ run: DevPipelineRun, log: String) -> String {
        header(run) + "\n\n" + log
    }

    /// At most `limit` lines, around the last error line, else the tail.
    public static func excerpt(_ text: String, limit: Int = excerptLines) -> (text: String, trimmed: Bool) {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > limit else { return (text, false) }
        let error = lines.lastIndex { $0.contains("##[error]") || $0.range(of: "error", options: .caseInsensitive) != nil }
        let end = min(lines.count, (error ?? lines.count - 1) + 1 + 20)
        return (lines[max(0, end - limit)..<end].joined(separator: "\n"), true)
    }

    /// A short prompt: what ended how, the run's link, and the log cut down
    /// by ``excerpt(_:limit:)``. `fullLog` says where the whole text is.
    public static func prompt(_ run: DevPipelineRun, log: String, fullLog: String?) -> String {
        let cut = excerpt(log)
        var out = "Pipeline run \(run.pipeline) “\(run.title)” ended \(run.state.rawValue.lowercased())."
        out += " Find the cause and propose a fix.\n\n" + header(run) + "\nRun: \(run.url)\n"
        if cut.trimmed { out += "(last \(excerptLines) lines around the error)\n" }
        out += "```\n" + cut.text + "\n```\n"
        if let fullLog { out += "\nThe full log is in \(fullLog)." }
        return out
    }

    /// The full text in a file only this user can read, under the temporary
    /// folder, or nil when it could not be written.
    public static func writeFullLog(_ text: String, runID: Int) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("devmate-pipeline-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("run-\(runID)-\(UUID().uuidString.prefix(8)).log")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return nil }
        return file.path
    }
}
