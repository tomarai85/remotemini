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

    func testTheFileButtonSitsBesideThePhotoButtonAndIsEnabledWhenTheComposerIs() {
        let app = launch(fixture: "conversation-busy")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "conversation.composerField").firstMatch.waitForExistence(timeout: 20))
        let photo = app.buttons["conversation.attachButton"]
        let file = app.buttons["conversation.attachFileButton"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "写真のボタンが無い(前提)")
        XCTAssertTrue(file.exists, "文書のボタンが無い")
        XCTAssertTrue(file.isEnabled, "composer が使えるのに文書のボタンが押せない")
        XCTAssertEqual(file.label, "Attach a text file")
    }
}
