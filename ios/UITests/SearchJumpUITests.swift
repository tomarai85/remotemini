import XCTest

/// 探索の当たりを押すと転写の其の行へ跳ぶ(対照表 #3、2026-09-03)。作り物の会話(`conversation-search`、240 行、
/// 初回の窓は末尾 50 行)で「探す → 当たりを押す → 探索の面が閉じ、転写に其の行が見えている」を指で辿る順のまま測る。
/// 単体(`SearchJumpTests`)は読み足しの判断を測る。此処で測るのは配線 —— 押せる事、面が閉じる事、行が画面に居る事。
final class SearchJumpUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = "conversation-search"
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func photograph(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTappingAResultClosesTheSearchAndShowsThatLineInTheTranscript() {
        let app = launch()
        XCTAssertTrue(element(app, "conversation.composerField").waitForExistence(timeout: 20), "会話が読み込まれていない")
        // 錨: 初回の窓(末尾 50 行 = 191〜240)に line 155 は無い
        XCTAssertFalse(app.staticTexts["line 155"].exists)

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "検索欄が画面に無い")
        field.tap()
        field.typeText("line 155\n")
        XCTAssertTrue(element(app, "conversation.search.summary").waitForExistence(timeout: 10))
        let hit = element(app, "conversation.search.hit.0")
        XCTAssertTrue(hit.waitForExistence(timeout: 5))
        XCTAssertTrue(hit.isEnabled, "錨の在る当たりが押せない")
        photograph(app, "search-jump-before")

        hit.tap()

        XCTAssertFalse(element(app, "conversation.search.summary").waitForExistence(timeout: 3), "跳んだのに探索の面が残っている")
        let line = app.staticTexts["line 155"]
        XCTAssertTrue(line.waitForExistence(timeout: 10), "跳んだ先の行が転写に無い(読み足していない)")
        XCTAssertTrue(line.isHittable, "行は在るが画面の外(scroll していない)")
        XCTAssertFalse(element(app, "conversation.search.jumpNotice").exists, "跳べたのに断りが出ている")
        photograph(app, "search-jump-after")
    }
}
