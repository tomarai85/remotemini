import XCTest
@testable import RemoteMini

/// Decode tests for `SessionDiffBody` (対照表 #4)、`HistoryModelsTests` と同じ様式。
/// 本体は `rc-backend/src/wire.mjs` の `diffBody` を鏡写しに読む -- 鍵名の突き合わせ
/// 自体は `test/wire-key-agreement.test.mjs` の PAIRS が机側の鍵と行う。
final class DiffModelsTests: XCTestCase {
    private func decode(_ json: String) throws -> SessionDiffBody {
        try JSONDecoder().decode(SessionDiffBody.self, from: Data(json.utf8))
    }

    // MARK: - 実物の形(diffBody の doc に在る例そのもの)

    private static let realShape = """
    {
      "files": [
        {
          "path": "src/app.js",
          "staged": false,
          "binary": false,
          "added": 2,
          "removed": 1,
          "truncated": false,
          "hunks": [
            {
              "header": "@@ -1,4 +1,5 @@",
              "lines": [
                { "kind": "ctx", "text": "const x = 1;" },
                { "kind": "del", "text": "const y = 2;" },
                { "kind": "add", "text": "const y = 3;" },
                { "kind": "add", "text": "const z = 4;" }
              ]
            }
          ]
        }
      ],
      "truncated": false,
      "totalBytes": 812,
      "reason": null
    }
    """

    func testRealShapeDecodesFully() throws {
        let response = try decode(Self.realShape)

        XCTAssertEqual(response.files.count, 1)
        XCTAssertEqual(response.truncated, false)
        XCTAssertEqual(response.totalBytes, 812)
        XCTAssertNil(response.reason)

        let file = response.files[0]
        XCTAssertEqual(file.path, "src/app.js")
        XCTAssertEqual(file.staged, false)
        XCTAssertEqual(file.binary, false)
        XCTAssertEqual(file.added, 2)
        XCTAssertEqual(file.removed, 1)
        XCTAssertEqual(file.hunks.count, 1)
        XCTAssertEqual(file.hunks[0].header, "@@ -1,4 +1,5 @@")
        XCTAssertEqual(file.hunks[0].lines.map(\.kind), [.ctx, .del, .add, .add])
        // ★行の text は先頭の記号が既に落ちている(机が落とす)。電話は其の侭表示する。
        XCTAssertEqual(file.hunks[0].lines[1].text, "const y = 2;")
    }

    // MARK: - `reason` -- 成功でも `null` で必ず載る欄(wire.mjs の doc)

    func testReasonStringDecodesForNotARepo() throws {
        let response = try decode(#"{ "files": [], "truncated": false, "totalBytes": 0, "reason": "not_a_repo" }"#)

        XCTAssertEqual(response.reason, "not_a_repo")
        XCTAssertEqual(response.files, [])
    }

    /// `HistoryResponse.truncated` と同じ緩さ: 鍵の不在と `null` はどちらも
    /// 「理由なし」を意味する。旧い机が此の欄を送らなくても電話は読める。
    func testReasonKeyAbsentDecodesToNil() throws {
        let response = try decode(#"{ "files": [], "truncated": false, "totalBytes": 0 }"#)

        XCTAssertNil(response.reason)
    }

    // MARK: - `staged` -- 同じ path が 2 行に分かれる(index の側と作業木の側)

    func testSamePathCanAppearTwiceWithDifferentStaged() throws {
        let json = """
        { "files": [
            { "path": "a.txt", "staged": false, "binary": false, "added": 1, "removed": 0, "truncated": false, "hunks": [] },
            { "path": "a.txt", "staged": true, "binary": false, "added": 1, "removed": 0, "truncated": false, "hunks": [] }
          ], "truncated": false, "totalBytes": 10, "reason": null }
        """
        let response = try decode(json)

        XCTAssertEqual(response.files.count, 2)
        XCTAssertEqual(Set(response.files.map(\.id)).count, 2, "id は staged を含めて一意にならなければならない")
    }

    // MARK: - `binary` -- 塊を運ばない

    func testBinaryFileHasNoHunks() throws {
        let json = """
        { "files": [
            { "path": "logo.png", "staged": false, "binary": true, "added": 0, "removed": 0, "truncated": false, "hunks": [] }
          ], "truncated": false, "totalBytes": 0, "reason": null }
        """
        let response = try decode(json)

        XCTAssertEqual(response.files[0].binary, true)
        XCTAssertEqual(response.files[0].hunks, [])
    }

    // MARK: - `DiffLineKind` -- 未知の値は decode を落とさず `.unknown` へ

    func testUnrecognizedLineKindFallsBackToUnknownWithoutFailingDecode() throws {
        let json = """
        { "files": [
            { "path": "a.txt", "staged": false, "binary": false, "added": 0, "removed": 0, "truncated": false,
              "hunks": [ { "header": "@@ -1 +1 @@", "lines": [ { "kind": "no-newline", "text": "x" } ] } ] }
          ], "truncated": false, "totalBytes": 1, "reason": null }
        """
        let response = try decode(json)

        XCTAssertEqual(response.files[0].hunks[0].lines[0].kind, .unknown)
        // 残りは decode できている -- 1 つの未知の値が全体を巻き込まない。
        XCTAssertEqual(response.files[0].hunks[0].lines[0].text, "x")
    }

    // MARK: - Negative controls(decode は必ず失敗しなければならない -- 緑のまま嘘をつかない)

    func testMissingFilesFieldFailsToDecodeNegativeControl() {
        XCTAssertThrowsError(try decode(#"{ "truncated": false, "totalBytes": 0, "reason": null }"#))
    }

    func testMissingAddedFieldFailsToDecodeNegativeControl() {
        let json = """
        { "files": [
            { "path": "a", "staged": false, "binary": false, "removed": 0, "truncated": false, "hunks": [] }
          ], "truncated": false, "totalBytes": 0, "reason": null }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testMissingTotalBytesFieldFailsToDecodeNegativeControl() {
        XCTAssertThrowsError(try decode(#"{ "files": [], "truncated": false, "reason": null }"#))
    }
}
