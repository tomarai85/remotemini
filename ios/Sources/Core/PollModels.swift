import Foundation

/// Decodable models for `GET /api/sessions/<id>/poll`, shaped from the real observed
/// response (Sprint 4 brief §0) PLUS ground truth read directly from
/// `rc-backend/src/server.mjs`'s poll handler (`action === "poll"`) -- the brief's own
/// §0-c admits `kind:"message"` and the worker route were never actually observed on
/// the wire this sprint, so those two shapes are "read," not "seen," and this file
/// says so at each spot that leans on that reading rather than an observation.
///
/// §0-b (7 discrepancies between the spec's prose and the real wire) is the source of
/// nearly every non-obvious choice below; each type's doc comment says which item.

// MARK: - Root response

/// The tmux root has 7 keys (`items`/`screen`/`display`/`route`/`queued`/`cursor`/
/// `more`, brief §0-a). No custom `init(from:)` needed -- every field that varies is a
/// plain `Optional`, and Swift's synthesized `Decodable` already calls
/// `decodeIfPresent` for those, which treats "key absent" and "key present but null"
/// identically. That is exactly the property brief §0-b⑤ needs: the worker route
/// drops the `display` key entirely rather than sending `display: null`, and the
/// synthesized decoder does not care which of the two happened.
struct PollResponse: Decodable, Equatable {
    let items: [PollItem]
    /// `null` = **held over**, not "no screen" (§0-b①, §2-c). Whoever applies this
    /// response must keep the previous value when this is `nil`, never treat `nil` as
    /// "clear the screen."
    let screen: ScreenBody?
    /// Entirely absent on the worker route (§0-b⑤) -- see the type doc above for why
    /// that needs no special handling here.
    let display: PollDisplay?
    /// `nil` on tmux (server sends the JSON literal `null`: the desk-side TUI's own
    /// queue is not observable from here) / a count on worker (§0-b⑤). Not rendered
    /// this sprint (brief §1-b) -- held only so the type does not silently misreport a
    /// route it can't observe as `0`.
    let queued: Int?
    let cursor: PollCursor
    let more: Bool
}

/// Brief §0-b⑤: exists only on the tmux root (`{choice: ...}`); the worker root omits
/// the whole `display` key, which `PollResponse.display: PollDisplay?` already handles
/// (see that property's doc).
struct PollDisplay: Decodable, Equatable {
    /// `null` = **held over**, same rule and same reasoning as `PollResponse.screen`
    /// (§2-c: "両者を同じ1箇所で扱う事" -- the apply site is what actually enforces
    /// that shared rule; this type only needs to decode the union correctly).
    let choice: ChoiceView?
}

/// `view.mjs`'s `choiceView(state)` output, shipped verbatim (S-group). Only `show`/
/// `reason` are modeled -- brief §1-b (D-A): the options/buttons/head/digest fields
/// are real on the wire but this sprint renders none of them, only `reason` as a
/// badge when `show` is true. Declaring the property is what makes `JSONDecoder`
/// require the key; simply not declaring `head`/`options`/`buttons`/`digest` is
/// sufficient for the decoder to ignore them, same precedent as
/// `SessionsModels.swift`'s `SessionsResponse` omitting `live`.
struct ChoiceView: Decodable, Equatable {
    let show: Bool
    let reason: String
}

// MARK: - screen (nested classification, §0-b①②)

/// Brief §0-b①: the spec's prose reads `screen === "CHOICE"`, but the wire's `screen`
/// is an object (`screenBody()` in `server.mjs`: `{route, pane, screen, choice?, work,
/// windowMs}`) -- the classification word is `screen.screen`, one level down. Only
/// `classification` is modeled: `route`/`pane` are not used by anything this sprint
/// builds, and `choice` here is the raw menu the server already folded into
/// `PollDisplay.choice` (`display.choice`) -- decoding it twice would be a second copy
/// of the same fact with its own chance to drift.
///
/// `work`/`windowMs` (§0-b②: the C-group `activity`/`limited` fields the spec's
/// `ConversationState` names do not exist on this wire at all -- the closest analog is
/// `work: "observed"|"quiet"`, a different name AND a different vocabulary) are also
/// not modeled: nothing built this sprint renders an activity badge (brief §1-a item 6
/// enumerates the staged-degradation banner and the `reason` badge, not an activity
/// indicator) -- see `progress.md` for this judgment call.
struct ScreenBody: Decodable, Equatable {
    let classification: Classification

    private enum CodingKeys: String, CodingKey {
        case classification = "screen"
    }

    /// 4 known values, read off `classifyScreen()`'s own return-type doc comment in
    /// `rc-backend/src/inject.mjs` (`"SENDABLE"|"CHOICE"|"UNKNOWN"|"BUSY"`) -- not
    /// separately confirmed on the wire (brief §0-c: only `SENDABLE` was actually
    /// observed). The fallback case is spelled `.unrecognized`, not `.unknown`,
    /// because `"UNKNOWN"` is itself one of the 4 legitimate wire values -- reusing
    /// `.unknown` for "value this phone has never heard of" would make a real,
    /// server-sent `"UNKNOWN"` and a genuinely-unrecognized future 5th value
    /// indistinguishable in Swift, which they are not on the wire.
    enum Classification: String, Equatable {
        case sendable = "SENDABLE"
        case choice = "CHOICE"
        case unknown = "UNKNOWN"
        case busy = "BUSY"
        case unrecognized
    }
}

