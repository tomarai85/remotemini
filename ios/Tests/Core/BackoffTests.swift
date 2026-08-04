import XCTest
@testable import RemoteMini

/// Ports `frames.mjs`'s `backoffMs` and `view.mjs`'s `nextAttempt` (spec §3-6).
final class BackoffTests: XCTestCase {
    // MARK: - backoffMs (frames.mjs)

    func testNotReconnectingYetReturnsZero() {
        XCTAssertEqual(Backoff.ms(attempt: 0), 0)
        XCTAssertEqual(Backoff.ms(attempt: -5), 0)
    }

    func testDoublesFromOneSecond() {
        XCTAssertEqual(Backoff.ms(attempt: 1), 1_000)
        XCTAssertEqual(Backoff.ms(attempt: 2), 2_000)
        XCTAssertEqual(Backoff.ms(attempt: 3), 4_000)
        XCTAssertEqual(Backoff.ms(attempt: 4), 8_000)
    }

    func testCapsAtFifteenSeconds() {
        // attempt 5 -> 1000*2^4 = 16000, capped to 15000.
        XCTAssertEqual(Backoff.ms(attempt: 5), 15_000)
        XCTAssertEqual(Backoff.ms(attempt: 6), 15_000)
        // A phone stuck retrying for hours (subway outage) must not diverge or crash.
        XCTAssertEqual(Backoff.ms(attempt: 1_000), 15_000)
    }

    func testCapNegativeControlWouldExceedTheLimit() {
        // Negative control: the easy mistake is porting the doubling but dropping
        // `Math.min(15_000, ...)`. Prove the control can fail -- the uncapped
        // formula genuinely exceeds 15s at attempt 5, where the real function does
        // not.
        func uncapped(_ attempt: Int) -> Int { 1000 * (1 << (attempt - 1)) }
        XCTAssertGreaterThan(uncapped(5), 15_000)
        XCTAssertNotEqual(Backoff.ms(attempt: 5), uncapped(5))
    }

    // MARK: - nextAttempt (view.mjs)

    func testNeverOpenedAlwaysIncrements() {
        XCTAssertEqual(Backoff.nextAttempt(attempt: 3, openedAtMs: nil, nowMs: 999_999), 4)
        XCTAssertEqual(Backoff.nextAttempt(attempt: 3, openedAtMs: 0, nowMs: 999_999), 4)
    }

    func testResetsOnlyAfterStayingOpenLongerThanHealthyWindow() {
        // Opened at 1000, now 6001 -> open 5001ms, strictly greater than 5000ms.
        XCTAssertEqual(Backoff.nextAttempt(attempt: 3, openedAtMs: 1_000, nowMs: 6_001), 1)
    }

    func testDoesNotResetOnABriefFlickerConnection() {
        // Opened at 1000, now 1001 -> open 1ms. A connection that opens and drops
        // almost immediately (a server that accepts then kills the socket) must not
        // reset the retry count, or the client spins reconnecting every second --
        // exactly the subway-flicker case named in the doc comment on `view.mjs`'s `nextAttempt`
        // (「地下鉄で電波が瞬く時がまさにそれ」).
        XCTAssertEqual(Backoff.nextAttempt(attempt: 3, openedAtMs: 1_000, nowMs: 1_001), 4)
    }

    func testDoesNotResetExactlyAtTheHealthyBoundary() {
        // Opened 5000ms ago exactly: `> HEALTHY_MS`, not `>=`, so this must still
        // increment.
        XCTAssertEqual(Backoff.nextAttempt(attempt: 3, openedAtMs: 1_000, nowMs: 6_000), 4)
    }

    func testResetBoundaryNegativeControl() {
        // Negative control: a `>=` implementation (the easy off-by-one) would reset
        // to 1 at exactly the boundary, where the real function increments. Prove
        // the control can fail by asserting the two implementations diverge there.
        func resetsWithGreaterOrEqual(attempt: Int, openedAtMs: Int?, nowMs: Int) -> Int {
            let opened = openedAtMs ?? 0
            let healthy = opened != 0 && (nowMs - opened) >= 5_000
            return healthy ? 1 : attempt + 1
        }
        let boundaryControl = resetsWithGreaterOrEqual(attempt: 3, openedAtMs: 1_000, nowMs: 6_000)
        XCTAssertEqual(boundaryControl, 1, "control must actually reset at the boundary")
        XCTAssertNotEqual(Backoff.nextAttempt(attempt: 3, openedAtMs: 1_000, nowMs: 6_000), boundaryControl)
    }

    func testAnyOpenResetsNegativeControl() {
        // Negative control: an implementation that resets on "it opened at all"
        // (ignoring duration) would reset even on the 1ms flicker case above. Prove
        // it can fail by showing the two implementations diverge there.
        func resetsOnAnyOpen(attempt: Int, openedAtMs: Int?, nowMs: Int) -> Int {
            (openedAtMs ?? 0) != 0 ? 1 : attempt + 1
        }
        let flickerControl = resetsOnAnyOpen(attempt: 3, openedAtMs: 1_000, nowMs: 1_001)
        XCTAssertEqual(flickerControl, 1, "control must actually reset on the flicker case")
        XCTAssertNotEqual(Backoff.nextAttempt(attempt: 3, openedAtMs: 1_000, nowMs: 1_001), flickerControl)
    }
}
