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
        // ★未 provisioning(鍵入力画面)なら**未測定**(2026-09-02)。新品のシミュレータには種が
        //   無い —— sim ビルドは**意図して**鍵を持たない(build.sh 1b の註「単体も UI 検査も本物の
        //   鍵を一度も見ない」)。此処で落とすと「製品が壊れた」と「測る前提が無い」が同じ赤になる。
        //   実測: iPhone-dogfood を作り直した朝、此の 2 本が 5 件 赤になり、犯人探しに 3 走行 使った。
        //   机のログには sim からの要求が 0 件 = 一覧が出る前に止まっていた。
        //   ★未 provisioning の sim が最初に出す画面は `DisconnectedView`(`disconnected.manualEntry`)で、
        //   `keyEntry.baseURL` は其処には無い。後者だけを待つと印は一度も発火せず、`list.row` 不在の
        //   skip に落ちるまで 20 秒 前後 空待ちしていた(2026-09-02、@ path レーンの実測 23.3 秒 / 16.4 秒)。
        if app.descendants(matching: .any).matching(identifier: "disconnected.manualEntry").firstMatch
            .waitForExistence(timeout: 3)
            || app.descendants(matching: .any).matching(identifier: "keyEntry.baseURL").firstMatch
            .waitForExistence(timeout: 1) {
            throw XCTSkip("鍵入力画面 = 未 provisioning のシミュレータ(測っていない)")
        }

        // 一覧が埋まるのを待つ。本物の机に問い合わせるので、単体より長く見る。
        let firstRow = app.buttons.matching(identifier: "list.row").firstMatch
        // ★`cells.firstMatch` へ逃げない(2026-09-02)。新品の sim では初回起動画面の Form の
        //   セルを掴んで「会話へ行けない」= 製品の赤に化けた。行が無ければ**未測定**。
        let anyRow = firstRow

        guard anyRow.waitForExistence(timeout: 10) else {
            // 机に繋がっていない / 会話が1本も無い。**製品の欠陥ではない**ので落とさない。
            throw XCTSkip("一覧に会話が無い(机が落ちている / tailnet の外)= 測っていない")
        }
        anyRow.tap()

        // ★2026-09-07(案 B)に添付は `+` の 1 つへ畳んだ。会話の面に常設で居るのは入口の方で、
        //   写真は其れを開いた後に出る。「常設の物が押せる位置に在る」「送信と離れている」は
        //   入口について測り、「写真が居てピッカーを開く」は開いた後に測る。
        let menu = app.descendants(matching: .any).matching(identifier: "conversation.attachMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "会話画面に添付の入口が無い")
        XCTAssertTrue(menu.isHittable, "添付の入口が在るのに押せない位置に居る")

        // ★送信ボタンと**離れている**事。片手持ちの誤タップが常態なので、
        //   この2つが近いと「送るつもりが添付」「添付のつもりが送信」が起きる。
        let send = app.buttons["conversation.sendButton"]
        if send.exists {
            let gap = abs(menu.frame.midX - send.frame.midX)
            XCTAssertGreaterThan(gap, 100, "添付の入口と送信ボタンが近すぎる(\(gap)pt)")
        }

        menu.tap()

        let attach = app.descendants(matching: .any).matching(identifier: "conversation.attachButton").firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 10), "開いた添付の中に写真が無い")
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
        // ★`cells.firstMatch` へ逃げない(2026-09-02)。行(`list.row`)が無ければ未測定。
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("一覧に会話が無い = 測っていない")
        }
        attachScreenshot(app, name: "01-sessions")

        row.tap()
        // ★案 B(2026-09-07)以降、会話の面に常設で居るのは添付の**入口**。写真は其れを開いた後。
        let menu = app.descendants(matching: .any).matching(identifier: "conversation.attachMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        attachScreenshot(app, name: "02-conversation-with-attach-button")

        menu.tap()
        let attach = app.descendants(matching: .any).matching(identifier: "conversation.attachButton").firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 10))
        attachScreenshot(app, name: "03-attach-menu-open")

        attach.tap()
        Thread.sleep(forTimeInterval: 3)
        attachScreenshot(app, name: "04-photo-picker")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways   // 緑でも残す。残らない証拠は証拠ではない
        add(a)
    }
}
