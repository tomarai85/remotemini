import XCTest
import SwiftUI
@testable import RemoteMini

/// 当たり語の強調の規則(対照表 #42、2026-09-03)。机の一致規則(大文字小文字を同一視した部分一致)と同じ範囲を塗る。
final class SearchHighlightTests: XCTestCase {

    func test_全出現を大文字小文字を同一視して拾う() {
        let text = "Line 15 and line 155 and LINE 15"
        let rs = SearchHighlight.ranges(in: text, of: "line 15")
        XCTAssertEqual(rs.count, 3)
        XCTAssertEqual(rs.map { String(text[$0]) }, ["Line 15", "line 15", "LINE 15"])
        XCTAssertEqual(SearchHighlight.count(in: text, of: "LINE"), 3)
    }

    func test_当たらない_空の問い_空白だけの問いは塗らない() {
        XCTAssertEqual(SearchHighlight.ranges(in: "hello", of: "zzz").count, 0)
        XCTAssertEqual(SearchHighlight.ranges(in: "hello", of: "").count, 0)
        XCTAssertEqual(SearchHighlight.ranges(in: "hello", of: "   ").count, 0)
        XCTAssertEqual(SearchHighlight.count(in: "", of: "a"), 0)
    }

    func test_重なりは作らない_隣接は別々に数える() {
        XCTAssertEqual(SearchHighlight.count(in: "aaaa", of: "aa"), 2, "重なる出現を二重に塗らない")
        XCTAssertEqual(SearchHighlight.count(in: "ab ab", of: "ab"), 2)
    }

    func test_日本語も部分一致で塗る() {
        XCTAssertEqual(SearchHighlight.count(in: "移動中スマホ作業のスマホ", of: "スマホ"), 2)
    }

    func test_属性付き文字列は当たりの範囲だけを色付ける_当たりが無ければ素のまま() {
        let a = SearchHighlight.attributed("foo BAR foo", query: "bar", color: .red)
        XCTAssertEqual(String(a.characters), "foo BAR foo", "本文を変えない")
        var colored = 0
        for run in a.runs where run.foregroundColor != nil { colored += String(a[run.range].characters).count }
        XCTAssertEqual(colored, 3, "塗られた文字数 = 当たり語の長さ")
        let plain = SearchHighlight.attributed("foo", query: "zzz", color: .red)
        XCTAssertTrue(plain.runs.allSatisfy { $0.foregroundColor == nil })
    }
}
