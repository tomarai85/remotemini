import XCTest

/// 検索の結果で当たり語が塗られる(対照表 #42、2026-09-03)。作り物の会話(`conversation-search`)で
/// 「探す → 結果の各行が『塗られた』印を持つ」を測る。色そのものは XCUI から読めないので、
/// 行の `accessibilityValue`("highlighted" / "plain")を印にする。単体(`SearchHighlightTests`)が範囲の規則を測る。
final class SearchHighlightUITests: XCTestCase {

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = fixture
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

    func testEveryResultRowCarriesTheHighlightedMark() {
        let app = launch(fixture: "conversation-search")
        XCTAssertTrue(element(app, "conversation.composerField").waitForExistence(timeout: 20), "会話が読み込まれていない")

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "検索欄が画面に無い")
        field.tap()
        field.typeText("line 15\n")

        XCTAssertTrue(element(app, "conversation.search.summary").waitForExistence(timeout: 10))
        let first = element(app, "conversation.search.hit.0")
        XCTAssertTrue(first.waitForExistence(timeout: 5), "結果の行に印が無い")
        XCTAssertEqual(first.value as? String, "highlighted", "当たった行が塗られていない")
        // 全部の行が塗られている(机の一致規則と電話の塗りの規則が一致している = "plain" が 0)
        let plain = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'conversation.search.hit.' AND value == 'plain'"))
        XCTAssertEqual(plain.count, 0, "机が当てた行を電話が塗れていない(規則の食い違い)")
        photograph(app, "search-highlight")
    }
}
