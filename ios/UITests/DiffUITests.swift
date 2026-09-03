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

    /// 机が混んでいる(503 + `reason:"busy"`)時の空面と、Try again が**本当に撃ち直す**事
    /// (2026-09-03、Codex #4 の 2)。fixture `diff-busy-then-sample` は 1 回目だけ busy を返すので、
    /// 押した後に sample の中身が出れば「押した」ではなく「効いた」を測っている。
    func testDiffBusyShowsTryAgainAndTappingItReloads() throws {
        let app = launch(conversation: "conversation-3roles", diff: "diff-busy-then-sample")
        _ = try openDiff(app)
        let reason = element(app, "diff.reason")
        XCTAssertTrue(reason.waitForExistence(timeout: 10), "busy の空面が出ない")
        XCTAssertTrue(app.staticTexts["The desk is busy"].exists, "busy の見出しが無い")
        // ★`ContentUnavailableView` の中の要素は型(`.buttons`)では捕まらない(此の file の頭の註と
        //   同じ実測、2026-09-03: `app.buttons["diff.retry"]` は 5 秒待っても空だった)。`.any` で降りる。
        let retry = element(app, "diff.retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "Try again のボタンが無い(行き止まり)")
        attachScreenshot(app, name: "diff-busy")
        retry.tap()
        let path = app.staticTexts["ios/Sources/Screens/Conversation/DiffView.swift"]
        XCTAssertTrue(path.waitForExistence(timeout: 10), "★Try again を押しても撃ち直していない(sample が出ない)")
        XCTAssertFalse(element(app, "diff.reason").exists, "撃ち直した後も busy の面が残っている")
        attachScreenshot(app, name: "diff-busy-retried")
    }

    // (2026-09-03: 「押しても混んだまま」の検査は削った —— 押した後の主張が押す前から見える物だけで、
    //  ボタンの動作を空にしても緑だった(Codex #6 の Low)。動作は上の busy → sample が守る。)

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
        // 陰性対照(2026-09-03): 撃ち直しても変わらない reason には Try again を出さない(busy だけ)
        XCTAssertFalse(element(app, "diff.retry").exists, "not_a_repo に Try again が出ている")
        attachScreenshot(app, name: "diff-not-a-repo")
    }
}
