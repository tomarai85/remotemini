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

    // MARK: - conversation-3roles: the ordinary transcript

    func testThreeRolesShowsAllThreeRolesAndTheLoadEarlierButton() {
        let app = launch(fixture: "conversation-3roles")

        XCTAssertTrue(app.staticTexts["予約の状況を確認して"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["確認します。少々お待ちください。"].exists)
        XCTAssertTrue(app.staticTexts["⚙ Bash"].exists)
        // `truncated: true` in the fixture is what puts this button on screen.
        XCTAssertTrue(element(app, "conversation.loadEarlier").exists)
        // Neither degradation banner belongs on a conversation that is reading fine.
        XCTAssertFalse(element(app, "conversation.degraded").exists)
        XCTAssertFalse(element(app, "conversation.stalled").exists)
        // 対照: この状態の poll は readable にならないので、下の2本が錨にしている
        // ライブの行は**出てはいけない**。出るなら錨の側が常に真 = 錨が錨でない。
        XCTAssertFalse(app.staticTexts["ライブ(作業中)の行が届いた"].exists)
        XCTAssertFalse(app.staticTexts["ライブ(確認待ち)の行が届いた"].exists)
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
            app.staticTexts["ライブ(作業中)の行が届いた"].waitForExistence(timeout: 10),
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
        XCTAssertTrue(app.staticTexts["ライブ(確認待ち)の行が届いた"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.staticTexts["この変更を適用しますか？"].exists)

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
        let promisesInterrupt = reason.label.contains("割り込み")
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
}
