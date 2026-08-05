import XCTest
@testable import RemoteMini

/// §5-c stage-transition tests, driven entirely through the injected `now:`/
/// `lastReadableAt` `Date` values `UnreadableMeter` itself takes as parameters --
/// no real sleeping, matching the `Backoff`/`BackoffTests` convention of an
/// explicit clock rather than a real 10-second wait in a test.
final class UnreadableMeterTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - streak == 0 is always .normal (the guard brief §3-b's table implies)

    func testFreshMeterIsNormal() {
        let meter = UnreadableMeter(lastReadableAt: epoch)
        XCTAssertEqual(meter.stage(now: epoch), .normal)
    }

    func testStreakZeroStaysNormalNoMatterHowStaleLastReadableAtIsNegativeControl() {
        // Guards the `guard streak > 0 else { return .normal }` line specifically:
        // a meter that has never failed once must not be pushed into `.stalled` by
        // elapsed time alone -- `streak` failing at least once is a precondition,
        // not something the elapsed-time branch can bypass.
        let meter = UnreadableMeter(lastReadableAt: epoch)
        let farFuture = epoch.addingTimeInterval(10_000)
        XCTAssertEqual(meter.stage(now: farFuture), .normal)
    }

    // MARK: - the streak >= 3 trigger (independent of elapsed time)

    func testOneOrTwoUnreadableMarksWithinTenSecondsIsDegraded() {
        var meter = UnreadableMeter(lastReadableAt: epoch)
        meter.markUnreadable()
        XCTAssertEqual(meter.stage(now: epoch.addingTimeInterval(1)), .degraded)

        meter.markUnreadable()
        XCTAssertEqual(meter.streak, 2)
        XCTAssertEqual(meter.stage(now: epoch.addingTimeInterval(2)), .degraded)
    }

    func testThirdConsecutiveUnreadableMarkEscalatesToStalledEvenAtZeroElapsed() {
        var meter = UnreadableMeter(lastReadableAt: epoch)
        meter.markUnreadable()
        meter.markUnreadable()
        meter.markUnreadable()

        // Same instant as the last readable response -- only the streak count
        // pushes this to `.stalled`, not elapsed time.
        XCTAssertEqual(meter.stage(now: epoch), .stalled)
    }

    // MARK: - the elapsed >= 10s trigger (independent of streak)

    func testStreakStuckAtOneEscalatesToStalledOnceTenSecondsHavePassed() {
        var meter = UnreadableMeter(lastReadableAt: epoch)
        meter.markUnreadable()

        XCTAssertEqual(meter.stage(now: epoch.addingTimeInterval(10)), .stalled)
    }

    func testElapsedBoundaryIsInclusiveAtExactlyTenSeconds() {
        var meter = UnreadableMeter(lastReadableAt: epoch)
        meter.markUnreadable()

        XCTAssertEqual(meter.stage(now: epoch.addingTimeInterval(9.999)), .degraded, "just under the floor")
        XCTAssertEqual(meter.stage(now: epoch.addingTimeInterval(10.0)), .stalled, "exactly at the floor -- inclusive")
        XCTAssertEqual(meter.stage(now: epoch.addingTimeInterval(10.001)), .stalled, "just over the floor")
    }

    func testEitherConditionAloneIsSufficientNeitherIsRequiredNegativeControl() {
        // Proves the two triggers are joined by OR, not AND: streak==3 with 0
        // elapsed already asserted stalled above; here, elapsed>=10 with streak==1
        // (nowhere near the streak-3 floor) must ALSO reach stalled on its own.
        var meter = UnreadableMeter(lastReadableAt: epoch)
        meter.markUnreadable()
        XCTAssertEqual(meter.streak, 1, "streak is nowhere near the streak-3 floor")
        XCTAssertEqual(meter.stage(now: epoch.addingTimeInterval(30)), .stalled)

        // Negative control: an AND-joined twin (both conditions required) would
        // stay `.degraded` here since streak < 3 -- prove the twin actually
        // disagrees with the real type, i.e. the control can fail.
        func andJoinedStage(streak: Int, elapsed: TimeInterval) -> UnreadableMeter.Stage {
            guard streak > 0 else { return .normal }
            return (streak >= 3 && elapsed >= 10) ? .stalled : .degraded
        }
        XCTAssertNotEqual(andJoinedStage(streak: 1, elapsed: 30), meter.stage(now: epoch.addingTimeInterval(30)))
    }

    // MARK: - markReadable is the only reset path

    func testMarkReadableResetsStreakToZeroAndUpdatesLastReadableAt() {
        var meter = UnreadableMeter(lastReadableAt: epoch)
        meter.markUnreadable()
        meter.markUnreadable()
        meter.markUnreadable()
        XCTAssertEqual(meter.stage(now: epoch), .stalled)

        let recoveredAt = epoch.addingTimeInterval(45)
        meter.markReadable(now: recoveredAt)

        XCTAssertEqual(meter.streak, 0)
        XCTAssertEqual(meter.lastReadableAt, recoveredAt)
        XCTAssertEqual(meter.stage(now: recoveredAt), .normal)
    }

    func testMarkUnreadableNeverTouchesLastReadableAtNegativeControl() {
        // The type doc is explicit: `lastReadableAt` means "the last time this
        // passed," not "the last time we tried." A naive twin that stamps
        // `lastReadableAt = Date()` on every attempt (readable or not) would make
        // the elapsed-time trigger unreachable -- prove the real type does NOT do
        // that, and that the naive twin's behavior actually differs.
        var meter = UnreadableMeter(lastReadableAt: epoch)
        let attemptedAt = epoch.addingTimeInterval(5)
        meter.markUnreadable() // must NOT stamp `attemptedAt` anywhere

        XCTAssertEqual(meter.lastReadableAt, epoch, "markUnreadable must not move lastReadableAt")

        // Naive twin: stamps `lastReadableAt` on every attempt, readable or not --
        // this would keep resetting the elapsed clock and mask a real stall.
        struct NaiveTwin {
            var lastAttemptAt: Date
            mutating func markUnreadable(now: Date) { lastAttemptAt = now }
        }
        var twin = NaiveTwin(lastAttemptAt: epoch)
        twin.markUnreadable(now: attemptedAt)
        XCTAssertNotEqual(twin.lastAttemptAt, meter.lastReadableAt, "the naive twin's timestamp diverges from the real meter's -- proof the control can fail")
    }
}
