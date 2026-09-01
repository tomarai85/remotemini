import XCTest

/// 転写の探索を**実アプリの画面**で測る(spec §8 の扉C)。
///
/// ── 此の扉でしか守れない物 ────────────────────────────────────────────────
/// 扉A(`TranscriptSearchResponseTests` / `HistoryClientTests`)は復号と要求の形を、
/// 扉B(`ConversationViewModelTests`)は状態機械を守るが、**どちらも View を守らない**。
/// 具体的に此処だけが赤くなる欠陥:
///   - 結果の面を `overlay` ではなく差し替え(`if isSearching { … } else { 転写 }`)に
///     戻す変異 —— 状態機械は 1 ミリも変わらないので扉A/Bは全部緑のまま、
///     取り消した瞬間に着地がやり直しになる(spec §6-a)。
///   - 探索中に composer が残る変異 —— 探しながら机へ送れる形。
///   - 面の識別子の取り違え —— `emptyWhole` の文言を `emptyBounded` の面に出す。
///
/// ── network stub を持たない ────────────────────────────────────────────────
/// `RC_UI_FIXTURE` で口ごと作り物に差し替える既存の形をそのまま使う
/// (`ConversationUITests` と同じ)。`HistoryFetchingFixture` の探索は机と同じ機構
/// (チャンク・窓・上限)を回すので、面が「探した振り」で緑にならない。
final class ConversationSearchUITests: XCTestCase {
    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = fixture
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// 検索欄に語を入れて確定する。
    ///
    /// ★`typeText` で打つ(値の直接代入をしない)。`.searchable` の欄は
    ///   SwiftUI の `TextField` なので、値を書き込んでも内部状態に入らない事が在る。
    ///   確定は `\n` —— `.onSubmit(of: .search)` が拾う唯一の合図。
    @discardableResult
    private func submitSearch(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "検索欄が画面に無い")
        field.tap()
        field.typeText(text + "\n")
        return field
    }

    /// 会話が `.loaded` に達するまで待つ。
    ///
    /// ★錨に**一番下の行**(`line 240`)を使わない(2026-09-01 に実測で外した)。
    ///   転写の最後の行は着地の反復が完走して初めて実体化するので、機械が混んだ
    ///   走行では 15 秒に間に合わない事が在る —— 実際
    ///   `testDifferentQueriesProduceDifferentCountsNegativeControl` が其れだけで
    ///   落ちた(探索そのものは同じ走行で正しく動いていた)。
    ///   `conversation.composerField` は `.loaded` の枝でしか描かれず、位置にも
    ///   着地にも依存しないので、測りたい事(会話が読めた)を直接 押さえる。
    @discardableResult
    private func waitForLoaded(_ app: XCUIApplication) -> XCUIElement {
        let composer = element(app, "conversation.composerField")
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "会話が読み込まれていない")
        return composer
    }

    /// 転写が着地し終わるまで待つ。読み出しは着地が終わると**凍る**ので、
    /// `settled` を見てから測れば、以後の比較は時計に依存しない。
    private func waitForSettledLanding(_ app: XCUIApplication) -> String {
        let readout = element(app, "conversation.landingDistance")
        XCTAssertTrue(readout.waitForExistence(timeout: 15), "着地の読み出しが画面に無い")
        let settled = NSPredicate(format: "value BEGINSWITH 'settled'")
        expectation(for: settled, evaluatedWith: readout, handler: nil)
        waitForExpectations(timeout: 20)
        return readout.value as? String ?? ""
    }

    // MARK: - 絞り込みが本当に効いている(spec §9 の M8)

    /// 打った語を含む行だけが並ぶ。
    ///
    /// ★判別子の選び方が此の検査の全部。結果の面は転写に**重ねる**ので、
    ///   転写の行は階層に残ったまま = 「当たらない行が `exists` しない」は主張できない
    ///   (重ねた事の当然の帰結であって、絞り込みの証拠ではない)。
    ///   代わりに**転写に載っていない行**を撃つ:
    ///     転写(初回 `limit` 50)= `line 191`…`line 240`
    ///     走査の窓(末尾 120)   = `line 121`…`line 240`
    ///   `line 155` は窓の中に在って転写には無い。之が画面に現れたなら、
    ///   出したのは結果の面以外に有り得ない。
    func testSearchNarrowsToTheTypedTerm() {
        let app = launch(fixture: "conversation-search")
        waitForLoaded(app)
        // 錨: 探す前は居ない(居るなら判別子が判別子でない)。
        XCTAssertFalse(app.staticTexts["line 155"].exists)

        submitSearch(app, "line 15")

        let summary = element(app, "conversation.search.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertEqual(summary.label, "10 matches")
        XCTAssertTrue(app.staticTexts["line 155"].waitForExistence(timeout: 5),
                      "転写に無い行が結果の面に出ていない = 探索が転写の窓しか見ていない")
    }

    /// spec §9 の M8。**問いを無視して固定の答えを返す fixture** で緑にならない事。
    /// 件数が問いによって変わる事は、1 本の検査では原理的に示せない。
    func testDifferentQueriesProduceDifferentCountsNegativeControl() {
        let app = launch(fixture: "conversation-search")
        waitForLoaded(app)

        submitSearch(app, "line 15")
        let summary = element(app, "conversation.search.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let ten = summary.label

        // 欄を消して打ち直す。
        let field = app.searchFields.firstMatch
        field.tap()
        field.buttons.firstMatch.tap()          // 欄のクリア
        field.typeText("line 155\n")

        let one = NSPredicate(format: "label == %@", "1 matches")
        expectation(for: one, evaluatedWith: summary, handler: nil)
        waitForExpectations(timeout: 15)

        XCTAssertEqual(ten, "10 matches")
        XCTAssertNotEqual(ten, summary.label)
    }

    // MARK: - 0 件の 2 意味(spec §9 の M3)

    /// 会話の頭まで見た上での 0 件。**此処だけ**が言い切りの文を出す。
    func testEmptyWholeSaysThereIsNoMatchAnywhere() {
        let app = launch(fixture: "conversation-3roles")
        waitForLoaded(app)

        submitSearch(app, "zzzzz")

        XCTAssertTrue(element(app, "conversation.search.emptyWhole").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "conversation.search.emptyBounded").exists)
    }

    /// 走査が末尾で止まった上での 0 件。言い切らない。
    func testEmptyBoundedDoesNotClaimTheWholeConversation() {
        let app = launch(fixture: "conversation-search")
        waitForLoaded(app)

        submitSearch(app, "zzzzz")

        XCTAssertTrue(element(app, "conversation.search.emptyBounded").waitForExistence(timeout: 10))
        // ★2 つの面が**同じ識別子に畳まれていない**事。`.emptyWhole` を
        //   `.emptyBounded` へ写像する変異は、上の 1 本を落とすだけなら
        //   「文言が変わった」と読めてしまう。対で置いて初めて畳みを名指しできる。
        XCTAssertFalse(element(app, "conversation.search.emptyWhole").exists,
                       "走査が途中で止まったのに『この会話のどこにも無い』と言い切っている")
    }

    // MARK: - 切った事を名乗る(spec §9 の M10)

    /// `line` は窓の中の 120 行 全部に当たり、100 で切られる。
    func testCappedResultsSayTheyAreCappedAndThatTheScanStoppedEarly() {
        let app = launch(fixture: "conversation-search")
        waitForLoaded(app)

        // `line` は走査の窓 120 行 全部に当たる。上限 100 で切られるので
        // `matched`(120)> 見せている数(100)。
        submitSearch(app, "line")

        let summary = element(app, "conversation.search.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertEqual(summary.label, "120 matches")
        XCTAssertTrue(element(app, "conversation.search.shownCap").exists,
                      "見つけた数より少なく見せているのに、切った事を名乗っていない")
        // ★S3(切った)と S4(頭まで見ていない)は**独立**。両方 真なら 2 行とも出る。
        XCTAssertTrue(element(app, "conversation.search.boundedScan").exists)
    }

    /// 対照: 切っていない結果では `shownCap` が出ない。上の 1 本だけだと
    /// 「常に出す」実装でも緑になる。
    func testUncappedResultsDoNotShowTheCapLineNegativeControl() {
        let app = launch(fixture: "conversation-search")
        waitForLoaded(app)

        submitSearch(app, "line 23")

        XCTAssertTrue(element(app, "conversation.search.summary").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "conversation.search.shownCap").exists)
        // 走査は依然 途中で止まっているので、此方は出たままである事。
        XCTAssertTrue(element(app, "conversation.search.boundedScan").exists)
    }

    // MARK: - 机に届かない時(S7)

    func testUnreachableSearchOffersRetryWithoutTakingTheWholeScreen() {
        let app = launch(fixture: "conversation-search-unreachable")
        waitForLoaded(app)

        submitSearch(app, "boot")

        XCTAssertTrue(element(app, "conversation.search.failed").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "conversation.search.retry").exists)
        // ★転写は生きている = 画面全部を取っていない。会話が読めなくなった時の
        //   面(`conversation.notFound` / `conversation.contractViolation`)は出ない。
        XCTAssertFalse(element(app, "conversation.notFound").exists)
        XCTAssertFalse(element(app, "conversation.contractViolation").exists)
    }

    // MARK: - 探索中は送れない(spec §9 の M5)

    func testComposerAndLoadEarlierAreAbsentWhileSearching() {
        let app = launch(fixture: "conversation-search")
        waitForLoaded(app)
        // 錨: 探す前は 3 つとも居る。居なければ以下の「居ない」は何も測っていない。
        XCTAssertTrue(element(app, "conversation.sendButton").exists)
        XCTAssertTrue(element(app, "conversation.loadEarlier").exists)

        submitSearch(app, "line 23")
        XCTAssertTrue(element(app, "conversation.search.summary").waitForExistence(timeout: 10))

        XCTAssertFalse(element(app, "conversation.composerField").exists, "探しながら机へ送れる")
        XCTAssertFalse(element(app, "conversation.sendButton").exists)
        XCTAssertFalse(element(app, "conversation.loadEarlier").exists,
                       "探索中に転写の窓(`currentLimit`)が黙って動く道が開いている")
    }

    /// 打ちかけは面を畳んでも残る(`draft` は `didSet` で打鍵ごとに保存される)。
    func testTheDraftSurvivesOpeningAndCancellingASearch() {
        let app = launch(fixture: "conversation-search")
        let composer = waitForLoaded(app)
        composer.tap()
        composer.typeText("half typed")

        submitSearch(app, "line 23")
        XCTAssertTrue(element(app, "conversation.search.summary").waitForExistence(timeout: 10))
        cancelSearch(app)

        let back = element(app, "conversation.composerField")
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertEqual(back.value as? String, "half typed")
    }

    /// 検索を畳む。
    ///
    /// ★`app.buttons["Cancel"]` を叩かない(2026-09-01 に実測で外した)。
    ///   `.searchable` の Cancel は**入力中しか出ない** —— `\n` で確定した後は
    ///   消えていて、5 秒 待っても現れない。面から出る口はアプリ自身が持つ
    ///   (`conversation.search.close`)。
    private func cancelSearch(_ app: XCUIApplication) {
        let close = element(app, "conversation.search.close")
        XCTAssertTrue(close.waitForExistence(timeout: 10), "結果の面から出る口が画面に無い")
        close.tap()
    }

    // MARK: - ★着地の輪を壊していない(spec §6-b / §9 の M4)

    /// 検索の開閉を跨いで `conversation.landingDistance` の読み出しが
    /// **バイト単位で同一**である事。
    ///
    /// ★之が此の spec で一番硬い主張。読み出しは
    /// `settled <残り pt> <hog> first=… corr=… <sab> h=… top=… v=…` の 1 行で、
    /// 門(`initialLandingPending`)が閉じた時点で凍る。だから:
    ///   - `corr=` が増える  = 補正の輪が回り直した
    ///   - `first=` が変わる = `armInitialLanding()` が走り直した(= 差し替え実装)
    ///   - `v=` が変わる     = 検索欄の開閉で窓の高さが動いた(= `.always` でない置き方)
    /// どれも「取り消した瞬間に下端へ引き戻される」画面の直接の原因。
    ///
    /// ★対照が本物である事の根拠: `overlay` を
    /// `if isSearchPresented { 結果 } else { 転写 }` に替えると、転写の `ScrollView` の
    /// `.onAppear` が再発火して `armInitialLanding()` が `corr` と `first` を初期化する
    /// ので、此処は必ず赤くなる。
    func testLandingReadoutIsUnchangedAcrossASearch() {
        let app = launch(fixture: "conversation-search")
        waitForLoaded(app)
        let before = waitForSettledLanding(app)
        XCTAssertFalse(before.isEmpty, "読み出しが空 = 以下の比較は何も測っていない")

        submitSearch(app, "line 23")
        XCTAssertTrue(element(app, "conversation.search.summary").waitForExistence(timeout: 10))
        cancelSearch(app)
        XCTAssertTrue(element(app, "conversation.composerField").waitForExistence(timeout: 10))

        let after = element(app, "conversation.landingDistance").value as? String ?? ""
        XCTAssertEqual(after, before, "検索の開閉が着地の輪を回し直した(= 上へ遡って読んでいた人が下端へ引き戻される)")
    }
}
