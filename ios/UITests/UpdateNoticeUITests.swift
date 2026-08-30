import XCTest

/// 「机は新しい版を配っている」の帯が、**実際に画素になるか**。
///
/// 単体(`ListUpdateNoticeTests`)は `ListViewModel.updateNotice` までしか届かない。
/// 最後の継ぎ目 —— view が其れを描くか —— は画を出す検査でしか物を言えない。
/// 2026-08-27 に同じ形で踏んでいる: `.accessibilityElement(children: .contain)` が
/// 無い `VStack` に識別子だけ付けても、SwiftUI は素の並びをアクセシビリティの要素として
/// 公開しないので、**錨を置いた気になって到達不能**になる。grep の対照では捕まらない。
///
/// ★なぜ此の帯が要るか: CF-11 で私は「4件の指摘は反映済み」と報告したが、其の修正は
///   Tom が持っているどの版にも入っていなかった。CF-17 の実測では配布口に
///   `client=app` が1本も来ておらず、栞は一度も叩かれていない。
///   「新しい版が在る」を伝える経路が**私が思い出して言う**しか無かった。
final class UpdateNoticeUITests: XCTestCase {

    /// ★型を決め打ちで引かない。`list.root` は容器に付いており `otherElements` では
    ///   拾えなかった(2026-08-30 実測)。既存の UI 検査 3 本が同じ形の補助を持っている。
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = fixture
        app.launch()
        return app
    }

    /// 机が言っている時に**出る**。
    func testNoticeIsVisibleWhenTheDeskPublishesANewerBuild() {
        let app = launch(fixture: "list-update")
        let bar = element(app, "list.updateAvailable")
        XCTAssertTrue(bar.waitForExistence(timeout: 20),
                      "帯が画素になっていない。view が updateNotice を描いていないか、識別子が届いていない")
        // ★文面を丸ごと固定しない(机が語を直すたびに赤くなる)。数が出ている事だけ縛る ——
        //   「新しいのが在る」だけでは Tom は自分が何番なのか判らず、動く材料にならない。
        // ★帯は `.accessibilityElement(children: .contain)` の容器なので、文字は**子**に在る。
        //   容器の `label` を読むと空で、其れを「文面が無い」と読み違える（2026-08-30 実測）。
        let text = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "105")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "配布側の番号が画面に出ていない")
        XCTAssertTrue(text.label.contains("96"), "手元の番号が文面に無い")
    }

    /// ★「後で」で**その版だけ**黙る。消せない帯は壁紙になる(Codex 2026-08-30)——
    ///   「入れれば消える」は反論にならず、問題は入れるまでの期間そのもの。
    ///   CF-17 の実測ではそれが 9 ビルド分続いた。
    func testSnoozeHidesTheBarForThatBuild() {
        let app = launch(fixture: "list-update")
        XCTAssertTrue(element(app, "list.updateAvailable").waitForExistence(timeout: 20))
        let snooze = element(app, "list.updateAvailable.snooze")
        XCTAssertTrue(snooze.waitForExistence(timeout: 5), "「後で」が押せる形で出ていない")
        snooze.tap()
        // 押した直後に消える(次の取得を待たない —— 待つ形だと、押しても暫く残る)。
        XCTAssertFalse(element(app, "list.updateAvailable").waitForExistence(timeout: 3),
                       "「後で」を押しても帯が残っている")
    }

    /// ★言っていない時に**出ない**。此方が要。常に出ている帯は、真になった日に読まれない
    ///   —— 観測器の鍵の段が「段を降りた時だけ」なのと同じ理由。
    func testNoticeIsAbsentOnAnOrdinaryList() {
        let app = launch(fixture: "list-normal")
        // ★**先に一覧が出た事を確かめる**。待たずに不在を主張すると、単に描画前を
        //   見ているだけで「出ていない」が言えてしまう —— 不在の主張は、
        //   在るはずの物が在る事を先に見せてからでないと何も測っていない。
        XCTAssertTrue(element(app, "list.root").waitForExistence(timeout: 20),
                      "一覧そのものが出ていない = 不在を主張できる状態ではない")
        XCTAssertFalse(element(app, "list.updateAvailable").exists,
                       "机が何も言っていないのに帯が出ている(常に点いた警告は、真になった日に読まれない)")
    }

    /// ★上の2本が**同じ錨で反対の答え**を出す事を、1回の走行の中で見る。
    ///   片方だけだと「識別子の綴りを間違えた」と「本当に出ていない」が区別できない。
    func testTheSameAnchorSeparatesTheTwoFaces() {
        let withNotice = launch(fixture: "list-update")
        XCTAssertTrue(element(withNotice, "list.updateAvailable").waitForExistence(timeout: 20))
        withNotice.terminate()

        let without = launch(fixture: "list-normal")
        XCTAssertTrue(element(without, "list.root").waitForExistence(timeout: 20))
        XCTAssertFalse(element(without, "list.updateAvailable").exists)
    }
}
