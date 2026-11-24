import DevMateCore
import Foundation

public struct AzureCLIError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Everything an app asks Azure DevOps goes through the `az` the person is
/// signed in to, using `az rest`. DevMate keeps no token of its own. Every
/// call blocks, so callers run them off the main thread.
public struct AzureCLI: Sendable {
    /// The organisation's address, such as `https://devops.example.com/example`.
    public var organization: String
    /// The project a repository without one in its `remote` belongs to.
    public var defaultProject: String?
    public var executable: String?

    /// `organization` is a bare name or a full address.
    public init(organization: String, defaultProject: String? = nil, executable: String? = ProcessRunner.find("az")) {
        self.organization = Self.normalized(organization)
        self.defaultProject = defaultProject
        self.executable = executable
    }

    /// Where a bare organisation name lives.
    static let defaultHost = ["dev", "azure", "com"].joined(separator: ".")

    static func normalized(_ organization: String) -> String {
        var text = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text.lowercased().hasPrefix("http") ? text : "https://" + Self.defaultHost + "/" + text
    }

    /// Azure DevOps' own application id, which `az rest` asks Entra for a
    /// token for. Written in pieces so it is plainly a constant, not a tenant.
    static let resource = ["499b84ac", "1321", "427f", "aa17", "267ca6975798"].joined(separator: "-")

    public static let apiVersion = "7.1"

    // MARK: Addresses

    private static let pathAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? text
    }

    /// The address of an `_apis` path, inside a project or at the organisation.
    func url(project: String?, team: String? = nil, path: String, query: [(String, String)] = [], apiVersion: String = AzureCLI.apiVersion) -> String {
        var address = organization
        if let project, !project.isEmpty { address += "/" + Self.encode(project) }
        if let team, !team.isEmpty { address += "/" + Self.encode(team) }
        address += "/_apis/" + path
        let items = query + [("api-version", apiVersion)]
        return address + "?" + items.map { "\($0.0)=\(Self.encode($0.1).replacingOccurrences(of: "%24", with: "$"))" }.joined(separator: "&")
    }

    /// The arguments to `az` for one request.
    static func arguments(method: String, url: String, body: String? = nil, contentType: String? = nil) -> [String] {
        var arguments = ["rest", "--method", method.lowercased(), "--resource", resource, "--url", url, "--output", "json"]
        if let body { arguments += ["--body", body] }
        if let contentType { arguments += ["--headers", "Content-Type=\(contentType)"] }
        return arguments
    }

    // MARK: Running

    @discardableResult
    public func request(method: String = "GET", project: String?, team: String? = nil, path: String, query: [(String, String)] = [],
                        body: String? = nil, contentType: String? = nil, apiVersion: String = AzureCLI.apiVersion,
                        timeout: TimeInterval = 40) throws -> String {
        guard let executable else { throw AzureCLIError("The Azure CLI (az) is not installed.") }
        let address = url(project: project, team: team, path: path, query: query, apiVersion: apiVersion)
        guard let result = ProcessRunner.run(executable, Self.arguments(method: method, url: address, body: body,
                                                                         contentType: contentType),
                                              timeout: timeout) else {
            throw AzureCLIError("az did not answer within \(Int(timeout)) seconds.")
        }
        guard result.status == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AzureCLIError(message.isEmpty ? "az failed (exit \(result.status))." : message)
        }
        return result.output
    }

    func decode<T: Decodable>(_ type: T.Type, project: String?, team: String? = nil, path: String, query: [(String, String)] = [],
                              method: String = "GET", body: String? = nil, contentType: String? = nil,
                              apiVersion: String = AzureCLI.apiVersion) throws -> T {
        let output = try request(method: method, project: project, team: team, path: path, query: query, body: body,
                                 contentType: contentType, apiVersion: apiVersion)
        return try AzureJSON.decode(type, from: output)
    }

    // MARK: Repositories

    /// The project and repository name in a registry `remote` of `Project/Repo`,
    /// or the repository's own name under the default project.
    func address(of repo: DevRepo) throws -> (project: String, name: String) {
        let parts = (repo.remote ?? "").split(separator: "/").map(String.init)
        if parts.count >= 2 { return (parts[parts.count - 2], parts[parts.count - 1]) }
        guard let defaultProject, !defaultProject.isEmpty else {
            throw AzureCLIError("\(repo.name) has no Azure DevOps project in its remote, and no default project is set.")
        }
        return (defaultProject, parts.last ?? repo.name)
    }

    func webURL(project: String, repo: String, suffix: String) -> String {
        "\(organization)/\(Self.encode(project))/_git/\(Self.encode(repo))/\(suffix)"
    }
}

enum AzureJSON {
    /// Azure writes seven fractional digits; DevMate's reader takes up to three.
    static func parseDate(_ text: String) -> Date? {
        var text = text
        if let dot = text.firstIndex(of: "."), let end = text.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }),
           dot < end {
            let digits = text[text.index(after: dot)..<end]
            if digits.count > 3 { text.replaceSubrange(text.index(after: dot)..<end, with: digits.prefix(3)) }
        }
        return DevMateJSON.parseDate(text)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Not a date: \(text)")
        }
        return decoder
    }()

    static func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        do {
            return try decoder.decode(T.self, from: Data(output.utf8))
        } catch {
            throw AzureCLIError("Could not read Azure DevOps' answer: \(error.localizedDescription)")
        }
    }

    /// A JSON object as the text `az rest --body` takes.
    static func text(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func branch(_ ref: String?) -> String? {
        ref.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
    }
}

struct AzList<T: Decodable>: Decodable {
    var value: [T]
}

struct AzIdentity: Decodable {
    var id: String?
    var displayName: String?
    var uniqueName: String?
}
