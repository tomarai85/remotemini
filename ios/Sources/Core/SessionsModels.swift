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
        let reason: String
        let detail: String
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

    struct RowDisplay: Decodable, Equatable {
        let route: RouteLabel
        /// Server-computed (`subtitleOf` in `view.mjs`). Rendered as-is -- brief
        /// §3-a: "自分で組み立てない".
        let subtitle: String
    }

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
