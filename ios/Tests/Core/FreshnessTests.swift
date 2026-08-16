import XCTest
@testable import RemoteMini

/// Mirrors `rc-backend/test/view.test.mjs`'s `freshness` blocks input-for-input
/// (Sprint 2 brief §2-a/§2-b). The JS fixtures use `[0, null, undefined, NaN,
/// Infinity]` for "unknown fetch time" -- `fetchedAtMs` here is a non-optional
/// `Double`, so `null`/`undefined` have no Swift equivalent at this signature (the
/// ViewModel represents "never fetched" as `0`, same as the JS call site would with
/// a falsy default); the three values actually representable in Swift (`0`, `.nan`,
/// `.infinity`) are all exercised below.
final class FreshnessTests: XCTestCase {
    // MARK: - view.test.mjs: "★一覧の古さ — 測った時刻が分からない時は「新しい」側へ倒さない"

    func testUnknownFetchTimeDoesNotFoldToFresh() {
        for bad in [0.0, Double.nan, Double.infinity] {
            let f = Freshness.freshness(bad, nowMs: 1_000_000)
            XCTAssertTrue(f.stale, "\(bad) を新しい側へ倒した")
            XCTAssertTrue(f.text.contains("unknown"), "分からない事を文でも言っていない")
        }
    }

    // MARK: - view.test.mjs: "★一覧の古さ — 60秒で「今」を名乗るのをやめる(画面自身の目盛りに合わせる)"

    func testSixtySecondBoundaryEndsTheJustNowClaim() {
        let t0 = 1_000_000.0
        XCTAssertFalse(Freshness.freshness(t0, nowMs: t0).stale)
        XCTAssertFalse(Freshness.freshness(t0, nowMs: t0 + 59_000).stale, "59秒で古いと言い出した")
        XCTAssertTrue(Freshness.freshness(t0, nowMs: t0 + 60_000).stale, "60秒を過ぎても「今」を名乗っている")

        // Positive control -- the text actually switches (a stale flag alone with unchanged text is unreadable)
        XCTAssertTrue(Freshness.freshness(t0, nowMs: t0 + 30_000).text.contains("30s ago"))
        XCTAssertTrue(Freshness.freshness(t0, nowMs: t0 + 120_000).text.contains("2m ago"))
        XCTAssertTrue(Freshness.freshness(t0, nowMs: t0 + 7_200_000).text.contains("2h ago"))
        XCTAssertTrue(Freshness.freshness(t0, nowMs: t0 + 172_800_000).text.contains("2d ago"))
        // Stale text also says how to fix it.
        XCTAssertTrue(Freshness.freshness(t0, nowMs: t0 + 120_000).text.contains("refresh"))
    }

    // MARK: - view.test.mjs: "一覧の古さ — 時計がずれて未来を指しても壊れない(relTime と同じ扱い)"

    func testClockSkewIntoTheFutureDoesNotBreak() {
        let f = Freshness.freshness(1_000_000, nowMs: 900_000) // now is in the past
        XCTAssertFalse(f.stale)
        XCTAssertTrue(f.text.contains("Just now"))
    }

    // MARK: - Negative control (repo convention: a control that doesn't go red when you break the thing measures nothing)

    func testFoldingUnknownToFreshEmptyMustGoRed() {
        // Brief §2-b: "★freshness の不明値を {text:"", stale:false} に倒す改変で必ず
        // 赤くなる検査を持つ事." Prove the wrong implementation actually diverges
        // from the real one on the exact unknown-value inputs -- if it did not
        // diverge, this fixture would prove nothing.
        func failOpen(_ fetchedAtMs: Double, nowMs: Double) -> Freshness.Result {
            guard fetchedAtMs != 0, fetchedAtMs.isFinite else {
                return Freshness.Result(text: "", stale: false) // the wrong turn
            }
            return Freshness.freshness(fetchedAtMs, nowMs: nowMs)
        }
        for bad in [0.0, Double.nan, Double.infinity] {
            XCTAssertNotEqual(Freshness.freshness(bad, nowMs: 1_000_000), failOpen(bad, nowMs: 1_000_000))
        }
    }
}
