import XCTest

/// End-to-end UI tests for the **Conversation** screen. `RemoteMiniUITests` covers
/// List; until this file, the screen the whole app exists for (履歴 + ライブ / 打ち込む /
/// 割り込む) had ViewModel unit tests and no UI-level coverage at all, so nothing
/// proved the *view* was wired to the rules the ViewModel enforces.
///
/// Same mechanism as the List tests: the real app process, driven through the
/// `RC_UI_FIXTURE` launch-environment gate (`ConversationHistoryFactory`/`RootView`),
/// no network stub and no `UI_TESTING` compile condition.
final class ConversationUITests: XCTestCase {
    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = fixture
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// 「画面に居るか」。`exists` では足りない -- `LazyVStack` は画面のすぐ外の行も
    /// 作る事が在り、`ScrollView` の中身は画面外でも要素として存在し得る。だから
    /// 位置を測る検査は必ず**窓との重なり**で判定する。
    ///
    /// `isHittable` を使わないのは、一番下の行が composer の帯に覆われる為 -- あれは
    /// 「押せるか」であって「見えているか」ではない。
    private func isOnScreen(_ app: XCUIApplication, _ text: String) -> Bool {
        let element = app.staticTexts[text]
        guard element.exists else { return false }
        let frame = element.frame
        guard !frame.isEmpty else { return false }
        return app.windows.firstMatch.frame.intersects(frame)
    }

    // MARK: - conversation-3roles: the ordinary transcript

    func testThreeRolesShowsAllThreeRolesAndTheLoadEarlierButton() {
        let app = launch(fixture: "conversation-3roles")

        XCTAssertTrue(app.staticTexts["Check the booking status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Checking now — one moment."].exists)
        XCTAssertTrue(app.staticTexts["⚙ Bash"].exists)
        // `truncated: true` in the fixture is what puts this button on screen.
        XCTAssertTrue(element(app, "conversation.loadEarlier").exists)
        // Neither degradation banner belongs on a conversation that is reading fine.
        XCTAssertFalse(element(app, "conversation.degraded").exists)
        XCTAssertFalse(element(app, "conversation.stalled").exists)
        // 対照: この状態の poll は readable にならないので、下の2本が錨にしている
        // ライブの行は**出てはいけない**。出るなら錨の側が常に真 = 錨が錨でない。
        XCTAssertFalse(app.staticTexts["live row (working) arrived"].exists)
        XCTAssertFalse(app.staticTexts["live row (awaiting confirm) arrived"].exists)
    }

    // MARK: - conversation-busy: Tom's ruling, measured at the UI

