import Foundation

/// C-group reconnect pacing, ported 1:1 from `frames.mjs`'s `backoffMs` and
/// `view.mjs`'s `nextAttempt` (spec §3-6, §0-4). Both depend on client-held state --
/// "how many times has *this* client retried," "how long did *this* client's last
/// connection stay open" -- which the server cannot know about itself.
enum Backoff {
    private static let healthyMs = 5_000
    private static let capMs = 15_000

    /// `frames.mjs`'s `backoffMs`: 1s, 2s, 4s, 8s, then capped at 15s. `attempt <= 0` means
    /// "not reconnecting yet" and returns 0.
    static func ms(attempt: Int) -> Int {
        guard attempt > 0 else { return 0 }
        // JS computes `1000 * 2 ** (attempt - 1)` and lets it overflow toward
        // Infinity, which `Math.min` then clamps harmlessly. Swift's `Int` traps on
        // overflow instead of saturating, so the exponent is clamped before the
        // shift -- 2^20 * 1000 already exceeds capMs by three orders of magnitude,
        // so this changes no observable output, only avoids a crash for a phone
        // stuck retrying for hours (user_work_pattern_mobile: subway flicker).
        let shift = min(attempt - 1, 20)
        return min(capMs, 1000 * (1 << shift))
    }

    /// `view.mjs`'s `nextAttempt`: reset the retry count to 1 only if the previous connection
    /// stayed open longer than `HEALTHY_MS` (5s); otherwise increment. `openedAtMs`
    /// of `nil` or `0` means "never opened," which mirrors JS's `Boolean(openedAt)`
    /// and always increments -- resetting on "it opened at all, however briefly"
    /// would spin a flickering connection into a reconnect-every-second loop.
    static func nextAttempt(attempt: Int, openedAtMs: Int?, nowMs: Int) -> Int {
        let opened = openedAtMs ?? 0
        let healthy = opened != 0 && (nowMs - opened) > healthyMs
        return healthy ? 1 : attempt + 1
    }
}
