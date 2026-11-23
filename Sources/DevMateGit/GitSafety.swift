import Foundation

/// What a clone's own config may not do. A clone can come from anyone, and its
/// `.git/config` can name programs for git to run, so reads turn those off and
/// network commands ignore the ones set in the repository.
enum GitSafety {
    /// Commands that only read. They run automatically, on refresh and
    /// selection, so nothing in the clone's config may run a program.
    static let readCommands: Set<String> = [
        "status", "log", "diff", "show", "format-patch", "grep", "ls-files", "for-each-ref", "branch",
        "rev-parse", "rev-list", "show-ref", "symbolic-ref", "worktree", "config", "check-ref-format",
    ]

    static let networkCommands: Set<String> = ["fetch", "pull", "push"]

    static func isRead(_ arguments: [String]) -> Bool {
        guard let command = arguments.first else { return false }
        if command == "stash" { return arguments.dropFirst().first == "list" }
        return readCommands.contains(command)
    }

    static func isNetwork(_ arguments: [String]) -> Bool {
        networkCommands.contains(arguments.first ?? "")
    }

    /// `-c` values for a read. Signature checks are off and any signing
    /// program is replaced.
    static let readConfig: [String] = [
        "log.showSignature=false",
        "gpg.program=/usr/bin/false",
        "gpg.openpgp.program=/usr/bin/false",
        "gpg.ssh.program=/usr/bin/false",
        "gpg.x509.program=/usr/bin/false",
        "status.submoduleSummary=false",
        "protocol.allow=never",
        "core.sshCommand=/usr/bin/false",
        "credential.helper=",
    ].flatMap { ["-c", $0] }

    /// `-c` values for fetch, pull and push. The `ext::` transport runs a
    /// command named by the remote URL, and submodules bring their own config.
    static let networkConfig: [String] = [
        "protocol.ext.allow=never",
        "submodule.recurse=false",
        "fetch.recurseSubmodules=false",
        "push.recurseSubmodules=no",
    ].flatMap { ["-c", $0] }

    /// Matches what a read must switch off or check first: filter drivers,
    /// credential helpers, and the settings that mark a partial clone.
    static let readKeys = #"^(filter\..*\.(clean|smudge|process|required)|credential\.(.*\.)?helper|extensions\.partialclone|remote\..*\.promisor)$"#

    /// The environment of every read. A partial clone would otherwise fetch
    /// a missing object from its remote in the middle of a diff.
    static let readEnvironment = ["GIT_NO_LAZY_FETCH": "1", "GIT_SSH_COMMAND": "/usr/bin/false"]

    /// The first git that honours `GIT_NO_LAZY_FETCH`.
    static let lazyFetchSwitchVersion = (major: 2, minor: 45)

