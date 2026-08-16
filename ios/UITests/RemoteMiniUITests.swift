import XCTest

/// End-to-end UI tests for the List screen (Sprint 2 brief §5-b). Drives the real
/// app process through the `RC_UI_FIXTURE` launch-environment gate (see
/// `SessionsListingFactory`/`RootView`) -- no network stub, no `UI_TESTING` compile
/// condition. `app.launchEnvironment` is exactly the mechanism `RootView` reads via
/// `ProcessInfo.processInfo.environment["RC_UI_FIXTURE"]`, so this is the same code
/// path a real launch takes, just with a known env var set.
final class RemoteMiniUITests: XCTestCase {
    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = fixture
        app.launch()
        return app
    }

    /// Any element with this identifier, regardless of SwiftUI's choice of
    /// accessibility element type for it (container vs. leaf) -- `.otherElements`
    /// alone misses some SwiftUI view kinds, `.any` does not.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// 走査行の文。2026-08-16(§9-4)から常設の帯ではなく `list.root` の
    /// accessibilityValue に載る(画素に出さず、検査からは読める)。
    private func scanText(_ root: XCUIElement) -> String {
        (root.value as? String) ?? ""
    }

    // MARK: - list-normal: the ordinary list, not the empty/fault banners

    func testListNormalShowsTheListNotTheEmptyOrFaultBanner() {
        let app = launch(fixture: "list-normal")

        XCTAssertTrue(element(app, "list.root").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "list.empty").exists)
        XCTAssertFalse(element(app, "list.paneFault").exists)
        XCTAssertFalse(element(app, "list.unreachable").exists)
        // One row per `RouteLabel.Kind` in the fixture (`SessionsListingFixture.sampleRows`)
        // -- the choice row's title is distinctive enough to assert directly.
        XCTAssertTrue(app.staticTexts["Waiting for approval"].waitForExistence(timeout: 5))
    }

    // MARK: - list-panefault: the fault banner, with its real reason/detail text

    func testListPaneFaultShowsTheFaultBannerText() {
        let app = launch(fixture: "list-panefault")

        XCTAssertTrue(element(app, "list.paneFault").waitForExistence(timeout: 10))
        // The identifier marks which phase rendered; the banner's actual copy is
        // asserted too, so a regression that renders the *wrong* fault text (right
        // phase, wrong words) is still caught, not just "some banner appeared."
        //
        // ★この2行が、以前は本番に存在しない文字列だった(2026-08-08 / 監査 S8-22)。
        //   `pane-scan-timeout` は `paneFaultReason` が作れない語で、日本語の方も本番が
        //   出さない文 —— 検査は在り、走り、緑で、**測っていた物が架空**だった。
        //   今は `rc-backend/test/fixture-labels-producible.test.mjs` が、此の関数の中の
        //   `staticTexts["..."]` を `paneFaultView` の出しうる集合と突き合わせる
        //   (本数もちょうど2本と主張する ので、黙って1本にして緑にする事も出来ない)。
        XCTAssertTrue(app.staticTexts["Can't read the tmux pane list"].exists)
        XCTAssertTrue(app.staticTexts["tmux is replying, but the output is corrupted and unreadable. Nothing can be sent until this recovers. Check the desk."].exists)
        XCTAssertFalse(element(app, "list.empty").exists)
    }

    // MARK: - list-empty: "会話がありません", only reachable with no paneFault

    func testListEmptyShowsTheNoConversationsMessage() {
        let app = launch(fixture: "list-empty")

        let empty = element(app, "list.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertEqual(empty.label, "No sessions")
        XCTAssertFalse(element(app, "list.paneFault").exists)
        XCTAssertFalse(element(app, "list.unreachable").exists)
    }

    // MARK: - 一覧が机側へ走査を飛ばす回数(S8-5)
    //
    // 下の2本が測っているのは表示ではなく**回数**で、これは画面を見ても絶対に
    // 判らない: 同じ応答なら `phase` は同じ値に落ち着くので、1回取っても2回取っても
    // 一覧はまったく同じに見える。`SessionsListingFixture` の scan 行に取得の通し番号を
    // 載せてあるのがその為で、UI から取得回数を読む唯一の口。
    //
    // 「回数」を主張する検査には固有の落とし穴が在って、**器が死ぬと静かに緑になる**
    // (番号が増えなくなれば「取り直していない」も「計器が壊れた」も同じ見え方)。
    // だから両方とも、番号が読めなかった時は `XCTUnwrap` で**錨として落とす** ——
    // 「番号が無い」を 0 に丸めない。`ios/tools/list-return-refresh-control.sh` の
    // M3 がその区別を実測で固定する。

    /// 起動で何回取るか。**1回**でなければならない。
    ///
    /// 2026-08-08 までここは 2 だった: `ListView` の `.onChange(of: scenePhase)` が
    /// `oldPhase` を捨てて「`.active` に着いたか」だけを見ていて、iOS が起動を
    /// `.inactive -> .active` で通す為に `.task` の初回取得と重なって二重に撃っていた。
    /// 会話画面は Sprint 4 で同じ穴を塞いでおり(`ForegroundResume`)、一覧だけが
    /// 5 sprint 空いていた。通知バナーの出入りや Control Center を引いて戻す操作でも
    /// 同じ事が起きていた = 電話では1日に何度も起こる。
    ///
    /// ★「一瞬を掴む」形にしない為に、3秒の窓で**最大値**を見る。1回目を読んだ直後に
    ///   終わる検査は、2回目が 0.2 秒後に来る実装を緑で通す。
    func testColdLaunchFetchesTheListExactlyOnce() throws {
        let app = launch(fixture: "list-normal")

        let scan = element(app, "list.root")
        XCTAssertTrue(scan.waitForExistence(timeout: 10))

        let highest = try XCTUnwrap(
            highestFetchCount(scan, over: 3),
            "錨: scan 行に取得の番号が一度も載らない(実測: \(scanText(scan)))= 以下の主張は何も測っていない"
        )
        XCTAssertEqual(highest, 1, "起動から3秒の間に走った取得の回数。2 = `.task` と scenePhase が両方撃っている")
    }

    /// 背面から戻った時に何回取るか。**ちょうど1回**増えなければならない
    /// (brief §3-d 引き金 #3)。
    ///
    /// 上の `testColdLaunchFetchesTheListExactlyOnce` と対になっていて、片方だけでは
    /// 意味を成さない: 起動側の主張だけなら `.onChange(of: scenePhase)` の塊を丸ごと
    /// 消しても緑のままで、「余分に取らない」を「一度も取り直さない」で満たせてしまう。
    /// 番人が**区別している**事は、落とす辺と通す辺の両方を測って初めて主張になる。
    ///
    /// `press(.home)` -> `activate()` は本物の背面往復(`.active -> .inactive ->
    /// .background`、戻りはその逆)。`ForegroundResume` の単体検査は規則そのものを
    /// 測るが、規則が**この画面に繋がっている**事は測れない —— それが此処。
    func testReturningFromTheBackgroundRefreshesTheListExactlyOnce() throws {
        let app = launch(fixture: "list-normal")

        let scan = element(app, "list.root")
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        let beforeLabel = scanText(scan)
        let before = try XCTUnwrap(
            fetchCount(beforeLabel),
            "錨: scan 行に取得の番号が載っていない(実測: \(beforeLabel))= 以下の主張は何も測っていない"
        )

        XCUIDevice.shared.press(.home)
        app.activate()

        let after = try XCTUnwrap(
            settledFetchCount(scan, changedFrom: beforeLabel, timeout: 15),
            "背面から戻っても番号が動かない = 引き金 #3 が繋がっていない(取得 #\(before) のまま)"
        )
        XCTAssertEqual(after, before + 1, "背面から戻った時の取り直しはちょうど1回")
    }

    /// 会話から戻った時に何回取るか。**ちょうど1回**増えなければならない。
    ///
    /// 5つ目の引き金は `ListView` に1行も書かれていない —— SwiftUI が push の間だけ
    /// 覆われた `ListView` の `.task` を中断し、pop で走らせ直す事から出ている
    /// (詳細と実測表は `ListViewModel.refresh()` の doc)。書かれていないという事は
    /// 整理の一手で静かに消せるという事なので、配線ではなく振る舞いを此処に固定する。
    ///
    /// ★主張が「番号が変わった」ではなく **ちょうど +1** なのが要点。「変わった」
    ///   だけだと、戻るたびに2回撃つ実装を緑で通してしまう —— 電話から見ると同じに
    ///   見えて、机側には毎回2倍の走査が飛ぶ。実際 S8-5 が最初に足した
    ///   `.onDisappear { refresh() }` の1行がまさにそれで、この `+1` が掴んだ。
    func testReturningFromAConversationRefreshesTheListExactlyOnce() throws {
        let app = launch(fixture: "list-normal")

        let scan = element(app, "list.root")
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        let beforeLabel = scanText(scan)
        let before = try XCTUnwrap(
            fetchCount(beforeLabel),
            "錨: scan 行に取得の番号が載っていない(実測: \(beforeLabel))= 以下の主張は何も測っていない"
        )

        app.staticTexts["Waiting for approval"].tap()
        // 会話画面へ push できた事の錨。戻るボタンの label は一覧側の
        // `navigationTitle`(= 「セッション」)。`ConversationView` は toolbar を
        // 一つも持たないので、この bar に他のボタンは居ない。
        let back = app.navigationBars.buttons["Sessions"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "錨: 会話画面へ push できていない")
        back.tap()

        let after = try XCTUnwrap(
            settledFetchCount(scan, changedFrom: beforeLabel, timeout: 10),
            "戻っても scan 行の番号が動かない = 5つ目の引き金が繋がっていない(取得 #\(before) のまま)"
        )
        XCTAssertEqual(after, before + 1, "会話から戻った時の取り直しはちょうど1回")
    }

    /// `scan: … (取得 #N)` から N を読む。載っていなければ `nil` -- 「番号が無い」を
    /// 0 や -1 に丸めない(丸めると、器が死んだ回が差分の主張を素通りし得る)。
    private func fetchCount(_ label: String) -> Int? {
        guard let hash = label.lastIndex(of: "#") else { return nil }
        let digits = label[label.index(after: hash)...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// 窓の間ずっと標本を取り、読めた取得番号の**最大**を返す(一度も読めなければ `nil`)。
    ///
    /// 最大を採るのは、「何回撃ったか」の主張が**一瞬の読み**で崩れるから: 1回目を
    /// 読んで即座に終わる検査は、2回目が少し遅れて来る実装をそのまま緑で通す。
    /// 逆に最後の1点だけを読む形も駄目で、途中で番号が飛んでも見えない。窓の中の
    /// 最大なら、余分な発火は窓に入った時点で必ず主張を壊す。
    private func highestFetchCount(_ subject: XCUIElement, over seconds: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(seconds)
        var highest: Int?
        while Date() < deadline {
            if let n = fetchCount(scanText(subject)) {
                highest = max(highest ?? n, n)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return highest
    }

    /// scan 行が「**変わって、かつ落ち着いた**」所まで待って、その時の取得番号を返す。
    ///
    /// なぜ2段構えか(片方だけでは倒れる方向が違う):
    /// - 「変わるまで待つ」だけだと、2回撃つ実装が `#before+1` を通過する一瞬を
    ///   掴んでしまい得る = **偽の緑**。
    /// - 「落ち着くまで待つ」だけだと、取り直しが始まる前の値を静止と読む = 偽の赤。
    ///
    /// 変化を待った上で「同じ値を2回続けて読めた事」を静止の条件にすると、2回撃つ
    /// 実装は途中で掴んでも次の読みで値が動くので、必ず最終値(= +2)へ落ちる。
    private func settledFetchCount(_ subject: XCUIElement, changedFrom previous: String, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSeen: String?
        while Date() < deadline {
            let now = scanText(subject)
            if now != previous {
                if let lastSeen, lastSeen == now { return fetchCount(now) }
                lastSeen = now
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }
}
