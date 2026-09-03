import Foundation

/// slash command の**引数の候補**(2026-09-03、対照表 #14「model の選択」)。
///
/// 公式 Remote Control は `/model sonnet` の様に引数インラインで model を選ばせる
/// (`research/remote-control-teardown.md` §3)。RemoteMini の `/model` チップは
/// 入力欄に `/model ` を差すだけで、其の先は打鍵だった —— 移動中に model の綴りを
/// 打つのは、選ぶ操作としては重い。
///
/// ★机に口は作らない。候補は入力欄の文字列を**足すだけ**で、送るのは人が送信を押す時
///   (写真の添付・slash・`@` 補完と同じ「押しても送らない」規約)。model を変える動詞は
///   机の `/model` そのもので、電話は其の綴りを手伝うだけ。
/// ★slash のチップ自体は増やさない(裁定: 移動中に効く 3 つだけ)。此処は其の 1 つ
///   `/model` の**後ろ**にだけ出る 2 段目で、`/model` を選んだ人にしか見えない。
///   `/effort` は別の裁定(4 つ目のチップになる)なので此処では扱わない。
/// ★純関数にして view から出したのは `PathMention` と同じ理由 —— 出る/出ないの規則が
///   view body の中に在ると検査から一度も触れない。
enum SlashArgument {

    /// `/model` に渡せる名前。Claude Code の `/model` が受ける別名(実測: `opus` / `sonnet` /
    /// `haiku` / `default`)。完全な id(`claude-opus-5` 等)も通るが、移動中に打つ物ではない。
    static let modelNames: [String] = ["opus", "sonnet", "haiku", "default"]

    /// 入力欄の中身から、出すべき候補。無ければ空。
    ///
    /// 出す条件(全部「出さない側に倒す」向き):
    ///   1. 先頭(空白を除く)が `/model` で、其の直後が終端か空白
    ///   2. 引数はまだ書きかけ = `/model` の後ろに**空白で区切られた語が 1 つ以下**で、
    ///      其の語の後ろに空白が無い(空白が来た = 書き終えた)
    ///   3. 書きかけの語で前方一致する名前だけ(`/model so` → `sonnet`)
    /// `/model` の後ろに何も無い時は全候補。`/model opus ` の様に書き終えていれば空。
    static func candidates(for text: String) -> [String] {
        let s = Substring(text).drop(while: { $0.isWhitespace })
        guard s.hasPrefix("/model") else { return [] }
        let rest = s.dropFirst("/model".count)
        // `/models` の様な別語を `/model` と読まない
        if let first = rest.first, !first.isWhitespace { return [] }
        let arg = rest.drop(while: { $0.isWhitespace })
        // 語の後ろに空白が在る = 書き終えた(候補を出し続けると、選び終わった後も帯が残る)
        guard !arg.contains(where: { $0.isWhitespace }) else { return [] }
        let partial = String(arg)
        let hits = modelNames.filter { $0.hasPrefix(partial) }
        // 打ち終えた名前そのもの(`/model opus`)にも、まだ空白が無ければ其の 1 件を出す
        // —— 押せば空白が付いて帯が消える。出さないと「消えない帯」と「消し方の無い帯」の
        // 差が人に判らない。
        return hits
    }

    /// 候補を選んだ後の入力欄の中身。`/model <name> `(末尾の空白 = 書き終えた合図で、
    /// 候補の帯が消える)。**送らない**。`/model` で始まっていなければ何も変えない。
    static func replacing(_ text: String, with name: String) -> String {
        guard !candidates(for: text).isEmpty || Substring(text).drop(while: { $0.isWhitespace }).hasPrefix("/model") else {
            return text
        }
        return "/model \(name) "
    }
}
