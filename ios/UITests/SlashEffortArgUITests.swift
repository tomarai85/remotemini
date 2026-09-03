import XCTest

/// `/effort` の引数の帯(対照表 #15、Tom 裁定 2026-09-03: **4 つ目のチップにはしない**)。
///
/// チップが無いので入口は打鍵: 作り物の面(`RC_UI_FIXTURE`)で「`/effort` と打つ → 2 段目が出る →
/// 段を押す → 入力欄が `/effort medium ` になり 2 段目が消える」を、人が指で辿る順のまま測る。
/// **送信は 1 度も押さない**(規約「押しても送らない」)。
///
/// 単体(`SlashArgumentTests`)は候補の規則を測る。此処で測るのは配線 —— 打鍵だけで(チップ無しで)
/// 帯が出るか、押した結果が `TextField` に届くか、`/model` の帯と識別子が分かれているか。
final class SlashEffortArgUITests: XCTestCase {

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

    func testTypingEffortRevealsLevelsAndPickingOneFillsTheComposerWithoutSending() {
        let app = launch(fixture: "conversation-busy") // BUSY = composer は使える(SlashModelArgUITests と同じ錨)
        let composer = element(app, "conversation.composerField")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))

        // 錨: チップ列に `/effort` は**無い**(裁定)。打つ前は帯も無い。
        XCTAssertFalse(element(app, "conversation.slash.effort").exists, "`/effort` のチップが在る(裁定違反)")
        XCTAssertFalse(element(app, "conversation.slash.effort.args").exists, "何も打っていないのに帯が出ている")

        composer.tap()
        composer.typeText("/effort")

        let args = element(app, "conversation.slash.effort.args")
        XCTAssertTrue(args.waitForExistence(timeout: 5), "`/effort` と打った後に 2 段目が出ない")
        for level in ["low", "medium", "high"] {
            XCTAssertTrue(element(app, "conversation.slash.effort.arg.\(level)").exists, "段 \(level) が無い")
        }
        // `/model` の帯と混ざっていない
        XCTAssertFalse(element(app, "conversation.slash.model.args").exists, "`/effort` を打ったのに model の帯が出ている")
        photograph(app, "slash-effort-args")

        element(app, "conversation.slash.effort.arg.medium").tap()
        XCTAssertEqual(composer.value as? String, "/effort medium ", "押した段が入力欄に差さっていない")
        XCTAssertFalse(element(app, "conversation.slash.effort.args").waitForExistence(timeout: 2), "選んだ後も帯が残っている")
        photograph(app, "slash-effort-picked")

        // ★送っていない
        XCTAssertFalse(element(app, "conversation.sendInFlight").exists)
    }
}
