import XCTest

/// 差分への行コメント(対照表 #6、2026-09-02)。`DiffUITests` と同じ2軸の起動 --
/// `RC_UI_FIXTURE`(会話)+ `RC_UI_DIFF_FIXTURE`(diff の中身、`DiffFactory`)。
///
/// ★此処だけの独立した fixture 軸は要らない -- 保留中のコメントは机へ一度も
///   読み書きしない、純粋に電話の中だけの状態(`ConversationViewModel.diffComments`)
///   なので、diff の中身さえ `diff-sample` で固定すれば足りる。**送信して消える所**
///   (`kind:"ok"` → clear)までは此処では測らない -- 送信の fixture
///   (`MessageSendingFixture`)は「飛んだまま返らない」1通りしか持たず(`WriteFixture`
///   の doc)、其れを変えると此の機能と無関係な検査(割り込み・打鍵)まで巻き込む。
///   其の分岐は `ConversationViewModelTests` が `applySendOutcome`/`send()` を直接
///   駆動して持つ -- 之は指で押せる部分(alert・マーカー・件数チップ)の網。
final class DiffCommentUITests: XCTestCase {
    private func launch(diff: String = "diff-sample") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = "conversation-3roles"
        app.launchEnvironment["RC_UI_DIFF_FIXTURE"] = diff
        app.launch()
        return app
    }

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

    /// `DiffFetchingFixture.sample` の1本目の file(`unstaged`)、1本目の hunk、
    /// 3番目の行(index 2 = `add` の `Text("new")`、行番号は 13 -- `DiffLineLocatorTests`
    /// が同じ算段を裏取りしている)。同じ header の中に旧側13(del 行)と新側13(此の行)
    /// が両方在るので、`kind` を宛先へ含める判断が効いている事も併せて踏む。
    private static let addedLineID =
        "diff.line.unstaged::ios/Sources/Screens/Conversation/DiffView.swift.0.2"

    private func openDiff(_ app: XCUIApplication) throws -> XCUIElement {
        let composerAnchor = app.buttons["conversation.sendButton"]
        guard composerAnchor.waitForExistence(timeout: 20) else {
            throw XCTSkip("会話画面が立たない = 測っていない")
        }
        let button = app.buttons["conversation.diff.open"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "工具帯に diff ボタンが無い")
        button.tap()
        return button
    }

    private func longPressAddedLine(_ app: XCUIApplication) -> XCUIElement {
        let line = element(app, Self.addedLineID)
        XCTAssertTrue(line.waitForExistence(timeout: 10), "sample fixture の3行目(add)が見つからない")
        line.press(forDuration: 0.8)
        return line
    }

    /// マーカーは行自体の `accessibilityValue`(`DiffHunkView` の doc、2026-09-02実測)で
    /// 持たせている -- 行の中の子 shape(見た目の縦線)の独立した識別子は `iPhone-lc` の
    /// 実測で一度も見つからなかった(親が `accessibilityIdentifier` を持つと、装飾用の
    /// 子は独立要素として出て来ない形だった)。
    private func hasCommentMarker(_ app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        let line = element(app, Self.addedLineID)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (line.value as? String) == "has-comment" { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (line.value as? String) == "has-comment"
    }

    func testLongPressOnALineOpensTheCommentAlert() throws {
        let app = launch()
        _ = try openDiff(app)

        _ = longPressAddedLine(app)

        XCTAssertTrue(app.alerts["Comment on this line"].waitForExistence(timeout: 5),
                      "長押しでコメントの alert が開かない")
        XCTAssertTrue(app.alerts.textFields.firstMatch.exists, "alert にコメントの入力欄が無い")
        XCTAssertTrue(app.alerts.buttons["Save"].firstMatch.exists)
        XCTAssertTrue(app.alerts.buttons["Cancel"].firstMatch.exists)
        XCTAssertFalse(app.alerts.buttons["Remove"].firstMatch.exists, "新規コメントに Remove は要らない")
        attachScreenshot(app, name: "diffcomment-alert-open")
    }

    func testSavingACommentShowsALineMarkerAndTheToolbarCountBadge() throws {
        let app = launch()
        _ = try openDiff(app)

        XCTAssertFalse(hasCommentMarker(app, timeout: 0.5), "前提: 保存前はマーカーが無い")

        _ = longPressAddedLine(app)
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("why this line?")
        app.alerts.buttons["Save"].firstMatch.tap()

        XCTAssertTrue(hasCommentMarker(app), "保存した行にマーカーが出ない")
        attachScreenshot(app, name: "diffcomment-marker-after-save")

        app.navigationBars.buttons.firstMatch.tap() // diff 画面から会話画面へ戻る
        let badge = element(app, "conversation.diff.commentCount")
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "工具帯の diff ボタンに件数チップが出ない")
        XCTAssertEqual(badge.label, "1")
        attachScreenshot(app, name: "diffcomment-badge-after-save")
    }

    func testLongPressingACommentedLineAgainPrefillsTheFieldAndOffersRemove() throws {
        let app = launch()
        _ = try openDiff(app)

        _ = longPressAddedLine(app)
        let field = app.alerts.textFields.firstMatch
        field.tap()
        field.typeText("first pass")
        app.alerts.buttons["Save"].firstMatch.tap()

        _ = longPressAddedLine(app)
        let reopened = app.alerts.textFields.firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertEqual(reopened.value as? String, "first pass", "編集時は前回のコメントで再開する")
        XCTAssertTrue(app.alerts.buttons["Remove"].firstMatch.exists, "既存コメントの編集には Remove が要る")
        app.alerts.buttons["Cancel"].firstMatch.tap()
    }

    func testRemoveClearsTheMarkerAndTheBadge() throws {
        let app = launch()
        _ = try openDiff(app)

        _ = longPressAddedLine(app)
        let field = app.alerts.textFields.firstMatch
        field.tap()
        field.typeText("to be removed")
        app.alerts.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(hasCommentMarker(app))

        _ = longPressAddedLine(app)
        XCTAssertTrue(app.alerts.buttons["Remove"].firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Remove"].firstMatch.tap()

        XCTAssertFalse(hasCommentMarker(app, timeout: 2), "Remove の後もマーカーが残っている")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertFalse(element(app, "conversation.diff.commentCount").exists,
                        "コメントが0件なのに件数チップが残っている")
        attachScreenshot(app, name: "diffcomment-after-remove")
    }

    /// ★押しても送らない規約(写真添付・slash チップ・`@` 補完と同じ4件目)を、
    ///   コメントの保存という別操作からも踏まない事を確かめる -- Save を押した直後の
    ///   composer に、コメントの文面が入っていてはいけない(入力欄は利用者の文だけ)。
    func testSavingACommentNeverTouchesTheComposerField() throws {
        let app = launch()
        _ = try openDiff(app)

        _ = longPressAddedLine(app)
        let field = app.alerts.textFields.firstMatch
        field.tap()
        field.typeText("should stay out of the composer")
        app.alerts.buttons["Save"].firstMatch.tap()

        app.navigationBars.buttons.firstMatch.tap()
        let composer = element(app, "conversation.composerField")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        // ★空欄の `TextField` は placeholder ("Message") を `value` に返す事が在るので、
        //   厳密な空文字との一致ではなく「コメントの文面を含まない」で見る。
        let value = composer.value as? String ?? ""
        XCTAssertFalse(value.contains("should stay out of the composer"),
                        "コメントの文面が composer へ漏れている")
    }
}
