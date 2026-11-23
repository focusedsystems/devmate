import DevMateCore
@testable import DevMateGit
import Foundation
import XCTest

final class GitWorkingCopyTests: XCTestCase {
    private var folder: URL!
    private var copy: GitWorkingCopy!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("devmate-git-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try shell("git", "init", "-q", "-b", "main")
        try shell("git", "config", "user.email", "person@example.com")
        try shell("git", "config", "user.name", "Example Person")
        try write("a.txt", "one\n")
        try shell("git", "add", "a.txt")
        try shell("git", "commit", "-q", "-m", "First")
        copy = GitWorkingCopy(path: folder.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    private func read(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: folder.appendingPathComponent(name)), as: UTF8.self)
    }

    @discardableResult
    private func shell(_ arguments: String..., in directory: URL? = nil) throws -> String {
        let result = ProcessRunner.run("/usr/bin/env", arguments, directory: directory ?? folder, timeout: 30)
        guard let result, result.status == 0 else {
            throw RepoError.gitFailed(command: arguments.joined(separator: " "), message: result?.error ?? "did not run")
        }
        return result.output
    }

    func testStatusStageAndUnstage() async throws {
        try write("a.txt", "two\n")
        try write("new.txt", "new\n")
        var status = try await copy.statusSnapshot()
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.unstagedCount, 1)
        XCTAssertEqual(status.untrackedCount, 1)

        try await copy.stage(["a.txt", "new.txt"])
        status = try await copy.statusSnapshot()
        XCTAssertEqual(status.stagedCount, 2)

