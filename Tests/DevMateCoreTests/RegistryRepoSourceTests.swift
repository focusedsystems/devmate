import Foundation
import XCTest
@testable import DevMateCore

final class RegistryRepoSourceTests: XCTestCase {
    private let bundleID = "com.example.devmate-sample"
    private let fallback = RepoCatalog(sections: [
        RepoSection(name: "Built in", repos: [
            DevRepo(id: "fallback/one", name: "one", path: "/tmp/one", provider: .github),
        ]),
    ])
    private var root: URL!
    private var registry: URL { root.appendingPathComponent("registry", isDirectory: true) }
    private var cacheFile: URL { root.appendingPathComponent("cache/last-good.json") }
    private var file: URL { registry.appendingPathComponent(bundleID + ".json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/registry/v1/\(name)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func source() -> RegistryRepoSource {
        RegistryRepoSource(bundleID: bundleID, fallback: fallback, directory: registry, lastGoodFile: cacheFile)
    }

    private func install(_ name: String) throws {
        try fixture(name).write(to: file)
    }

    func testMissingFileUsesTheFallbackWithNoBanner() {
        let result = source().reload()
        XCTAssertEqual(result.catalog, fallback)
        XCTAssertEqual(result.state, .fallback)
        XCTAssertNil(result.state.banner)
    }

    func testValidFileIsRead() throws {
        try install("valid")
        let result = source().reload()
        XCTAssertEqual(result.state, .registry)
        XCTAssertNil(result.state.banner)
        XCTAssertEqual(result.catalog.repos.map(\.name), ["widget", "service", "notes"])
        XCTAssertEqual(result.catalog.sections.map(\.name), ["Apps", "Folders"])
        XCTAssertEqual(result.catalog.settings.gitHubOwners, ["example"])
        let widget = result.catalog.repos[0]
        XCTAssertEqual(widget.provider, .github)
        XCTAssertTrue(widget.fork)
        XCTAssertEqual(widget.upstream, "example-upstream/widget")
        XCTAssertEqual(result.catalog.repos[1].provider, .azureDevOps)
        XCTAssertFalse(result.catalog.repos[1].surfaces.projects)
        XCTAssertEqual(result.catalog.repos[2].kind, .folder)
        XCTAssertNil(result.catalog.repos[2].remote)
    }

    func testUnusableFilesKeepTheLastGoodListAndShowABanner() throws {
        let cases: [(String, RegistryProblem)] = [
            ("malformed", .malformed),
            ("newer-schema", .newerSchema(found: 2)),
            ("unknown-old-schema", .unknownSchema(found: 0)),
            ("wrong-app", .wrongApp(found: "com.example.other-app")),
            ("unknown-provider", .malformed),
            ("duplicate-id", .malformed),
            ("missing-field", .malformed),
        ]
        for (name, problem) in cases {
            try install("valid")
            let reader = source()
            let good = reader.reload().catalog
            try install(name)
            let result = reader.reload()
            XCTAssertEqual(result.catalog, good, name)
            XCTAssertEqual(result.state, .keptLastGood(problem), name)
            XCTAssertNotNil(result.state.banner, name)
        }
    }

    func testBadFileWithNoEarlierListUsesTheFallbackWithABanner() throws {
        try install("newer-schema")
        let result = source().reload()
        XCTAssertEqual(result.catalog, fallback)
        XCTAssertEqual(result.state, .fallbackAfterProblem(.newerSchema(found: 2)))
        XCTAssertNotNil(result.state.banner)
    }

    func testLastGoodListSurvivesARelaunch() throws {
        try install("valid")
        let good = source().reload().catalog
        try install("malformed")
        let relaunched = source().reload()
        XCTAssertEqual(relaunched.catalog, good)
        XCTAssertEqual(relaunched.state, .keptLastGood(.malformed))
    }

    func testLastGoodCopyIsPrivate() throws {
        try install("valid")
        source().reload()
        let attributes = try FileManager.default.attributesOfItem(atPath: cacheFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testNeverWritesTheRegistryFile() throws {
        try install("valid")
        let before = try Data(contentsOf: file)
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let reader = RegistryRepoSource(bundleID: bundleID, fallback: fallback, directory: registry, lastGoodFile: file)
        reader.reload()
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, modified)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: registry.path), [bundleID + ".json"])
    }

    private func editedValid(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("valid")) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testEmptyListNeverReplacesTheLastGoodOne() throws {
        try install("valid")
        let reader = source()
        let good = reader.reload().catalog
        let saved = try Data(contentsOf: cacheFile)
        let emptySections = try editedValid { $0["sections"] = [] }
        let emptyRepos = try editedValid { $0["sections"] = [["name": "Apps", "repos": []]] }
        for data in [emptySections, emptyRepos] {
            try data.write(to: file)
            let result = reader.reload()
            XCTAssertEqual(result.catalog, good)
            XCTAssertEqual(result.state, .keptLastGood(.emptyList))
            XCTAssertEqual(try Data(contentsOf: cacheFile), saved)
        }
    }

    func testBlankRepoFieldsAreMalformed() throws {
        for field in ["id", "name", "path"] {
            let data = try editedValid { object in
                var sections = object["sections"] as! [[String: Any]]
                var repos = sections[0]["repos"] as! [[String: Any]]
                repos[0][field] = "  "
                sections[0]["repos"] = repos
                object["sections"] = sections
            }
            try data.write(to: file)
            XCTAssertEqual(source().reload().state, .fallbackAfterProblem(.malformed), field)
        }
    }

    func testLastGoodFileCannotBeTheRegistryByCaseOrHardLink() throws {
        try install("valid")
        let before = try Data(contentsOf: file)
        let upper = registry.appendingPathComponent(bundleID.uppercased() + ".json")
        XCTAssertTrue(RegistryRepoSource.isSameFile(upper, file))
        RegistryRepoSource(bundleID: bundleID, fallback: fallback, directory: registry, lastGoodFile: upper).reload()
        XCTAssertEqual(try Data(contentsOf: file), before)
        let link = root.appendingPathComponent("hard-link.json")
        try FileManager.default.linkItem(at: file, to: link)
        XCTAssertTrue(RegistryRepoSource.isSameFile(link, file))
        XCTAssertFalse(RegistryRepoSource.isSameFile(cacheFile, file))
    }

    func testRecoversWhenTheFileIsFixed() throws {
        try install("malformed")
        let reader = source()
        XCTAssertEqual(reader.reload().state, .fallbackAfterProblem(.malformed))
        try install("valid")
        XCTAssertEqual(reader.reload().state, .registry)
    }

    func testBundleIDCannotLeaveTheDirectory() {
        let reader = RegistryRepoSource(bundleID: "../escape", fallback: fallback, directory: registry,
                                        usesDefaultLastGoodFile: false)
        XCTAssertEqual(reader.reload().state, .fallbackAfterProblem(.unreadable))
    }
}
