import XCTest

/// 留守中の要約の帯が、**製品の経路で本当に画面に出る**事を撮る。2026-08-26 新設。
///
/// ★`RC_UI_FIXTURE` を渡さない。作り物の面で撮った画は「作り物が描けた」しか証明しない ——
///   `AttachButtonUITests` と同じ判断で、通常経路(本物の机から取る)だけを通す。
/// ★机が落ちている / tailnet の外なら **`XCTSkip`**。赤にしない ——
///   「測れなかった」を「壊れている」と言うと、次に本当に壊れた日に読まれなくなる。
final class AwayDigestUITests: XCTestCase {

    private func launchReal() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    func testTheAwayDigestLineAppearsWhenOpeningAConversation() throws {
        let app = launchReal()

        let firstRow = app.buttons.matching(identifier: "list.row").firstMatch
        let anyRow = firstRow.waitForExistence(timeout: 20) ? firstRow : app.cells.firstMatch
        guard anyRow.waitForExistence(timeout: 10) else {
            throw XCTSkip("一覧に会話が無い(机が落ちている / tailnet の外)= 測っていない")
        }
        anyRow.tap()

        // 会話画面が立ち上がった事を、帯より先に確かめる。立っていない画面で
        // 「帯が無い」と言うのは、帯の話ではなく画面の話になってしまう。
        let composerAnchor = app.buttons["conversation.sendButton"]
        guard composerAnchor.waitForExistence(timeout: 20) else {
            throw XCTSkip("会話画面が立たない(机が落ちている)= 測っていない")
        }

        let digest = app.staticTexts["conversation.awayDigest"]
        let appeared = digest.waitForExistence(timeout: 20)

        // 撮る。出ていても出ていなくても撮る —— 出ていない時の画こそ、
        // 次に読む人が「何が起きているか」を判じる材料になる。
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot)
        a.name = appeared ? "away-digest-visible" : "away-digest-absent"
        a.lifetime = .keepAlways
        add(a)

        XCTAssertTrue(appeared,
                      "会話を開いても留守中の要約の帯が出ない(型と口は在るのに画面へ届いていない)")
        XCTAssertFalse(digest.label.isEmpty, "帯は在るが中身が空 = 何も伝えていない")
    }
}
