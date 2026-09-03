import XCTest
@testable import RemoteMini

/// 一覧の絞り込みの規則(対照表 #24、2026-09-03)。守る線は 2 方向: 覚えている語で当たる / 関係ない行を残さない。
final class SessionFilterTests: XCTestCase {

    func test_空や空白の問いは絞らない() {
        XCTAssertTrue(SessionFilter.matches(title: "An active session", subtitle: "Desktop · Active", query: ""))
        XCTAssertTrue(SessionFilter.matches(title: "x", subtitle: "y", query: "   \n"))
        XCTAssertEqual(SessionFilter.normalized("  abc  "), "abc")
    }

    func test_題名の途中の語で当たり_大文字小文字を同一視する() {
        XCTAssertTrue(SessionFilter.matches(title: "An active session", subtitle: "", query: "active"))
        XCTAssertTrue(SessionFilter.matches(title: "An active session", subtitle: "", query: "ACTIVE"))
        XCTAssertTrue(SessionFilter.matches(title: "An active session", subtitle: "", query: "ve sess"), "前方一致ではなく部分一致")
    }

    func test_副題でも当たる() {
        XCTAssertTrue(SessionFilter.matches(title: "Background work", subtitle: "Worker · Waiting for reply", query: "waiting"))
        XCTAssertFalse(SessionFilter.matches(title: "Background work", subtitle: "Worker · Waiting for reply", query: "desktop"))
    }

    func test_日本語と記号も普通に部分一致する() {
        XCTAssertTrue(SessionFilter.matches(title: "移動中スマホ作業", subtitle: "", query: "スマホ"))
        XCTAssertTrue(SessionFilter.matches(title: "rc-backend/diff", subtitle: "", query: "backend/d"))
    }

    func test_当たらない行は落ちる_問いの空白は無視する() {
        XCTAssertFalse(SessionFilter.matches(title: "An active session", subtitle: "Desktop · Active", query: "zzz"))
        XCTAssertTrue(SessionFilter.matches(title: "An active session", subtitle: "", query: " active "))
    }
}
