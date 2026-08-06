import XCTest
@testable import RemoteMini

/// `PollLoop.step()` state-machine tests -- brief §5-b's branches that are actually
/// `PollLoop`'s own responsibility (merge/hold-over/gap-drawing live one layer up, in
/// `ConversationViewModelTests`, since `PollLoop` -- per its own type doc -- does not
/// own `UnreadableMeter`, `screen`, or `display.choice`). Driven directly against a
/// stub `PollFetching`, exactly as `PollLoop.swift`'s own doc comment describes this
/// file: no real sleeping, no real actor-hop timing to fight.
final class PollLoopTests: XCTestCase {
    /// Records every request `PollLoop.step()` actually issued, in order, so a test
    /// can assert on the SECOND request's cursor/wait -- not just the first response's
    /// content -- which is what §5-b item 2 (immediate re-poll on `more:true`) and N6
    /// (cursor must not advance on `.unreadable`) both need.
    private final class StubPollFetching: PollFetching {
        var outcomes: [PollOutcome] = []
        private(set) var requestedCursors: [PollCursor] = []
        private(set) var requestedWaitMs: [Int] = []
        private var index = 0

        func poll(baseURL: URL, apiKey: String, sessionID: String, cursor: PollCursor, waitMs: Int) async -> PollOutcome {
            requestedCursors.append(cursor)
            requestedWaitMs.append(waitMs)
            defer { index += 1 }
            guard index < outcomes.count else {
                XCTFail("PollLoopTests stub ran out of queued outcomes -- test queued too few")
                return .unreachable
            }
            return outcomes[index]
        }
    }

    private let baseURL = URL(string: "https://unit-test.invalid")!

    private func makeLoop(client: PollFetching, initialCursor: PollCursor = .empty) -> PollLoop {
        PollLoop(client: client, baseURL: baseURL, apiKey: "k", sessionID: "s", initialCursor: initialCursor)
    }

    private func response(cursor: String, more: Bool, items: [PollItem] = []) -> PollResponse {
        PollResponse(items: items, screen: nil, display: nil, queued: nil, cursor: PollCursor(raw: cursor), more: more)
    }

    // MARK: - §5-b branch 1: normal round trip -- message decoded, cursor advances

    func testNormalRoundTripAdvancesCursorAndReturnsTheReadableResponse() async {
        let message = PollItem.message(MessageItem(entries: [HistoryEntry(role: .assistant, text: "hi", display: .init(who: "w"))], seq: 1))
        let stub = StubPollFetching()
        stub.outcomes = [
            .success(response(cursor: "t.a.2.0", more: false, items: [message])),
            .success(response(cursor: "t.a.3.0", more: false)),
        ]
        let loop = makeLoop(client: stub)

        let result = await loop.step(waitMs: 20_000)

        guard case .readable(let received) = result?.kind else { return XCTFail("expected .readable, got \(String(describing: result))") }
        XCTAssertEqual(received.cursor, PollCursor(raw: "t.a.2.0"))
        XCTAssertEqual(result?.nextWaitMs, 20_000, "more:false -> idle at the server's own long-poll ceiling")

        // The NEXT request must carry the advanced cursor -- not the one this loop started with.
        _ = await loop.step(waitMs: 20_000)
        XCTAssertEqual(stub.requestedCursors, [.empty, PollCursor(raw: "t.a.2.0")])
    }

    // MARK: - §5-b branch 2: more:true -> wait=0, and the immediate re-poll actually fires

    func testMoreTrueRequestsImmediateRepollAndTheSecondRequestActuallyCarriesWaitZero() async {
        let stub = StubPollFetching()
        stub.outcomes = [
            .success(response(cursor: "t.a.1.0", more: true)),
            .success(response(cursor: "t.a.2.0", more: false)),
        ]
        let loop = makeLoop(client: stub)

        let first = await loop.step(waitMs: 20_000)
        XCTAssertEqual(first?.nextWaitMs, 0, "more:true -> drain immediately, brief §2-a step 7")

        // The caller (ConversationViewModel.drivePolling) feeds `nextWaitMs` straight
        // into the next call -- reproduce that choreography here rather than asserting
        // on `first?.nextWaitMs` alone, which would pass even if nothing downstream
        // actually respected it.
        _ = await loop.step(waitMs: first!.nextWaitMs)
        XCTAssertEqual(stub.requestedWaitMs, [20_000, 0], "the second request must actually carry wait=0, not just report that it should")
    }

    // MARK: - §5-b branch 4 / N6: unreadable -> cursor untouched, no local backoff invented

    func testUnreadableLeavesCursorUntouchedAndInventsNoLocalBackoff() async {
        let stub = StubPollFetching()
        stub.outcomes = [.unreadable, .unreadable]
        let loop = makeLoop(client: stub, initialCursor: PollCursor(raw: "t.keep.5.0"))

        let first = await loop.step(waitMs: 20_000)
        XCTAssertEqual(first?.kind, .unreadable)
        XCTAssertEqual(first?.localBackoffMs, 0, "§3-a: unreadable is UnreadableMeter's counter, not Backoff's -- no invented local sleep")

        _ = await loop.step(waitMs: 20_000)
        XCTAssertEqual(stub.requestedCursors, [PollCursor(raw: "t.keep.5.0"), PollCursor(raw: "t.keep.5.0")], "N6: cursor must never advance past a response the phone could not read")
    }

