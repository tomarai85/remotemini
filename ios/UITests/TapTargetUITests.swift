import XCTest

/// **的の寸法**を実機(simulator)で測る(2026-08-08、監査 X2-3)。
///
/// この app は「机の前で使う道具」ではなく、**移動中に片手で押す道具**として作って
/// いる。にも関わらず、押す物の寸法を一度も測っていなかった —— 単体は「押したら
/// 何が起きるか」を答えるが、「親指が当たるか」は答えない。`ConversationView` の
/// 割り込み / 送信は `Image` に `.font(.title2)` を当てただけの素の的で、
/// 「再試行」「読み直す」に至っては `.font(.caption)` が乗っている。
///
/// ── なぜ XCUITest でなら測れるのか ──────────────────────────────────────────
/// XCUITest は色も材質も読めない(X-1 / X-3 がバイトの走査に落ちたのはその為)。
/// だが **`XCUIElement.frame` は読める**。寸法は色と違って実行時に取れる唯一の
/// 見た目の量なので、この項目だけは画面を撮らずに機械が判定できる。
///
/// ── なぜ変異対照(`*-control.sh`)を書かないか ─────────────────────────────
/// X-1 / X-3 に対照を置いたのは、あちらの検査が**バイトの走査**で、整形・改名・枝の
/// 追加で静かに的を外し、外れた事が緑で出るから。此処の主張は走っている画面から
/// 実測した数なので、`.tapTarget()` を1つ落とせばその的の行が**そのまま赤くなる**。
/// 検査自身が失敗する側に錨を持っている(寸法 0 は下限を満たさない)ので、
/// 対照の顔をした空回りを足す方が害になる。
///
/// 代わりに払った証拠: **当てる前にこの file を走らせて赤を見た**。実測値は
/// `DESIGN.md` の 2.66 に、どの的が何 pt だったかで入っている。緑にしてから
/// 書いた検査は、それが本物か永久に判らない。
///
/// ── 赤が暴いた別の欠陥(寸法より重い)────────────────────────────────────
/// 最初の走行で `conversation.stalled.retry` は「小さい」ではなく **「居ない」**で
/// 落ちた —— 入れ物の `conversation.stalled` に識別子を付けた時点で SwiftUI が
/// 中身を1要素に畳み、中のボタンが XCUITest からも VoiceOver からも触れなくなる。
/// `choiceCard` が同じ穴で一度直っている(`ConversationView` の
/// `.accessibilityElement(children: .contain)` の註)のに、同じ形が4箇所残っていた。
/// 名前の前方一致では取れない —— `failureView` は入れ物が `conversation.unreachable`、
/// 中が `conversation.retry` で、字面は親子に見えない。brace の入れ子で数えて4件。
///
/// だから此処には**寸法を測らない検査が1本**在る(`testTheDegradedBannerDoesNotSwallow…`)。
/// 畳みが解けている事だけを単独で見る面で、寸法の緑に紛れない。
///
/// ── 測れていない物(緑に丸めない)──────────────────────────────────────────
/// `conversation.retry`(取得失敗)と `conversation.notFound.backToList`(404)は
/// 作り物の面が無いので、修飾子は当てたが**寸法は測っていない**。両方 `ProgressView`
/// も持たない素の `Text` ボタンなので、測れている `list.retry` と同じ形。
/// この2つの入れ物に当てた `.contain` も同じ理由で未測定 —— 効いている事を主張
/// できるのは `.degraded` と `.stalled` の2面だけ。
final class TapTargetUITests: XCTestCase {
    /// Apple HIG の下限。app 側の定数を呼ばずに手で書くのは `InFlightUITests` の
    /// 文言と同じ理由 —— 生成側を呼んで比べると「同じ定数が同じ値を返す」しか
    /// 言えず、画面に出ている的が本当にその寸法かを測れない。
    private static let minimum: CGFloat = 44

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = fixture
        app.launch()
        return app
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

    /// 1つの的を測る。**居る事を先に取る**のは、赤の理由が「小さい」なのか
    /// 「そもそも画面に無い」なのかを、読む側が区別できるようにする為。
    ///
    /// ★居ない時に何が起きるかは実測した(2026-08-08 の初回走行)。`frame` が
    /// `CGRect.zero` を返すのではなく、`Failed to get matching snapshot` という
    /// **この file の外の言葉**で落ちる。錨が無ければ、寸法の話をしている検査が
    /// 寸法と無関係の文言で赤くなり、読む側は何を見ているのか判らない。
    private func assertThumbSized(
        _ app: XCUIApplication,
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = element(app, identifier)
        XCTAssertTrue(
            target.waitForExistence(timeout: 10),
            "錨: \(identifier) が画面に居ない = 以下の寸法は何も測っていない",
            file: file, line: line
        )
        let frame = target.frame
        XCTAssertGreaterThanOrEqual(
            frame.height, Self.minimum,
            "\(identifier) の高さが \(frame.height)pt(下限 \(Self.minimum)pt)",
            file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.width, Self.minimum,
            "\(identifier) の幅が \(frame.width)pt(下限 \(Self.minimum)pt)",
            file: file, line: line
        )
    }

