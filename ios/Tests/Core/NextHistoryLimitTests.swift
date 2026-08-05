import XCTest
@testable import RemoteMini

/// `MergeHistory.nextHistoryLimit` (Sprint 3 brief §2-b-4): `Math.min(500, (current || 50) + 100)`.
/// All 5 assertions inside `test/view.test.mjs`'s single `"★nextHistoryLimit:
/// 押すたびに必ず増える"` test, ported verbatim to one Swift `func` each (brief §2-a's rule,
/// and brief §2-b-4 訂正6-1's own note that the first brief draft tabled `mergeHistory`'s
/// 6 cases but never tabled these 5 -- an omission this file must not repeat).
final class NextHistoryLimitTests: XCTestCase {
    /// JS case ("treats 0 the same as not-yet-loaded" in `test/view.test.mjs`):
    /// `nextHistoryLimit(0)` is 150, not 100.
    /// JS's `current || 50` treats `0` as falsy and falls back to 50 same as `nil`
    /// would -- a naive Swift `current ?? 50` port gets this case wrong (`0 ?? 50`
    /// is `0`, not `50`, since `??` only catches `nil`). This is the case brief
    /// §2-b-4 訂正6-1 flagged as the one an `?? 50` translation silently breaks.
    func testZeroStepsToOneFiftyNotOneHundred() {
        XCTAssertEqual(MergeHistory.nextHistoryLimit(0), 150, "current:0 is falsy in JS -- must fall back to 50 before the +100, same as nil")
    }

    func testFiftyStepsToOneFifty() {
        XCTAssertEqual(MergeHistory.nextHistoryLimit(50), 150)
    }

    /// JS case ("always grows the limit" in `test/view.test.mjs`): the result is
    /// always strictly greater than the input, away from the ceiling.
    func testOneTwentyIsStrictlyGreaterThanItself() {
        XCTAssertGreaterThan(MergeHistory.nextHistoryLimit(120), 120)
    }

    /// Sprint 3 carryover (brief §8, Sprint 3 evaluator: "1 line, close it now"):
    /// this used 450 (550 would've been the naive un-capped result), but
    /// `test/view.test.mjs`'s own case for this row is seeded at 480, not 450 -- a
    /// silent divergence between the ported test and the JS source it claims to
    /// port verbatim. 480 still exercises the identical property (the cap engages
    /// before a plain `+100` would: 480 + 100 = 580), it just now matches the JS
    /// side's actual input instead of a nearby stand-in.
    func testFourEightyStepsToFiveHundredNotFiveEighty() {
        XCTAssertEqual(MergeHistory.nextHistoryLimit(480), 500)
    }

    /// The ceiling property `ConversationViewModel`'s "retract the button
    /// permanently" rule depends on (brief §3-b-1): once at 500, asking for "the
    /// next limit" returns the SAME value, not a larger one.
    func testFiveHundredStaysAtFiveHundred() {
        XCTAssertEqual(MergeHistory.nextHistoryLimit(500), 500)
    }

    func testNilFallsBackToFifty() {
        // Exercised directly -- `ConversationViewModel` never actually calls this
        // with `nil` (it always seeds `currentLimit = 50`), but the fallback is part
        // of the ported contract itself, and `nil` must land on the same 150 that
        // `0` (above) and `50` (above) both do.
        XCTAssertEqual(MergeHistory.nextHistoryLimit(nil), 150)
    }
}
