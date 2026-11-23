import Foundation
import XCTest
@testable import DevMateCore

final class RegistryFixtureTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/registry/v1/\(name)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testValidFixtureDeclaresTheCurrentSchema() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("valid")) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, DevMate.registrySchemaVersion)
    }

    func testNewerFixtureIsAheadOfTheCurrentSchema() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("newer-schema")) as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(object["schema_version"] as? Int), DevMate.registrySchemaVersion)
    }

    func testMalformedFixtureIsNotJSON() throws {
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: fixture("malformed")))
    }
}
