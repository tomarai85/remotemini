import XCTest

/// **飛んでいる最中の画面**を、初めて実機(simulator)で押して撮る(2026-08-08)。
///
/// `DESIGN.md` §2.56 が自分で「一番弱い所」と書いた項目がこれ ——
/// 3操作の「飛んでいる間」の文とスピナは、単体と純関数(`ConversationView.spins`)では
/// 測れているが、**`ProgressView` が画面で実際にどう出るか**は一度も見ていなかった。
/// 単体は「回すべきか」を答えるが「回った物が見えるか」は答えない。
///
/// ★その差が実際に出た(2026-08-08、監査 X-1): スピナは当初ボタン label の `HStack` の
/// 中に在り、`spins` は正しく押した鍵だけを回していたのに、`.disabled` がボタンの
/// subtree ごと淡くするので**スピナも一緒に淡くなり**、押した鍵と押していない鍵が
/// 同じ濃さで並んだ。撮る事で見つかり、位置(ボタンの外へ出す)で直した。
///
/// ★この file が Sprint 8 まで書けなかった理由は、消極ではなく**構造**。8-7 まで、
/// UI 検査用の会話画面は送信 / 割り込み / 打鍵の3口だけ**本物の client** を握っていて、
/// ボタンを押すと `ui-fixture.invalid` へ本当に HTTP が飛んだ。だから
/// `ios/UITests` の中の `.tap()` は Sprint 8-7 まで3箇所(古い行を読む / 一覧の行 /
/// 戻る)しか無く、**書き込み側のボタンを押す検査は1本も無かった**。
/// `ios/Sources/Core/WriteFixture.swift` が入って初めて、押しても外へ出ない。
///
/// 作り物の3口は 60 秒返らないので、押した後の画面は**止まったまま**測れる。
/// `RC_UI_FIXTURE` の面は1つも増えていない —— 飛んでいる面は「既存の面でボタンを
/// 押した状態」であって、新しい面ではない。
///
/// 撮った物の取り出し方(この file 自体は撮って添えるだけ):
/// `xcrun xcresulttool export attachments --path <.xcresult> --output-path <dir>`。
final class InFlightUITests: XCTestCase {
    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = fixture
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// 撮って `.xcresult` に添える。`.keepAlways` でないと**緑の実行では捨てられる** ——
    /// この file の目的は落ちた時の証拠ではなく、緑の時の見え方を人が見る事なので、
    /// 既定(`.deleteOnSuccess`)だと撮った物が毎回消える。
    private func photograph(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 文言は `ConversationViewModel` の3つの `*InFlightText` と同じ物を、
    /// **手で書き写して**置く。生成側を呼んで比べると「同じ関数が同じ物を返す」しか
    /// 言えず、画面に出ているのが本当にその文かを測れない。秒数だけは鎖の値なので
    /// `BackendSession.writeTimeout` に合わせて 30 —— これが変わったらこの検査は
    /// 落ちるべきで、落ちた時に直すのは文ではなく「電話が言う上限」の方。
    private let interruptSentence = "Asking it to stop… (waiting up to 30s for the desk)"
    private let choiceSentence = "Sending your choice… (waiting up to 30s for the desk)"
    private let sendSentence = "Sending… (waiting up to 30s for the desk)"

    // MARK: - 割り込みが飛んでいる間

    func testInterruptInFlightShowsItsSentenceAndLocksTheButton() {
        let app = launch(fixture: "conversation-busy")

        // 錨(`ConversationUITests` と同じ理由): BUSY と「まだ screen を観測していない」は
        // 画面上まったく同じなので、ライブの行が届いた事を先に取らないと、以下は
        // 「割り込める状態だったか」すら測っていない事になる。
        XCTAssertTrue(
            app.staticTexts["live row (working) arrived"].waitForExistence(timeout: 10),
            "錨: readable な poll が適用されていない = 以下は何も測っていない"
        )

        let button = element(app, "conversation.interruptButton")
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isEnabled, "押す前に押せない = 以下の tap は何も起こしていない")
        button.tap()

        let notice = app.staticTexts[interruptSentence]
        XCTAssertTrue(
            notice.waitForExistence(timeout: 10),
            "割り込みが飛んでいる間、画面が無言のまま(§2.56 が直した当の症状)"
        )
        XCTAssertTrue(element(app, "conversation.interruptInFlightNotice").exists)
        // 同じ `isInterrupting` が文とボタンの両方を動かしている事の観測。
        // 文だけ出てボタンが生きているなら、二度押しで2本飛ぶ。
        XCTAssertFalse(button.isEnabled, "飛んでいる間は押し直せてはならない")

        photograph(app, "interrupt-in-flight")

        // 対照。この画面は BUSY であって送信も打鍵もしていないので、他の2文が
        // 出ていたら「3操作の文が判別できる」という §2.56 の要点が崩れている。
        XCTAssertFalse(app.staticTexts[sendSentence].exists)
        XCTAssertFalse(app.staticTexts[choiceSentence].exists)
    }

