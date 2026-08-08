import XCTest

/// **画面に出ている版が、本当に今焼いた commit を名乗っているか**を simulator で測る
/// (2026-08-08、監査 X2-7、DESIGN §2.67)。
///
/// ── 起票された欠陥より、その下に在った物の方が重い ────────────────────────
/// 監査が挙げたのは「版の名乗りが鍵入力画面にしか出ない」。読みに行ったら、出ている
/// 文字列そのものが何も識別していなかった —— `CFBundleShortVersionString: "0.1"` と
/// `CFBundleVersion: "1"` は `ios/project.yml` の直値で、最初のビルドから一度も
/// 変わっていない。つまり全てのビルドが `v0.1 (1)` と名乗っていた。
/// 意味の無い文字列を2画面目にも出すのは嘘を大きくするだけなので、出す先を増やす前に
/// 中身を実物(commit の short sha)にした。
///
/// ── この file の主張が、なぜ変異対照(`*-control.sh`)を要らなくするか ──────
/// 「版の行が `unknown` でない」は**鎖が丸ごと通った時にしか緑にならない**:
///   `ios/tools/build.sh` が `RC_BUILD_REV` を export する
///     -> `xcodegen generate` が `ios/project.yml` の `${RC_BUILD_REV}` へ差し込む
///       -> Info.plist に `RCBuildRev` が実値で載る
///         -> `BuildInfo.displayRev` が `${` を含まない値として通す
///           -> 帯と鍵入力画面の `Text` が描く
/// どの1本を切っても `unknown` に落ちて赤になる。検査自身が失敗する側に錨を持っている
/// ので(X2-3 の `TapTargetUITests` と同じ理由)、対照の顔をした空回りを足す方が害になる。
///
/// ★ただし赤が出た時の読み方を1つだけ知っておく事: `build.sh` を通さずに素の
/// `xcodegen generate` + `xcodebuild` で焼くと `RC_BUILD_REV` は未定義になり、
/// xcodegen は**落ちずに** `${RC_BUILD_REV}` を literal で書く。その時この file は
/// 赤くなるが、それは app の欠陥ではなく「焼き方が違う」の意味。既存の対照はどれも
/// `-only-testing` で自分の class しか撃たないので、此処には届かない(実測)。
///
/// ★上の「錨を持っている」は主張ではなく**測定**(2026-08-08): `RC_BUILD_REV` を
/// わざと未定義にして焼き、plist に `${RC_BUILD_REV}` が literal で入った状態で
/// この class を撃ったら **5/5 が赤**(`rev unknown`)。緑にした後で「赤にもなる筈」と
/// 書くのは、その検査が本物かを永久に判らなくする。対照を置かない判断の根拠が
/// 「錨がある」である以上、錨が在る事の方を観測しないと判断が自分の言葉に寄りかかる。
///
/// ── 測っていない物(緑に丸めない)────────────────────────────────────────
/// 画面の版が**机側(`/healthz` の `version`)と一致しているか**は測っていない。
/// 一致を目で確かめられる形(同じ repo の同じ short sha)にはしたが、電話が机の版を
/// 取りに行く配線は入れていない。それは v1 の範囲外。
final class BuildIdentityUITests: XCTestCase {
    /// `BuildInfo.unknown` / `BuildInfo.line` の前置きを**手で書き写す**。生成側を
    /// 呼んで比べると「同じ定数が同じ値を返す」しか言えず、画面に出ている文字列が
    /// 本当にそれかを測れない(`InFlightUITests` からの約束)。
    private let unknown = "unknown"
    private let prefix = "rev "

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

    /// 版の行を1面ぶん検める。存在 + 形 + 「識別している事」の3点。
    private func assertNamesARealBuild(_ app: XCUIApplication, _ identifier: String, _ face: String) -> String {
        let line = element(app, identifier)
        XCTAssertTrue(line.waitForExistence(timeout: 10), "錨: \(face) に版の行 \(identifier) が出ている")
        let text = line.label
        XCTAssertTrue(text.hasPrefix(prefix), "\(face): 版の行は「\(prefix)」で始まる: \(text)")
        XCTAssertNotEqual(text, prefix + unknown,
                          "\(face): 版が unknown = build.sh の RC_BUILD_REV が差し込まれずに焼かれている: \(text)")
        XCTAssertFalse(text.contains("${"),
                       "\(face): 差し込み前の文字列がそのまま画面に出ている: \(text)")
        XCTAssertFalse(text.contains("v0.1"),
                       "\(face): 直値の定数に戻っている(どのビルドでも同じ文字列を名乗る): \(text)")
        return text
    }

