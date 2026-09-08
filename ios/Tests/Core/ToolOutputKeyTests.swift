import XCTest
@testable import RemoteMini

/// 道具の出力の展開を覚える鍵は **中身から出る**(2026-09-08、電話の掃引)。
///
/// 何が壊れていたか: 展開は `EntryBubble` の `@State` に在り、`ForEach` の identity が `offset` ——
/// つまり状態が画面上の**位置**に付いていた。「もっと読む」は `history` を大きい limit で丸ごと
/// 置き換えるので既存の行の offset が全部ずれ、離脱の窓は同じ offset に別の配列を出す。
/// 結果、開いた行は畳まれ、**其の位置に来た別の行が開いた状態で描かれる** ——
/// 見ていない道具呼び出しの出力が、見ていた行の場所に出ていた。
final class ToolOutputKeyTests: XCTestCase {
    private func tool(_ name: String, output: String?, anchor: String?) -> HistoryEntry {
        HistoryEntry(role: .tool, text: name, display: .init(who: "tool"),
                     anchor: anchor, output: output)
    }

    func testOpenableRowsAreKeyedByTheDesksAnchor() {
        let e = tool("⚙ Bash", output: "ok", anchor: "1234:0")
        XCTAssertEqual(e.toolOutputKey, "a:1234:0")
    }

    /// ★本題。**位置が変わっても鍵は変わらない** —— 「もっと読む」で 20 番目が 70 番目になっても、
    /// 開いていた行は同じ行のまま。
    func testTheKeyDoesNotDependOnPosition() {
        let before = tool("⚙ Bash", output: "ok", anchor: "1234:0")
        let after = tool("⚙ Bash", output: "ok", anchor: "1234:0")
        XCTAssertEqual(before.toolOutputKey, after.toolOutputKey)
    }

    /// 別の項目は別の鍵(同じ道具名でも机の錨が違う)。
    func testDifferentRowsGetDifferentKeys() {
        XCTAssertNotEqual(tool("⚙ Bash", output: "ok", anchor: "1:0").toolOutputKey,
                          tool("⚙ Bash", output: "ok", anchor: "2:0").toolOutputKey)
    }

    /// 開く物が無い行は鍵を持たない(持たせると、開けない行の為に集合が育つ)。
    func testRowsWithNoOutputHaveNoKey() {
        XCTAssertNil(tool("⚙ Bash", output: nil, anchor: "1:0").toolOutputKey)
        XCTAssertNil(HistoryEntry(role: .assistant, text: "hello", display: .init(who: "Claude")).toolOutputKey)
    }

    /// 錨の無い出力付きの行(ライブには来ない筈だが、来ても位置には戻さない)。
    func testAnchorlessOutputFallsBackToContentNotPosition() {
        let a = tool("⚙ Bash", output: "one", anchor: nil)
        let b = tool("⚙ Bash", output: "two", anchor: nil)
        XCTAssertNotNil(a.toolOutputKey)
        XCTAssertNotEqual(a.toolOutputKey, b.toolOutputKey, "出力が違うのに同じ鍵 = 片方の展開が他方に移る")
        XCTAssertEqual(a.toolOutputKey, tool("⚙ Bash", output: "one", anchor: nil).toolOutputKey)
    }

    /// ★否定対照: 錨が在る時は錨だけで決まる(中身が変わっても同じ行)。
    /// 之が崩れると、机が出力を伸ばした瞬間に「別の行」になって展開が外れる。
    func testTheAnchorWinsOverContent() {
        XCTAssertEqual(tool("⚙ Bash", output: "one", anchor: "9:1").toolOutputKey,
                       tool("⚙ Bash", output: "one … more", anchor: "9:1").toolOutputKey)
    }
}
