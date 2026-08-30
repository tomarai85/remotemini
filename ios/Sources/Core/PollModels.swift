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

/// `view.mjs`'s `choiceView(state)` output, shipped verbatim (S-group).
///
/// Sprint 5 modeled only `show`/`reason` and drew a badge -- a deliberate scope call,
/// recorded in that sprint's brief §1-b (D-A). The consequence was the shape the
/// owner's ruling names as the thing to avoid: 「見えるが答えられない」 -- the phone
/// said "this conversation is waiting on a choice" and offered no way to answer it.
/// This sprint widens the decode to the whole wire object and renders it.
///
/// **The phone never decides what is pressable.** `buttons` is computed server-side by
/// `choiceView` in `view.mjs`, which gates each entry on two independent facts (the
/// key kind appears in the injector's allow-list AND the numbered option actually
/// exists on screen). Re-deriving that here would be a second copy of the same rule
/// with its own chance to drift -- the same reasoning `InterruptClient` gives for
/// refusing to look at `interrupted`/`reason`.
///
/// The four added fields are decoded **leniently** (absent -> empty), unlike
/// `show`/`reason` which stay required. The asymmetry is the point: `choiceView`
/// always emits all six keys today, but if a future server drops one, a strict decode
/// would throw and take `reason` down with it -- turning "we cannot show you the
/// buttons" into "we cannot read this response at all". Same argument
/// `ResultDisplay.kind` makes for being a `String` rather than an enum: an unknown
/// wire shape degrades what is shown, never whether anything is shown.
/// `view.mjs` の `choiceView().risk`。段は**上がるだけ**(サーバ側の規約)。
struct ChoiceRisk: Decodable, Equatable {
    /// `danger` / `caution` / `unmatched`。**enum にしない** -- 知らない語が来た時に
    /// カード全体を落とすより、知らない語として運ぶ方が安全側(この repo の既存規約)。
    let tier: String
    /// 人へ出す1文。`unmatched` では空文字で届く。
    let notice: String
    let signals: [ChoiceRiskSignal]
    /// サーバの分類器の版(`src/risk.mjs` の `RISK_CLASSIFIER_VERSION`)。電話は自分で
    /// 分類しないので、これが無いと「古いサーバの弱い判定」と「新しい判定」を区別できない。
    let version: Int

    /// ★`notice` は空ではなく**明文**。無言に戻すと、帯の出ない要求が「安全」に読まれる
    ///   (2026-08-26 の裁定)。古いサーバから `risk` が来ない時もこの文が出る。
    static let unmatched = ChoiceRisk(
        tier: "unmatched",
        notice: "Not checked against known hazards — read it yourself.",
        signals: [], version: 0)

    var isDanger: Bool { tier == "danger" }
    var isCaution: Bool { tier == "caution" }

    private enum CodingKeys: String, CodingKey { case tier, notice, signals, version }
    init(tier: String, notice: String, signals: [ChoiceRiskSignal], version: Int = 0) {
        self.tier = tier; self.notice = notice; self.signals = signals; self.version = version
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = (try? c.decode(String.self, forKey: .tier)) ?? "unmatched"
        notice = (try? c.decode(String.self, forKey: .notice)) ?? ""
        signals = (try? c.decode([ChoiceRiskSignal].self, forKey: .signals)) ?? []
        // 0 = 版を名乗らないサーバ。**「版が無い = 新しい」と読まない**為に既定を最小にする。
        version = (try? c.decode(Int.self, forKey: .version)) ?? 0
    }
}

/// 何が怖いかを1行で。`id` は機械用、`why` は人が読む文。
struct ChoiceRiskSignal: Decodable, Equatable {
    let id: String
    let why: String
    init(id: String, why: String) { self.id = id; self.why = why }
    private enum CodingKeys: String, CodingKey { case id, why }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        why = (try? c.decode(String.self, forKey: .why)) ?? ""
    }
}