        try await copy.unstage(["a.txt"])
        status = try await copy.statusSnapshot()
        XCTAssertEqual(status.stagedCount, 1)
        XCTAssertEqual(status.unstagedCount, 1)
    }

    func testCommitRefusesProtectedBranch() async throws {
        try write("a.txt", "two\n")
        try await copy.stage(["a.txt"])
        do {
            try await copy.commit(subject: "Change", body: nil, amend: false, runHooks: true, protectedBranches: ["main"])
            XCTFail("Commit on a protected branch went through")
        } catch let error as RepoError {
            XCTAssertEqual(error, .protectedBranch("main"))
        }
    }

    func testCommitOnBranchAndHistoryGraph() async throws {
        _ = try await copy.switchBranch("work", create: true)
        try write("a.txt", "two\n")
        try await copy.stage(["a.txt"])
        let commit = try await copy.commit(subject: "Second", body: "Why", amend: false, runHooks: true,
                                           protectedBranches: ["main"])
        XCTAssertEqual(commit.subject, "Second")
        let history = try await copy.history()
        XCTAssertEqual(history.map(\.subject), ["Second", "First"])
    }

    func testPushNeverForcesOverDivergedRemote() async throws {
        let remote = folder.appendingPathExtension("remote")
        defer { try? FileManager.default.removeItem(at: remote) }
        try shell("git", "init", "-q", "--bare", "-b", "main", remote.path)
        try shell("git", "remote", "add", "origin", remote.path)
        _ = try await copy.switchBranch("work", create: true)
        try write("a.txt", "two\n")
        try await copy.stage(["a.txt"])
        try await copy.commit(subject: "Second", body: nil, amend: false, runHooks: true, protectedBranches: [])
        _ = try await copy.push(protectedBranches: ["main"])
        let pushed = try shell("git", "rev-parse", "refs/heads/work", in: remote)

        try await copy.commit(subject: "Rewritten", body: nil, amend: true, runHooks: true, protectedBranches: [])
        do {
            _ = try await copy.push(protectedBranches: ["main"])
            XCTFail("A rewritten branch was pushed")
        } catch {
            let after = try shell("git", "rev-parse", "refs/heads/work", in: remote)
            XCTAssertEqual(after, pushed)
        }
    }

    func testDiscardStaysInsideTheCheckout() async throws {
        try write("a.txt", "two\n")
        try await copy.discard(["a.txt"])
        XCTAssertEqual(try read("a.txt"), "one\n")
        do {
            try await copy.discard(["../outside.txt"])
            XCTFail("A path outside the checkout was accepted")
        } catch let error as RepoError {
            XCTAssertEqual(error, .pathOutsideRepository("../outside.txt"))
        }
    }

    func testHunkStageAndReverse() async throws {
        try write("a.txt", "two\n")
        let text = try await copy.fileDiff("a.txt")
        let file = try XCTUnwrap(DiffParser.parse(text).files.first)
        let hunk = try XCTUnwrap(file.hunks.first)
        try await copy.applyPatch(file.patch(forHunk: hunk), cached: true, reverse: false)
        var status = try await copy.statusSnapshot()
        XCTAssertEqual(status.stagedCount, 1)
        try await copy.applyPatch(file.patch(forHunk: hunk), cached: true, reverse: true)
        status = try await copy.statusSnapshot()
        XCTAssertEqual(status.stagedCount, 0)
    }

    func testStashPushApplyPopAndDrop() async throws {
        let empty = try await copy.stashPush(message: "nothing", includeUntracked: false)
        XCTAssertFalse(empty)

        try write("a.txt", "two\n")
        try write("new.txt", "new\n")
        let saved = try await copy.stashPush(message: "Half done", includeUntracked: true)
        XCTAssertTrue(saved)
        XCTAssertEqual(try read("a.txt"), "one\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("new.txt").path))

        var list = try await copy.stashes()
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list[0].message.contains("Half done"))

        try await copy.stashApply(list[0])
        XCTAssertEqual(try read("a.txt"), "two\n")
        list = try await copy.stashes()
        XCTAssertEqual(list.count, 1)

        try await copy.discard(["a.txt", "new.txt"])
        try await copy.stashPop(list[0])
        XCTAssertEqual(try read("a.txt"), "two\n")
        list = try await copy.stashes()
        XCTAssertTrue(list.isEmpty)

        try await copy.stashPush(message: "To drop", includeUntracked: true)
        list = try await copy.stashes()
        try await copy.stashDrop(list[0])
        list = try await copy.stashes()
        XCTAssertTrue(list.isEmpty)
    }

    func testStashDropRefusesWhenTheListMoved() async throws {
        try write("a.txt", "two\n")
        try await copy.stashPush(message: "Chosen", includeUntracked: false)
        let chosen = try await copy.stashes()[0]
        try write("a.txt", "three\n")
        try shell("git", "stash", "push", "-q", "-m", "Newer")
        do {
            try await copy.stashDrop(chosen)
            XCTFail("Dropped a stash at a shifted position")
        } catch let error as RepoError {
            XCTAssertEqual(error, .stashMoved(chosen.name))
        }
        let count = try await copy.stashes().count
        XCTAssertEqual(count, 2)
    }

    func testStaleIndexLockIsRemovedAndHeldOneIsNot() async throws {
        let lock = GitIndexLock.lockPath(checkout: folder.path)
        FileManager.default.createFile(atPath: lock, contents: Data())
        let handle = try XCTUnwrap(FileHandle(forReadingAtPath: lock))
        do {
            try await GitIndexLock.removeStale(at: lock)
            XCTFail("Removed a lock that is held open")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: lock))
        }
        try handle.close()
        try await GitIndexLock.removeStale(at: lock)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock))
    }

    func testReadsDoNotRunRepositoryHooksOrPrograms() {
        let read = GitWorkingCopy.safetyConfig(for: ["status"])
        XCTAssertTrue(read.contains("core.hooksPath=/dev/null"))
        XCTAssertTrue(read.contains("core.fsmonitor=false"))
        let diff = GitWorkingCopy.withSafeDiffOptions(["diff", "HEAD"])
        XCTAssertEqual(Array(diff.prefix(3)), ["diff", "--no-ext-diff", "--no-textconv"])
    }

    func testStartPointCannotBeAnOption() async throws {
        do {
            _ = try await copy.switchBranch("work", create: true, startPoint: "--detach")
            XCTFail("An option was accepted as a start point")
        } catch let error as RepoError {
            guard case .invalidArgument = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Hostile repository config

    /// A script that leaves a marker file if anything ever runs it.
    private func hostileProgram() throws -> (program: String, marker: URL) {
        let outside = folder.appendingPathExtension("hostile")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let marker = outside.appendingPathComponent("marker")
        let script = outside.appendingPathComponent("evil.sh")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\ncat\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, marker)
    }

    func testAutomaticReadsNeverRunRepositoryPrograms() async throws {
        let (program, marker) = try hostileProgram()
        try write(".gitattributes", "*.txt filter=evil diff=evil\n")
        try shell("git", "add", ".gitattributes")
        try shell("git", "commit", "-q", "-m", "Attributes")
        for (key, value) in [
            ("filter.evil.clean", program), ("filter.evil.smudge", program), ("filter.evil.process", program),
            ("filter.evil.required", "true"), ("filter.dotted.name.clean", program),
            ("diff.evil.command", program), ("diff.evil.textconv", program), ("diff.external", program),
            ("core.fsmonitor", program), ("core.pager", program), ("pager.log", program),
            ("gpg.program", program), ("gpg.ssh.program", program), ("gpg.format", "openpgp"),
            ("log.showSignature", "true"), ("core.sshCommand", program), ("core.hooksPath", folder.path),
        ] {
            try shell("git", "config", key, value)
        }
        try shell("git", "-c", "filter.evil.clean=", "-c", "filter.evil.smudge=", "-c", "filter.evil.process=",
                  "-c", "filter.evil.required=false", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                  "commit", "-q", "--allow-empty", "-m", "Plain")
        // A commit carrying a signature, so a signature check would call gpg.
        let signed = try shell("/bin/sh", "-c", """
            git -c core.fsmonitor=false cat-file commit HEAD \
            | awk '/^committer/{print; print "gpgsig -----BEGIN PGP SIGNATURE-----"; print " x"; print " -----END PGP SIGNATURE-----"; next}1' \
            | git -c core.fsmonitor=false hash-object -t commit -w --stdin
            """).trimmingCharacters(in: .whitespacesAndNewlines)
        try shell("git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "update-ref", "HEAD", signed)
        try await Task.sleep(for: .milliseconds(1100))
        // The same size as before, so status has to read the content and
        // would run the clean filter.
        try write("a.txt", "two\n")
        try write("new.txt", "new\n")

        _ = try await copy.statusSnapshot()
        _ = try await copy.statusEntries()
        _ = try await copy.history()
        _ = try await copy.log()
        _ = try await copy.diff()
        _ = try await copy.fileDiff("a.txt")
        _ = try await copy.fileDiff("new.txt")
        _ = try await copy.combinedDiff("a.txt")
        _ = try await copy.show(try shell("git", "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines))
        _ = try await copy.grep("two")
        _ = try await copy.listFiles()
        _ = try await copy.stashes()
        _ = await copy.git(["format-patch", "-1", "--stdout", "HEAD"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A read ran a program from the repository's config")
    }

    func testFetchIgnoresRepositorySSHCommandAndExtTransport() async throws {
        let (program, marker) = try hostileProgram()
        try shell("git", "config", "core.sshCommand", program)
        try shell("git", "remote", "add", "origin", "ssh://127.0.0.1:1/example.git")
        _ = try? await copy.fetch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Fetch ran the repository's SSH command")

        try shell("git", "remote", "set-url", "origin", "ext::\(program)")
        _ = try? await copy.fetch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Fetch ran an ext:: remote")
    }

    func testFetchIgnoresRepositoryUploadPack() async throws {
        let (program, marker) = try hostileProgram()
        let remote = folder.appendingPathExtension("remote")
        defer { try? FileManager.default.removeItem(at: remote) }
        try shell("git", "init", "-q", "--bare", "-b", "main", remote.path)
        try shell("git", "remote", "add", "origin", remote.path)
        try shell("git", "config", "remote.origin.uploadpack", program)
        _ = try await copy.fetch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Fetch ran the repository's upload-pack")
    }

    func testNetworkRefusesARepositoryRemoteHelper() async throws {
        try shell("git", "remote", "add", "origin", "https://example.invalid/example.git")
        try shell("git", "config", "remote.origin.vcs", "evil")
        do {
            _ = try await copy.fetch()
            XCTFail("Fetch ran with a repository-set remote helper")
        } catch let error as RepoError {
            XCTAssertTrue(error.localizedDescription.contains("remote.origin.vcs"))
        }
    }

    func testNetworkPlanKeepsAccountSettingsAndDropsRepositoryOnes() {
        let entries = [
            GitSafety.ConfigEntry(scope: "global", key: "credential.helper", value: "osxkeychain"),
            GitSafety.ConfigEntry(scope: "local", key: "credential.helper", value: "!evil"),
            GitSafety.ConfigEntry(scope: "global", key: "core.sshcommand", value: "ssh -i key"),
            GitSafety.ConfigEntry(scope: "local", key: "core.sshcommand", value: "evil"),
            GitSafety.ConfigEntry(scope: "local", key: "credential.https://example.com.helper", value: "!evil"),
        ]
        let plan = GitSafety.networkPlan(entries, inherited: [:])
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.environment["GIT_SSH_COMMAND"], "ssh -i key")
        XCTAssertEqual(plan.config.map(\.0), ["credential.helper", "credential.helper", "credential.https://example.com.helper"])
        XCTAssertEqual(plan.config.map(\.1), ["", "osxkeychain", ""])
    }

    func testScopedConfigParsing() {
        let parsed = GitSafety.parseScoped("global\0credential.helper\nosxkeychain\0local\0core.sshcommand\0")
        XCTAssertEqual(parsed, [
            GitSafety.ConfigEntry(scope: "global", key: "credential.helper", value: "osxkeychain"),
            GitSafety.ConfigEntry(scope: "local", key: "core.sshcommand", value: nil),
        ])
    }

    // MARK: Symlinks

    private func outsideTarget() throws -> URL {
        let target = folder.appendingPathExtension("target")
        try Data("keep\n".utf8).write(to: target)
        addTeardownBlock { try? FileManager.default.removeItem(at: target) }
        return target
    }

    func testDiscardOfUntrackedSymlinkLeavesItsTarget() async throws {
        let target = try outsideTarget()
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try await copy.discard(["link"])
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), "keep\n")
    }

    func testDiscardOfTrackedSymlinkRestoresTheLinkAndLeavesItsTarget() async throws {
        let target = try outsideTarget()
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try shell("git", "add", "link")
        try shell("git", "commit", "-q", "-m", "Link")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "a.txt")
        try await copy.discard(["link"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), "keep\n")
        XCTAssertEqual(try read("a.txt"), "one\n")
    }

    func testEntryPathRefusesAParentThatLeavesTheCheckout() throws {
        let outside = folder.appendingPathExtension("dir")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("out"), withDestinationURL: outside)
        XCTAssertThrowsError(try copy.entryPath("out/file.txt"))
        XCTAssertThrowsError(try copy.entryPath(".GIT/config"))
        XCTAssertEqual(try copy.entryPath("out"), "out")
    }

    // MARK: Partial clones

    func testReadsNeverLazyFetchInAPartialClone() async throws {
        let (program, marker) = try hostileProgram()
        let remote = folder.appendingPathExtension("partial-remote")
        let clone = folder.appendingPathExtension("partial")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: clone)
        }
        try shell("git", "clone", "-q", "--bare", folder.path, remote.path)
        try shell("git", "config", "uploadpack.allowFilter", "true", in: remote)
        try shell("git", "-c", "protocol.file.allow=always", "clone", "-q", "--no-checkout", "--filter=blob:none",
                  "file://" + remote.path, clone.path)
        try shell("git", "config", "remote.origin.uploadpack", program, in: clone)
        try shell("git", "config", "core.sshCommand", program, in: clone)
        try shell("git", "config", "credential.helper", "!" + program, in: clone)

        let partial = GitWorkingCopy(path: clone.path)
        let head = try shell("git", "rev-parse", "HEAD", in: clone).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try? await partial.show(head)
        _ = try? await partial.log()
        _ = await partial.git(["format-patch", "-1", "--stdout", head])
        _ = await partial.git(["diff", "HEAD"])
        _ = await partial.git(["grep", "one", head])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A read contacted the partial clone's remote")
    }

    func testVersionParsingAndTheLazyFetchThreshold() {
        XCTAssertTrue(GitSafety.honoursNoLazyFetch(GitSafety.parseVersion("git version 2.54.0 (Apple Git-157)")))
        XCTAssertTrue(GitSafety.honoursNoLazyFetch(GitSafety.parseVersion("git version 2.45.0")))
        XCTAssertFalse(GitSafety.honoursNoLazyFetch(GitSafety.parseVersion("git version 2.44.9")))
        XCTAssertFalse(GitSafety.honoursNoLazyFetch(GitSafety.parseVersion("not git")))
    }

    func testReadOverridesCoverURLScopedHelpers() {
        let overrides = GitSafety.readOverrides(keys: ["credential.https://example.com.helper", "filter.a.clean"])
        XCTAssertTrue(overrides.contains { $0.0 == "credential.https://example.com.helper" && $0.1.isEmpty })
        XCTAssertTrue(overrides.contains { $0.0 == "filter.a.process" && $0.1.isEmpty })
    }

    // MARK: Push destination

    private func makeRemoteWithMain() throws -> URL {
        let remote = folder.appendingPathExtension("push-remote")
        addTeardownBlock { try? FileManager.default.removeItem(at: remote) }
        try shell("git", "init", "-q", "--bare", "-b", "main", remote.path)
        try shell("git", "remote", "add", "origin", remote.path)
        try shell("git", "push", "-q", "origin", "main")
        return remote
    }

    private func commitOnWork() async throws {
        _ = try await copy.switchBranch("work", create: true)
        try write("a.txt", "two\n")
        try await copy.stage(["a.txt"])
        try await copy.commit(subject: "Second", body: nil, amend: false, runHooks: true, protectedBranches: ["main"])
    }

    func testPushRefusesARefspecThatTargetsAProtectedBranch() async throws {
        let remote = try makeRemoteWithMain()
        let before = try shell("git", "rev-parse", "refs/heads/main", in: remote)
        try await commitOnWork()
        try shell("git", "config", "remote.origin.push", "+refs/heads/work:refs/heads/main")
        do {
            _ = try await copy.push(protectedBranches: ["main"])
            XCTFail("A refspec pushed to a protected branch")
        } catch let error as RepoError {
            XCTAssertEqual(error, .protectedBranch("main"))
        }
        let after = try shell("git", "rev-parse", "refs/heads/main", in: remote)
        XCTAssertEqual(after, before)
    }

    func testPushRefusesAnUpstreamModeThatTargetsAProtectedBranch() async throws {
        let remote = try makeRemoteWithMain()
        let before = try shell("git", "rev-parse", "refs/heads/main", in: remote)
        try await commitOnWork()
        try shell("git", "config", "branch.work.remote", "origin")
        try shell("git", "config", "branch.work.merge", "refs/heads/main")
        try shell("git", "config", "push.default", "upstream")
        do {
            _ = try await copy.push(protectedBranches: ["main"])
            XCTFail("An upstream push reached a protected branch")
        } catch let error as RepoError {
            XCTAssertEqual(error, .protectedBranch("main"))
        }
        let after = try shell("git", "rev-parse", "refs/heads/main", in: remote)
        XCTAssertEqual(after, before)
    }

    func testAWorkBranchTrackingMainPushesToItsOwnName() async throws {
        let remote = try makeRemoteWithMain()
        let before = try shell("git", "rev-parse", "refs/heads/main", in: remote)
        try await commitOnWork()
        try shell("git", "config", "branch.work.remote", "origin")
        try shell("git", "config", "branch.work.merge", "refs/heads/main")
        _ = try await copy.push(protectedBranches: ["main"])
        let main = try shell("git", "rev-parse", "refs/heads/main", in: remote)
        XCTAssertEqual(main, before)
        let work = try shell("git", "rev-parse", "refs/heads/work", in: remote)
        let local = try shell("git", "rev-parse", "HEAD")
        XCTAssertEqual(work, local)
    }

    func testPushSendsOnlyTheOneBranch() async throws {
        let remote = try makeRemoteWithMain()
        try shell("git", "branch", "other")
        try shell("git", "tag", "-a", "v1", "-m", "Tag")
        try shell("git", "config", "push.followTags", "true")
        try await commitOnWork()
        _ = try await copy.push(protectedBranches: ["main"])
        let refs = try shell("git", "for-each-ref", "--format=%(refname)", in: remote)
        XCTAssertEqual(refs.split(separator: "\n").map(String.init), ["refs/heads/main", "refs/heads/work"])
    }

    func testRefspecDestinations() {
        XCTAssertEqual(GitSafety.destination(of: "refs/heads/*:refs/heads/team/*", branch: "work"), "refs/heads/team/work")
        XCTAssertEqual(GitSafety.destination(of: "+work:main", branch: "work"), "refs/heads/main")
        XCTAssertEqual(GitSafety.destination(of: "HEAD:refs/heads/main", branch: "work"), "refs/heads/main")
        XCTAssertEqual(GitSafety.destination(of: ":", branch: "work"), "refs/heads/work")
        XCTAssertNil(GitSafety.destination(of: "other:main", branch: "work"))
        XCTAssertNil(GitSafety.destination(of: "^refs/heads/work", branch: "work"))
        XCTAssertThrowsError(try GitSafety.pushDestination(
            .init(branch: "work", refspecs: ["work:a", "refs/heads/*:refs/heads/b/*"]), protected: []))
        XCTAssertThrowsError(try GitSafety.pushDestination(.init(branch: "work", refspecs: ["work:refs/tags/x"]), protected: []))
        XCTAssertThrowsError(try GitSafety.pushDestination(.init(branch: "work", refspecs: ["work:MAIN"]), protected: ["main"]))
    }

    // MARK: Withheld paths

    private let policy = WithheldPaths(folderNames: ["private-data"])

    private func put(_ relative: String, _ text: String) throws {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func commitAll(_ message: String) throws -> String {
        try shell("git", "add", "-A")
        try shell("git", "commit", "-q", "-m", message)
        return try shell("git", "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var guarded: GitWorkingCopy { GitWorkingCopy(path: folder.path, withheld: policy) }

    func testReadsExcludeWithheldPathsAtTheSource() async throws {
        try put("private-data/a.csv", "needle secret\n")
        try put("nested/Private-Data/b.csv", "needle secret\n")
        try put("src/app.txt", "needle public\n")
        let sha = try commitAll("Add files")
        try put("private-data/a.csv", "changed secret\n")
        try put("src/app.txt", "changed public\n")

        let copy = guarded
        let shown = try await copy.show(sha)
        XCTAssertTrue(shown.contains("src/app.txt"))
        XCTAssertFalse(shown.lowercased().contains("private-data"))
        XCTAssertFalse(shown.contains("secret"))
        let diff = try await copy.diff()
        XCTAssertFalse(diff.contains("secret"))
        let status = try await copy.statusSnapshot()
        XCTAssertEqual(status.changes.map(\.path), ["src/app.txt"])
        let files = try await copy.listFiles()
        XCTAssertFalse(files.contains { $0.lowercased().contains("private-data") })
        let found = try await copy.grep("needle")
        XCTAssertEqual(found.map(\.path), [])
        let patch = try await copy.emailPatch(sha)
        XCTAssertTrue(patch.contains("Add files"))
        XCTAssertFalse(patch.contains("secret"))
        let count = try await copy.withheldChangeCount()
        XCTAssertEqual(count, 1)
    }

    func testAMergeCommitShowsNoWithheldContent() async throws {
        try put("private-data/a.csv", "base\n")
        _ = try commitAll("Base")
        try shell("git", "switch", "-q", "-c", "side")
        try put("private-data/a.csv", "side secret\n")
        try put("side.txt", "side\n")
        _ = try commitAll("Side")
        try shell("git", "switch", "-q", "main")
        try put("private-data/a.csv", "main secret\n")
        _ = try commitAll("Main")
        _ = try? shell("git", "merge", "-q", "--no-edit", "side")
        try put("private-data/a.csv", "merged secret\n")
        let merge = try commitAll("Merge")
        let shown = try await guarded.show(merge)
        XCTAssertFalse(shown.contains("secret"))
        XCTAssertFalse(shown.contains("private-data"))
        XCTAssertTrue(shown.contains("side.txt"))
    }

    func testRenamesIntoAndOutOfAWithheldFolder() async throws {
        try put("public.txt", "shared line\nanother line\n")
        try put("private-data/old.csv", "moved out\nsecond line\n")
        _ = try commitAll("Base")
        try shell("git", "mv", "public.txt", "private-data/moved-in.csv")
        try shell("git", "mv", "private-data/old.csv", "moved-out.txt")
        let sha = try commitAll("Move")
        let shown = try await guarded.show(sha)
        XCTAssertFalse(shown.contains("private-data"))
        XCTAssertFalse(shown.contains("moved-in"))
    }

    func testStatisticsLeaveOutWithheldPaths() async throws {
        try put("private-data/a.csv", "one\ntwo\n")
        try put("src/app.txt", "one\n")
        _ = try commitAll("Mixed")
        try put("private-data/b.csv", "only private\n")
        _ = try commitAll("Only private")

        let commits = try await guarded.churnLog()
        let paths = commits.flatMap(\.files).map(\.path)
        XCTAssertTrue(paths.contains("src/app.txt"))
        XCTAssertFalse(paths.contains { $0.contains("private-data") })

        let checkout = GitCheckout(id: "example/app", displayName: "app", path: folder.path, withheld: policy)
        let summary = await RepoStatsSummary.load([checkout], since: nil)
        let listed = (summary.combined.files + summary.combined.areas).map(\.path)
        XCTAssertFalse(listed.contains { $0.contains("private-data") })
        XCTAssertTrue(summary.combined.files.map(\.path).contains("src/app.txt"))
        // The first commit and "Mixed"; "Only private" is not counted.
        XCTAssertEqual(summary.combined.totals.commits, 2)
    }

    func testActionsRefuseAWithheldPath() async throws {
        try put("private-data/a.csv", "secret\n")
        let copy = guarded
        for action: () async throws -> Void in [
            { try await copy.stage(["private-data/a.csv"]) },
            { try await copy.discard(["private-data/a.csv"]) },
            { _ = try await copy.fileDiff("private-data/a.csv") },
            { _ = try await copy.combinedDiff("PRIVATE-DATA/a.csv") },
            { _ = try copy.readFile("private-data/a.csv") },
            { try await copy.stashPush(message: nil, includeUntracked: true) },
        ] {
            do {
                try await action()
                XCTFail("A withheld path was acted on")
            } catch let error as RepoError {
                switch error {
                case .withheld, .withheldChanges: break
                default: XCTFail("\(error)")
                }
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("private-data/a.csv").path))
    }

    func testCommitRefusesAStagedWithheldFile() async throws {
        _ = try await copy.switchBranch("work", create: true)
        try put("private-data/a.csv", "secret\n")
        try shell("git", "add", "private-data/a.csv")
        let before = try shell("git", "rev-parse", "HEAD")
        do {
            try await guarded.commit(subject: "Add", body: nil, amend: false, runHooks: true, protectedBranches: [])
            XCTFail("A withheld file was committed")
        } catch let error as RepoError {
            XCTAssertEqual(error, .withheldChanges)
        }
        do {
            try await guarded.commit(subject: "Amend", body: nil, amend: true, runHooks: true, protectedBranches: [])
            XCTFail("An amend took in a withheld file")
        } catch let error as RepoError {
            XCTAssertEqual(error, .withheldChanges)
        }
        do {
            try await guarded.commit(message: "All", protectedBranches: [])
            XCTFail("A commit of everything took in a withheld file")
        } catch let error as RepoError {
            XCTAssertEqual(error, .withheldChanges)
        }
        do {
            try await guarded.commitStaged(message: "Staged", protectedBranches: [])
            XCTFail("A staged commit took in a withheld file")
        } catch let error as RepoError {
            XCTAssertEqual(error, .withheldChanges)
        }
        let after = try shell("git", "rev-parse", "HEAD")
        XCTAssertEqual(after, before)
    }

    func testASymlinkIntoAWithheldFolderIsWithheld() throws {
        try put("private-data/a.csv", "secret\n")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.csv"),
                                                   withDestinationURL: folder.appendingPathComponent("private-data/a.csv"))
        XCTAssertTrue(guarded.isWithheld("link.csv"))
        XCTAssertThrowsError(try guarded.readFile("link.csv"))
    }

    func testChurnRunsAsARead() {
        XCTAssertTrue(GitSafety.isRead(["log", "--numstat"]))
    }

    // MARK: Diffs from a host

    private func section(_ path: String) -> String {
        "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -1 +1 @@\n-old\n+new\n"
    }

    func testHostDiffDropsAWithheldFileAndKeepsTheRest() {
        let text = section("private-data/a.csv") + section("src/app.txt")
        let result = WithheldDiff.filter(text, withheld: policy)
        XCTAssertFalse(result.isWithheldEntirely)
        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertFalse(result.text.contains("private-data"))
        XCTAssertTrue(result.text.contains("src/app.txt"))
    }

    func testHostDiffDecodesQuotedAndNonASCIIPaths() {
        let quoted = "diff --git \"a/private-data/caf\\303\\251.csv\" \"b/private-data/caf\\303\\251.csv\"\n--- \"a/private-data/caf\\303\\251.csv\"\n+++ \"b/private-data/caf\\303\\251.csv\"\n@@ -1 +1 @@\n-old\n+new\n"
        let tabbed = "diff --git \"a/x\\tprivate-data/y.csv\" \"b/private-data/y.csv\"\nnew file mode 100644\n"
        let escapedFolder = "diff --git \"a/private\\055data/a.csv\" \"b/private\\055data/a.csv\"\nBinary files differ\n"
        let plain = section("private-data/caf\u{E9}.csv")
        for text in [quoted, tabbed, escapedFolder, plain] {
            let result = WithheldDiff.filter(text, withheld: policy)
            XCTAssertFalse(result.isWithheldEntirely, text)
            XCTAssertEqual(result.removedFiles, 1, text)
        }
        XCTAssertEqual(WithheldDiff.quotedPrefix("\"a\\\"b\\\\c\\n\"")?.0, "a\"b\\c\n")
    }

    func testHostDiffChecksBothSidesOfARename() {
        let into = "diff --git a/public.txt b/private-data/a.csv\nsimilarity index 100%\nrename from public.txt\nrename to private-data/a.csv\n"
        let outOf = "diff --git a/private-data/a.csv b/public.txt\nsimilarity index 100%\nrename from private-data/a.csv\nrename to public.txt\n"
        for text in [into, outOf] {
            XCTAssertEqual(WithheldDiff.filter(text, withheld: policy).removedFiles, 1, text)
        }
    }

    func testHostDiffCoversCombinedHeaders() {
        for header in ["diff --cc private-data/a.csv", "diff --combined private-data/a.csv"] {
            let text = header + "\nindex 1,2..3\n--- a/private-data/a.csv\n+++ b/private-data/a.csv\n@@@ -1,1 -1,1 +1,1 @@@\n"
            XCTAssertEqual(WithheldDiff.filter(text, withheld: policy).removedFiles, 1, header)
        }
    }

    func testAnUnreadableHeaderWithholdsTheWholeDiff() {
        let unreadable = [
            "diff --git \"a/private\\9data/a.csv\" \"b/x\"\n",
            "diff --git \"a/unterminated b/x\n",
            "diff --git \"a/bad\\377.csv\" \"b/bad\\377.csv\"\n",
            "diff --git a/one two b/three\n",
            "diff --unknown private-data/a.csv\n",
            "diff --git a/x b/x\n--- nonsense\n+++ b/x\n",
            "preamble that is not a diff\n" + "diff --git a/x b/x\n--- a/x\n+++ b/x\n",
        ]
        for text in unreadable + [section("src/app.txt") + unreadable[0]] {
            let result = WithheldDiff.filter(text, withheld: policy)
            XCTAssertTrue(result.isWithheldEntirely, text)
            XCTAssertEqual(result.text, "", text)
        }
    }

    func testNoPolicyLeavesADiffUntouched() {
        let text = "diff --unknown anything\n"
        XCTAssertEqual(WithheldDiff.filter(text, withheld: .none).text, text)
    }
}
