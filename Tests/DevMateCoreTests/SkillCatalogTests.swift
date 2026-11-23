import Foundation
import XCTest
@testable import DevMateCore

final class SkillCatalogTests: XCTestCase {
    private var tmp: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    @discardableResult
    private func write(_ text: String, at path: String) throws -> URL {
        let url = tmp.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func scan(_ repos: [String] = ["example"]) -> [SkillCatalog.Skill] {
        SkillCatalog.scan(repos: repos.map { (name: $0, folder: tmp.appendingPathComponent($0)) },
                          home: tmp.appendingPathComponent("home"))
    }

    func testFrontMatterParsesQuotesAndIgnoresJunk() {
        let text = "---\nname: \"Example\"\ndescription: 'A thing'\nnot a pair\n  nested: ignored\nspaced  :  value \n---\nBody"
        let meta = SkillCatalog.frontMatter(text)
        XCTAssertEqual(meta["name"], "Example")
        XCTAssertEqual(meta["description"], "A thing")
        XCTAssertEqual(meta["spaced"], "value")
        XCTAssertEqual(meta.count, 3)
        XCTAssertEqual(SkillCatalog.body(of: text), "Body")
    }

    func testNestedKeysCannotOverrideTopLevel() {
        let text = "---\ndescription: Real\nmeta:\n  description: Fake\n\tname: Fake\ndescription: Later\n---\n"
        let meta = SkillCatalog.frontMatter(text)
        XCTAssertEqual(meta["description"], "Real")
        XCTAssertNil(meta["name"])
    }

    func testBlockScalars() {
        let folded = "---\ndescription: >-\n  one\n  two: not a key\nname: Example\n---\n"
        let metaFolded = SkillCatalog.frontMatter(folded)
        XCTAssertEqual(metaFolded["description"], "one two: not a key")
        XCTAssertEqual(metaFolded["name"], "Example")
        XCTAssertNil(metaFolded["two"])
        let literal = "---\ndescription: |\n  a\n  b\n---\n"
        XCTAssertEqual(SkillCatalog.frontMatter(literal)["description"], "a\nb")
    }

    func testNoFrontMatter() {
        XCTAssertEqual(SkillCatalog.frontMatter("just text"), [:])
        XCTAssertEqual(SkillCatalog.body(of: "just text"), "just text")
        XCTAssertEqual(SkillCatalog.frontMatter("---\nname: x\nno end"), [:])
        XCTAssertEqual(SkillCatalog.body(of: "---\nname: x\nno end"), "---\nname: x\nno end")
    }

    func testScanFindsSkillsAndFallsBackToFolderName() throws {
        try write("---\nname: Alpha\ndescription: First\n---\nx", at: "example/.claude/skills/a/SKILL.md")
        try write("no front matter", at: "example/.agents/skills/folder-name/SKILL.md")
        let found = scan()
        XCTAssertEqual(found.map(\.name), ["Alpha", "folder-name"])
        XCTAssertEqual(found[0].description, "First")
        XCTAssertEqual(found[1].description, "")
        XCTAssertEqual(found[0].source, "example")
    }

    func testUserSkills() throws {
        try write("---\nname: Mine\n---\n", at: "home/.claude/skills/mine/SKILL.md")
        let found = scan([])
        XCTAssertEqual(found.map(\.source), [SkillCatalog.userSource])
    }

    func testOtherFileNamesAndMissingFoldersAreSkipped() throws {
        try write("x", at: "example/.claude/skills/a/SKILL.markdown")
        try write("x", at: "example/.claude/skills/SKILL.md")
        XCTAssertTrue(scan(["example", "absent"]).isEmpty)
    }

    func testSymlinkedSkillFileIsSkipped() throws {
        let real = try write("x", at: "elsewhere/SKILL.md")
        let dir = tmp.appendingPathComponent("example/.claude/skills/linked")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("SKILL.md"), withDestinationURL: real)
        XCTAssertTrue(scan().isEmpty)
    }

    func testSymlinkedFolderEscapingRootIsSkipped() throws {
        try write("x", at: "outside/SKILL.md")
        let root = tmp.appendingPathComponent("example/.claude/skills")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape"),
                                  withDestinationURL: tmp.appendingPathComponent("outside"))
        XCTAssertTrue(scan().isEmpty)
    }

    func testSymlinkedFolderInsideRootIsAllowed() throws {
        try write("x", at: "example/.claude/skills/real/SKILL.md")
        let root = tmp.appendingPathComponent("example/.claude/skills")
        try fm.createSymbolicLink(at: root.appendingPathComponent("alias"),
                                  withDestinationURL: root.appendingPathComponent("real"))
        XCTAssertEqual(scan().count, 2)
    }

    func testOrderingAndDeduplication() throws {
        try write("---\nname: Beta\n---\n", at: "one/.claude/skills/b/SKILL.md")
        try write("---\nname: Beta\n---\n", at: "two/.claude/skills/b/SKILL.md")
        try write("---\nname: alpha\n---\n", at: "two/.claude/skills/a/SKILL.md")
        let found = scan(["two", "one", "two"])
        XCTAssertEqual(found.map { "\($0.name)/\($0.source)" }, ["alpha/two", "Beta/one", "Beta/two"])
    }
}
