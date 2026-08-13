import XCTest

/// 生きた机(edith)に繋ぐ煙試験。**普段の走行では走らない** —— `RC_LIVE_URL` /
/// `RC_LIVE_KEY` が test runner の環境に無ければ XCTSkip で降りる。
///
/// ★何を測るか(2026-08-13、Tom「Simulator でやれば?」から):
/// 合格条件 1-3 の「実機でしか測れない」とされていた部分のうち、**機能が繋がって
/// いる事**はシミュレータ + 本物のサーバで測れる。実機にしか残らないのは
/// セルラー経路の遅延と体感だけ。此の1本は其の線引きを機械にした物:
///   鍵入力画面に URL と鍵を**実際に打ち**(#64 の手動経路)、
///   本物のセッション一覧が描かれ、先頭の会話を開いて履歴が読める、まで。
///
/// ★fixture を一切使わない(`RC_UI_FIXTURE` を渡さない)。この suite で唯一、
///   normalFlow を通る検査 —— fixture の面が製品の入口を構造的に迂回する事故
///   (2026-08-11 の #64)への、走らせられる側からの対照でもある。
///
/// ★書かない事: 送信・割り込み・口座切替。生きた艦隊の状態を変える操作は
///   煙試験の資格を超える(読みだけが安全側)。
final class LiveSmokeUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testKeyEntryThenLiveListThenOpenFirstConversation() throws {
        // ★受け渡しはファイル(/tmp/rc-live-smoke.json、走行の間だけ在る)。
        //   env で渡す形は2つの理由で捨てた: (a) TEST_RUNNER_ 前置は此の構成では
        //   runner に届かず skip した(2026-08-13 実測)。(b) コマンドラインに載せると
        //   xcodebuild が実行行ごと echo して**鍵がログに出る**(同日、実際に出した)。
        //   シミュレータのプロセスは Mac のファイルを読めるので、0600 の一時ファイルが
        //   一番漏れない経路。
        let seedPath = "/tmp/rc-live-smoke.json"
        guard let data = FileManager.default.contents(atPath: seedPath),
              let seed = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let url = seed["url"], let key = seed["key"],
              !url.isEmpty, !key.isEmpty else {
            throw XCTSkip("\(seedPath) が無い = 生きた机に繋ぐ走行ではない")
        }

        let app = XCUIApplication()
        // fixture を名乗らない = normalFlow。新しい simulator では Keychain が空なので
        // 鍵入力画面から始まる(種は runner が再インストールした app には無い)。
        app.launch()

        // --- 鍵入力 or 既に一覧(どちらも正しい入口)---
        // simulator の Keychain は再インストールを跨いで生きるので、前の走行が蒔いた種で
        // **一覧へ直行**する事がある —— 其れは #64 の直し(種で入力欄を飛ばす)が働いた形で、
        // 検査が落ちる理由にならない。鍵入力が出た時だけ、手動経路(打って繋ぐ)を通す。
        let urlField = element(app, "keyEntry.baseURL")
        let scanLine = element(app, "list.scanLine")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && !urlField.exists && !scanLine.exists {
            usleep(300_000)
        }
        if urlField.exists {
            urlField.tap()
            urlField.typeText(url)
            let keyField = element(app, "keyEntry.apiKey")
            XCTAssertTrue(keyField.waitForExistence(timeout: 5))
            keyField.tap()
            keyField.typeText(key)
            element(app, "keyEntry.submit").tap()
        }

        // --- 生きた一覧(本物の走査行が出る = サーバの実データが着いた)---
        XCTAssertTrue(element(app, "list.scanLine").waitForExistence(timeout: 30),
                      "一覧に本物の走査行が出ない = 机に繋がっていない")

        // --- 先頭の会話を開いて履歴が読める ---
        let target = app.cells.firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "一覧の行が押せる形で居ない")
        target.tap()
        // 会話画面の印 = composer の実在(既存の ConversationUITests と同じ識別子)。
        // 履歴の中身はセッション依存なので個別の文字列は当てにしない(嘘の赤を作らない)。
        XCTAssertTrue(element(app, "conversation.composerField").waitForExistence(timeout: 20),
                      "会話画面に入力欄が出ない")
    }
}