extension ScreenBody.Classification: Decodable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ScreenBody.Classification(rawValue: raw) ?? .unrecognized
    }
}

// MARK: - items (§0-b③④⑥⑦)

/// One entry of the poll response's `items` array. Branches on the wire's `kind`
/// discriminator; an unrecognized `kind` decodes to `.unrecognized` rather than
/// throwing -- `ReadablePoll.check` already made this same judgment (an unknown
/// `kind` "is left alone," per that file's own doc comment) for the SAME reason: a
/// future server addition must not make an old phone treat the whole poll response as
/// unreadable.
enum PollItem: Decodable, Equatable {
    case message(MessageItem)
    case gap(GapItem)
    case unrecognized(kind: String)

    private enum CodingKeys: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "message":
            self = .message(try MessageItem(from: decoder))
        case "gap":
            self = .gap(try GapItem(from: decoder))
        default:
            self = .unrecognized(kind: kind)
        }
    }
}

/// Brief §0-b⑥: `kind:"message"` always carries `seq` on both routes -- kept
/// non-optional. `entries` is the tmux shape (`entries: e.data.entries.map(withWho)`
/// in `server.mjs`, confirmed identical to `HistoryEntry`'s own wire shape via
/// `withWho()`); the worker shape carries `event` instead (one raw NDJSON line) and is
/// not modeled here at all (brief §1-a/§1-b: not rendered this sprint, and nothing
/// downstream needs its internal structure) -- `entries` is `nil` on that route, which
/// is also how `entries` decodes for a genuinely malformed tmux item that happens to
/// omit it. Declaring `entries` optional (never absent+non-optional) is what keeps a
/// worker-route poll response decodable at all (§5-b branch 8): a non-optional
/// `[HistoryEntry]` would fail the whole response's decode on every worker-route
/// message, which brief §0-c flags as read-but-unobserved code, not something to
/// break further by refusing to decode it.
struct MessageItem: Decodable, Equatable {
    let entries: [HistoryEntry]?
    let seq: Int
}

/// Brief §0-b③④⑥.
struct GapItem: Decodable, Equatable {
    let why: GapWhy
    /// Brief §0-b④, the sprint's most dangerous single fact: `gapNotice("tail-attached")`
    /// returns `null` on purpose (`view.mjs`'s `gapNotice`: `if (!why || why ===
    /// "tail-attached") return null;`, quoted verbatim in the brief) --
    /// this is a real, benign wire value, not a malformed response. A non-optional
    /// `String` here would make every `tail-attached` gap fail to decode, which
    /// `ReadablePoll`/§3-3 step 2 counts as "unreadable" -- turning a quiet resync
    /// signal into a false alarm on the degradation banner (brief's own words: "良性の
    /// 合図が偽の警報になる"). `nil` here means "draw nothing," never "draw the
    /// fallback text" -- the suppression already happened server-side (`gapNotice` is
    /// S-group); this type only has to respect the `null` it was handed, not
    /// re-derive the suppression rule.
    let notice: String?
    /// Brief §0-b⑥: present only for the `tail-attached`/`generation-changed`/
    /// `truncated`/`checkpoint-mismatch` family (fed through `feedGap` -> ring ->
    /// resume replay) and for `ring-overflow`; absent for the 4 values `pollDecision`
    /// itself returns (`cursor-too-long`/`cursor-malformed`/`route-changed`/
    /// `epoch-mismatch`, `gapItem(why)` called with no second argument). Optional, not
    /// defaulted to some sentinel -- nothing downstream reads `seq` off a gap item
    /// this sprint (gap resync always resets the cursor to empty regardless, §4 point
    /// 3), so there is no wrong value to default to; the honest one is "not present."
    let seq: Int?

    private enum CodingKeys: String, CodingKey { case why, display, seq }
    private struct DisplayBox: Decodable { let notice: String? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        why = try container.decode(GapWhy.self, forKey: .why)
        let display = try container.decodeIfPresent(DisplayBox.self, forKey: .display)
        notice = display?.notice
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
    }
}

/// Brief §0-b③: the spec's prose names 5 values; the real taxonomy is 9, from two
/// different call sites (`pollDecision` in `tail.mjs`, 4 values, confirmed by reading
/// that function directly -- NOT the brief's own paraphrase -- plus `gapItem(...)`
/// call sites elsewhere in `server.mjs` for the other 5). Falls back to
/// `.unrecognized` for the same reason every other wire enum in this codebase does:
/// `why` flows through `JsonlTail` (`r.error`), and that module gaining a 10th reason
/// must not make an old phone refuse to decode the gap it's trying to describe.
enum GapWhy: String, Equatable {
    case cursorTooLong = "cursor-too-long"
    case cursorMalformed = "cursor-malformed"
    case routeChanged = "route-changed"
    case epochMismatch = "epoch-mismatch"
    case ringOverflow = "ring-overflow"
    case tailAttached = "tail-attached"
    case generationChanged = "generation-changed"
    case truncated = "truncated"
    case checkpointMismatch = "checkpoint-mismatch"
    case unrecognized
}

extension GapWhy: Decodable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GapWhy(rawValue: raw) ?? .unrecognized
    }
}
