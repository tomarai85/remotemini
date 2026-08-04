import Foundation

/// C-group port of `view.mjs`'s `readablePoll`/`isPlainEvent` (spec §0-4, §3-3
/// step 3).
///
/// Kept off the server on purpose: `readablePoll` checks the shape of a payload
/// *after* it has traveled the wire and is about to be merged into client state --
/// something the server cannot observe about itself. A server that validated its own
/// just-built payload would only ever prove it built what it intended to build; the
/// check would become a tautology and hide exactly the failure it exists to catch
/// (spec §0-4: "検められる側が自分について発行する証明書は fail-closed になれない").
///
/// Operates on the loosely-typed tree `JSONSerialization.jsonObject(with:)` produces
/// (`[String: Any]` / `[Any]` / `NSNull` / etc.), not a `Decodable` model. That is
/// deliberate: the whole point of this check is "is the shape of what arrived
/// trustworthy," and a `Decodable` failure would already have discarded the
/// malformed data before this function ever saw it -- defeating the check it exists
/// to perform (spec §3-3 step 2 vs step 3 are separate failure modes for this
/// reason: a decode failure keeps the last known state; a decode *success* whose
/// shape fails this check also keeps the last known state, but for a different
/// reason -- the bytes were valid JSON, just not a shape we trust yet).
enum ReadablePoll {
    static func check(_ d: Any?) -> Bool {
        guard let dict = d as? [String: Any], let items = dict["items"] as? [Any] else {
            return false
        }
        for item in items {
            // JS `typeof it !== "object"` is a well-known quirk: it is true for
            // BOTH plain objects and arrays (only null and primitives fail it --
            // and `!it` catches null separately, since `typeof null` is *also*
            // "object" in JS). A bare-array item is therefore not exercised by
            // `view.test.mjs` and, in the real function, passes this guard
            // un-rejected (it just has no `.kind`, so the loop body no-ops for it).
            // Preserved here rather than "fixed," per the spec's "そのまま移植"
            // instruction -- Swift's type system has no equivalent quirk, so the
            // JS behaviour has to be spelled out explicitly instead of falling out
            // of a single cast.
            guard !isNullOrPrimitive(item) else { return false }
            guard let itemDict = item as? [String: Any] else { continue } // array item: see above
            guard (itemDict["kind"] as? String) == "message" else { continue }
            // `kind:"message"` differs by route: tmux carries `entries` (an array
            // of already-formatted rows), worker carries `event` (one decoded
            // NDJSON line, a plain object). Neither present means unreadable.
            let hasEntries = itemDict["entries"] is [Any]
            let hasEvent = isPlainEvent(itemDict["event"])
            if !hasEntries && !hasEvent { return false }
        }
        // An unrecognized `kind` is left alone (not rejected): a future server
        // addition must not make an old phone hang on every poll.
        return true
    }

    private static func isNullOrPrimitive(_ value: Any) -> Bool {
        if value is NSNull { return true }
        return !(value is [String: Any]) && !(value is [Any])
    }

    private static func isPlainEvent(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if value is [Any] { return false }
        return value is [String: Any]
    }
}
