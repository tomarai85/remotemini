import Foundation

/// The long-poll bookmark rc-backend hands back on every `/poll` response
/// (spec §3-2, `tail.mjs`'s `formatPollCursor`/`pollDecision`).
///
/// **Opaque by contract**: the client stores whatever string arrives and returns it
/// byte-for-byte on the next request. It never parses the
/// `t.<epoch>.<seq>.<screenRev>` / `w.<generation>.<seq>.0` shape -- `tail.mjs` is the
/// only code allowed to know that shape exists, so a future server-side cursor format
/// change never requires a client release.
struct PollCursor: Equatable {
    /// The exact string sent back to the server on the next poll request. Not a
    /// token type, not a parsed struct -- see the type-level doc for why.
    let wireValue: String

    init(raw: String) {
        self.wireValue = raw
    }

    /// The documented "no cursor yet" sentinel (spec §3-2: an empty string reads as
    /// `fresh` in `tail.mjs`'s `pollDecision`). Using this is not "constructing a
    /// server token" -- it is the one value the wire protocol itself defines as
    /// meaning "nothing to resume from," identical to a first-ever request.
    static let empty = PollCursor(raw: "")
}