    /// `(2, 54)` from `git version 2.54.0 (Apple Git-157)`.
    static func parseVersion(_ text: String) -> (major: Int, minor: Int)? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3, words[0] == "git", words[1] == "version" else { return nil }
        let parts = words[2].split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        return (major, minor)
    }

    static func honoursNoLazyFetch(_ version: (major: Int, minor: Int)?) -> Bool {
        guard let version else { return false }
        return (version.major, version.minor) >= lazyFetchSwitchVersion
    }

    static func isPartialCloneKey(_ key: String) -> Bool {
        key == "extensions.partialclone" || (key.hasPrefix("remote.") && key.hasSuffix(".promisor"))
    }

    /// Everything a read overrides for the keys its config query found.
    static func readOverrides(keys: [String]) -> [(String, String)] {
        let helpers = Array(Set(keys.filter { $0.hasPrefix("credential.") })).sorted().map { ($0, "") }
        return filterOverrides(keys: keys.filter { $0.hasPrefix("filter.") }) + helpers
    }

    /// Matches the settings a network command reads to choose a program.
    static let networkKeys = #"^(core\.(sshcommand|gitproxy|alternaterefscommand)|credential\.(.*\.)?helper|remote\..*\.(uploadpack|receivepack|vcs))$"#

    /// Overrides that turn off each named filter driver. `key` arrives as
    /// `filter.<name>.<setting>`, and the name may itself hold dots.
    static func filterOverrides(keys: [String]) -> [(String, String)] {
        var names: [String] = []
        for key in keys {
            guard let dot = key.lastIndex(of: ".") else { continue }
            let driver = String(key[..<dot])
            if !names.contains(driver) { names.append(driver) }
        }
        return names.flatMap { driver in
            [("\(driver).clean", ""), ("\(driver).smudge", ""), ("\(driver).process", ""), ("\(driver).required", "false")]
        }
    }

    struct ConfigEntry: Equatable {
        let scope: String
        let key: String
        let value: String?

        var isRepositoryScoped: Bool { scope == "local" || scope == "worktree" }
    }

    /// Parses `git config --show-scope --null --get-regexp`: scope, NUL, then
    /// the key and an optional newline and value, NUL.
    static func parseScoped(_ output: String) -> [ConfigEntry] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var entries: [ConfigEntry] = []
        var index = 0
        while index + 1 < fields.count {
            let body = fields[index + 1]
            if let newline = body.firstIndex(of: "\n") {
                entries.append(ConfigEntry(scope: fields[index], key: String(body[..<newline]),
                                           value: String(body[body.index(after: newline)...])))
            } else {
                entries.append(ConfigEntry(scope: fields[index], key: body, value: nil))
            }
            index += 2
        }
        return entries
    }

    struct NetworkPlan: Equatable {
        var config: [(String, String)] = []
        var environment: [String: String] = [:]
        var overridesUploadPack = false
        var overridesReceivePack = false
        /// Why the command must not run.
        var refusal: String?

        static func == (a: NetworkPlan, b: NetworkPlan) -> Bool {
            a.config.map(\.0) == b.config.map(\.0) && a.config.map(\.1) == b.config.map(\.1)
                && a.environment == b.environment && a.overridesUploadPack == b.overridesUploadPack
                && a.overridesReceivePack == b.overridesReceivePack && a.refusal == b.refusal
        }
    }

    // MARK: Push destination

    /// What decides where a push of `branch` lands.
    struct PushInputs: Equatable {
        var branch: String
        var refspecs: [String] = []
        /// `@{push}` as a branch name on the remote, when git can resolve it.
        var pushTarget: String?
        /// `branch.<name>.merge` as a branch name.
        var upstream: String?
        var pushDefault: String?
    }

    /// Where `refspec` sends `refs/heads/<branch>`: a full ref, or nil when
    /// it does not apply to that branch.
    static func destination(of refspec: String, branch: String) -> String? {
        var spec = refspec.trimmingCharacters(in: .whitespaces)
        if spec.hasPrefix("^") { return nil }
        if spec.hasPrefix("+") { spec.removeFirst() }
        let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let source = parts[0]
        let full = "refs/heads/" + branch
        // A bare `:` is git's "matching" push: each branch to its own name.
        if source.isEmpty { return parts.count == 2 && parts[1].isEmpty ? full : nil }
        let target = parts.count == 2 ? parts[1] : source
        if source == full || source == branch || source == "HEAD" {
            return target == "HEAD" ? full : (target.hasPrefix("refs/") ? target : "refs/heads/" + target)
        }
        guard let star = source.firstIndex(of: "*") else { return nil }
        let prefix = String(source[..<star])
        let suffix = String(source[source.index(after: star)...])
        let candidate = source.hasPrefix("refs/") ? full : branch
        guard candidate.hasPrefix(prefix), candidate.hasSuffix(suffix),
              candidate.count >= prefix.count + suffix.count else { return nil }
        let middle = String(candidate.dropFirst(prefix.count).dropLast(suffix.count))
        let mapped = target.replacingOccurrences(of: "*", with: middle)
        return mapped.hasPrefix("refs/") ? mapped : "refs/heads/" + mapped
    }

    /// The one branch this push may update on the remote. Throws when config
    /// points it at a protected branch, at something that is not a branch, or
    /// at more than one place.
    static func pushDestination(_ inputs: PushInputs, protected: Set<String>) throws -> String {
        let prefix = "refs/heads/"
        let mapped = Array(Set(inputs.refspecs.compactMap { destination(of: $0, branch: inputs.branch) })).sorted()
        guard mapped.count <= 1 else {
            throw RepoError.invalidArgument("This repository's push settings send \(inputs.branch) to several places: \(mapped.joined(separator: ", ")).")
        }
        let mode = (inputs.pushDefault ?? "simple").lowercased()
        if mapped.isEmpty, mode == "nothing" {
            throw RepoError.invalidArgument("push.default is set to nothing, so \(inputs.branch) has no destination.")
        }
        let chosen: String
        if let first = mapped.first {
            guard first.hasPrefix(prefix) else {
                throw RepoError.invalidArgument("This repository's push settings send \(inputs.branch) to \(first), which is not a branch.")
            }
            chosen = String(first.dropFirst(prefix.count))
        } else if mode == "upstream" || mode == "tracking", let upstream = inputs.upstream {
            chosen = upstream
        } else {
            // `simple`, `current` and `matching` all use the branch's own
            // name. A work branch started from origin/main tracks main and
            // still pushes to its own name.
            chosen = inputs.branch
        }
        var reached = [chosen]
        if let target = inputs.pushTarget { reached.append(target) }
        let guarded = Set(protected.map { $0.lowercased() })
        if let hit = reached.first(where: { guarded.contains($0.lowercased()) }) {
            throw RepoError.protectedBranch(hit)
        }
        return chosen
    }

    /// Keeps what the person configured for their account and drops what the
    /// repository configured for itself.
    static func networkPlan(_ entries: [ConfigEntry], inherited: [String: String]) -> NetworkPlan {
        var plan = NetworkPlan()
        let local = entries.filter(\.isRepositoryScoped)

        // No setting can turn these off without breaking the command, so a
        // repository that sets one is refused.
        if let blocked = local.first(where: {
            $0.key == "core.gitproxy" || $0.key == "core.alternaterefscommand"
                || ($0.key.hasPrefix("remote.") && $0.key.hasSuffix(".vcs"))
        }) {
            plan.refusal = "This repository's config sets \(blocked.key), which can run a program. "
                + "Remove it from .git/config to use fetch, pull or push here."
            return plan
        }

        if local.contains(where: { $0.key == "core.sshcommand" }), inherited["GIT_SSH_COMMAND"] == nil {
            let own = entries.last { $0.key == "core.sshcommand" && !$0.isRepositoryScoped }?.value
            plan.environment["GIT_SSH_COMMAND"] = own ?? "ssh"
        }

        // An empty helper clears the list, then the person's own are re-added.
        let helperKeys = local.map(\.key).filter { $0.hasPrefix("credential.") && $0.hasSuffix(".helper") || $0 == "credential.helper" }
        var seen = Set<String>()
        for key in helperKeys where seen.insert(key).inserted {
            plan.config.append((key, ""))
            for entry in entries where entry.key == key && !entry.isRepositoryScoped {
                if let value = entry.value { plan.config.append((key, value)) }
            }
        }

        plan.overridesUploadPack = local.contains { $0.key.hasPrefix("remote.") && $0.key.hasSuffix(".uploadpack") }
        plan.overridesReceivePack = local.contains { $0.key.hasPrefix("remote.") && $0.key.hasSuffix(".receivepack") }
        return plan
    }

    /// Config passed through the environment, which unlike `-c` accepts any
    /// character in a key, including the `=` a filter name may hold.
    static func configEnvironment(_ pairs: [(String, String)]) -> [String: String] {
        guard !pairs.isEmpty else { return [:] }
        var environment = ["GIT_CONFIG_COUNT": String(pairs.count)]
        for (index, pair) in pairs.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = pair.0
            environment["GIT_CONFIG_VALUE_\(index)"] = pair.1
        }
        return environment
    }
}
