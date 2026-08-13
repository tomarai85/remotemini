import XCTest

/// 口座の表示と切替(REQUIREMENTS §4-5 / §5-8)を**画面で**測る。
///
/// ★何故 UI 検査が要るか: 此の repo は同じ形の欠陥を繰り返し測っている ——
/// 単体が全部緑のまま画面から物が消える(`ios/tools/signout-notice-control.sh` の
/// M8 / M9 / M17 が其の実演)。口座の層も同型で、`AccountViewModel` の相が正しくても
/// `ListView` の toolbar から `AccountBar` が外れれば単体は1本も落ちない。
/// 配線の1行が黙って外れた日に気付けるかを此処で測る。
///
/// `RC_UI_FIXTURE` は `RootView.fixtureAccountViewModel()` が読む。fixture の名前を
/// 名乗らない走行でも本物のクライアントには落ちない(同関数の注釈)ので、
/// 一覧の fixture(`list-normal`)でも口座は fixture のまま出る。
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

    /// ①**画面に出ている事**。単体では永久に届かない一歩。
    func testTheAccountIsActuallyOnTheScreen() {
        let app = launch(account: "account-rotating")

        let label = element(app, "account.label")
        XCTAssertTrue(label.waitForExistence(timeout: 10), "口座のラベルが画面に無い")
        XCTAssertEqual(label.label, "fixture-a@example.com")
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

    /// ③**押すと実際に変わる**。ラベルが押せる事ではなく、**中身が入れ替わる**事を測る。
    /// 2つの名前を持つ fixture にしてあるのは此の為で、1つだと「押せた」までしか言えない。
    func testTappingThroughTheConfirmationActuallyChangesTheAccount() {
        let app = launch(account: "account-rotating")

        let label = element(app, "account.label")
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        XCTAssertEqual(label.label, "fixture-a@example.com")

        element(app, "account.switch").tap()

        // ④確認を挟む事そのものの検査。確認なしで即座に切り替わる実装は、
        //   歩きながらの誤タップで艦隊の口座を動かす。
        let confirm = element(app, "account.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "確認が出ないまま切り替わろうとしている")
        confirm.tap()

        let switched = element(app, "account.label")
        XCTAssertTrue(switched.waitForExistence(timeout: 10))
        // 中身が入れ替わった事を名前で見る。
        var attempts = 0
        while switched.label != "fixture-b@example.com" && attempts < 20 {
            usleep(200_000)
            attempts += 1
        }
        XCTAssertEqual(switched.label, "fixture-b@example.com", "押したのに口座が変わっていない")
    }

    /// ⑤**負の対照**: 1回目のタップでは口座が動かない。
    ///
    /// ④だけだと「確認は出すが、出した時点でもう切り替えている」実装が緑になる ——
    /// 人から見れば確認は形だけで、押す前に艦隊の口座が動いている。此処が其の的。
    ///
    /// ★取消ボタンを押す形では書かない(2026-08-12、実測): `role: .cancel` の
    ///   ボタンは iOS が確認シートの別枠に描き、`accessibilityIdentifier` が付かない
    ///   (`account.confirm` は見付かるのに `account.cancel` だけが見付からない)。
    ///   文言で探す形にすると、文言を変えた日に**黙って**外れる。
    ///   測りたいのは「取り消せる事」ではなく「**1回目で動かない事**」なので、
    ///   確認が出ている間に口座が元のままである事を直に見る。④と対で完全になる。
    func testTheFirstTapOpensTheConfirmationWithoutSwitchingAnything() {
        let app = launch(account: "account-rotating")

        let label = element(app, "account.label")
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        XCTAssertEqual(label.label, "fixture-a@example.com")

        element(app, "account.switch").tap()

        XCTAssertTrue(element(app, "account.confirm").waitForExistence(timeout: 5),
                      "確認が出ていない")
        // 確認が出ている**間**、口座は元のまま。切替は2回目のタップでしか起きない。
        XCTAssertEqual(element(app, "account.label").label, "fixture-a@example.com",
                       "確認を出した時点で既に切り替わっている")
    }
}
