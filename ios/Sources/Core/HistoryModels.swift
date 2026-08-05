import Foundation

/// Decodable models for `GET /api/sessions/<id>/history`, shaped from the real
/// observed response (Sprint 3 brief §0), not the spec's prose.
struct HistoryResponse: Decodable, Equatable {
    let history: [HistoryEntry]
    /// ★Brief §0-a-1, "the single easiest thing to get wrong this sprint": empty
    /// history has TWO real wire shapes. `server.mjs`'s `/history` handler returns
    /// `{"history": []}` (the `truncated` key entirely absent) when the conversation
    /// file doesn't exist yet, and `{"history": [], "truncated": false}` (key
    /// present) once it does but is empty -- both observed in the same 39-session
    /// sweep (§0, 1 of each).
    ///
    /// A non-optional `Bool` fails decoding outright on the first shape -- the whole
    /// conversation would refuse to open. `Bool?` would decode both shapes, but then
    /// a THIRD state ("don't know") leaks into the view's branching, when "key
    /// absent" and "key present, false" mean the exact same thing to the phone: don't
    /// show "load earlier." Decoded as `decodeIfPresent(...) ?? false`, not left
    /// `Optional` -- see `HistoryModelsTests.testTruncatedKeyAbsentDecodesToFalse`,
    /// which feeds a body with the key missing, not just one where it's `false`
    /// (feeding only the latter would stay green even with the non-optional mistake).
    let truncated: Bool

    /// Not part of the wire shape -- only `Decodable`'s synthesized `init(from:)`
    /// needs `CodingKeys`; fixtures and tests use this memberwise form directly.
    init(history: [HistoryEntry], truncated: Bool) {
        self.history = history
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case history, truncated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        history = try container.decode([HistoryEntry].self, forKey: .history)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

struct HistoryEntry: Decodable, Equatable {
    let role: EntryRole
    /// The message body, rendered as-is (brief §3-a: no Markdown interpretation, no
    /// truncation in v1). For a `.tool` entry this is a short one-line tool label
    /// (e.g. `"⚙ Bash"`, `sessions.mjs`'s `toolNames`), not prose -- brief §0-a-2.
    let text: String
    let display: EntryDisplay

    init(role: EntryRole, text: String, display: EntryDisplay) {
        self.role = role
        self.text = text
        self.display = display
    }

    /// Brief §0-a-3: `who` is S-group -- computed server-side by `whoOf(role)` and
    /// shipped verbatim. Swift renders `display.who`, never reconstructs a display
    /// name from `role` itself: two implementations of "what does this role show as"
    /// is exactly the kind of duplicate that goes silently stale when only one side
    /// gets fixed.
    struct EntryDisplay: Decodable, Equatable {
        let who: String

        init(who: String) {
            self.who = who
        }
    }
}

/// Brief §0-a-2: 3 known values on the wire (`user`/`assistant`/`tool`). An
/// unrecognized value must fall back to `.unknown` and MUST NOT fail decoding --
/// the same judgment `SessionsModels.swift`'s `RouteLabel.Kind` already makes for an
/// unrecognized route `kind`: an old phone talking to a server that has grown a 4th
/// role must render *something*, not go blank.
enum EntryRole: String, Equatable {
    case user, assistant, tool, unknown
}

extension EntryRole: Decodable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EntryRole(rawValue: raw) ?? .unknown
    }
}