    /// 「返答待ちであれ作業中であれいつでも見て、干渉できればいいんじゃないかな？」 --
    /// the ruling the whole screen is shaped around. `ConversationViewModel` has unit
    /// tests for `composerEnabled`/`interruptEnabled`, but a `.disabled(...)` modifier
    /// attached to the wrong subview would leave every one of them green while the
    /// phone went mute during exactly the state it exists to watch.
    func testBusyLeavesBothTheComposerAndTheInterruptButtonUsable() {
        let app = launch(fixture: "conversation-busy")

        // ★錨を先に取る。BUSY と「まだ screen を観測していない」は画面上まったく
        // 同じ(どちらも `guard let screen else { return true }` を通る)ので、
        // composer の主張だけでは **poll が読めたかどうかに関わらず緑**になる。
        // ライブの行は `applyReadablePoll` が `screen` を代入するのと同じ呼び出しで
        // しか届かないので、これが出た事が「BUSY が着いた」の証拠になる。
        XCTAssertTrue(
            app.staticTexts["live row (working) arrived"].waitForExistence(timeout: 10),
            "錨: readable な poll が適用されていない = 以下の主張は何も測っていない"
        )

        let composer = element(app, "conversation.composerField")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.isEnabled, "BUSY は composer を止めない(spec §0-c ⑤)")
        XCTAssertTrue(element(app, "conversation.interruptButton").isEnabled)
        XCTAssertFalse(element(app, "conversation.composerDisabledReason").exists)
        XCTAssertFalse(element(app, "conversation.interruptDisabledReason").exists)
    }

    // MARK: - conversation-choice: the one state that DOES take the composer away

    func testChoiceDisablesTheComposerAndSaysWhy() {
        let app = launch(fixture: "conversation-choice")

        // 錨(BUSY と同じ理由。CHOICE は composer が止まる事自体が判別子になるので
        // 此処では二重の確認だが、fixture を取り違えた時に気付ける = 文言が
        // classification ごとに違う理由)。
        XCTAssertTrue(app.staticTexts["live row (awaiting confirm) arrived"].waitForExistence(timeout: 10))
        // `display.choice` が適用された事の観測 -- 画面の分類とは別経路(§2-c は
        // 両者を同じ1箇所で扱うと決めているので、片方だけ着く事は在り得ない筈だが、
        // 「筈」を測る為に置く)。Sprint 6 の `choiceBadge` は Sprint 7 で card に
        // 統合済み(同じ refusal を2箇所に出すと、後で片方だけ動く)。
        XCTAssertTrue(element(app, "conversation.choiceCard").exists)

        let composer = element(app, "conversation.composerField")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertFalse(composer.isEnabled, "CHOICE と UNKNOWN だけが composer を止める")
        // The field stays on screen (deliberate: a composer that vanishes explains
        // nothing) and the reason is shown next to it.
        XCTAssertTrue(element(app, "conversation.composerDisabledReason").exists)
    }

    /// ★★**The end-to-end form of 「自動化に安全確認を押させない」.**
    ///
    /// `conversation-choice` is a permission prompt: `show: true`, three numbered
    /// options, and `buttons: []` because `classifyChoice` did not match it. What must
    /// be true on screen is a pair -- the question is fully visible (hiding it would
    /// hide the desk's own words from the person being asked to go check them), and
    /// **not one key exists to press**.
    func testAPermissionPromptShowsTheQuestionAndOffersNoKeys() {
        let app = launch(fixture: "conversation-choice")

        XCTAssertTrue(element(app, "conversation.choiceCard").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Claude requests permission to run:"].exists, "設問は隠さない")
        XCTAssertTrue(
            element(app, "conversation.choiceReason").exists,
            "server の refusal をそのまま出す(文言は view.mjs の CHOICE_BLOCKED)"
        )

        for key in ["1", "2", "3", "escape", "enter"] {
            XCTAssertFalse(
                element(app, "conversation.choiceButton.\(key)").exists,
                "許可画面に押せる鍵が1つでも出たら、それが D4 の逸脱そのもの(key=\(key))"
            )
        }
    }

    /// The other half of the pair. Same classification, same fixture machinery, one
    /// difference: the server handed over keys. If this screen ALSO had no buttons, the
    /// test above would pass for the wrong reason -- "the phone never draws buttons" is
    /// not the same property as "the phone draws exactly the buttons the server allowed".
    func testABenignMenuDrawsExactlyTheKeysTheServerAllowedNegativeControl() {
        let app = launch(fixture: "conversation-choice-keys")

        XCTAssertTrue(element(app, "conversation.choiceCard").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Apply this change?"].exists)

        for key in ["1", "2", "escape"] {
            let button = element(app, "conversation.choiceButton.\(key)")
            XCTAssertTrue(button.exists, "server が渡した鍵は出す(key=\(key))")
            XCTAssertTrue(button.isEnabled)
        }
        // …and only those. `enter` was not in `buttons`, so nothing may draw it.
        XCTAssertFalse(element(app, "conversation.choiceButton.enter").exists)

        // The refusal band is absent here, which is what makes the previous test's
        // assertion of its presence meaningful.
        XCTAssertFalse(element(app, "conversation.choiceReason").exists)

        // The composer is still disabled -- the card is the only way to act on a menu,
        // and the sentence next to the field must point at it rather than deny it.
        XCTAssertFalse(element(app, "conversation.composerField").isEnabled)
        let reason = element(app, "conversation.composerDisabledReason")
        XCTAssertTrue(reason.exists)
        XCTAssertFalse(
            reason.label.contains("選べません"),
            "押せる card の真上で「選べません」と言ってはならない"
        )
    }

    /// The invariant `ConversationViewModel.interruptAllowedOnChoiceScreen` exists to
    /// protect: the sentence shown to the user and the button's actual state must
    /// agree. Asserted as a **pair**, not against today's value -- item F in the
    /// carry-overs may flip that constant, and a test pinned to one wording would
    /// have to be edited in lockstep, which is precisely the two-places-to-update
    /// shape the constant was introduced to remove.
    func testTheChoiceSentenceAndTheInterruptButtonNeverDisagree() {
        let app = launch(fixture: "conversation-choice")

        let reason = element(app, "conversation.composerDisabledReason")
        XCTAssertTrue(reason.waitForExistence(timeout: 10))
        let promisesInterrupt = reason.label.contains("or interrupt")
        let interruptUsable = element(app, "conversation.interruptButton").isEnabled

        XCTAssertEqual(
            promisesInterrupt, interruptUsable,
            "文面が割り込みを約束するなら button は押せねばならず、押せないなら約束してはならない"
        )
        // The other half of the same pair: when it is not usable, the screen says so
        // rather than leaving a dead button unexplained.
        if !interruptUsable {
            XCTAssertTrue(element(app, "conversation.interruptDisabledReason").exists)
        }
    }

    // MARK: - conversation-long: どこへ寄せるか (Sprint 8)

    /// 開いた時、一番下に居る事。
    ///
    /// この主張が Sprint 8 まで書けなかったのは、上の6状態が**どれも4行**しか
    /// 返さないから -- 画面から溢れない会話では「一番下に居る」と「一番上に居る」が
    /// 同じ画面になり、どんな実装でも緑になる。溢れる長さは主張の前提であって
    /// 飾りではない。
    func testOpeningALongConversationLandsAtTheNewestLine() {
        let app = launch(fixture: "conversation-long")

        // 錨: 履歴が着いた事。`行 090` は最後の行なので、これが出た時点で
        // 「読み込めた」と「一番下に居る」が両方成り立っている。
        // ★倒れた時に**画面に何が居たか**を必ず残す(2026-08-31)。
        //   之を足した理由は、同じ赤を3回追って毎回「行が無い」までしか判らなかったから:
        //     全掃き(752件)  FAIL / FAIL / PASS   ← 断続的
        //     この class だけ  PASS
        //     単体 x3          PASS(3.6 / 3.8 / 4.2 秒)
        //     先行 class を1つずつ足す(Account / BuildIdentity / Attach / AwayDigest)PASS
        //   待ちを 20 秒へ延ばしても倒れた(23.4 秒で、行は**遅いのではなく無い**)ので、
        //   混み具合の問題ではない。次に倒れた1回で原因が判る様に、木と
        //   「そもそも会話画面に居るのか」を書き出す。**直すのではなく記録する** ——
        //   待ちを延ばすのは既に一度試して外した band-aid。
        let anchorArrived = app.staticTexts["line 090"].waitForExistence(timeout: 10)
        if !anchorArrived {
            print("DIAG-LONG-CONVERSATION-BEGIN")
            print("conversation.loadEarlier exists = \(element(app, "conversation.loadEarlier").exists)")
            print("conversation.composerField exists = \(element(app, "conversation.composerField").exists)")
            print("line 031 exists = \(app.staticTexts["line 031"].exists)")
            print("line 090 exists = \(app.staticTexts["line 090"].exists)")
            print(app.debugDescription)
            print("DIAG-LONG-CONVERSATION-END")
        }
        XCTAssertTrue(anchorArrived, "錨: 90行の履歴が着いていない = 以下は何も測っていない")
        XCTAssertTrue(isOnScreen(app, "line 090"), "開いた時は一番新しい行が見えていなければならない")

        // 対照。これが偽なら「1画面に全部入っている」= 上の主張は位置を測っていない。
        XCTAssertFalse(
            isOnScreen(app, "line 031"),
            "60行が1画面に収まっている = この fixture は位置の検査に使えない"
        )
    }

    /// ★★**素朴な「件数が変わったら一番下へ」を殺す為だけに在る検査。**
    ///
    /// `loadEarlier()` は古い行を**先頭に**足す。件数で追従させる実装はここで画面を
    /// 一番下へ引き戻し、押した行為そのものを画面から消す -- 動くし、落ちないし、
    /// 単体テストも全部緑のまま、ただ機能だけが無くなる。
    ///
    /// 主張は対の後半が本体: `行 031` が見える事**だけ**なら、たまたま長い画面でも
    /// 通り得る。`行 090` が**見えていない**事が、引き戻しが起きていない証拠。
    func testLoadEarlierRevealsTheOlderLinesInsteadOfSnappingBackToTheNewest() {
        let app = launch(fixture: "conversation-long")

        let loadEarlier = element(app, "conversation.loadEarlier")
        XCTAssertTrue(loadEarlier.waitForExistence(timeout: 10))
        loadEarlier.tap()

        // 錨: 2回目の応答は `truncated: false` なので、ボタンが消える事が
        // 「古い行が本当に増えた」の観測になる。行の有無で錨を取ると、増えていない
        // のに画面外で待ち続ける形になり得る。
        let buttonGone = NSPredicate(format: "exists == false")
        expectation(for: buttonGone, evaluatedWith: loadEarlier)
        waitForExpectations(timeout: 10)

        XCTAssertTrue(isOnScreen(app, "line 031"), "足す前に一番古かった行が見えていなければならない")
        XCTAssertFalse(
            isOnScreen(app, "line 090"),
            "一番下へ引き戻されている = 件数で追従する実装。押した行為が画面から消えた"
        )
    }

    // ★未測定(緑にも赤にも数えない): 「上へ遡って読んでいる最中に机が喋った時、
    // 引き摺り下ろさない事」。`isPinnedToBottom` が守っている性質そのものだが、
    // 現在の fixture では**読んでいる最中**という状態を決定的に作れない --
    // `PollFetchingFixture` は `.long` でライブ行を出さず、出す状態(`.busy`)は
    // 4行しか無いので溢れない。両方を満たす状態を作ると、今度は「行が届いた時刻」
    // と「指がスクロールを終えた時刻」の競争になる。
    // 決定的に測るには fixture 側に「合図を受けてから1行足す」口が要る。Sprint 9。

    // MARK: - Queue(v2、2026-08-14)— 帯が**画面に**在る事(単体では永久に届かない一歩)

    /// `.busy` の fixture は送信待ち2件を持つ(`PollFixture` の註釈)。此処で測るのは
    /// 3つ: 帯が出る / 件数と「まだ渡していない」の断りが出る / 取り消しの button が
    /// 押せる形で居る。押した後の挙動は fixture が「返らない」規約なので、
    /// isClearingQueue の間 button が死ぬ事(二度押しの口が無い事)まで。
    func testBusyShowsTheQueueStripWithCountAndCancelButton() {
        let app = launch(fixture: "conversation-busy")

        let strip = element(app, "conversation.queueStrip")
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "送信待ちの帯が画面に無い")
        let text = element(app, "conversation.queueText")
        XCTAssertTrue(text.label.contains("2 queued"), "件数が出ていない: \(text.label)")
        XCTAssertTrue(text.label.contains("not yet handed to Claude"),
                      "「走っている番は別」の断りの前半が落ちた: \(text.label)")

        let clear = element(app, "conversation.queueClear")
        XCTAssertTrue(clear.exists, "取り消しの button が居ない")
        clear.tap()
        // fixture は返らないので、押した直後から button は死んでいる = 二度押しの口が無い。
        XCTAssertFalse(clear.isEnabled, "取り消しが飛んでいる間も押せる = 二度撃ちの口")
    }

    /// 負の対照: queue を観測していない状態(`.threeRoles` は queued: nil)では
    /// 帯が**出ない**。出ると「0件」という観測の主張に見える。
    func testAStateWithoutAQueueObservationDrawsNoStrip() {
        let app = launch(fixture: "conversation-3roles")

        XCTAssertTrue(element(app, "conversation.composerField").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "conversation.queueStrip").exists,
                       "観測していないのに帯が出ている")
    }
}
