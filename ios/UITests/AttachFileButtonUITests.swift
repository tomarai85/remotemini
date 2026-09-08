import XCTest

/// 文書の添付ボタン(対照表 #23、2026-09-03)が composer に居て押せる事。Files の画面は別 process なので
/// XCUI からは中身を辿れない —— 此処で測るのは配線(ボタンが在る・composer が使える相でだけ押せる)まで。
/// 机との往復は `AttachFileClientTests`(request の形)と机側の `attach-file.test.mjs` が測る。
final class AttachFileButtonUITests: XCTestCase {

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = fixture
        app.launch()
        return app
    }

    /// ★2026-09-07(案 B)に添付は `+` の 1 つへ畳んだ。写真と文書は**押した時に出る**ので、
    ///   此の検査は先に `conversation.attachMenu` を開く。畳む前の主張(2 つが並んで居る・composer が
    ///   使える相では押せる・読み上げの名前が「何の添付か」を言う)は其の儘測る。
    func testTheFileButtonSitsBesideThePhotoButtonAndIsEnabledWhenTheComposerIs() {
        let app = launch(fixture: "conversation-busy")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "conversation.composerField").firstMatch.waitForExistence(timeout: 20))

        let menu = app.descendants(matching: .any).matching(identifier: "conversation.attachMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "添付の入口が無い(前提)")
        XCTAssertTrue(menu.isEnabled, "composer が使えるのに添付の入口が押せない")
        menu.tap()

        let photo = app.descendants(matching: .any).matching(identifier: "conversation.attachButton").firstMatch
        let file = app.descendants(matching: .any).matching(identifier: "conversation.attachFileButton").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "開いた添付の中に写真が無い(前提)")
        XCTAssertTrue(file.exists, "開いた添付の中に文書が無い")
        XCTAssertTrue(file.isEnabled, "composer が使えるのに文書が押せない")
        XCTAssertEqual(file.label, "Attach a text file", "読み上げの名前が『何の添付か』を言っていない")
    }
}
