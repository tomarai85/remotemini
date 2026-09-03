import Foundation

/// Turns pending diff comments(#6)into the plain-text prefix `ConversationViewModel
/// .send()` prepends to what the user typed. **Pure function** -- same shape as
/// `MergeHistory`/`PathMention`: no network, no state, easy to test in isolation.
///
/// ★the desk needs no new route for this. `rc-backend/src/server.mjs`'s `messages`
///   handler does `body.text.trim()` and nothing else structural to it (verified by
///   reading that handler before writing this file) -- so a comment block is just
///   more plain-text prose ahead of the user's own words, on the exact same
///   `POST …/messages` route #4/#10/slash chips already use.
enum DiffCommentFormatter {
    /// One block per comment, in the order they were added, followed by a blank
    /// line and then the user's own text (empty `userText` = comments only, valid
    /// on its own -- e.g. flagging a line with no further chat). Format, verbatim:
    ///
    ///   `<path>:<line> (<+|-|context> "<quoted line text>") — <comment>`
    ///
    /// ★no comments = returns `userText` completely unchanged (not even a trailing
    ///   newline added) -- this keeps `ConversationViewModel`'s existing
    ///   "text is transmitted unmodified" tests green for every conversation that
    ///   never opens the diff screen.
    static func compose(comments: [DiffComment], userText: String) -> String {
        guard !comments.isEmpty else { return userText }
        let blocks = comments.map(block(for:)).joined(separator: "\n")
        return userText.isEmpty ? blocks : "\(blocks)\n\n\(userText)"
    }

    /// One comment's block, exposed separately so a test can check the exact
    /// literal format without going through `compose`'s joining/ordering rules.
    static func block(for comment: DiffComment) -> String {
        "\(comment.path):\(comment.line) (\(symbol(for: comment.kind)) \"\(comment.quotedText)\") — \(comment.text)"
    }

    /// `+`/`-` read naturally as the diff's own marks; `ctx` has none in the diff
    /// itself, so it gets the word instead of a blank space a reader could miss.
    /// `unknown`(将来 机が増やすかもしれない種類)は `ctx` と同じ扱い -- 記号が
    /// 決まらない種類を理由に此の行のコメントだけ組めなくする理由が無い。
    private static func symbol(for kind: DiffLineKind) -> String {
        switch kind {
        case .add: return "+"
        case .del: return "-"
        case .ctx, .unknown: return "context"
        }
    }
}
