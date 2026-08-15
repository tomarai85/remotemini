import XCTest

/// 口座の表示と切替(REQUIREMENTS §4-5 / §5-8 / §9-3 / §9-4)を**画面で**測る。
///
/// ★何故 UI 検査が要るか: 此の repo は同じ形の欠陥を繰り返し測っている ——
/// 単体が全部緑のまま画面から物が消える(`ios/tools/signout-notice-control.sh` の
/// M8 / M9 / M17 が其の実演)。口座の層も同型で、`AccountViewModel` の相が正しくても
/// `ListView` の toolbar から `AccountBar` が外れれば単体は1本も落ちない。
/// 配線の1行が黙って外れた日に気付けるかを此処で測る。
///
/// ★2026-08-14 に**操作の道筋が変わった**(§9-4)。以前は工具帯のラベルを押すと
/// 確認シートが出て `POST /api/account/next` が飛んでいた(`account.switch` /
/// `account.confirm`)。今は工具帯は**名乗りと入口**だけで、切替は設定画面に在る:
///
///     account.open  ->  settings.account.row.<name>
///
/// 確認シートを畳んだのは「押した先が一覧の画面」だから —— 名指しは押す前に
/// 相手が読めていて、押した結果も同じ画面に出る。誤タップ1回で艦隊が動く形
/// (確認が要る形)だったのは、工具帯の1マスに切替を押し込んでいたからで、
/// 部屋を分けた事で確認そのものが要らなくなった。
final class AccountUITests: XCTestCase {
    /// 一覧の相と口座の相は**別の変数**(`AccountFixture.fromEnvironment()` の注釈が
    /// 経緯)。一覧を `list-normal` に固定して ListView へ到達させ、其の上で口座の相を
    /// 独立に振る —— 1つの変数に相乗りさせた最初の版は `root flow:normal` に落ちて
    /// 鍵入力画面が出ていた(2026-08-12、走行のログで確定)。
    private func launch(account: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = "list-normal"
        app.launchEnvironment["RC_UI_ACCOUNT_FIXTURE"] = account
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// 設定画面まで開く。`AccountFixture` の名前は4本 = `team` / `biz` / `sdgs` / `tom`。
    @discardableResult
    private func openSettings(_ app: XCUIApplication) -> XCUIElement {
        let entry = element(app, "account.open")
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "設定画面への入口が工具帯に無い")
        entry.tap()
        let root = element(app, "settings.root")
        XCTAssertTrue(root.waitForExistence(timeout: 10), "設定画面が開かない")
        return root
    }

    /// ラベルが `expected` になるまで待つ(`waitForExistence` は中身の変化を待たない)。
    private func waitForLabel(_ element: XCUIElement, _ expected: String, message: String) {
        var attempts = 0
        while element.label != expected && attempts < 25 {
            usleep(200_000)
            attempts += 1
        }
        XCTAssertEqual(element.label, expected, message)
    }

    // MARK: - 工具帯(名乗り)

    /// ①**画面に出ている事**。単体では永久に届かない一歩。
    func testTheAccountIsActuallyOnTheScreen() {
        let app = launch(account: "account-rotating")

        let label = element(app, "account.label")
        XCTAssertTrue(label.waitForExistence(timeout: 10), "口座のラベルが画面に無い")
        XCTAssertEqual(label.label, "team")
    }

    /// ②口座を名乗れない fixture でも**黙らない**。理由が画面に出る。
    /// 黙る実装は「口座が無い」と「訊けなかった」を見分けられなくする。
    func testABackendFailureIsSaidOutLoudRatherThanLeavingABlankLabel() {
        let app = launch(account: "account-backend-fails")

        XCTAssertTrue(element(app, "account.failed").waitForExistence(timeout: 10),
                      "机が失敗したのに画面が黙っている")
        XCTAssertFalse(element(app, "account.label").exists,
                       "失敗しているのに口座名を名乗っている")
    }

    func testAnUnreachableBackendAlsoSaysSo() {
        let app = launch(account: "account-unreachable")

        XCTAssertTrue(element(app, "account.failed").waitForExistence(timeout: 10))
    }

