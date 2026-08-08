import XCTest

/// **401 で戻された鍵入力画面**を simulator で実際に開いて見る(2026-08-08、監査 X2-6、
/// DESIGN §2.65)。
///
/// ★この file が在る理由は S8-5 の再発防止。あの時は規則(どう振る舞うべきか)が正しく
/// 書かれ、単体も緑で、**画面に繋がっていなかった**。X2-6 の直しは形が全く同じ ——
/// 断りの文を作る純関数と、それを運ぶ器と、画面。単体で測れるのは前2つまでで、
/// 「body が実際に描くか」は単体からは永久に見えない。
///
/// ここで通す鎖は disk から画素まで:
///   `SignOutNoticeStoring` に断りが在る
///     -> `AppState.loadStoredCredentials()` が読む
///       -> `RootView.normalFlow` が鍵入力画面を選ぶ
///         -> `KeyEntryView` の body が節を描く
/// 途中のどれか1本が切れたらこの検査が落ちる。単体はどこも落ちない。
///
/// 種は `ios/Sources/Core/SignOutNoticeFixture.swift`(`#if DEBUG`)。`RC_UI_FIXTURE` の
/// 面は1つ増えるが、増やさない道は「画面に出る事を測らない」しか無かった —— 既存2面
/// (一覧 / 会話)は `AppState` を迂回する形なので、`AppState` が生む面には使えない。
final class KeyEntryUITests: XCTestCase {
    /// 文言は `KeyEntryView.sentence(for:)` から**手で書き写す**。生成側を呼んで
    /// 比べると「同じ関数が同じ物を返す」しか言えず、画面に出ているのがその文かを
    /// 測れない(`InFlightUITests` と同じ約束)。
    private let noticeSentence = "通っていた鍵がサーバに拒まれました。URL は前のまま入れてあるので、鍵だけ入れ直してください。"

    /// `SignOutNoticeFixture.baseURL` と同じ物を、これも手で書き写す。
    private let seededURL = "https://ui-fixture.invalid"

    private func launchRejected() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = "keyentry-rejected"
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

    /// ★断りが**画面に出ている**。
    func testTheRejectedKeyNoticeIsActuallyOnTheScreen() {
        let app = launchRejected()

        let notice = element(app, "keyEntry.signOutNotice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10),
                      "★body が節を描かない実装を落とす(純関数は緑のまま通る)")
        XCTAssertEqual(notice.label, noticeSentence)

        photograph(app, "keyentry-signed-out")
    }

    /// URL 欄が前の値で埋まっている。
    func testTheURLFieldComesBackFilledWithTheURLThatWasBeingUsed() {
        let app = launchRejected()

        let field = element(app, "keyEntry.baseURL")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, seededURL,
                       "★URL を運ばない実装を落とす(電話で tailnet の URL を打ち直させる)")
    }

    /// ★鍵の側は埋まっていない。
    ///
    /// 直に「鍵欄が空」を見ないのは、空の `SecureField` の `value` が実装依存で
    /// (空文字か placeholder か)脆いから。代わりに**画面の事実**で押さえる:
    /// 接続ボタンは URL と鍵の両方が埋まるまで押せない。上の検査で URL が埋まっている
    /// 事は確定しているので、ボタンが押せない事は「鍵が空」以外では起こらない。
    ///
    /// 拒まれた鍵を欄に残す実装は、Tom に「入っているから合っている」と読ませて
    /// もう一度拒ませる —— 迷子を一段深くする。
    func testTheKeyFieldIsNotPrefilledWithTheKeyThatWasJustRejected() {
        let app = launchRejected()

        let field = element(app, "keyEntry.baseURL")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, seededURL, "前提: URL は埋まっている")

        let submit = element(app, "keyEntry.submit")
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled,
                       "★拒まれた鍵を欄に残す実装を落とす(URL が埋まっている以上、押せない理由は鍵が空だけ)")
    }
}
