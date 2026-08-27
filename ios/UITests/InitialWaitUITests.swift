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
