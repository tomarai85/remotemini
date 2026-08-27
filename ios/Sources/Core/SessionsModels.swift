import Foundation

/// Decodable models for `GET /api/sessions`, shaped from the real observed response
/// (Sprint 2 brief §0), not from the spec's prose -- the spec's field names
/// (`display.routeLabel` / `display.scanLine`) are stale; the server actually writes
/// `display.route` / `display.scan` (`rc-backend/src/server.mjs`'s `/api/sessions`
/// handler, `display: { route: routeLabel(live), subtitle: subtitleOf(s) }` and
/// `display: { scan: scanLine(scanBody) }`).
///
/// `live` is deliberately NOT modeled here (brief §1-b): it is a union whose shape
/// differs by route (tmux/worker/blocked), Sprint 2 never renders it, and an
/// `optional`-everything struct standing in for a union that "happens to decode"
/// would be the exact `entries`/`event` mixup `ReadablePoll` already exists to catch,
/// just moved one layer up. Not declaring the property is sufficient for it to be
/// ignored -- `JSONDecoder` does not require every wire key to have a matching
/// property, and does not fail on keys it doesn't know about.
struct SessionsResponse: Decodable, Equatable {
    let sessions: [SessionRow]
    /// The outer, response-level `display` -- distinct from each row's own
    /// `display` (same key name, different object; see `SessionRow.RowDisplay`).
    let display: OuterDisplay
    /// `null` in the normal case; server always includes the key (never omits it),
    /// but this is still modeled as optional rather than a non-null default so that
    /// "no fault" and "a fault report" cannot be confused by a missing-vs-null slip.
    let paneFault: PaneFault?

    struct OuterDisplay: Decodable, Equatable {
        /// The scan line, already formatted server-side (`scanLine()` in
        /// `view.mjs`). Rendered as-is (brief §3-b: "加工しない").
        let scan: String
    }

    struct PaneFault: Decodable, Equatable {
        /// Internal token from the server's `paneFaultReason` -- a closed vocabulary
        /// (`panes-unreadable` / `tmux-unavailable`), kept for diagnostics. **Never
        /// drawn**: see `display`.
        let reason: String
        /// The raw `e.message` of whatever threw while listing panes. Free text that
        /// can carry pane names and working-directory paths -- `test/wire-shape-controls.sh`
        /// redacts it from diagnostic output for exactly that reason. **Never drawn.**
        let detail: String
        /// The banner's copy, computed server-side (`paneFaultView` in `blocked.mjs`).
        ///
        /// Optional on purpose: the phone can be newer than the server (edith has
        /// already been observed running behind HEAD). A non-optional field here would
        /// make an old server fail the *whole* `/api/sessions` decode, i.e. the list
        /// screen would show "取れていません" with no explanation at all -- strictly
        /// worse than a banner that names no cause. Same judgment `RouteLabel.Kind`
        /// already makes for an unknown route name.
        let display: Display?

        struct Display: Decodable, Equatable {
            let headline: String
            let body: String
        }

        init(reason: String, detail: String, display: Display? = nil) {
            self.reason = reason
            self.detail = detail
            self.display = display
        }
    }
}

extension SessionsResponse.PaneFault {
    /// 帯に描く1組。サーバが説明を送ってこなかった時だけ、此処の組に落ちる。
    ///
    /// ★**原因を作らない**。落ちた時に分かっているのは「説明が来ていない」事だけで、
    /// `reason` の意味を電話側で解釈し直すと、サーバの文言ともう1枚の写しができる
    /// (`blocked.mjs` の「文面の出所を1つに保つ」)。`reason` は**診断コードとして**だけ
    /// 出す —— 生のトークンを見出しに据えていたのが此の監査(S8-22)で潰した形なので、
    /// 見出しではなく、説明が来ていないと名乗った後ろに置く。
    var bannerDisplay: Display {
        display ?? Display(
            headline: "Can't read the desktop pane list",
            body: "The server sent no explanation for this fault (it may be an older build). "
                + "Nothing can be sent until this recovers. Check the desk. Diagnostic code: \(reason)"
        )
    }
}

