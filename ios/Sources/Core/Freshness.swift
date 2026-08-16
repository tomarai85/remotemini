import Foundation

/// C-group port of `view.mjs`'s `freshness` (Sprint 2 brief §2).
///
/// Answers "how old is the list I'm looking at" -- the List screen fetches once (no
/// poll loop this sprint) and must show its own age rather than silently claiming to
/// be current forever. Pure function, `nowMs` injected, same reasoning as `RelTime`.
enum Freshness {
    struct Result: Equatable {
        let text: String
        let stale: Bool
    }

    /// - Parameters:
    ///   - fetchedAtMs: epoch ms the list was last successfully fetched, or `0` /
    ///     `.nan` if it has never been fetched.
    ///   - nowMs: "now," injected by the caller.
    static func freshness(_ fetchedAtMs: Double, nowMs: Double) -> Result {
        // fail-closed, deliberately: an unknown fetch time must read as "stale,
        // unknown" rather than folding to `{text:"", stale:false}`, which would be
        // the quietest possible lie -- the warning vanishes but the underlying value
        // is still old. `view.mjs`'s own doc-comment on this function calls out this
        // exact wrong turn by name; this is the fixed point it is warning against.
        guard fetchedAtMs != 0, fetchedAtMs.isFinite else {
            return Result(text: "Measured at an unknown time", stale: true)
        }
        let d = floor((nowMs - fetchedAtMs) / 1000)
        if d < 0 { return Result(text: "Just now", stale: false) } // clock skew; same treatment as RelTime
        if d < 60 { return Result(text: "As of \(Int(d))s ago", stale: false) }
        // The 60-second line is the screen's own tick mark, not an arbitrary
        // choice: `RelTime` folds everything under 60s into "たった今," so finer
        // staleness below that line could not be shown anyway.
        if d < 3600 { return Result(text: "As of \(Int(floor(d / 60)))m ago — pull to refresh", stale: true) }
        if d < 86400 { return Result(text: "As of \(Int(floor(d / 3600)))h ago — pull to refresh", stale: true) }
        return Result(text: "As of \(Int(floor(d / 86400)))d ago — pull to refresh", stale: true)
    }
}
