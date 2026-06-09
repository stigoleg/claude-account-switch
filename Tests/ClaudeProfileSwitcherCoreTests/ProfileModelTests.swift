import XCTest

@testable import ClaudeProfileSwitcherCore

final class ProfileModelTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let original = Profile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "work",
            colorHex: "#5B8DEF",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        let data = try JSONEncoder.iso.encode(original)
        let decoded = try JSONDecoder.iso.decode(Profile.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeWithoutUpdatedAtFallsBackToDistantPast() throws {
        // Old v1.0 JSON format: no updatedAt field.
        let legacy = """
            {
                "id": "22222222-2222-2222-2222-222222222222",
                "name": "personal",
                "colorHex": "#E07856",
                "createdAt": "2024-01-01T00:00:00Z"
            }
            """.data(using: .utf8)!
        let decoded = try JSONDecoder.iso.decode(Profile.self, from: legacy)
        XCTAssertEqual(decoded.name, "personal")
        XCTAssertEqual(decoded.updatedAt, .distantPast)
    }

    func testDefaultColorIsValidHex() {
        for hex in Profile.defaultColors {
            XCTAssertEqual(hex.count, 7, "Expected #RRGGBB, got \(hex)")
            XCTAssertTrue(hex.hasPrefix("#"))
            let stripped = String(hex.dropFirst())
            XCTAssertNotNil(
                UInt64(stripped, radix: 16),
                "\(hex) is not a parseable hex color")
        }
    }
}
