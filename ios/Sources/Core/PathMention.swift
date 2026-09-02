import Foundation

/// 入力欄の**末尾**に書きかけの `@` が在るか、そして選んだ候補をどう差すか。
///
/// ★純関数にして view から出したのは `ForegroundResume.shouldResume` と同じ理由 ——
///   「利用者が見る物」を決める規則が view body の中に在ると、検査から一度も触れない。
///   此の規則は誤ると害が2方向に出る(出るべき時に出ない / 出てはいけない時に出る)ので、
///   両方を直に測れる形に置く。
///
/// ★**末尾だけ**を見る。文の途中の `@` を拾わないのは、拾うと差し込み位置を
///   電話が推定する事になり、`TextField` が持つカーソル位置と食い違った日に
///   **人が打った文字を消す**からで、その害は候補が出ない事より遥かに重い。
enum PathMention {

    /// 書きかけの `@` の**後ろ**(= 机へ送る問い)。無ければ `nil`。
    ///
    /// 条件は3つ。どれも「候補を出さない側に倒す」向きに選んである:
    ///   1. 最後の `@` より後ろに**空白・改行が無い**(空白が来た = 書き終えた)
    ///   2. `@` の**直前**が行頭か空白(`user@example.com` の `@` を拾わない)
    ///   3. 後ろが長すぎない(打ち間違いで文を丸ごと問いにして机を舐めさせない)
    ///
    /// `@` を打った直後(後ろが空)は `""` を返す —— 之は `nil` ではない。
    /// 机は空の問いに **cwd の直下**を返すので、`@` を打つと一段目が出る。
    static func trailingQuery(in text: String, maxLength: Int = 200) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }

        // ② `@` の直前。行頭か空白でなければ、之は path の書きかけではない。
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            guard before.isWhitespace else { return nil }
        }

        let tail = text[text.index(after: at)...]
        // ① 空白が入ったら書き終わり。改行も同じ(`isWhitespace` が両方を含む)。
        guard !tail.contains(where: { $0.isWhitespace }) else { return nil }
        // ③ 長さの枠。机側にも同じ枠が在る(`PATHS_QUERY_MAX`)が、送る前に止めた方が
        //    往復1回ぶん安く、机の判断に頼らずに済む(`HistoryClient.search` と同じ形)。
        guard tail.count <= maxLength else { return nil }

        return String(tail)
    }

    /// 候補を選んだ後の入力欄の中身。**`@` は残し、その後ろだけ**を置き換える。
    ///
    /// ★dir は末尾に `/` を付けて**空白を足さない**。付けないと、選んだ次の瞬間に
    ///   問いが `src` のままになり、同じ候補列がもう一度出る = 一段も降りられない。
    ///   `/` を足せば問いが `src/` になり、机は其の下を返す(前方一致が区切りを跨ぐ)。
    /// ★file は末尾に**空白**を足す。足さないと `trailingQuery` が返り続けるので、
    ///   選び終わった後も候補列が画面に残る。空白1つが「書き終えた」の合図になる。
    /// ★**送らない**。写真の添付・slash のチップと同じ規約で、差し込むだけ。
    ///
    /// 書きかけの `@` が無ければ**何も変えない**(`text` をそのまま返す)。
    /// 押せる所に候補が出ている以上 起きない筈だが、起きた時に文の末尾へ
    /// 勝手に足すより、何もしない方が失う物が無い。
    static func replacingTrailingQuery(in text: String, with suggestion: PathSuggestion) -> String {
        guard trailingQuery(in: text) != nil, let at = text.lastIndex(of: "@") else { return text }
        let head = text[..<at]
        let suffix = suggestion.kind == .dir ? "/" : " "
        return head + "@" + suggestion.path + suffix
    }
}
