import XCTest

/// **401 で戻された鍵入力画面**を simulator で実際に開いて見る(2026-08-08、監査 X2-6、
/// DESIGN §2.65)。
///
/// ★この file が在る理由は S8-5 の再発防止。あの時は規則(どう振る舞うべきか)が正しく
/// 書かれ、単体も緑で、**画面に繋がっていなかった**。X2-6 の直しは形が全く同じ ——
/// 断りの文を作る純関数と、それを運ぶ器と、画面。単体で測れるのは前2つまでで、
/// 「body が実際に描くか」は単体からは永久に見えない。
///
/// ここで通す鎖は disk から画素まで:
///   `SignOutNoticeStoring` に断りが在る
///     -> `AppState.loadStoredCredentials()` が読む
///       -> `RootView.normalFlow` が鍵入力画面を選ぶ
///         -> `KeyEntryView` の body が節を描く
/// 途中のどれか1本が切れたらこの検査が落ちる。単体はどこも落ちない。
///
/// 種は `ios/Sources/Core/SignOutNoticeFixture.swift`(`#if DEBUG`)。`RC_UI_FIXTURE` の
/// 面は1つ増えるが、増やさない道は「画面に出る事を測らない」しか無かった —— 既存2面
/// (一覧 / 会話)は `AppState` を迂回する形なので、`AppState` が生む面には使えない。
final class KeyEntryUITests: XCTestCase {
    /// 文言は `KeyEntryView.sentence(for:)` から**手で書き写す**。生成側を呼んで
    /// 比べると「同じ関数が同じ物を返す」しか言えず、画面に出ているのがその文かを
    /// 測れない(`InFlightUITests` と同じ約束)。
    private let noticeSentence = "通っていた鍵がサーバに拒まれました。URL は前のまま入れてあるので、鍵だけ入れ直してください。"

    /// `SignOutNoticeFixture.baseURL` と同じ物を、これも手で書き写す。
    private let seededURL = "https://ui-fixture.invalid"

