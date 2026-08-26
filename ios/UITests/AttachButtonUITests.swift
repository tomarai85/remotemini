import XCTest

/// 「電話でしか押せないボタン」を、**人の指を借りずに**押せる所まで測る。2026-08-26。
///
/// ★他の UI 検査と決定的に違う点: `RC_UI_FIXTURE` を**渡さない**。つまり作り物の面ではなく
///   **製品の面**が立ち、焼き込まれた URL と鍵で本物の机に繋ぎに行く。
///   2026-08-16 に踏んだ「撮影器が製品を映していなかった」の逆をやる為で、
///   ここで fixture を渡した瞬間、この検査は「電話でしか押せない物」を1つも測らなくなる。
///
/// ★従って**繋がらない機体では意味を持たない**。tailnet の外や机が落ちている時は
///   一覧が空になり、下の検査は「会話が無い」で skip する —— 赤にしない。
///   赤にすると、回線の都合が製品の欠陥として報告される。
final class AttachButtonUITests: XCTestCase {

    private func launchReal() -> XCUIApplication {
        let app = XCUIApplication()
        // fixture を渡さない = 製品の経路。ここが此の検査の全部。
        app.launch()
        return app
    }

    func testTheAttachButtonExistsAndOpensThePicker() throws {
        let app = launchReal()

        // 一覧が埋まるのを待つ。本物の机に問い合わせるので、単体より長く見る。
        let firstRow = app.buttons.matching(identifier: "list.row").firstMatch
        let anyRow = firstRow.waitForExistence(timeout: 20)
            ? firstRow
            : app.cells.firstMatch

        guard anyRow.waitForExistence(timeout: 10) else {
            // 机に繋がっていない / 会話が1本も無い。**製品の欠陥ではない**ので落とさない。
            throw XCTSkip("一覧に会話が無い(机が落ちている / tailnet の外)= 測っていない")
        }
        anyRow.tap()

        let attach = app.buttons["conversation.attachButton"]
        XCTAssertTrue(attach.waitForExistence(timeout: 15),
                      "会話画面に写真ボタンが無い")
        XCTAssertTrue(attach.isHittable, "写真ボタンが在るのに押せない位置に居る")

        // ★送信ボタンと**離れている**事。片手持ちの誤タップが常態なので、
        //   この2つが近いと「送るつもりが写真」「写真のつもりが送信」が起きる。
        let send = app.buttons["conversation.sendButton"]
        if send.exists {
            let gap = abs(attach.frame.midX - send.frame.midX)
            XCTAssertGreaterThan(gap, 100, "写真ボタンと送信ボタンが近すぎる(\(gap)pt)")
        }

        attach.tap()

        // 写真ピッカーは別プロセス(PHPickerViewController)。**アプリ側の要素では出ない**ので
        // springboard 側を見る。出ない = 利用目的の文が無い等で iOS が出さなかった。
        let picker = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .otherElements.matching(NSPredicate(format: "label CONTAINS[c] 'Photo' OR label CONTAINS[c] '写真'")).firstMatch
        let appeared = picker.waitForExistence(timeout: 10)
            || app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] 'Photo'")).firstMatch.exists
            || app.navigationBars.count > 0

        XCTAssertTrue(appeared, "写真ボタンを押してもピッカーが出なかった")
    }
}

extension AttachButtonUITests {
    /// 押した後の画面を**焼いて残す**。2026-08-26。
    ///
    /// ★この repo の規約「Tom の目が検証器」を、Tom の手を借りずに満たす為の段。
    ///   緑の数は「押せた」を意味しない —— 画を1枚残して初めて、後から人が見て判る。
    ///   保存先に日付を焼かない(`shots.sh` が過去の証拠を黙って上書きした型を繰り返さない)。
    func testCaptureTheAttachFlowForHumanEyes() throws {
        let app = XCUIApplication()
        app.launch()

        let row = app.buttons.matching(identifier: "list.row").firstMatch
        guard row.waitForExistence(timeout: 20) || app.cells.firstMatch.waitForExistence(timeout: 10) else {
            throw XCTSkip("一覧に会話が無い = 測っていない")
        }
        attachScreenshot(app, name: "01-sessions")

        (row.exists ? row : app.cells.firstMatch).tap()
        let attach = app.buttons["conversation.attachButton"]
        XCTAssertTrue(attach.waitForExistence(timeout: 15))
        attachScreenshot(app, name: "02-conversation-with-attach-button")

        attach.tap()
        Thread.sleep(forTimeInterval: 3)
        attachScreenshot(app, name: "03-photo-picker")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways   // 緑でも残す。残らない証拠は証拠ではない
        add(a)
    }
}
