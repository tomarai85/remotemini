import XCTest

/// 「注意の限界を超えた待ちで、画面が黙るのをやめる」を**実際の画面で**測る。
///
/// ★なぜ単体だけでは足りないか(2026-08-27 に自分で書いた欠けを塞ぐ):
///   `WaitEscalationTests` が測るのは**規則**で、`initial-load-narration-control.sh` が
///   測るのは「`ListView` がその規則を呼んでいる」事の grep の錨。どちらも
///   「呼んでいるが結果を捨てている」を捕まえられない。ここだけが、出た画に対して
///   物を言う。
///
/// ★閾値は `RC_WAIT_ESCALATE_S=1` へ縮める。本当に10秒待つ検査は、それ1本で
///   全体の実行時間を押し上げ、やがて誰も回さなくなる(= 在るのに測られない検査)。
///   縮める口が実装側に在る事は `WaitEscalationTests` が別に押さえている。
final class InitialWaitUITests: XCTestCase {

    private func launchHangingList(escalateAfter seconds: String) -> XCUIApplication {
        let app = XCUIApplication()
        // 机が黙っている面。`list-fetchfail`(即座に失敗)では `.retryable` へ落ちてしまい、
        // 初回の待ちそのものを長く保てない。
        app.launchEnvironment["RC_UI_FIXTURE"] = "list-hanging"
        app.launchEnvironment["RC_WAIT_ESCALATE_S"] = seconds
        app.launch()
        return app
    }

    func test_限界を超えたら黙るのをやめる() {
        // ★閾値を 3 秒にしてある。1 秒にすると、検査が最初の問い合わせを出す頃には
        //   もう昇格が終わっていて「通常段を通った」事を観測できない(実測 2026-08-27)。
        //   測りたいのは終点ではなく**遷移**なので、手前を観測できる幅が要る。
        let app = launchHangingList(escalateAfter: "3")

        // 先に通常段が出る事を押さえる。ここを飛ばすと、「最初から異常段だった」
        // (= 閾値が効いていない)と「ちゃんと昇格した」が区別できない。
        XCTAssertTrue(app.activityIndicators.firstMatch.waitForExistence(timeout: 5),
                      "初めは無言のスピナーが出ている筈")

        let slow = app.otherElements["list.loading.slow"]
        XCTAssertTrue(slow.waitForExistence(timeout: 15),
                      "閾値(1秒)を超えても表現が切り替わらない = 20秒間 無言のままの状態に戻っている")

        // 切り替わった後は、次に何ができるかが押せる形で在る事。
        XCTAssertTrue(app.buttons["list.retry"].waitForExistence(timeout: 5),
                      "異常段で再試行の的が無いと、読める様になっただけで手が無い")
    }

    func test_待っている間に画面が一瞬も空にならない() {
        // ★「スピナーが2枚続く」への答え。**1つに融合しない** —— 2枚は意味が別物で
        //   (1枚目 = Keychain の読みで網を使わない / 2枚目 = 網の取得)、識別子まで一緒に
        //   すると「鍵で固まった」と「机に届かない」が外から区別できなくなる。
        //   `RootView` の1枚目にも別の名前(`root.loading`)を与えた上で、測るのは
        //   **利用者に見える性質**: 待っている間、画面が一瞬も空にならない事。
        //
        // ★この検査が**測っていない事**を名前と一緒に書いておく(2026-08-27):
        //   fixture の経路は `RootView` の注記どおり `AppState` を丸ごと迂回するので、
        //   ここでは `root.loading` は一度も描かれない。つまり此れは
        //   「1枚目 → 2枚目の受け渡し」を見ていない。**最初その名前で書いて、
        //   迂回に気付いて改名した。**
        //   受け渡しそのものを見るには fixture 無しの走行が要るが、1枚目は Keychain の
        //   読みだけで**ミリ秒で終わる**ので、UI 検査の刻み(200ms)では原理的に捉えられない。
        //   捉えられない物を「検査した」と名乗らない為に、名前を測っている物へ寄せた。
        let app = launchHangingList(escalateAfter: "600") // 昇格させない = 待ちの帯だけを見る

        var sawSomething = false
        var sawGap = false
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let root = app.otherElements["root.loading"].exists
            let list = app.activityIndicators.firstMatch.exists
                || app.otherElements["list.loading"].exists
            if root || list { sawSomething = true }
            else if sawSomething { sawGap = true; break } // 一度出た後に「何も無い」= 途切れ
            usleep(200_000)
        }
        XCTAssertTrue(sawSomething, "待ちの表示が一度も出ていない = この検査は何も見ていない")
        XCTAssertFalse(sawGap, "起動から一覧までの間に、どちらの表示も無い瞬間が在った(画面が一瞬空になる)")
    }

    func test_閾値の手前では切り替わらない() {
        // ★陰性対照。上の検査だけだと「常に異常段を出している」でも緑になる。
        //   閾値を十分に長くして、**出ない事**を測る。
        let app = launchHangingList(escalateAfter: "600")

        XCTAssertTrue(app.otherElements["list.loading"].waitForExistence(timeout: 5)
                      || app.activityIndicators.firstMatch.waitForExistence(timeout: 5),
                      "無言のスピナーは出ている")
        XCTAssertFalse(app.otherElements["list.loading.slow"].waitForExistence(timeout: 6),
                       "閾値の手前で異常段が出た = 切替が時間ではない何かで起きている")
    }
}
