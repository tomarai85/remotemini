import Foundation

#if DEBUG

/// DEBUG-only fixture `PollFetching`, same convention as `HistoryFetchingFixture`
/// (Sprint 3) and `SessionsListingFixture` (Sprint 2): selected via `RC_UI_FIXTURE`,
/// holds no hostname/URL, never touches the network or the Keychain.
///
/// A `final class`, not a `struct`: it has to remember how many times it has been
/// called across one running `PollLoop`, and `PollLoop` holds its `client:
/// PollFetching` as a `let` -- an existential held in a `let` cannot dispatch to a
/// `mutating` struct method, so reference semantics is the only option that doesn't
/// also require changing `PollLoop`'s own storage.
///
/// Exists for two independent reasons, not one:
/// 1. Hygiene (unconditional): before this file, `RootView`'s DEBUG Conversation
///    branch never passed a `pollClient:` at all, so it defaulted to a real
///    `PollClient()` -- a background `Task` would have been making real (if
///    doomed-to-fail) HTTP requests against the inert `ui-fixture.invalid` host for
///    as long as any UI test or screenshot run kept that screen on-screen. Every
///    `RC_UI_FIXTURE` state, including the pre-existing `.threeRoles`, now gets an
///    explicit fixture instead.
/// 2. Sprint 4 brief §7 DoD item 6: 2 Simulator screenshots of the staged
///    degradation banner (`UnreadableMeter.Stage.degraded`/`.stalled`) -- `.degraded`
///    and `.stalled` drive `poll()` to return `.unreadable` just enough times to
///    reach and then FREEZE at the target stage, so a screenshot taken a couple of
///    seconds after launch reliably lands on the intended stage rather than racing
///    past it.
final class PollFetchingFixture: PollFetching {
    private let historyState: HistoryFetchingFixture.State
    private var callCount = 0

    init(historyState: HistoryFetchingFixture.State) {
        self.historyState = historyState
    }

    func poll(baseURL: URL, apiKey: String, sessionID: String, cursor: PollCursor, waitMs: Int) async -> PollOutcome {
        callCount += 1
        let unreadableTarget: Int
        switch historyState {
        case .threeRoles:
            // No degradation intended for this state -- 0 means the very first call
            // already falls through to the "hold forever" branch below, so
            // `unreadableStage` never leaves `.normal`.
            unreadableTarget = 0
        case .degraded:
            unreadableTarget = 1 // streak 1, below the stage-2 floor of 3.
        case .stalled:
            unreadableTarget = 3 // streak 3 crosses `UnreadableMeter`'s stalled floor.
        }

        if callCount <= unreadableTarget {
            return .unreadable
        }

        // Simulate a long-poll the server is holding open rather than one that keeps
        // resolving immediately -- without this, an unthrottled fixture would climb
        // straight past the intended stage within milliseconds of screen launch,
        // since nothing here is actually waiting on a real network round trip. A
        // 60s sleep comfortably outlasts `shots.sh`'s 2s capture delay and any UI
        // test's assertion timeout.
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return .unreadable
    }
}

#endif
