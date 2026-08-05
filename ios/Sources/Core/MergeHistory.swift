import Foundation

/// C-group port of `view.mjs`'s `mergeHistory`/`nextHistoryLimit` (Sprint 3 brief §2).
///
/// Kept off the server on purpose, same reasoning as `ReadablePoll`/`Backoff`: both
/// functions depend on state only the *client* holds (which `history` array this
/// phone already rendered, which `live` items it has already subscribed to) --
/// something the server cannot observe about a specific phone's screen. This is the
/// **only** place a JS implementation and a Swift implementation of the same logic
/// co-exist (brief §2-a) -- everything else server-computed ships as a `display.*`
/// field and is rendered verbatim, never recomputed here.
///
/// Because two implementations of the same behavior is the one spot they can drift,
/// the brief's instruction is not "read `view.mjs` and write equivalent Swift" but
/// "port every one of `view.test.mjs`'s `mergeHistory` cases verbatim" -- see
/// `MergeHistoryTests`, which does exactly that, one JS `test(...)` per Swift `func`.
enum MergeHistory {
    /// `view.mjs`'s `mergeHistory(history, live)`. JS accepts `null`/`undefined` and
    /// folds them to `[]` internally (`history || []`); Swift's `[HistoryEntry]` has
    /// no nil state to begin with, so every caller already passes `[]` for "nothing
    /// yet" (`ConversationViewModel.live` starts empty and stays empty this sprint,
    /// brief §2-d) -- case 4's "both nil" JS input is exercised here as "both empty."
    static func merge(_ history: [HistoryEntry], _ live: [HistoryEntry]) -> [HistoryEntry] {
        let maxK = min(history.count, live.count)
        guard maxK > 0 else { return history + live }

        // Brief §2-b-2: the strip length is the LARGEST matching k, tried in
        // DESCENDING order from `maxK` down to 1 -- not ascending. Ascending would
        // "fix" case 6 (the known over-stripping limitation) at the cost of breaking
        // case 2 (a real history/live overlap would only get partially stripped).
        var k = maxK
        while k > 0 {
            let tail = history.suffix(k)
            if zip(tail, live.prefix(k)).allSatisfy(sameRoleAndText) {
                return history + live.suffix(from: k)
            }
            k -= 1
        }
        return history + live
    }

    /// Brief §2-b-1: the overlap check compares `role`+`text` ONLY -- `display` is
    /// deliberately excluded. JS's `history`/`live` elements never carry `display` to
    /// begin with (`{role, text}` is the whole shape it compares), so a Swift
    /// `Equatable` synthesized straight off `HistoryEntry` (which does carry
    /// `display`) would fold `display` into the comparison too and silently diverge
    /// from what `view.test.mjs` actually asserts. This function is the single
    /// definition of "same entry" -- also reused by `ConversationViewModel` for the
    /// "did the oldest entry actually advance" check (brief §3-b-1), rather than
    /// inventing a second equality notion that could drift out of sync with this one.
    static func sameRoleAndText(_ a: HistoryEntry, _ b: HistoryEntry) -> Bool {
        a.role == b.role && a.text == b.text
    }

    /// `view.mjs`'s `nextHistoryLimit`: `Math.min(500, (current || 50) + 100)`
    /// (`rc-backend/src/view.mjs`, brief §2-b-4 訂正6-1, 実測). The `min`
    /// is load-bearing, not a defensive extra -- brief §2-b-4/§3-b-1: the Conversation
    /// screen's "you've hit the ceiling, permanently retract the button" rule (the
    /// only permanent give-up in §3-b-2's table) depends on this function eventually
    /// returning its own input unchanged (`nextHistoryLimit(500) == 500`). Drop the
    /// cap and that condition can never become true.
    ///
    /// JS's `||` treats `0` as falsy, so `nextHistoryLimit(0)` also falls back to 50
    /// (`test/view.test.mjs`'s own case for this input asserts 150, not 100). Swift's
    /// `??` only catches `nil` -- a direct `current ?? 50` port would let `0` sail
    /// through unchanged and return 100 instead. Steering `0` onto the same fallback
    /// path as `nil` before the `??` keeps the two languages' `nextHistoryLimit`
    /// answering identically for every input the JS test suite names, not just the
    /// ones a `nil`-only translation happens to get right.
    static func nextHistoryLimit(_ current: Int?) -> Int {
        let base = (current == 0 ? nil : current) ?? 50
        return min(500, base + 100)
    }
}
