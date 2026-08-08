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

    /// 「送った本文が、取り直した履歴に**新しく**現れたか」。DESIGN §2.52。
    ///
    /// ★差分である事が全部。取り直した側に一致行が在る事**だけ**を見ると、過去に
    /// 同じ本文を送った事の在る会話では何を送っても「届いた」と言う —— 一度も
    /// 落ちず、単体検査も緑のまま、答えだけが常に当たりに見える型。だから
    /// `before` を要求する形にしてある(引数を渡さないと呼べない = 忘れられない)。
    ///
    /// ★★「新しく」は**件数の差ではなく、増えた区間**で見る。両方とも同じ `limit` で
    /// 取った**末尾の窓**であって、机が1行進めば窓は前から1行こぼれる。だから
    ///
    ///     before = [〈止めて〉, a, b, …, y]      (50件で満杯)
    ///     after  = [a, b, …, y, 〈止めて〉]      (先頭がこぼれ、送った物が末尾に付いた)
    ///
    /// で件数を引くと 1 - 1 = 0 になり、**届いているのに「出ていません」**と言う。
    /// それは再送を勧める向き = 二重配達を作る向きで、この節が一番避けたい誤り。
    /// 窓を跨いで安定な量は件数ではなく「重なりの外側」なので、`merge` と同じ
    /// 降順の重なり探索で `after` の**新しい部分**を切り出してから、そこだけを見る。
    ///
    /// 重なりが1つも見付からず、かつ `before` が空でない時は **`nil` を返す**。
    /// 送信と取り直しの間に窓1枚分が丸ごと流れた事になり、`after` のどこに境目が
    /// 在るか電話には分からない。分からないまま `after` 全体を見ると、遥か昔の
    /// 同じ本文を今回の配達と読む —— **見当を失った時は主張しない。**
    ///
    /// ★★`false` ではなく `nil` である事が要点。`false` は呼ぶ側で
    /// 「今の机には出ていません。もう一度送れます。」 になる —— 見ていない事を机に
    /// ついて断言し、しかも再送 = 二重配達を勧める。この節が直しているのは
    /// 「電話が机の状態を語った事」なので、当ての中で同じ事をやったら意味が無い。
    /// 型で3つ目の答えを要求する事で、呼ぶ側が「分からない」を潰せなくしてある。
    ///
    /// `before` が空の時だけは `after` 全体が新しい区間で、これは推測ではない
    /// (無かった所に在る)。
    ///
    /// 同じ本文を2回送るのは正当な操作なので、**増えた区間の中に在るか**で見れば
    /// 2通目も正しく「届いた」になる。存在の真偽を `after` 全体に対して問う形は、
    /// 過去に同じ本文が在る会話で常に真になるので採らない。
    ///
    /// `role == .user` に絞るのは、机の Claude が本文を引用して読み上げる事が在る為。
    /// 引用は `assistant` の行なので、役割を見なければ引用を配達と読む。
    ///
    /// JS 側に対応物は無い(電話だけが持つ判定)。`sameRoleAndText` と同じ場所に
    /// 置くのは、両方とも「同じ発言とは何か」を決める唯一の定義だから。
    ///
    /// ★本文の一致は字面では見ない。`server.mjs` は受け取った本文を注入前に `trim()`
    /// しており(実測)、複数行は端末の composer へ行単位で打ち込まれるので、机に残る
    /// 記録が電話の `draft` と1バイトずつ同じである保証はどこにも無い。空白の違いで
    /// 外す方向の間違いも**再送を勧める**方向なので、そちら側には倒さない。逆向きの
    /// 誤り(空白だけ違う別の発言を自分のと読む)が起きるには、増えた区間の中で机の
    /// 人がその本文を打っている必要が在り、費用が釣り合わない。
    ///
    /// 重なりの一致だけは正規化しない(`sameRoleAndText` = 字面)。両側は**同じ記録を
    /// 2回読んだ物**なので、そこで揺れる余地は無い。
    static func landed(text: String, before: [HistoryEntry], after: [HistoryEntry]) -> Bool? {
        guard let newlyArrived = entriesAppearingAfter(before, in: after) else { return nil }
        let needle = normalizedForLanding(text)
        return newlyArrived.contains { $0.role == .user && normalizedForLanding($0.text) == needle }
    }

    /// `after` のうち `before` に無かった区間。見当が付かない時は `nil`(「無かった」
    /// を意味する `[]` とは別物 —— 呼ぶ側が両者を混同できない形にしてある)。
    private static func entriesAppearingAfter(
        _ before: [HistoryEntry], in after: [HistoryEntry]
    ) -> ArraySlice<HistoryEntry>? {
        guard !before.isEmpty else { return after[...] }

        var k = min(before.count, after.count)
        while k > 0 {
            if zip(before.suffix(k), after.prefix(k)).allSatisfy(sameRoleAndText) {
                return after.dropFirst(k)
            }
            k -= 1
        }
        return nil
    }

    private static func normalizedForLanding(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
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