struct ChoiceView: Decodable, Equatable {
    let show: Bool
    let reason: String
    /// The prompt text above the menu, one entry per screen line.
    let head: [String]
    /// Every option the screen offers, whether or not it is pressable. Rendered even
    /// when `buttons` is empty: on a hard-stop screen (trust/permission prompts the
    /// server refuses to answer remotely) Tom still needs to READ what is being asked
    /// before deciding whether to reach the desk.
    let options: [ChoiceOption]
    /// Only what the server says may be pressed. Empty is a normal, meaningful state.
    let buttons: [ChoiceButton]
    /// The screen's fingerprint. `POST …/choice` requires it, so an empty one means
    /// nothing on this card can be sent -- see `canPress`.
    let digest: String
    /// How heavy this approval is. **This never changes what may be pressed** --
    /// `buttons` still decides that. It only lets the screen show a `rm -rf` prompt
    /// and an `ls` prompt with different weight, which no tool in this space does
    /// (research 2026-08-26). `tier` is one of `danger` / `caution` / `unmatched`.
    /// ★`unmatched` means "no known dangerous pattern matched" -- **not "safe"**.
    ///   Never render it as a reassurance; the server deliberately sends an empty
    ///   `notice` for it so there is no wording to misuse.
    let risk: ChoiceRisk

    private enum CodingKeys: String, CodingKey { case show, reason, head, options, buttons, digest, risk }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        show = try c.decode(Bool.self, forKey: .show)
        reason = try c.decode(String.self, forKey: .reason)
        // `try?` + `decode` (not `decodeIfPresent`): one expression covers both ways a
        // field can fail to arrive -- key absent, and key present with the wrong type.
        // `decodeIfPresent` only covers the first, and a `head` that arrived as a
        // string instead of an array would still throw out the whole card.
        head = (try? c.decode([String].self, forKey: .head)) ?? []
        options = (try? c.decode([ChoiceOption].self, forKey: .options)) ?? []
        buttons = (try? c.decode([ChoiceButton].self, forKey: .buttons)) ?? []
        digest = (try? c.decode(String.self, forKey: .digest)) ?? ""
        // A server older than this build sends no `risk`. Falling back to
        // `unmatched` is correct: it is the "nothing known matched" value, and its
        // notice is empty, so an old server renders exactly as it did before.
        risk = (try? c.decode(ChoiceRisk.self, forKey: .risk)) ?? ChoiceRisk.unmatched
    }

    /// Memberwise init for fixtures and tests (the custom `init(from:)` suppresses the
    /// synthesized one).
    init(show: Bool, reason: String, head: [String] = [], options: [ChoiceOption] = [],
         buttons: [ChoiceButton] = [], digest: String = "",
         risk: ChoiceRisk = ChoiceRisk.unmatched) {
        self.show = show
        self.reason = reason
        self.head = head
        self.options = options
        self.buttons = buttons
        self.digest = digest
        // 既定は `unmatched`。検体を1本ずつ直さずに済むが、**危険な検体を書く時は
        // 明示的に渡す事** —— 既定のまま書いた検体は「危険度を測っていない検体」で、
        // それを危険側の検査に使うと空振りする。
        self.risk = risk
    }

    /// Fail-closed, on the phone's own side of the wire: a button with no fingerprint
    /// behind it is a button whose every tap is guaranteed to 400. `view.mjs` already
    /// refuses to emit that pair, and this re-check exists for the same reason the
    /// server's own comment gives -- 押せない物を押せる顔で出さない -- not because the
    /// server is distrusted, but because the cost of the check is one comparison and
    /// the cost of being wrong is a button that lies.
    var canPress: Bool { !digest.isEmpty && !buttons.isEmpty }
}

/// One line of the menu as it appears on screen. `n` is the digit the TUI itself
/// prints, not this app's array index -- the server reads it off the rendered line.
struct ChoiceOption: Decodable, Equatable {
    let n: Int
    let label: String
}