    // N6's actual red/green proof is a live mutation of `PollLoop.swift` itself
    // (plant `cursor = response.cursor` unconditionally inside the `.unreadable`
    // case, confirm this test goes red, revert, confirm green) -- recorded in
    // `progress.md`'s N1-N7 table. A hand-written "broken twin" inline here would
    // only prove a fake twin disagrees with itself, not that this test catches the
    // real corruption.

    // MARK: - §5-b branch 9 (the PollLoop-level half): unauthorized maps straight through

    func testUnauthorizedMapsThroughWithoutTouchingCursor() async {
        let stub = StubPollFetching()
        stub.outcomes = [.unauthorized]
        let loop = makeLoop(client: stub, initialCursor: PollCursor(raw: "t.a.1.0"))

        let result = await loop.step(waitMs: 20_000)
        let cursorAfter = await loop.currentCursor()

        XCTAssertEqual(result?.kind, .unauthorized)
        XCTAssertEqual(cursorAfter, PollCursor(raw: "t.a.1.0"))
    }

    // MARK: - cancel()

    func testStepReturnsNilAfterCancel() async {
        let stub = StubPollFetching()
        stub.outcomes = [.success(response(cursor: "t.a.1.0", more: false))]
        let loop = makeLoop(client: stub)
        await loop.cancel()

        let result = await loop.step(waitMs: 20_000)

        XCTAssertNil(result, "a cancelled loop must not apply anything, even if the stub would have answered")
    }

    // MARK: - N1: the streak counter and Backoff's attempt counter are wired independently

    func testRepeatedUnreadableResponsesNeverClimbTheLocalBackoffLadderNegativeControl() async {
        // N1 (§5-a): "unreadableStreak を attempt と同じ値に繋ぐ改変で赤くなる検査を1本."
        // `UnreadableMeter` lives one layer up (`ConversationViewModel`), so the
        // PollLoop-level half of this guarantee is: `attempt` (only observable here via
        // `localBackoffMs`) must stay untouched by `.unreadable` outcomes no matter how
        // many arrive in a row -- a corruption that folds the two counters together
        // would make `localBackoffMs` start climbing here, which this test would catch.
        let stub = StubPollFetching()
        stub.outcomes = Array(repeating: PollOutcome.unreadable, count: 5)
        let loop = makeLoop(client: stub)

        var localBackoffs: [Int] = []
        for _ in 0..<5 {
            let result = await loop.step(waitMs: 20_000)
            localBackoffs.append(result?.localBackoffMs ?? -1)
        }

        XCTAssertEqual(localBackoffs, [0, 0, 0, 0, 0], "5 consecutive unreadable responses must never produce a nonzero local backoff")
    }

    func testButUnreachableResponsesDoClimbTheLadderProvingTheCounterIsRealAndLiveNegativeControl() async {
        // The other half of the same proof: it is not that `localBackoffMs` is
        // hard-coded to 0 -- a genuinely failing transport (`.unreachable`) DOES climb
        // it. Without this half, the test above would pass even for a `PollLoop` whose
        // backoff ladder was simply dead code, which proves nothing about N1.
        let stub = StubPollFetching()
        stub.outcomes = Array(repeating: PollOutcome.unreachable, count: 3)
        let loop = makeLoop(client: stub)

        var localBackoffs: [Int] = []
        for _ in 0..<3 {
            let result = await loop.step(waitMs: 20_000)
            localBackoffs.append(result?.localBackoffMs ?? -1)
        }

        XCTAssertEqual(localBackoffs, [1_000, 2_000, 4_000], "3 consecutive unreachable failures, opened-and-closed instantly, must climb Backoff's ladder")
    }

    // MARK: - 404 SESSION_NOT_FOUND: terminal, and outside Backoff's counter

    func testSessionNotFoundSurfacesAsItsOwnKindWithNoLocalBackoff() async {
        let stub = StubPollFetching()
        stub.outcomes = [.sessionNotFound]
        let loop = makeLoop(client: stub)

        let result = await loop.step(waitMs: 20_000)

        XCTAssertEqual(result?.kind, .sessionNotFound)
        XCTAssertEqual(result?.localBackoffMs, 0, "there is no next attempt to pace -- a delay before a retry that never happens is a delay nobody waits")
    }

    /// The non-obvious half. `.sessionNotFound` must leave `attempt` exactly where it
    /// found it, which is only observable through what a LATER `.unreachable` is
    /// charged. This actor outlives the drive loop (a resync reuses the instance), so
    /// an `attempt` silently advanced here becomes a rung a future loop inherits
    /// without ever having failed -- the phone waiting 4s before its first retry on a
    /// connection that has not yet gone wrong once.
    func testSessionNotFoundDoesNotAdvanceTheBackoffLadderForALaterRealFailure() async {
        let stub = StubPollFetching()
        stub.outcomes = [.unreachable, .sessionNotFound, .unreachable]
        let loop = makeLoop(client: stub)

        var localBackoffs: [Int] = []
        for _ in 0..<3 {
            let result = await loop.step(waitMs: 20_000)
            localBackoffs.append(result?.localBackoffMs ?? -1)
        }

        XCTAssertEqual(
            localBackoffs,
            [1_000, 0, 2_000],
            "the third value is the assertion: 2000 means the 404 was not charged to Backoff, 4000 means it was"
        )
    }
}
