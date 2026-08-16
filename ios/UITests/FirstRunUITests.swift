import XCTest

/// **鍵を持たない電話が、打たずに一覧へ着く**を simulator で実際に見る(2026-08-11)。
///
/// ★此の file が在る理由。2026-08-11 に Tom が実機で開いた最初の画面は「Base URL と
/// API Key を打て」という欄だった。`REQUIREMENTS.md` の合格条件は「開くとセッション
/// 一覧が出る」で、人が打つとは何処にも書いていない。数十本の検査が一度も赤くならな
/// かったのは、**製品の入口を見る計器が1つも無かった**から:
///   - 一覧 / 会話の面(`RC_UI_FIXTURE` 既存3種)は `AppState` を丸ごと迂回する
///   - 鍵入力側の2面は鍵の**無い**金庫を渡し、鍵入力画面が出る事を確かめていた
/// つまり全ての面が「鍵は既に在る / 鍵は無いのが正しい」のどちらかを前提にしていて、
/// **鍵が無い電話が一覧に着く**を測る面が空席だった。私はスクリーンショットで毎回
/// 一覧を見て、アプリは一覧から始まると信じていた —— それは fixture が既に鍵を持って
/// いる面の写真で、初回起動の写真ではなかった。
///
/// 此処で通す鎖は刻印から画素まで:
///   `ProvisioningSource` が種を持つ
///     -> `AppState.loadStoredCredentials()` が Keychain の空を見て蒔く
///       -> `RootView.normalFlow` が一覧を選ぶ
///         -> `ListView` の body が版の帯まで描く
/// 途中のどれか1本が切れたら此の検査が落ちる。単体は何処も落ちない。
///
/// 種は `ios/Sources/Core/ProvisioningFixture.swift`(`#if DEBUG`)。**本物の刻印は
/// 握らせない** —— 焼いた機械の `Info.plist` に本物の鍵が入っている日に `Bundle` を
/// 読むと、結果が「その機械で誰が最後に焼いたか」で変わって検査でなくなる。
final class FirstRunUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func launch(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = fixture
        app.launch()
        return app
    }

    private func photograph(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// ★本体。刻印を持つ電話は、鍵入力画面を**一度も見ずに**一覧へ着く。
    ///
    /// 版の帯(`list.buildInfo`)で「一覧に着いた」を測るのは、口が本物の
    /// `SessionsClient` で `https://ui-fixture.invalid` へ繋ぎに行く = 一覧の中身は
    /// 取得に失敗した相で描かれるから。帯は `ListView` の `.safeAreaInset` に在って
    /// **どの相でも必ず出る**ので、着いた事だけを測るのに丁度いい。中身を測りたい
    /// 訳ではない —— 口まで作り物にすると、また入口を迂回した面が1つ増える。
    func testAProvisionedPhoneReachesTheListWithoutBeingAskedToTypeAnything() {
        let app = launch("provisioned-seed")

        XCTAssertTrue(element(app, "list.buildInfo").waitForExistence(timeout: 20),
                      "★種を蒔かない実装を落とす(初回起動が Base URL と API Key の入力欄になる)")
        XCTAssertFalse(element(app, "keyEntry.baseURL").exists,
                       "★入口に打つ欄が出る実装を落とす(下の錨が、此の行が測れる事を保証する)")
        XCTAssertFalse(element(app, "disconnected.reason").exists,
                       "★種が効いているのに『繋がっていない』面を出す実装を落とす")

        photograph(app, "firstrun-provisioned")
    }

    /// ★§9-5 の合格条件そのもの(2026-08-16、DESIGN §2.100)。
    /// **種の無い電話の1枚目にも、打つ欄は出ない。** 出るのは「なぜ繋がっていないか」と、
    /// 手入力への退避路だけ。
    ///
    /// 逐語(Tom、2回言われている): 「なんで俺が、値を埋めないといけない形になってるの？」
    /// / 「そもそも最初にこういう画面なのが論外」。**欄が出ない事**が合格で、欄が
    /// 「奥に在る」事は合格を壊さない —— 机が鍵を回した時の唯一の復旧路なので消せない。
    func testTheFirstScreenNeverAsksForAValueEvenWithoutASeed() {
        let app = launch("keyentry-slow-key")

        XCTAssertTrue(element(app, "disconnected.reason").waitForExistence(timeout: 20),
                      "★1枚目が理由を名乗らない実装を落とす(白紙のフォームに戻る形)")
        XCTAssertFalse(element(app, "keyEntry.baseURL").exists,
                       "★1枚目に URL 欄が出る実装を落とす(§9-5 の逐語)")
        XCTAssertFalse(element(app, "keyEntry.apiKey").exists,
                       "★1枚目に鍵欄が出る実装を落とす(§9-5 の逐語)")

        photograph(app, "firstrun-no-seed")
    }

    /// ★錨(anchor)。打つ欄は**退避路の奥に現に在る**。
    ///
    /// 此れが無いと上の2本の `XCTAssertFalse` は永久に緑になり得る —— 識別子の綴りが
    /// 変わった日も、探し方そのものが壊れて何も見付けられなくなった日も、「打つ欄は
    /// 無い」と答える。**常に真の検査は無価値**で、実在する欠陥を否定する分たちが悪い。
    /// 併せて「畳んだのであって消していない」も此処で測っている。
    func testTheManualFormIsStillReachableOneStepIn() {
        let app = launch("keyentry-slow-key")

        let link = element(app, "disconnected.manualEntry")
        XCTAssertTrue(link.waitForExistence(timeout: 20), "退避路が1枚目に無い")
        link.tap()

        XCTAssertTrue(element(app, "keyEntry.baseURL").waitForExistence(timeout: 20),
                      "錨: 打つ欄は此の探し方で見付かる(上の否定が測定である事の根拠)")
        XCTAssertFalse(element(app, "list.buildInfo").exists,
                       "錨: 鍵を持たない電話は一覧へ着かない(此の面には種が無い)")
    }
}
