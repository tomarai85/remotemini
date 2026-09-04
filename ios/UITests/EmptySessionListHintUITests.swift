import XCTest

/// 空の机の面が `+` を指す(対照表 #11 の後追い、2026-09-03)。作り物の空の一覧(`list-empty`)で、
/// 「No sessions」の下に案内の 1 行が居て、工具帯の `+` が本当に押せる位置に在る事を測る。
/// 案内は文であってボタンではない(根拠: `.harness/evidence-2026-09-03/research-empty-state-hint.md`)。
final class EmptySessionListHintUITests: XCTestCase {

    func testTheEmptyFacePointsAtThePlusAndThePlusIsThere() {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = "list-empty"
        app.launch()
        let empty = app.descendants(matching: .any).matching(identifier: "list.empty").firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 15), "空の面が出ない")
        let hint = app.descendants(matching: .any).matching(identifier: "list.empty.hint").firstMatch
        XCTAssertTrue(hint.exists, "案内の 1 行が無い")
        XCTAssertTrue(hint.label.contains("+"), "案内が `+` を名指ししていない: \(hint.label)")
        XCTAssertTrue(hint.label.hasPrefix("Tap + above"), hint.label)
        // 指した先が本当に在る(文だけで、押す物が無い面にしない)
        let plus = app.descendants(matching: .any).matching(identifier: "list.newSession").firstMatch
        XCTAssertTrue(plus.exists, "`+` が工具帯に無いのに案内が指している")
        XCTAssertTrue(plus.isEnabled)
        // 案内はボタンではない
        XCTAssertFalse(app.buttons.matching(identifier: "list.empty.hint").firstMatch.exists, "案内がボタンになっている(押し場所を 2 つ作らない)")
    }
}