    /// ③一覧が読めていない事は**工具帯でも判る**。設定画面を開くまで気付けないと、
    /// 切替を試して初めて壊れていると知る事になる。
    func testADegradedListingIsFlaggedOnTheBarNotOnlyInsideSettings() {
        let app = launch(account: "account-listing-unreadable")

        XCTAssertTrue(element(app, "account.label").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "account.degraded").exists,
                      "一覧が読めていないのに工具帯が普段通りの顔をしている")
    }

    // MARK: - 設定画面(§9-4)

    /// ④**候補が名前で並ぶ**事。Tom の §9-3(「矢印のフォームでしかない」)の的。
    func testTheSettingsScreenListsTheAccountsByName() {
        let app = launch(account: "account-rotating")
        openSettings(app)

        for name in ["team", "biz", "sdgs", "tom"] {
            XCTAssertTrue(element(app, "settings.account.row.\(name)").exists,
                          "候補 \(name) が一覧に出ていない")
        }
        XCTAssertEqual(element(app, "settings.account.current").label, "team")

        // ★どれが現用かが**行の側でも**判る事。「現用」の欄だけだと、4本並んだ一覧の
        //   中で自分が今どこに居るかを人が目で照合する事になる。印(checkmark)は
        //   Button の `Selected` に畳まれて出るので、そこを測る
        //   (`settings.account.active` の識別子は行の身元を奪うので置いていない ——
        //   ⑧の註が実測)。
        XCTAssertTrue(element(app, "settings.account.row.team").isSelected,
                      "現用の行に印が付いていない")
        XCTAssertFalse(element(app, "settings.account.row.biz").isSelected,
                       "現用でない行に印が付いている")
    }

    /// ⑤**名指しで押すと実際に変わる**。1本目(現用)ではなく3本目を押すので、
    /// 「次へ進めただけ」の実装では此処が緑にならない —— 矢印なら `biz` に行く。
    func testTappingANamedRowSwitchesToThatAccountNotMerelyTheNextOne() {
        let app = launch(account: "account-rotating")
        openSettings(app)

        element(app, "settings.account.row.tom").tap()

        waitForLabel(element(app, "settings.account.current"), "tom",
                     message: "押した口座ではない所に着いた(矢印で1つ進めただけの可能性)")
    }

    /// ⑥切替が**工具帯まで戻る**事。設定画面の中だけ直って一覧の名乗りが古いままだと、
    /// 電話が嘘をつく形になる(相を持つ器は1つ = `AccountViewModel` を渡している事の観測)。
    func testTheSwitchIsReflectedBackOnTheListScreen() {
        let app = launch(account: "account-rotating")
        openSettings(app)

        element(app, "settings.account.row.biz").tap()
        waitForLabel(element(app, "settings.account.current"), "biz", message: "設定画面で切り替わっていない")

        app.navigationBars.buttons.firstMatch.tap() // 戻る

        let label = element(app, "account.label")
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        waitForLabel(label, "biz", message: "設定画面では変わったのに一覧の名乗りが古いまま")
    }

    /// ⑦**負の対照その1**: 入口を押しただけでは口座が動かない。
    ///
    /// ⑤だけだと「設定画面を開いた時点でもう切り替えている」実装が緑になる ——
    /// 人から見れば画面を見に行っただけで艦隊の口座が動いている。
    func testOpeningSettingsDoesNotItselfSwitchAnything() {
        let app = launch(account: "account-rotating")
        openSettings(app)

        XCTAssertEqual(element(app, "settings.account.current").label, "team",
                       "設定画面を開いた時点で既に切り替わっている")
    }

    /// ⑧**負の対照その2**: 選べない行が**消えない**。
    ///
    /// トークンの欠けた `sdgs` を一覧から外す実装は、人から見れば「そんな口座は無い」
    /// になり、本当の理由が画面から消える。出して・押せなくして・理由を置く。
    ///
    /// ★理由を**別の element ではなく行の label で**測る(2026-08-15、走行の木を出して
    ///   判った)。SwiftUI の Button は label を子から畳む時に子の識別子も吸い上げるので、
    ///   理由の `Text` に識別子を付けると**行の Button がその識別子を名乗る**
    ///   (実測: 行が `settings.account.blocked` を名乗り、身元が子に乗っ取られていた)。
    ///   畳まれた label を読むのが、この構造で「描かれた文字列」を測る唯一の形。
    func testARowThatCannotBeSelectedStaysVisibleAndDisabledWithItsReason() {
        let app = launch(account: "account-rotating")
        openSettings(app)

        let blockedRow = element(app, "settings.account.row.sdgs")
        XCTAssertTrue(blockedRow.exists, "選べない行が一覧から消えている")
        XCTAssertFalse(blockedRow.isEnabled, "選べない行が押せてしまう")
        XCTAssertTrue(blockedRow.label.contains("トークンが edith にありません"),
                      "選べない理由が行に出ていない(label: \(blockedRow.label))")
    }

    /// ⑧-b **押しても動かない**事を、押して測る。⑧は印(`Disabled`)を測っているが、
    /// 印が正しくても押した先が動く実装は在り得る —— 人が触るのは印ではなく画面。
    ///
    /// 電話の側は2重に守ってある(view が `.disabled`、view model も
    /// `AccountViewModel.select` で行の `blocked` を見て往復を止める)。どちらが効いても
    /// 此処は緑になる = 片方が外れた日は**もう片方が残っている**事の観測。
    func testTappingABlockedRowDoesNotSwitchTheAccount() {
        let app = launch(account: "account-rotating")
        openSettings(app)

        element(app, "settings.account.row.sdgs").tap()

        // 何かが動くなら此処で動く(⑤の名指しの切替は fixture 相手なので即時 ——
        // `waitForLabel` の 25 回 x 0.2 秒を待たずに 1 回目で一致する)。
        usleep(1_500_000)
        XCTAssertEqual(element(app, "settings.account.current").label, "team",
                       "選べない行を押したら口座が動いた")
    }

    /// ⑨机が断った時、**画面だけ切り替わらない**事。
    /// `account-refuses` の fixture は `index` を動かさずに 400 を返す。
    func testARefusalShowsTheReasonAndLeavesTheAccountWhereItWas() {
        let app = launch(account: "account-refuses")
        openSettings(app)

        element(app, "settings.account.row.biz").tap()

        XCTAssertTrue(element(app, "settings.account.lastFailure").waitForExistence(timeout: 10),
                      "断られたのに画面が黙っている")
        XCTAssertEqual(element(app, "settings.account.current").label, "team",
                       "机が断ったのに画面だけ切り替わった")
    }

    /// ⑩一覧が読めない時、**候補を空で並べない**。空の一覧は「候補が1つも無い」と
    /// 読めるが、実際は「読めなかった」。理由を出し、退避路(矢印)は残す。
    func testAnUnreadableListingSaysSoAndKeepsTheFallbackArrow() {
        let app = launch(account: "account-listing-unreadable")
        openSettings(app)

        XCTAssertTrue(element(app, "settings.account.unreadable").exists,
                      "読めなかった理由が画面に無い")
        XCTAssertFalse(element(app, "settings.account.row.team").exists,
                       "読めていない一覧から候補を描いている")
        XCTAssertTrue(element(app, "settings.account.next").exists,
                      "唯一残る手(矢印)まで消えている")
    }

    /// ⑪退避路が**実際に効く**事。名指しが出せない場面で押せる手が動かないなら、
    /// 出しておく意味が無い。
    func testTheFallbackArrowStillAdvancesWhenNamesCannotBeShown() {
        let app = launch(account: "account-listing-unreadable")
        openSettings(app)

        element(app, "settings.account.next").tap()

        waitForLabel(element(app, "settings.account.current"), "biz",
                     message: "一覧が読めない時の退避路が動いていない")
    }

    /// ⑫繋ぎ先が判る事(§9-4 で設定画面に移した表示)。**鍵は出さない**。
    func testTheSettingsScreenNamesTheEndpointWithoutTheKey() {
        let app = launch(account: "account-rotating")
        openSettings(app)

        let endpoint = element(app, "settings.endpoint")
        XCTAssertTrue(endpoint.exists, "繋ぎ先が画面に無い")
        XCTAssertFalse(endpoint.label.contains("ui-fixture-key"), "鍵が画面に出ている")
    }
}
