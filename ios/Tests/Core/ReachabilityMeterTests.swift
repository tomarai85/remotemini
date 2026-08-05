import XCTest
@testable import RemoteMini

/// Spec §5-4's counter. Four properties, and three of them have a naive twin that
/// would pass every "does the banner appear?" test while being wrong in the field:
/// `==` instead of `>=`, decay instead of reset, and a second threshold constant
/// living somewhere else. Each has its own control below.
final class ReachabilityMeterTests: XCTestCase {
    // MARK: - The threshold itself

    func testAFreshMeterIsNotUnreachable() {
        var meter = ReachabilityMeter()

        XCTAssertEqual(meter.consecutiveFailures, 0)
        XCTAssertFalse(meter.isUnreachable)

        // Positive anchor, on the derivation this test eats rather than on some
        // distant input: THIS meter does flip. Without it, a type whose
        // `isUnreachable` were hard-`false` and whose count never moved would pass
        // the two assertions above and every "does the banner stay down?" check
        // written against it.
        for _ in 0..<ReachabilityMeter.unreachableThreshold { meter.recordFailure() }
        XCTAssertEqual(meter.consecutiveFailures, 3)
        XCTAssertTrue(meter.isUnreachable)
    }

    func testTwoFailuresAreNotEnoughAndTheThirdIsTheOneThatTrips() {
        var meter = ReachabilityMeter()

        meter.recordFailure()
        XCTAssertFalse(meter.isUnreachable, "1回")
        meter.recordFailure()
        XCTAssertFalse(meter.isUnreachable, "2回 -- spec §5-4 is 3, not 2")
        meter.recordFailure()
        XCTAssertTrue(meter.isUnreachable, "3回目で立つ")
        XCTAssertEqual(meter.consecutiveFailures, ReachabilityMeter.unreachableThreshold)
    }

    /// ★`>=`, not `==`. A meter written with `==` passes the test above and then
    /// switches the banner OFF on the 4th consecutive failure -- the phone would say
    /// "応答がありません" for exactly one poll and then look healthy again while
    /// nothing had recovered. The twin below is that implementation; the assertion is
    /// that the real type and the twin actually disagree, so this control can fail.
    func testTheBannerStaysUpPastTheThresholdNegativeControl() {
        var meter = ReachabilityMeter()
        for _ in 0..<40 { meter.recordFailure() }

        XCTAssertTrue(meter.isUnreachable, "40回連続でも立ったまま")

        func equalityJoinedIsUnreachable(_ failures: Int) -> Bool {
            failures == ReachabilityMeter.unreachableThreshold
        }
        XCTAssertFalse(equalityJoinedIsUnreachable(meter.consecutiveFailures), "twin: the `==` implementation")
        XCTAssertNotEqual(
            equalityJoinedIsUnreachable(meter.consecutiveFailures),
            meter.isUnreachable,
            "the twin must actually diverge from the real type at 40 -- otherwise this control measures nothing"
        )
    }

    // MARK: - Recovery is a reset, not a decay

    func testOneSuccessClearsTheWholeStreak() {
        var meter = ReachabilityMeter()
        for _ in 0..<12 { meter.recordFailure() }
        XCTAssertTrue(meter.isUnreachable, "precondition: deep into the streak")

        meter.recordSuccess()

        XCTAssertEqual(meter.consecutiveFailures, 0)
        XCTAssertFalse(meter.isUnreachable, "§5-4: 「復帰(1回でも成功)したら即座に消す」")
    }

    /// ★The spec says 即座に. A decaying twin -- one success takes the count down by
    /// one -- would leave a phone that failed 12 times needing 10 more successes
    /// before it stopped claiming the backend was gone, i.e. a banner that outlives
    /// the condition it reports. Asserted as a divergence so the control can fail.
    func testRecoveryIsNotADecayNegativeControl() {
        var meter = ReachabilityMeter()
        for _ in 0..<12 { meter.recordFailure() }
        meter.recordSuccess()

        var decayed = 12
        decayed -= 1 // the twin's idea of "recovered once"

        XCTAssertEqual(meter.consecutiveFailures, 0)
        XCTAssertNotEqual(decayed, meter.consecutiveFailures, "the decaying twin diverges -- proof this control can fail")
    }

    func testASuccessOnAFreshMeterChangesNothing() {
        var meter = ReachabilityMeter()

        meter.recordSuccess()

        XCTAssertEqual(meter.consecutiveFailures, 0, "reset of an already-zero streak must not go negative")
        XCTAssertFalse(meter.isUnreachable)

        // ★The positive anchor is also the only thing here that can actually catch the
        // bug the line above names. A meter that decremented to -1 would still report
        // 0 failures and `false` at this point -- `-1` is not observable through
        // either accessor. It becomes observable three failures later: a phone in that
        // state needs FOUR consecutive failures to raise the banner, one poll cycle
        // late, every time it happens to open on a healthy backend.
        meter.recordFailure()
        meter.recordFailure()
        meter.recordFailure()
        XCTAssertEqual(meter.consecutiveFailures, 3)
        XCTAssertTrue(meter.isUnreachable, "three after a no-op success, not four")
    }

    func testFailuresResumeCountingFromZeroAfterARecovery() {
        var meter = ReachabilityMeter()
        meter.recordFailure()
        meter.recordFailure()
        meter.recordSuccess()

        meter.recordFailure()
        meter.recordFailure()

        XCTAssertFalse(meter.isUnreachable, "the two pre-recovery failures must not be carried across the reset")
        meter.recordFailure()
        XCTAssertTrue(meter.isUnreachable, "…and the post-recovery streak still trips on its own third")
    }

    // MARK: - One threshold, not two

    /// ★`ListViewModel.unreachableThreshold` is a forwarding alias kept so Sprint 2's
    /// call sites and tests can go on naming the constant they already named. A
    /// forwarding alias is exactly the shape that silently becomes a second, divergent
    /// constant the day someone "inlines" it -- at which point List and Conversation
    /// would escalate at different counts while both suites stayed green, because each
    /// asserts against its own screen's constant. This is the one assertion that reads
    /// both.
    /// `@MainActor` only because `ListViewModel` is; the constant itself has no
    /// isolation of its own. Read into a local first so the value -- not a
    /// main-actor-isolated lookup -- is what crosses into `XCTAssertEqual`'s
    /// nonisolated autoclosure.
    @MainActor
    func testListViewModelForwardsToThisThresholdRatherThanHoldingItsOwn() {
        let listScreensThreshold = ListViewModel.unreachableThreshold

        XCTAssertEqual(listScreensThreshold, ReachabilityMeter.unreachableThreshold)
        XCTAssertEqual(ReachabilityMeter.unreachableThreshold, 3, "spec §5-4 (the §3-6 '2回' line lost this argument in Sprint 2)")
    }
}