    /// ★本命。**取得が失敗している面でも**版が見える事。
    ///
    /// 直す前は帯が `.empty` / `.paneFault` / `.list` の3相にしか貼られておらず、
    /// 失敗の3相では帯ごと消えていた —— 「電話が古いビルドなのでは」を最も疑う場面で
    /// 版が見えない、という向きの欠け方。
    func testTheVersionIsVisibleWhileTheListIsFailing() {
        let app = launch(fixture: "list-fetchfail")
        XCTAssertTrue(element(app, "list.retryable").waitForExistence(timeout: 10),
                      "錨: 取得に失敗した面が出ている(fixture が効いていない緑を落とす)")
        _ = assertNamesARealBuild(app, "list.buildInfo", "取得失敗(retryable)")
        photograph(app, "buildinfo-list-fetchfail")
    }

    /// 3回失敗して赤い帯が出た後も版は残る。`.unreachable` は `.retryable` とは別の相で、
    /// 直す前はどちらも帯を持っていなかった。
    func testTheVersionSurvivesIntoTheUnreachableBanner() {
        let app = launch(fixture: "list-fetchfail")
        XCTAssertTrue(element(app, "list.retryable").waitForExistence(timeout: 10),
                      "錨: まず取得失敗の面に居る")

        // `ReachabilityMeter` の閾値は3。初回の取得で1、再試行2回で3になる。
        for _ in 0..<2 {
            let retry = element(app, "list.retry")
            XCTAssertTrue(retry.waitForExistence(timeout: 10), "錨: 再試行の的が出ている")
            retry.tap()
        }
        XCTAssertTrue(element(app, "list.unreachable").waitForExistence(timeout: 15),
                      "錨: 3回失敗して赤い帯まで来ている")
        _ = assertNamesARealBuild(app, "list.buildInfo", "接続不能(unreachable)")
        photograph(app, "buildinfo-list-unreachable")
    }

    /// 成功している3相にも出ている事。直す前から帯は在ったが、版は載っていなかった。
    func testTheVersionIsOnEverySuccessfulListFace() {
        for (fixture, face) in [("list-normal", "通常"), ("list-empty", "空"), ("list-panefault", "ペイン異常")] {
            let app = launch(fixture: fixture)
            XCTAssertTrue(element(app, "list.scanLine").waitForExistence(timeout: 10),
                          "錨: \(face) の帯が出ている")
            _ = assertNamesARealBuild(app, "list.buildInfo", face)
            app.terminate()
        }
    }

    /// 鍵入力画面 —— 直す前はここが**唯一**の出所だったのに、識別子が無いので
    /// どの検査からも見えていなかった。「出ている」を主張していたのは人の記憶だけ。
    func testTheVersionIsOnTheKeyEntryScreenAndCanBeSeenByATest() {
        let app = launch(fixture: "keyentry-rejected")
        XCTAssertTrue(element(app, "keyEntry.submit").waitForExistence(timeout: 10),
                      "錨: 鍵入力画面に居る")
        _ = assertNamesARealBuild(app, "keyEntry.buildInfo", "鍵入力")
        photograph(app, "buildinfo-keyentry")
    }

    /// ★2つの画面が**同じ1つのビルド**を名乗る事。別々に組み立てる実装(片方が
    /// `CFBundleVersion`、片方が `RCBuildRev` 等)だと、画面ごとに違う版が出て
    /// 「どっちが本当か」を人が判定する羽目になる。
    func testBothScreensNameTheSameBuild() {
        let listApp = launch(fixture: "list-normal")
        let onList = assertNamesARealBuild(listApp, "list.buildInfo", "一覧")
        listApp.terminate()

        let keyApp = launch(fixture: "keyentry-rejected")
        let onKeyEntry = assertNamesARealBuild(keyApp, "keyEntry.buildInfo", "鍵入力")

        XCTAssertEqual(onList, onKeyEntry, "一覧と鍵入力が違う版を名乗っている")
    }
}
