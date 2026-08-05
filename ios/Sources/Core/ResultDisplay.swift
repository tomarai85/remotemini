import Foundation

/// 系統B `display` -- the screen-language the server attaches to the response of an
/// *action* (`rc-backend/src/view.mjs`'s `sendResult`, injected into the body by
/// `server.mjs`'s `json()` because the handler declared a formatter via `speaks()`).
///
/// Distinct type from `PollDisplay`, which is the poll response's own `display` and
/// carries `choice` rather than `kind`/`text`. Same wire key, two different shapes on
/// two different routes -- collapsing them into one Swift type would mean a decoder
/// that accepts either, which is exactly the "one type, two meanings" shape the 404
/// finding (Sprint 5 brief §0-c ②) shows costs more than it saves.
///
/// **The phone renders `text` verbatim and never derives wording from the HTTP status
/// or the body's other fields.** That rule is the whole point of this type existing
/// (brief §0-c ③, Codex 2026-08-05): the moment the phone starts composing its own
/// sentence for "409 means refused," there are two places that decide what the user
/// reads and they drift.
struct ResultDisplay: Decodable, Equatable {
    /// Deliberately `String`, NOT a `String`-backed `Decodable` enum (brief §0-c ⑥).
    /// Today the server sends exactly `ok` / `warn` / `refused` / `error`. Binding
    /// this to a strict enum would make the decode *throw* on the day a fifth value
    /// ships -- and because `text` is decoded from the same object, throwing would
    /// discard a perfectly readable message and show "couldn't read the response"
    /// instead. Unknown `kind` degrades the *appearance* (see `tone`), never the text.
    let kind: String

    /// The sentence shown to the user, as the server wrote it. Never post-processed,
    /// never localized (brief §0-c ④: the 400 branch legitimately carries internal
    /// English like `text required`, and translating it on the phone would create a
    /// second source of truth for wording).
    let text: String

    /// Whether the composer must KEEP what the user typed. Read as a field, never
    /// inferred from `kind` (brief §2 step 5): `keepText:false` happens to occur on
    /// exactly one branch today (`kind:"ok"`), so `kind == "ok"` would be green now
    /// and silently wrong the day the server adds a second.
    ///
    /// `nil` (key absent) is treated as **keep** by `ConversationViewModel`, which is
    /// a deliberate departure from the Sprint 5 brief's §2 step 5 ("偽/不在なら消す")
    /// -- see `ConversationViewModel.applySendOutcome(_:)` for the reasoning. The
    /// field stays optional here either way; this type only decodes, it does not
    /// decide.
    let keepText: Bool?
}

extension ResultDisplay {
    /// How the banner should LOOK. Separate from `kind` because appearance is the one
    /// thing that may safely fall back: an unrecognized `kind` still shows its text,
    /// just in the neutral warning style rather than a style this build has never
    /// heard of.
    enum Tone: Equatable {
        case ok
        case warn
        case refused
        case error
    }

    /// Brief §0-c ⑥: unknown values fall back to `.warn` -- deliberately not `.ok`
    /// (which would dress an unrecognized outcome as success) and not `.error`
    /// (which would dress a possibly-fine outcome as failure).
    var tone: Tone {
        switch kind {
        case "ok": return .ok
        case "refused": return .refused
        case "error": return .error
        case "warn": return .warn
        default: return .warn
        }
    }
}

/// What the Conversation screen actually draws under the composer after a send.
///
/// `fromServer` exists so a test can assert the *provenance* of the wording, not just
/// its content: the normal path must carry `display.text` unmodified, and the only
/// banners the phone is allowed to word itself are the ones where no `display` ever
/// arrived (response-contract violation, transport failure). Without this flag, a
/// regression that quietly replaced the server's sentence with a locally-composed one
/// would still look green to any test that only checks "some text is shown."
struct SendBanner: Equatable {
    let tone: ResultDisplay.Tone
    let text: String
    let fromServer: Bool

    /// The verbatim path: `display.text` and nothing else.
    init(display: ResultDisplay) {
        self.tone = display.tone
        self.text = display.text
        self.fromServer = true
    }

    /// The phone-worded path. Only three call sites are allowed to use it (contract
    /// violation, transport failure, cancelled-supersede) and each names its reason.
    init(locallyWorded text: String, tone: ResultDisplay.Tone) {
        self.tone = tone
        self.text = text
        self.fromServer = false
    }
}

/// The server's recovery vocabulary, as it appears on the wire. `server.mjs` keeps
/// these words in frozen constants specifically so that "which 404 is this?" is
/// answered by a named value rather than re-decided at each call site; this type is
/// the phone's half of that agreement.
///
/// Only `code` is declared. The sibling `error` field is human prose that the server
/// is free to reword -- brief §0-b: "電話が繋ぐ鍵は `error` の文言ではなく `code` の側."
struct RecoveryCode: Decodable, Equatable {
    let code: String?

    /// The one code that changes which screen the phone shows. `AUTH_REQUIRED` is not
    /// listed because the phone acts on the 401 status itself (the code adds nothing
    /// there), and `NO_SUCH_ROUTE` is not listed because nothing branches on it -- it
    /// reaches the user only as the diagnostic inside a contract violation.
    static let sessionNotFound = "SESSION_NOT_FOUND"
}

/// A response that carried neither a `display` nor one of the two recovery signals
/// the contract allows to lack one (brief §0-c ③).
///
/// Only `status` and `code` are retained. The response BODY is deliberately not kept:
/// `server.mjs`'s own 400 handler notes that a parser error message can quote a
/// fragment of the request body, so anything derived from an error body is a path for
/// the user's typed text to reach a log. Status and `code` are server-issued
/// vocabulary words with no user content in them.
struct ResponseContractViolation: Equatable {
    let status: Int
    let code: String?

    /// The FIXED failure text (brief §0-c ③: "電話が文言を創作しない" -- one sentence
    /// for every violation, not a per-status explanation, because an explanation the
    /// phone invents for a response it could not read is a guess wearing a fact's
    /// clothes). The status/code are appended as diagnostics, not as prose: they say
    /// what arrived, they do not claim to say why.
    var displayText: String {
        let diagnostic = code.map { "HTTP \(status) / \($0)" } ?? "HTTP \(status)"
        return "サーバの応答に、画面へ出すべき内容が入っていませんでした(\(diagnostic))。送れたかどうかは確認できていません。机の画面を確認してください。"
    }
}