struct SessionRow: Decodable, Equatable {
    let id: String
    let title: String
    /// ISO8601 string, fed to `RelTime.relTime` as-is. Kept as a raw `String` rather
    /// than parsed at decode time: `RelTime` already fails closed (returns `""`) on
    /// an unparseable value, so decoding it as a string here means a malformed
    /// timestamp degrades one row's relative-time label instead of failing the
    /// whole response.
    let updatedAt: String
    /// Present in only 1 of the 39 sessions observed in brief §0 -- must stay
    /// optional. A non-optional `Bool` here would fail decoding on every row that
    /// lacks the key, i.e. on the overwhelming majority of real responses.
    let fromRegistryOnly: Bool?
    let display: RowDisplay
    /// §9-2(2026-08-16): 今どちらの機体の仕事か。Optional なのは古いサーバ
    /// (machine を知らない版)との互換 — 無ければ「机の仕事」として描く。
    let machine: Machine?

    /// 「机が Tom の返事を待っている」(2026-08-27)。
    ///
    /// ★**判定は机が持つ。** サーバは digest と**同じ `attentionOf`** で決めて此処へ載せる。
    ///   電話側で `route` や画面から推測すると、机と電話で「待っている」の定義が分かれ、
    ///   必ず片方だけ腐る(`AccountClient` の `blocked` と同じ判断)。
    ///
    /// ★なぜ要るか(実測 2026-08-26): 会話を開けば digest が「待っている」と言うが、
    ///   一覧は `route.kind == .choice` の時だけ札を出していた。生きた 2 本とも
    ///   `route = null` で、あの札は一度も出ていない。**開くまで待たれている事を
    ///   知れない**のでは、取り戻したい死に時間がそのまま残る(60 分観測)。
    ///
    /// ★Optional は古いサーバとの互換。無ければ「待っていない」ではなく
    ///   **「判らない」**なので、札を出さない側へ倒す(`unknown` を急かしに使わない、
    ///   という 2026-08-26 の裁定と同じ)。
    let requiresOwnerInput: Bool?

    struct RowDisplay: Decodable, Equatable {
        let route: RouteLabel
        /// Server-computed (`subtitleOf` in `view.mjs`). Rendered as-is -- brief
        /// §3-a: "自分で組み立てない".
        let subtitle: String
    }

    /// `sessionRow`(`wire.mjs`)の machine。kind は enum にしない(知らない語で
    /// 行ごと落とさない — `RouteLabel.Kind` の unknown 吸収と同じ判断を素の文字列で)。
    struct Machine: Decodable, Equatable {
        let kind: String                 // "desk" | "checkout"(将来増え得る)
        let checkoutId: String?
        let returnRequestedAt: String?
    }

    /// 持ち出し(remote-mini)の仕事か。
    var isCheckout: Bool { machine?.kind == "checkout" }

    /// Brief §3-a: row title falls back to the id's first 8 characters when `title`
    /// is empty. The wire shape lists `title` as always-present (`string`, not
    /// `string | null`), so the fallback is a display-time concern, not a decode
    /// concern -- there is no observed case of the key being absent to guard against
    /// at the `Decodable` layer.
    var displayTitle: String {
        title.isEmpty ? String(id.prefix(8)) : title
    }
}

/// `display.route` on a session row. Brief §0-a-2: `screen` is `""` (not absent, not
/// null) on the worker route -- kept as a non-optional `String` so that "no screen"
/// (`""`) and "field missing" can never be confused by an `Optional` in between.
/// Every branch of the server's `routeLabel()` sets `screen` explicitly (to `v.screen`,
/// `v.screen || ""`, or a literal `""`), so the key is always present on the wire.
struct RouteLabel: Decodable, Equatable {
    let kind: Kind
    /// Short badge text, ~9-10 characters in practice.
    let short: String
    /// Up to 92 characters (`view.mjs`'s own note on `routeLabel`) -- must not be
    /// truncated or squeezed onto one line by the row layout.
    let text: String
    let screen: String

    /// Brief §1-b: 5 known values (`tmux`/`worker`/`choice`/`blocked`/`unknown`),
    /// with `choice` carrying the strongest visual emphasis (it is the only state
    /// where pressing Enter on the desk side becomes an approval/charge). An
    /// unrecognized value must fall to `.unknown` and MUST NOT fail decoding -- an
    /// old phone talking to a server that has grown a 6th route name must not go
    /// blank, matching the same judgment `ReadablePoll` already makes for unknown
    /// `kind` values in the poll stream.
    enum Kind: String, Equatable {
        case tmux, worker, choice, blocked, unknown
    }
}

extension RouteLabel.Kind: Decodable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RouteLabel.Kind(rawValue: raw) ?? .unknown
    }
}
