import XCTest
@testable import RemoteMini

/// `WaitEscalation` の対照。
///
/// ★測るのは**規則**であって描画ではない。時計を持たない純関数にしてあるので、
///   ここは時間を1秒も進めずに全段を作れる(10秒待つ検査は、やがて誰も回さなくなる)。
final class WaitEscalationTests: XCTestCase {

    func test_十秒未満は何も足さない() {
        // ★実測のサーバ応答は 0.1-0.3 秒(2026-08-27、friday 本番)。殆どの起動はこの帯域で
        //   終わるので、ここが `.normal` である事がこの設計の主たる主張。
        XCTAssertEqual(WaitEscalation.stage(elapsedSeconds: 0), .normal)
        XCTAssertEqual(WaitEscalation.stage(elapsedSeconds: 0.3), .normal)
        XCTAssertEqual(WaitEscalation.stage(elapsedSeconds: 1), .normal)
        XCTAssertEqual(WaitEscalation.stage(elapsedSeconds: 9.99), .normal)
    }

    func test_注意の限界を超えたら表現を切り替える() {
        // Nielsen の 10 秒 = 注意がこの対話に留まる限界。
        XCTAssertEqual(WaitEscalation.stage(elapsedSeconds: 10), .abnormal)
        XCTAssertEqual(WaitEscalation.stage(elapsedSeconds: 19.9), .abnormal)
    }

    func test_境界はちょうど十秒で切り替わる() {
        // ★`>` と `>=` の取り違えは、片側だけの検査では素通りする。両側を押さえる。
        XCTAssertEqual(WaitEscalation.stage(elapsedSeconds: WaitEscalation.attentionLimitSeconds - 0.001), .normal)
        XCTAssertEqual(WaitEscalation.stage(elapsedSeconds: WaitEscalation.attentionLimitSeconds), .abnormal)
    }

    func test_異常段の文はHIGが避けろと言う曖昧語を使わない() {
        // Apple HIG 逐語: "Avoid vague terms like loading or authenticating because they
        // seldom add value." —— 直した本人が後から「読み込み中…」に戻すのを、
        // 文言の性質そのもので止める。
        let text = (WaitEscalation.abnormalHeadline + " " + WaitEscalation.abnormalBody).lowercased()
        for vague in ["loading", "authenticating", "please wait", "読み込み中"] {
            XCTAssertFalse(text.contains(vague), "曖昧語『\(vague)』が混ざっている(HIG が名指しで避けている語)")
        }
        XCTAssertFalse(WaitEscalation.abnormalHeadline.isEmpty)
        XCTAssertFalse(WaitEscalation.abnormalBody.isEmpty)
    }

    func test_観測していない事を助言の形で言わない() {
        // ★この画面は「この電話が tailnet に居るか」を一度も観測していない。
        //   していない観測を根拠に「電波/VPN を確認してください」と言うと、
        //   当たれば正しく見え、外れれば人を誤った所へ走らせる。
        let text = WaitEscalation.abnormalHeadline + " " + WaitEscalation.abnormalBody
        for unobserved in ["Wi-Fi", "VPN", "Tailscale", "cellular", "network settings"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(unobserved),
                           "観測していない『\(unobserved)』を助言している")
        }
    }

    func test_閾値は検査から縮められる() {
        // UI 検査が本当に 10 秒待つと、その1本で検査全体の実行時間が跳ね上がる。
        // 既定が 10 である事と、口が在る事の両方を押さえる。
        XCTAssertEqual(WaitEscalation.attentionLimitSeconds, 10,
                       "既定は Nielsen の 10 秒。環境変数が無い時にこれ以外なら、既定が漂流している")
    }
}