/// One thing the server says may be pressed. `key` is sent back verbatim in the
/// request body; `label` is shown verbatim. Neither is composed here.
///
/// `key` is one of `"1"`..`"9"`, `"enter"`, `"escape"` (`CHOICE_KEYS` in `choice.mjs`)
/// but is typed as `String` rather than an enum for `ResultDisplay.kind`'s reason: a
/// value this build has not heard of must degrade to "a button we won't draw", never
/// to a decode failure that discards the whole card.
struct ChoiceButton: Decodable, Equatable {
    let key: String
    let label: String
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

    /// 机の画面に**上限の告知が出ているか**。`classification` とは独立に立つ ——
    /// 送れる(`SENDABLE`)のに答えは返らない、が実在する状態。
    ///
    /// ★上の註記は此の欄を「この sprint は活動バッジを描かないので modeled しない」と書いていた。
    ///   **判断は当時正しく、理由が失効した**(2026-08-30)。サーバ側は `rc-backend/src/server.mjs` の `limited は state と独立に出す` の註記に
    ///   意図をこう書いている ——「電話から見た時『返事が来ない』と『上限に当たっている』は
    ///   取る行動が全く違うので、理由の見える化そのものが機能」。
    ///   線は 2026-08-02 から送っていて、電話は復号せず捨てていた。
    ///
    /// ★`nil` は「線が何も言わなかった」。`false` に丸めない —— 古い机は此の鍵を持たない。
    let limited: Bool?

    private enum CodingKeys: String, CodingKey {
        case classification = "screen"
        case limited
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

/// ★2026-08-09, 実測 -- `screen` is **not** always present, and requiring it cost the
/// phone the whole response.
///
/// `PollResponse.screen` is filled from `f.screen.body`, and `feedTick` writes that cell
/// as `r.pane ? screenBody(f, r.pane) : blockedBody(r)`. The second producer emits
/// `{route, reason, candidates, source, message}` and **no `screen` key** -- measured by
/// calling `blockedBody()` for all 8 of `WIRE_REASONS`, not read off a comment. The cell
/// is sticky across ticks while the poll handler re-resolves the pane per request, so a
/// pane that was gone at the last screen tick and is resolvable at poll time takes the
/// `tmux` branch and ships that stale blocked body here.
///
/// A `keyNotFound` here did not degrade one field: `PollClient` maps any failed decode to
/// `.unreadable` and `PollLoop` answers that with a 20-second wait plus the degradation
/// band, so one pane flicker bought a 20-second dead phone. Every other unknown wire value
/// in this file already degrades instead of throwing (`PollItem`'s unrecognized `kind`,
/// `GapWhy`, `Classification` itself); this was the one place the rule was not applied.
///
/// What this must **not** do is render the blocked body's `message`. By the time the poll
/// handler chose the `tmux` branch it had already re-resolved the pane, so that sentence
/// is stale news -- drawing 「開いていた画面が見つかりません」 over a live connection is a
/// lie in the other direction. `.unrecognized` is the honest reading: this phone has no
/// classification for this screen. `composerEnabled` and `interruptEnabled` both already
/// treat that as "leave the capability alone", which is also where the server puts the
/// real guard -- it refuses a doomed send with a 409 carrying the reason in its own words.
///
/// Declared in an extension, not the struct body: an initializer inside the body would
/// suppress the memberwise `ScreenBody(classification:)` that `PollFixture` builds with.
extension ScreenBody {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        classification = try container.decodeIfPresent(Classification.self, forKey: .classification)
            ?? .unrecognized
        // ★`decodeIfPresent`。鍵が無い机(2026-08-02 より前の版)は `nil` になる ——
        //   `false` に丸めると「上限は出ていない」と**断言**する事になり、
        //   知らない事を知っている事にすり替える。
        limited = try container.decodeIfPresent(Bool.self, forKey: .limited)
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
