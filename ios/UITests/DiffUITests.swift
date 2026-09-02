import XCTest

/// 差分(diff)画面(対照表 #4、2026-09-02)。`ConversationUITests` と同じ機構 --
/// `RC_UI_FIXTURE`(`RootView`/`ConversationHistoryFactory`)で会話を立て、
/// 二次軸 `RC_UI_DIFF_FIXTURE`(`AccountUITests` と同じ形の独立変数、`DiffFactory`)で
/// diff の中身を撃ち分ける。撮った画は`Tom の目が検証器`の実践 -- 緑の数は
/// 「押せた」を意味しない。
final class DiffUITests: XCTestCase {
    private func launch(conversation: String, diff: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = conversation
        if let diff { app.launchEnvironment["RC_UI_DIFF_FIXTURE"] = diff }
        app.launch()
        return app
    }

    /// `ConversationUITests.element(_:_:)` と同じ形。`ContentUnavailableView` は
    /// 単一の accessibility 型では捕まらない(実測 2026-09-02: `.otherElements[...]` は
    /// 空面(`diff.empty`/`diff.reason`)を見付けられなかった -- `staticTexts` は
    /// 拾えていた同じ回、識別子を持つ入れ物の**型**が `.other` ではなかった)。
    /// `.any` で降りて識別子だけを条件にする。
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func openDiff(_ app: XCUIApplication) throws -> XCUIElement {
        let composerAnchor = app.buttons["conversation.sendButton"]
        guard composerAnchor.waitForExistence(timeout: 20) else {
            throw XCTSkip("会話画面が立たない = 測っていない")
        }
        let button = app.buttons["conversation.diff.open"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "工具帯に diff ボタンが無い")
        XCTAssertTrue(button.isHittable, "diff ボタンが在るのに押せない位置に居る")
        button.tap()
        return button
    }

    /// ★`RC_UI_DIFF_FIXTURE` を**渡さない** -- `DiffFactory` の既定分岐(会話が fixture
    ///   なら本物の口を開けず `.sample` に落ちる)を撃つ。渡した場合しか動かない実装は、
    ///   此の対照が無いと「明示し忘れた日」に本物の `DiffClient` へ静かに戻る。
    func testDiffButtonWithoutExplicitFixtureFallsBackToSampleNotTheRealClient() throws {
        let app = launch(conversation: "conversation-3roles")
        _ = try openDiff(app)

        // sample fixture の中身(`DiffFetchingFixture.sample`)から取った、実在を保証する文字列。
        let path = app.staticTexts["ios/Sources/Screens/Conversation/DiffView.swift"]
        XCTAssertTrue(path.waitForExistence(timeout: 10),
                      "既定の fixture が出ていない(本物の DiffClient へ落ちた疑い = 網羅欠陥の再発)")
        XCTAssertTrue(app.staticTexts["+2"].exists)
        XCTAssertTrue(app.staticTexts["-1"].exists)
        attachScreenshot(app, name: "diff-default-fallback-sample")
    }

    func testDiffSampleShowsStagedAndUnstagedFiles() throws {
        let app = launch(conversation: "conversation-3roles", diff: "diff-sample")
        _ = try openDiff(app)

        XCTAssertTrue(app.staticTexts["ios/Sources/Screens/Conversation/DiffView.swift"]
            .waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["rc-backend/src/sessiondiff.mjs"].exists)
        XCTAssertTrue(app.staticTexts["staged"].exists, "stage 済み file のチップが出ていない")
        attachScreenshot(app, name: "diff-sample")
    }

    func testDiffEmptyShowsTheQuietNoChangesState() throws {
        let app = launch(conversation: "conversation-3roles", diff: "diff-empty")
        _ = try openDiff(app)

        let empty = element(app, "diff.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "差分が無い会話で静かな空面が出ない")
        attachScreenshot(app, name: "diff-empty")
    }

    func testDiffNotARepoShowsTheReasonNotAnErrorBanner() throws {
        let app = launch(conversation: "conversation-3roles", diff: "diff-not-a-repo")
        _ = try openDiff(app)

        let reason = element(app, "diff.reason")
        XCTAssertTrue(reason.waitForExistence(timeout: 10), "git 管理外の理由面が出ない")
        // ★異常ではなく状態 -- エラーの帯(`diff.failed`)には絶対に落ちない。
        XCTAssertFalse(element(app, "diff.failed").exists,
                        "`not_a_repo` がエラー帯として描かれている(状態と異常を混同)")
        attachScreenshot(app, name: "diff-not-a-repo")
    }
}