    // MARK: - composer(割り込み / 送信)

    /// ★飛んでいる最中も測る。両方のボタンは飛ぶと `Image` が `ProgressView` に
    /// 入れ替わり、**中身が変われば的も変わる** —— 素のままだと縮む。押し直しを
    /// 止めたい局面(飛んでいる間)で的が縮むのは、伏せてある事に助けられて
    /// 症状が出ないだけで、寸法としては直っていない。
    func testTheComposerButtonsAreThumbSizedIdleAndInFlight() {
        let app = launch(fixture: "conversation-busy")
        XCTAssertTrue(
            app.staticTexts["live row (working) arrived"].waitForExistence(timeout: 10),
            "錨: readable な poll が適用されていない = 割り込める状態かも判っていない"
        )

        assertThumbSized(app, "conversation.interruptButton")
        assertThumbSized(app, "conversation.sendButton")
        photograph(app, "tap-targets-composer-idle")

        let interrupt = element(app, "conversation.interruptButton")
        XCTAssertTrue(interrupt.isEnabled, "押す前に押せない = 以下の飛行中は作れていない")
        interrupt.tap()
        XCTAssertTrue(
            app.staticTexts["Asking it to stop… (waiting up to 30s for the desk)"].waitForExistence(timeout: 10),
            "錨: 割り込みが飛んでいない = 以下は idle の的をもう一度測っているだけ"
        )
        assertThumbSized(app, "conversation.interruptButton")
    }

    /// 枠だけ広げて `contentShape` を落とすと、`frame` は 44pt を名乗るのに
    /// **押せるのは絵柄の上だけ**になる。上の検査は寸法しか見ないのでその実装で
    /// 緑のまま通る —— 既定の `tap()` が中心 = 絵柄の上を叩く為。だから端を叩く。
    func testTheInterruptButtonAnswersATapAtTheEdgeOfItsTarget() {
        let app = launch(fixture: "conversation-busy")
        XCTAssertTrue(
            app.staticTexts["live row (working) arrived"].waitForExistence(timeout: 10),
            "錨: readable な poll が適用されていない"
        )

        let button = element(app, "conversation.interruptButton")
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isEnabled, "押す前に押せない = 以下の tap は何も起こしていない")
        // 錨。的が下限に足りていなければ「広げた端」は存在せず、下の tap は
        // 絵柄の上に落ちる = contentShape を測っていない。
        XCTAssertGreaterThanOrEqual(
            button.frame.width, Self.minimum,
            "錨: 的が \(button.frame.width)pt しか無い。以下の『端を叩く』が端になっていない"
        )

        // 左端から 10%(44pt なら 4.4pt)。絵柄は中央の 22pt 前後なので、
        // 此処は広げた余白の側にしか無い。
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()

