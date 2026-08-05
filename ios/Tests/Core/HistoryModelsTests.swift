import XCTest
@testable import RemoteMini

/// Decode tests for `HistoryResponse`/`HistoryEntry` against the real observed shape
/// (Sprint 3 brief §0), same style as `SessionsModelsTests`.
final class HistoryModelsTests: XCTestCase {
    private func decode(_ json: String) throws -> HistoryResponse {
        try JSONDecoder().decode(HistoryResponse.self, from: Data(json.utf8))
    }

    // MARK: - ★Brief §0-a-1, "the single easiest thing to get wrong this sprint"

    func testTruncatedKeyAbsentDecodesToFalse() throws {
        // The `truncated` key is entirely ABSENT here, not present-and-false -- a
        // body that only ever supplies the latter would stay green even with the
        // wrong (non-optional `Bool`) implementation. This is the shape
        // `server.mjs`'s "no session found" early return actually produces.
        let response = try decode(#"{ "history": [] }"#)

        XCTAssertEqual(response.truncated, false)
        XCTAssertEqual(response.history, [])
    }

    func testTruncatedKeyPresentFalseAlsoDecodes() throws {
        // The other real empty-history shape (`server.mjs`'s ENOENT catch path):
        // key present, `false`. Both shapes must mean the same thing to the phone.
        let response = try decode(#"{ "history": [], "truncated": false }"#)

        XCTAssertEqual(response.truncated, false)
    }

    func testTruncatedTrueDecodes() throws {
        let response = try decode(Self.threeRoleFixture)

        XCTAssertEqual(response.truncated, true)
    }

    // MARK: - Brief §0-a-2: 3 known roles + a `tool` row is a short label, not prose

    func testThreeRolesDecodeWithDisplayWhoVerbatim() throws {
        let response = try decode(Self.threeRoleFixture)

        XCTAssertEqual(response.history.count, 3)
        XCTAssertEqual(response.history[0].role, .user)
        XCTAssertEqual(response.history[0].display.who, "Tom")
        XCTAssertEqual(response.history[1].role, .assistant)
        XCTAssertEqual(response.history[1].display.who, "Claude")
        XCTAssertEqual(response.history[2].role, .tool)
        XCTAssertEqual(response.history[2].display.who, "道具")
        XCTAssertEqual(response.history[2].text, "⚙ Bash")
    }

    // MARK: - Brief §0-a-2: an unrecognized `role` falls back to `.unknown`, decode does not fail

    func testUnrecognizedRoleFallsBackToUnknownWithoutFailingDecode() throws {
        let response = try decode(Self.futureRoleFixture)

        XCTAssertEqual(response.history[0].role, .unknown)
        // The rest of the entry decoded fine -- only the enum fell back.
        XCTAssertEqual(response.history[0].text, "未来の役割からの発言")
    }

    // MARK: - Negative controls (decode must FAIL, not silently produce an empty conversation)

    func testMissingHistoryFieldFailsToDecodeNegativeControl() {
        // If `HistoryResponse.history` were `Optional`, this would decode to a
        // response indistinguishable from "genuinely no messages yet" instead of
        // throwing -- the same "green but lying" failure mode
        // `SessionsModelsTests`'s negative controls guard against.
        XCTAssertThrowsError(try decode(#"{ "truncated": false }"#))
    }

    func testMissingEntryDisplayFailsToDecodeNegativeControl() {
        XCTAssertThrowsError(try decode(#"{ "history": [ { "role": "user", "text": "x" } ] }"#))
    }

    func testMissingEntryRoleFailsToDecodeNegativeControl() {
        XCTAssertThrowsError(try decode(#"{ "history": [ { "text": "x", "display": { "who": "Tom" } } ] }"#))
    }

    // MARK: - Fixtures

    private static let threeRoleFixture = """
    {
      "history": [
        { "role": "user", "text": "予約の状況を確認して", "display": { "who": "Tom" } },
        { "role": "assistant", "text": "確認します。少々お待ちください。", "display": { "who": "Claude" } },
        { "role": "tool", "text": "⚙ Bash", "display": { "who": "道具" } }
      ],
      "truncated": true
    }
    """

    private static let futureRoleFixture = """
    {
      "history": [
        { "role": "orchestrator", "text": "未来の役割からの発言", "display": { "who": "?" } }
      ],
      "truncated": false
    }
    """
}