    // MARK: - 打鍵が飛んでいる間(3操作で唯一、的が複数並ぶ)

    func testChoiceInFlightSpinsOnlyTheKeyThatWasPressed() {
        let app = launch(fixture: "conversation-choice-keys")

        let card = element(app, "conversation.choiceCard")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "錨: 選択カードが届いていない")

        let pressed = element(app, "conversation.choiceButton.1")
        let other = element(app, "conversation.choiceButton.2")
        XCTAssertTrue(pressed.waitForExistence(timeout: 10))
        XCTAssertTrue(pressed.isEnabled)
        XCTAssertTrue(other.isEnabled)
        pressed.tap()

        XCTAssertTrue(
            app.staticTexts[choiceSentence].waitForExistence(timeout: 10),
            "打鍵が飛んでいる間、画面は灰色になるだけで無言だった(§2.56)"
        )
        XCTAssertTrue(element(app, "conversation.choiceInFlightNotice").exists)
        // `choiceEnabled` は `isChoosing` の間 false なので**両方**伏せられる。
        // 「どれを押したか」を持つのは文ではなくスピナ側 —— それが撮る対象。
        XCTAssertFalse(pressed.isEnabled)
        XCTAssertFalse(other.isEnabled)

        // ★§2.62: スピナはボタンの**外**に居る事。
        //
        // これは撮っただけでは戻される類の欠陥だった —— 判定(`spins`)も文も正しく、
        // 単体は全部緑で、それでも画面上ではスピナが伏せられたボタンと一緒に淡くなり、
        // 押した鍵と押していない鍵の濃さが**同じ**になっていた(一番濃い画素が
        // どちらも 212 / 2026-08-08 実測)。単体で測れないのは色ではなく**位置**なので、
        // 位置の方を検査にする。
        //
        // 錨を先に取るのは、`ProgressView` が activityIndicator 以外の種別で
        // 出ていると下の「入っていない」が**中身を見ずに緑**になる為。
        // 錨が落ちたら直すのは実装ではなくこの検査の種別の方。
        XCTAssertGreaterThan(
            app.descendants(matching: .activityIndicator).count, 0,
            "錨: 画面のどこにもスピナが居ない。以下の『ボタンの中に居ない』が空振りする"
        )
        XCTAssertEqual(
            pressed.descendants(matching: .activityIndicator).count, 0,
            "スピナが押したボタンの中に戻っている = `.disabled` に一緒に淡くされる(X-1)"
        )

        photograph(app, "choice-in-flight")

        // ★カードが消えていない事。文をカードの**外**に置いた理由がこれで、
        // 逆に言えばカードが残っている限りこの検査はその設計を測っていない ——
        // 消える場合(poll が CHOICE でない画面を届ける)は作り物では作れないので、
        // ここで測れるのは「押した直後に消えはしない」までである事を明記しておく。
        XCTAssertTrue(card.exists)

        XCTAssertFalse(app.staticTexts[sendSentence].exists)
        XCTAssertFalse(app.staticTexts[interruptSentence].exists)
    }

    // MARK: - 送信が飛んでいる間

    /// `ios/UITests` で**初めて文字を打ち込む**検査。`canSend` は空白を除いた本文が
    /// 空でない事を要求するので、送信の面は打鍵・割り込みと違い「押すだけ」では作れない。
    func testSendInFlightShowsItsSentenceWhileTheButtonIsHeldDown() {
        let app = launch(fixture: "conversation-busy")

        XCTAssertTrue(
            app.staticTexts["live row (working) arrived"].waitForExistence(timeout: 10),
            "錨: readable な poll が適用されていない"
        )

        let composer = element(app, "conversation.composerField")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.isEnabled, "BUSY は composer を止めない(この検査の前提)")
        composer.tap()
        // ASCII で打つ。日本語を `typeText` に渡すと simulator の入力方式に依存し、
        // **測りたい物(送信中の面)と関係の無い所**で落ちる。
        composer.typeText("ping")

        let send = element(app, "conversation.sendButton")
        XCTAssertTrue(send.isEnabled, "本文を入れても押せない = 以下の tap は何も起こしていない")
        send.tap()

        XCTAssertTrue(
            app.staticTexts[sendSentence].waitForExistence(timeout: 10),
            "送信が飛んでいる間、文の無いスピナが最大30秒続く(§2.54 が直した当の症状)"
        )
        XCTAssertTrue(element(app, "conversation.sendInFlightNotice").exists)
        XCTAssertFalse(send.isEnabled, "飛んでいる間は押し直せてはならない")

        photograph(app, "send-in-flight")

        XCTAssertFalse(app.staticTexts[interruptSentence].exists)
        XCTAssertFalse(app.staticTexts[choiceSentence].exists)
    }
}
