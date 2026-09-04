import XCTest

/// keyboard の上の道具列(対照表 #43、2026-09-03)。作り物の会話(`conversation-busy` = composer が使える)で、
/// 「入力欄に触る → 道具列が出る → `/` と `@` を押すと入力欄の末尾に差さる → Hide で keyboard が畳まれる」を
/// 指で辿る順のまま測る。**送信は 1 度も押さない**。
final class ComposerKeyboardToolbarUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = "conversation-busy"
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

    func testTheToolRowInsertsSymbolsAtTheEndAndHidesTheKeyboardWithoutSending() {
        let app = launch()
        let composer = element(app, "conversation.composerField")
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        // 錨: 触る前は道具列が無い(常に出る実装を落とす)
        XCTAssertFalse(element(app, "conversation.kb.slash").exists, "keyboard が出ていないのに道具列が居る")

        composer.tap()
        let slash = element(app, "conversation.kb.slash")
        XCTAssertTrue(slash.waitForExistence(timeout: 5), "入力欄に触っても道具列が出ない")
        for id in ["conversation.kb.at", "conversation.kb.backtick", "conversation.kb.hide"] {
            XCTAssertTrue(element(app, id).exists, "\(id) が無い")
        }
        photograph(app, "keyboard-toolbar")

        slash.tap()
        XCTAssertEqual(composer.value as? String, "/", "`/` が末尾に差さっていない")
        composer.typeText("compact")
        element(app, "conversation.kb.at").tap()
        XCTAssertEqual(composer.value as? String, "/compact @", "語の後ろに `@` を差す時は空白を 1 つ挟む")
        element(app, "conversation.kb.backtick").tap()
        XCTAssertEqual(composer.value as? String, "/compact @`", "バッククォートはそのまま末尾へ")
        photograph(app, "keyboard-toolbar-inserted")

        let hadKeyboard = app.keyboards.count > 0
        element(app, "conversation.kb.hide").tap()
        if hadKeyboard {
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Hide を押しても keyboard が畳まれない")
        }
        XCTAssertEqual(composer.value as? String, "/compact @`", "Hide が本文を変えた")
        // ★送っていない
        XCTAssertFalse(element(app, "conversation.sendInFlight").exists)
    }
}
