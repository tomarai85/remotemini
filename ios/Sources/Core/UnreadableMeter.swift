import Foundation

/// Counts consecutive **unreadable-but-200** poll responses and how long it has been
/// since the last trustworthy one (brief §3-a/§3-b).
///
/// This is a SEPARATE counter from `Backoff.attempt` on purpose, not an oversight --
/// brief §3-a names this explicitly, and negative control N1 exists specifically to
/// catch the two being folded together. `Backoff.attempt` answers "is the connection
/// itself failing" (timeout / unreachable / 5xx); `UnreadableMeter.streak` answers "is
/// the connection fine but the SERVER's responses untrustworthy" (200, but
/// `ReadablePoll.check` rejected it, or the typed decode failed). A phone with a
/// perfectly healthy connection to a server that has started returning garbage should
/// show the degradation banner while `Backoff.attempt` stays at 0 the entire time --
/// collapsing the two would either hide that failure mode (folded into `attempt`,
/// which only drives reconnect pacing, not this banner) or make a real network outage
/// look like a "server is sending bad data" problem instead.
///
/// Pure struct, `Date` values passed in rather than read via `Date()` inside --
/// `PollLoop`/`ConversationViewModel` own the real clock; this type only compares the
/// two timestamps it is handed, which is what makes the §5-c stage-transition tests
/// (10-second boundary, both sides) possible without a real 10-second sleep.
struct UnreadableMeter: Equatable {
    /// Brief §3-b's 3-row table. `.stalled` is reached by EITHER of its two
    /// conditions independently -- a streak that hits 3 escalates immediately even if
    /// the last readable response was seconds ago; a streak stuck at 1 still
    /// escalates once 10 seconds have passed without a single readable response.
    enum Stage: Int, Equatable {
        /// `streak == 0`. Nothing shown.
        case normal = 0
        /// `streak` is 1 or 2, and fewer than 10 seconds have passed since
        /// `lastReadableAt`. Quiet 1-line notice, no buttons (brief §1-a item 6).
        case degraded = 1
        /// `streak >= 3`, OR 10+ seconds have passed since `lastReadableAt` --
        /// whichever condition is true first. Warning + `[再試行]`/`[読み直す]`
        /// (brief §1-a item 6), and the trigger for the one-per-episode auto-resync
        /// (§3-c) the moment this stage is first entered.
        case stalled = 2
    }

    private static let stalledStreakFloor = 3
    private static let stalledElapsedFloorSeconds: TimeInterval = 10

    private(set) var streak: Int = 0
    private(set) var lastReadableAt: Date

    /// `lastReadableAt` has no "never" state -- brief §3-b's banner text always shows
    /// a clock time, so the caller seeds this with "now" at the moment polling starts
    /// (before any request has even gone out), the same way `Freshness` treats a
    /// never-fetched List as maximally stale rather than displaying nothing.
    init(lastReadableAt: Date) {
        self.lastReadableAt = lastReadableAt
    }

    /// §2-a step 5 (merge succeeded): the ONLY place `streak` returns to 0 -- not on
    /// "got a 200," on "got a 200 AND it decoded AND `ReadablePoll.check` accepted
    /// it." A transport failure (`Backoff`'s territory) leaves this meter exactly as
    /// it was; it neither advances nor resets it.
    mutating func markReadable(now: Date) {
        streak = 0
        lastReadableAt = now
    }

    /// §2-a steps 2-4 failing. Does not touch `lastReadableAt` -- that timestamp
    /// means "the last time this passed," not "the last time we tried."
    mutating func markUnreadable() {
        streak += 1
    }

    func stage(now: Date) -> Stage {
        guard streak > 0 else { return .normal }
        let elapsed = now.timeIntervalSince(lastReadableAt)
        if streak >= Self.stalledStreakFloor || elapsed >= Self.stalledElapsedFloorSeconds {
            return .stalled
        }
        return .degraded
    }
}
