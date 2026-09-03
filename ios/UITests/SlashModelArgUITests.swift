import XCTest

/// `/model` の引数ピッカー(対照表 #14、2026-09-03)—— 作り物の面(`RC_UI_FIXTURE`)で、
/// 「チップを押す → 2 段目が出る → 名前を押す → 入力欄が `/model sonnet ` になり 2 段目が消える」
/// を、人が指で辿る順のまま測る。**送信は 1 度も押さない**(規約「押しても送らない」)。
///
/// 単体(`SlashArgumentTests`)は候補の規則を測る。此処で測るのは配線 ——
/// 2 段目が `draft` を本当に読んでいるか、押した結果が `TextField` に届くか。
final class SlashModelArgUITests: XCTestCase {

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

    func testModelChipRevealsArgumentsAndPickingOneFillsTheComposerWithoutSending() {
        let app = launch(fixture: "conversation-busy") // BUSY = composer は使える(ConversationUITests と同じ錨)
        let composer = element(app, "conversation.composerField")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))

        // 錨: `/model` を押す前は 2 段目が無い(常に出る実装を落とす)
        XCTAssertFalse(element(app, "conversation.slash.model.args").exists, "何も押していないのに引数の帯が出ている")

        let modelChip = element(app, "conversation.slash.model")
        XCTAssertTrue(modelChip.waitForExistence(timeout: 5))
        modelChip.tap()

        let args = element(app, "conversation.slash.model.args")
        XCTAssertTrue(args.waitForExistence(timeout: 5), "`/model` を差した後に 2 段目が出ない")
        for name in ["opus", "sonnet", "haiku", "default"] {
            XCTAssertTrue(element(app, "conversation.slash.model.arg.\(name)").exists, "候補 \(name) が無い")
        }
        photograph(app, "slash-model-args")

        element(app, "conversation.slash.model.arg.sonnet").tap()
        XCTAssertEqual(composer.value as? String, "/model sonnet ", "押した名前が入力欄に差さっていない")
        // 選び終えたら 2 段目は消える(末尾の空白が「書き終えた」の合図)
        XCTAssertFalse(element(app, "conversation.slash.model.args").waitForExistence(timeout: 2), "選んだ後も帯が残っている")
        photograph(app, "slash-model-picked")

        // ★送っていない: 送信ボタンを押していないので、送信中の印も送信済みの行も無い
        XCTAssertFalse(element(app, "conversation.sendInFlight").exists)
    }
}
