import XCTest

/// 一覧の絞り込み(対照表 #24、2026-09-03)。作り物の一覧(`list-normal`、6 行)で、
/// 「検索欄に語を打つ → 当たる行だけ残る → 当たらない語で空の面 → 消すと全部戻る」を指で辿る順のまま測る。
///
/// 単体(`SessionFilterTests`)は規則を測る。此処で測るのは配線 —— 検索欄が `.searchable` として工具帯に居るか、
/// 打った文字が本当に行を絞るか、空の面が「机に会話が無い」の面(`list.empty`)と別物か。
final class ListSearchUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = "list-normal"
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func rowCount(_ app: XCUIApplication) -> Int {
        app.buttons.matching(identifier: "list.row").count
    }

    private func photograph(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTypingInTheSearchFieldFiltersRowsAndClearingRestoresThem() {
        let app = launch()
        XCTAssertTrue(element(app, "list.root").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(identifier: "list.row").firstMatch.waitForExistence(timeout: 10), "行が来ない")
        let before = rowCount(app)
        XCTAssertGreaterThanOrEqual(before, 3, "絞り込みを測るには行が 3 本以上要る(fixture が痩せた)")

        let field = app.searchFields.firstMatch
        if !field.exists {
            // iOS 26 の検索欄は工具帯の中で畳まれている事が在る: 下へ引いて出す
            app.swipeDown()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "検索欄が無い(.searchable が付いていない)")
        field.tap()
        field.typeText("active")

        let active = app.staticTexts["An active session"]
        XCTAssertTrue(active.waitForExistence(timeout: 5), "当たる行が残っていない")
        XCTAssertFalse(app.staticTexts["Background work"].exists, "当たらない行が残っている")
        XCTAssertLessThan(rowCount(app), before, "行数が減っていない = 絞れていない")
        XCTAssertFalse(element(app, "list.search.empty").exists)
        photograph(app, "list-search-filtered")

        field.typeText("zzzz")
        XCTAssertTrue(element(app, "list.search.empty").waitForExistence(timeout: 5), "0 本の時の面が無い")
        XCTAssertFalse(element(app, "list.empty").exists, "絞り込みの 0 本を「机に会話が無い」の面で描いた")
        photograph(app, "list-search-empty")

        // 消す = 全部戻る
        let clear = field.buttons["Clear text"].firstMatch
        if clear.exists { clear.tap() } else {
            field.tap()
            let n = (field.value as? String)?.count ?? 10
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: n))
        }
        XCTAssertTrue(app.staticTexts["Background work"].waitForExistence(timeout: 5), "問いを消しても戻らない")
        XCTAssertEqual(rowCount(app), before, "消した後の行数が元と違う")
    }
}