        XCTAssertTrue(
            app.staticTexts["Asking it to stop… (waiting up to 30s for the desk)"].waitForExistence(timeout: 10),
            "的の端が反応しない = 枠だけ 44pt で、実際に押せるのは絵柄の上だけ"
        )
    }

    // MARK: - 選択肢(縦に並ぶので、誤タップが別の答えを送る)

    func testTheChoiceButtonsAreThumbSized() {
        let app = launch(fixture: "conversation-choice-keys")
        XCTAssertTrue(
            element(app, "conversation.choiceCard").waitForExistence(timeout: 10),
            "錨: 選択カードが届いていない"
        )

        assertThumbSized(app, "conversation.choiceButton.1")
        assertThumbSized(app, "conversation.choiceButton.2")
        assertThumbSized(app, "conversation.choiceButton.escape")
        photograph(app, "tap-targets-choice-card")

        // ★隣と重なっていない事。的を縦に太らせた時に間隔を詰めると、
        // 「押しやすくした」が「隣も押しやすくなった」に化ける —— この画面は
        // 誤タップが**別の答えの送信**になる唯一の面なので、寸法だけでは足りない。
        let first = element(app, "conversation.choiceButton.1").frame
        let second = element(app, "conversation.choiceButton.2").frame
        XCTAssertGreaterThan(
            second.minY, first.maxY - 1,
            "選択肢の的が重なっている(1 の下端 \(first.maxY) / 2 の上端 \(second.minY))"
        )
    }

    // MARK: - 転写を遡る入口

    func testTheLoadEarlierEntranceIsThumbSized() {
        let app = launch(fixture: "conversation-long")
        assertThumbSized(app, "conversation.loadEarlier")
    }

    // MARK: - 壊れている時に押す物(旅程で一番押される類)

    /// 「応答が確認できません」の下に出る2つ。`.font(.caption)` が乗っていたので
    /// この画面の中で**一番小さい的**であり、かつ**一番追い詰められた時に押す物**。
    /// `.stalled` は連続 3 回の unreadable か経過 10 秒で来るので、待ちは長めに取る。
    func testTheStalledRecoveryButtonsAreThumbSized() {
        let app = launch(fixture: "conversation-stalled")
        XCTAssertTrue(
            element(app, "conversation.stalled").waitForExistence(timeout: 30),
            "錨: 段階が .stalled に上がっていない = 以下の2つは画面に無い"
        )

        assertThumbSized(app, "conversation.stalled.retry")
        assertThumbSized(app, "conversation.stalled.reread")
    }

    /// `list-panefault` ではない。あの面は brief §4 で「banner を単独で見せる」と
    /// 決まっていて**再試行のボタンを持たない** —— 最初にあの fixture で書いたら
    /// 「`list.retry` が画面に居ない」で落ち、それで気付いた。`list-fetchfail` は
    /// 取得が毎回失敗する面で、1回目の失敗で `.retryable(priorSessions: nil)` に入る。
    func testTheListRetryIsThumbSized() {
        let app = launch(fixture: "list-fetchfail")
        XCTAssertTrue(
            element(app, "list.retryable").waitForExistence(timeout: 10),
            "錨: 取得失敗の面(まだ取れていません)が出ていない = 再試行のボタンも出ていない"
        )

        assertThumbSized(app, "list.retry")
    }

    // MARK: - 畳みが解けている事(寸法ではない)

    /// `.stalled` の的が最初の走行で「小さい」ではなく**「居ない」**で落ちた事から
    /// 出た検査。入れ物に `.accessibilityIdentifier` を付けると SwiftUI は中身を
    /// 1要素に畳むので、`.accessibilityElement(children: .contain)` を併せて付けない
    /// 限り、中の識別子は XCUITest からも VoiceOver からも消える。
    ///
    /// ★`.degraded` を選ぶ理由: この面には**的が1つも無い**。`.stalled` でも同じ事は
    /// 起きているが、あちらは寸法の検査と同居しているので「44pt を満たした」の緑に
    /// 紛れる。此処なら、畳みが解けている事**だけ**が緑/赤を決める。
    func testTheDegradedBannerDoesNotSwallowItsTimestamp() {
        let app = launch(fixture: "conversation-degraded")
        XCTAssertTrue(
            element(app, "conversation.degraded").waitForExistence(timeout: 30),
            "錨: 段階が .degraded に上がっていない = 以下は空の面を見ているだけ"
        )

        XCTAssertTrue(
            element(app, "conversation.lastReadableAt").waitForExistence(timeout: 10),
            "入れ物が中身を畳んでいる = この banner の中に在る識別子は誰からも届かない"
        )
    }

    // MARK: - 鍵入力(Form の行は既に 44pt 在る、という前提を観測に変える)

    /// `keyEntry.submit` には `.tapTarget()` を当てていない。`Form` の `Section` の
    /// 行が既に下限を満たしている**筈**だから —— だがそれは私の思い込みであって
    /// 観測ではない。当てない判断の根拠を、思い込みではなく此処の数にする。
    /// 赤くなったら直すのは `KeyEntryView` の側。
    func testTheKeyEntrySubmitRowIsAlreadyThumbSized() {
        let app = launch(fixture: "keyentry-rejected")

        // 2026-08-16(DESIGN §2.100)。鍵の無い起動の1枚目は**名乗る面**になり、打つ欄と
        // 「接続」は退避路の奥へ移った。此の検査が見たい数(`Form` の行が親指に足りるか)は
        // 奥の面に在るので、一段降りてから測る。
        let link = element(app, "disconnected.manualEntry")
        XCTAssertTrue(link.waitForExistence(timeout: 10), "錨: 1枚目に手入力への退避路が在る")
        // 退避路の行も同じ下限で測る。**押せない退避路は退避路ではない**。
        assertThumbSized(app, "disconnected.manualEntry")
        link.tap()

        XCTAssertTrue(
            element(app, "keyEntry.signOutNotice").waitForExistence(timeout: 10),
            "錨: 断り付きの鍵入力画面に着いていない"
        )

        assertThumbSized(app, "keyEntry.submit")
    }
}