    private func launchRejected() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = "keyentry-rejected"
        app.launch()
        openManualEntry(app)
        return app
    }

    /// 2026-08-16(DESIGN §2.100)。鍵入力の欄は**1枚目から退避した**ので、此処の検査は
    /// 一段降りてから始まる。この関数を launch 側に埋めてあるのは、各検査が
    /// 「降りる」事を覚えていなくても済ませる為 —— 覚えさせると、書き忘れた1本が
    /// 「欄が無い」と言って落ち、製品の欠陥に見える。
    private func openManualEntry(_ app: XCUIApplication) {
        let link = element(app, "disconnected.manualEntry")
        XCTAssertTrue(link.waitForExistence(timeout: 20),
                      "1枚目に手入力への退避路が無い(§9-5 は欄を消すのではなく畳む)")
        link.tap()
        XCTAssertTrue(element(app, "keyEntry.baseURL").waitForExistence(timeout: 20),
                      "退避路を押しても欄に着かない")
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

    /// ★断りが**画面に出ている**。
    func testTheRejectedKeyNoticeIsActuallyOnTheScreen() {
        let app = launchRejected()

        let notice = element(app, "keyEntry.signOutNotice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10),
                      "★body が節を描かない実装を落とす(純関数は緑のまま通る)")
        XCTAssertEqual(notice.label, noticeSentence)

        photograph(app, "keyentry-signed-out")
    }

    /// URL 欄が前の値で埋まっている。
    func testTheURLFieldComesBackFilledWithTheURLThatWasBeingUsed() {
        let app = launchRejected()

        let field = element(app, "keyEntry.baseURL")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, seededURL,
                       "★URL を運ばない実装を落とす(電話で tailnet の URL を打ち直させる)")
    }

    /// ★鍵の側は埋まっていない。
    ///
    /// 直に「鍵欄が空」を見ないのは、空の `SecureField` の `value` が実装依存で
    /// (空文字か placeholder か)脆いから。代わりに**画面の事実**で押さえる:
    /// 接続ボタンは URL と鍵の両方が埋まるまで押せない。上の検査で URL が埋まっている
    /// 事は確定しているので、ボタンが押せない事は「鍵が空」以外では起こらない。
    ///
    /// 拒まれた鍵を欄に残す実装は、Tom に「入っているから合っている」と読ませて
    /// もう一度拒ませる —— 迷子を一段深くする。
    func testTheKeyFieldIsNotPrefilledWithTheKeyThatWasJustRejected() {
        let app = launchRejected()

        let field = element(app, "keyEntry.baseURL")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, seededURL, "前提: URL は埋まっている")

        let submit = element(app, "keyEntry.submit")
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled,
                       "★拒まれた鍵を欄に残す実装を落とす(URL が埋まっている以上、押せない理由は鍵が空だけ)")
    }

    // MARK: - 押した後の無言(2026-08-08、監査 X2-8、DESIGN §2.68)

    /// 文言は `KeyEntryViewModel` から**手で書き写す**。生成側を呼んで比べると
    /// 「同じ関数が同じ物を返す」しか言えない。秒は `BackendSession.interactiveTimeout`
    /// (= 8)の現物 —— 定数が動いたらこの検査が落ちるのが正しい。
    private let urlStageSentence = "サーバに届くか確かめています…(返事を最大8秒待ちます)"
    private let keyStageSentence = "鍵が通るか確かめています…(返事を最大8秒待ちます)"

    /// 1段目で止まる面 = 既存の `keyentry-rejected`(口が `.fixture(stallingAt: .url)`)。
    /// 2段目で止まる面 = `keyentry-slow-key`(`ios/Sources/Core/KeyEntryProbeFixture.swift`)。
    private func launchStallingOnKey() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = "keyentry-slow-key"
        app.launch()
        openManualEntry(app)
        return app
    }

    /// 打つ。ASCII のみ(日本語入力は simulator の入力元に依存する)。
    private func fill(_ app: XCUIApplication, _ identifier: String, _ text: String) {
        let field = element(app, identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "錨: \(identifier) が画面に在る")
        field.tap()
        field.typeText(text)
    }

    /// 識別子で絞った上で**文言まで**一致する要素。識別子だけで待つと、2段目の面では
    /// 1段目の文を掴んだ瞬間に緑になり得る(素通しの healthz は一瞬で返る)。
    private func sentence(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "keyEntry.inFlight")
            .matching(NSPredicate(format: "label == %@", text))
            .firstMatch
    }

    /// ★1段目の最中、画面が何を待っているかを言う。
    ///
    /// 直す前、接続を押した後は丸い印だけで最大16秒無言だった —— 電話の側からは
    /// 「押せていないのか / 待っているのか / 死んだのか」の区別が付かない。
    func testTheURLStageSaysWhatItIsWaitingFor() {
        let app = launchRejected()
        fill(app, "keyEntry.apiKey", "fixture-key")

        let submit = element(app, "keyEntry.submit")
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        submit.tap()

        XCTAssertTrue(sentence(app, urlStageSentence).waitForExistence(timeout: 10),
                      "★押した後を無言のままにする実装を落とす")
        XCTAssertFalse(sentence(app, keyStageSentence).exists,
                       "★2段を1つの文に畳む実装を落とす(どちらが詰まったかが消える)")

        photograph(app, "keyentry-inflight-url")
    }

    /// ★2段目の文は別物で、しかも1段目を**通り抜けた**事の報告になっている。
    ///
    /// ここが分かれ道: 1段目で止まるなら tailnet か edith 自体、2段目で止まるなら
    /// edith は起きていて rc-backend が詰まっている。旅先での直し方が別物。
    func testTheKeyStageSaysThatTheURLAlreadyPassed() {
        let app = launchStallingOnKey()
        fill(app, "keyEntry.baseURL", seededURL)
        fill(app, "keyEntry.apiKey", "fixture-key")

        let submit = element(app, "keyEntry.submit")
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        submit.tap()

        XCTAssertTrue(sentence(app, keyStageSentence).waitForExistence(timeout: 10),
                      "★2段目を言葉にしない実装を落とす")

        photograph(app, "keyentry-inflight-key")
    }

    /// ★確かめている間、欄は打ち替えられない。
    ///
    /// 打てる欄を残すと、返って来た「鍵が違います」が**画面に見えている鍵**の話では
    /// なくなる。単体は `viewModel.isChecking` までしか見られないので、
    /// `.disabled` が現に効いている事はここでしか測れない。
    func testTheFieldsCannotBeEditedWhileAStageIsRunning() {
        let app = launchRejected()
        fill(app, "keyEntry.apiKey", "fixture-key")

        let url = element(app, "keyEntry.baseURL")
        XCTAssertTrue(url.isEnabled, "前提: 押す前は打てる")

        let submit = element(app, "keyEntry.submit")
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        submit.tap()

        XCTAssertTrue(sentence(app, urlStageSentence).waitForExistence(timeout: 10), "錨: 現に走っている")
        XCTAssertFalse(url.isEnabled, "★確かめている間に URL を打ち替えられる実装を落とす")
        XCTAssertFalse(element(app, "keyEntry.apiKey").isEnabled,
                       "★確かめている間に鍵を打ち替えられる実装を落とす")
    }
}
