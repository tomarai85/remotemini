import Foundation

/// C-group port of `view.mjs`'s `relTime` (Sprint 2 brief §2).
///
/// Pure function: `nowMs` is injected rather than read from `Date()` internally, so
/// the boundary between "just now" and "N minutes ago" can be tested without a fake
/// clock. Behavior is copied property-for-property from the JS source, not
/// re-derived -- see `RelTimeTests` for the exact `view.test.mjs` inputs this is
/// checked against.
enum RelTime {
    /// - Parameters:
    ///   - iso: an ISO8601 `updatedAt` string.
    ///   - nowMs: "now," in epoch milliseconds, injected by the caller.
    /// - Returns: a Japanese relative-time label, or `""` if `iso` does not parse --
    ///   never a thrown error and never a placeholder like "?": an unparseable
    ///   timestamp must not take the whole row down with it.
    static func relTime(_ iso: String, nowMs: Double) -> String {
        guard let t = parseISO8601Ms(iso) else { return "" }
        let d = floor((nowMs - t) / 1000)
        // A negative diff (clock skew making the timestamp look like it's in the
        // future) folds into "たった今" rather than printing a negative duration --
        // same bucket as "just happened," not a distinct error state.
        if d < 0 { return "たった今" }
        if d < 60 { return "たった今" }
        if d < 3600 { return "\(Int(floor(d / 60)))分前" }
        if d < 86400 { return "\(Int(floor(d / 3600)))時間前" }
        if d < 86400 * 7 { return "\(Int(floor(d / 86400)))日前" }
        let dt = Date(timeIntervalSince1970: t / 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let comps = calendar.dateComponents([.month, .day], from: dt)
        return "\(comps.month ?? 0)/\(comps.day ?? 0)"
    }

    /// `Date.parse` in JS accepts a broader grammar than `ISO8601DateFormatter`'s
    /// strict mode (fractional seconds are optional either way, but a bare instant
    /// with no time component is also valid JS). `updatedAt` is always full
    /// ISO8601-with-milliseconds in practice (server always writes it via
    /// `new Date().toISOString()`), so trying the two common shapes covers the real
    /// input; anything else -- including the JS test's literal `"こわれた"` -- falls
    /// through to `nil`, matching `Number.isFinite(Date.parse(...))` being false.
    private static func parseISO8601Ms(_ iso: String) -> Double? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: iso) { return date.timeIntervalSince1970 * 1000 }

        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        if let date = whole.date(from: iso) { return date.timeIntervalSince1970 * 1000 }

        return nil
    }
}
