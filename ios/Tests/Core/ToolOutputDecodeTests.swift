import XCTest
@testable import RemoteMini

/// 対照表 #41(2026-09-04): tool 行に机が対にした結果の写しが載る。3 つの鍵は**全部 optional** —
/// 古い机(鍵を出さない)と新しい机(出す)の両方を同じ電話が読む。`HistoryModelsTests` と同じ流儀。
final class ToolOutputDecodeTests: XCTestCase {
    private func decode(_ json: String) throws -> HistoryResponse {
        try JSONDecoder().decode(HistoryResponse.self, from: Data(json.utf8))
    }

    func testToolEntryWithOutputDecodesAllThreeKeys() throws {
        let r = try decode(#"""
        { "history": [ { "role": "tool", "text": "⚙ Bash", "display": { "who": "Tool" },
                         "output": "line 1\nline 2", "outputTruncated": true, "outputError": false } ] }
        """#)
        let e = try XCTUnwrap(r.history.first)
        XCTAssertEqual(e.role, .tool)
        XCTAssertEqual(e.output, "line 1\nline 2")
        XCTAssertEqual(e.outputTruncated, true)
        XCTAssertEqual(e.outputError, false)
    }

    func testKeysAbsentDecodeToNilNotFalse() throws {
        // 机が対にできなかった行(結果が窓の外)は鍵ごと無い。nil と false を区別する:
        // `outputTruncated == nil` は「出力が無い」、`false` は「出力があって全文」。
        let r = try decode(#"{ "history": [ { "role": "tool", "text": "⚙ Bash", "display": { "who": "Tool" } } ] }"#)
        let e = try XCTUnwrap(r.history.first)
        XCTAssertNil(e.output)
        XCTAssertNil(e.outputTruncated)
        XCTAssertNil(e.outputError)
    }

    func testErrorResultDecodes() throws {
        let r = try decode(#"""
        { "history": [ { "role": "tool", "text": "⚙ Bash", "display": { "who": "Tool" },
                         "output": "command not found", "outputTruncated": false, "outputError": true } ] }
        """#)
        XCTAssertEqual(r.history.first?.outputError, true)
        XCTAssertEqual(r.history.first?.outputTruncated, false)
    }

    func testEqualityIncludesOutput() {
        let a = HistoryEntry(role: .tool, text: "⚙ Bash", display: .init(who: "Tool"), output: "x")
        let b = HistoryEntry(role: .tool, text: "⚙ Bash", display: .init(who: "Tool"), output: "y")
        let c = HistoryEntry(role: .tool, text: "⚙ Bash", display: .init(who: "Tool"))
        XCTAssertNotEqual(a, b, "出力が違えば別の項目(merge が同じ行と誤認しない)")
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a, HistoryEntry(role: .tool, text: "⚙ Bash", display: .init(who: "Tool"), output: "x"))
    }
}
