import Foundation

/// slash command の**引数の候補**(2026-09-03、対照表 #14「model の選択」/ #15「effort」)。
///
/// 公式 Remote Control は `/model sonnet` の様に引数インラインで model を選ばせる
/// (`research/remote-control-teardown.md` §3)。RemoteMini の `/model` チップは
/// 入力欄に `/model ` を差すだけで、其の先は打鍵だった —— 移動中に model の綴りを
/// 打つのは、選ぶ操作としては重い。
///
/// ★机に口は作らない。候補は入力欄の文字列を**足すだけ**で、送るのは人が送信を押す時
///   (写真の添付・slash・`@` 補完と同じ「押しても送らない」規約)。model を変える動詞は
///   机の `/model` そのもので、電話は其の綴りを手伝うだけ。
/// ★slash のチップ自体は増やさない(裁定: 移動中に効く 3 つだけ)。此処は其の command の
///   **後ろ**にだけ出る 2 段目で、其の command を入力欄に持つ人にしか見えない。
/// ★`/effort` は **2026-09-03 に Tom が「4 つ目のチップにはしない」と裁定**した。チップは無いが、
///   `/effort` と**打った時だけ** 2 段目(`low / medium / high`)を出す(brief #15 の案 2)。
///   チップ経由か打鍵経由かを此の型は区別しない —— 見るのは入力欄の文字列だけ。
/// ★純関数にして view から出したのは `PathMention` と同じ理由 —— 出る/出ないの規則が
///   view body の中に在ると検査から一度も触れない。
enum SlashArgument {

    /// `/model` に渡せる名前。Claude Code の `/model` が受ける別名(実測: `opus` / `sonnet` /
    /// `haiku` / `default`)。完全な id(`claude-opus-5` 等)も通るが、移動中に打つ物ではない。
    static let modelNames: [String] = ["opus", "sonnet", "haiku", "default"]

    /// `/effort` に渡せる段。公式(whats-new 2026-w34)「Picking a level from the effort control」の
    /// 3 段。順は軽い方から(移動中に一番押すのは `low` か `high` で、真ん中は既定)。
    static let effortLevels: [String] = ["low", "medium", "high"]

    /// 2 段目を持つ command と其の候補。**順序が在る**(上から順に照合する)ので配列。
    /// 増やす時は此処に 1 行 —— 判定・差し込み・画面の識別子が全部此の表から出る。
    static let commands: [(command: String, values: [String])] = [
        ("/model", modelNames),
        ("/effort", effortLevels),
    ]

    /// 入力欄の中身が持つ command(`/model` / `/effort`)。無ければ nil。
    ///
    /// 条件: 先頭(空白を除く)が其の command で、其の直後が終端か空白(`/models` を `/model` と
    /// 読まない)。文の途中の `/model` は拾わない(差し込み位置を推定しない)。
    static func command(in text: String) -> String? {
        let s = Substring(text).drop(while: { $0.isWhitespace })
        for entry in commands where s.hasPrefix(entry.command) {
            let rest = s.dropFirst(entry.command.count)
            if let first = rest.first, !first.isWhitespace { continue }
            return entry.command
        }
        return nil
    }

    /// 画面の識別子に使う短い名(`/model` → `model`)。
    static func key(of command: String) -> String {
        String(command.drop(while: { $0 == "/" }))
    }

    /// 入力欄の中身から、出すべき候補。無ければ空。
    ///
    /// 出す条件(全部「出さない側に倒す」向き):
    ///   1. `command(in:)` が command を返す
    ///   2. 引数はまだ書きかけ = command の後ろに**空白で区切られた語が 1 つ以下**で、
    ///      其の語の後ろに空白が無い(空白が来た = 書き終えた)
    ///   3. 書きかけの語で前方一致する名前だけ(`/model so` → `sonnet`、`/effort h` → `high`)
    /// command の後ろに何も無い時は全候補。`/model opus ` の様に書き終えていれば空。
    static func candidates(for text: String) -> [String] {
        guard let cmd = command(in: text),
              let values = commands.first(where: { $0.command == cmd })?.values else { return [] }
        let s = Substring(text).drop(while: { $0.isWhitespace })
        let rest = s.dropFirst(cmd.count)
        let arg = rest.drop(while: { $0.isWhitespace })
        // 語の後ろに空白が在る = 書き終えた(候補を出し続けると、選び終わった後も帯が残る)
        guard !arg.contains(where: { $0.isWhitespace }) else { return [] }
        let partial = String(arg)
        // 打ち終えた名前そのもの(`/model opus`)にも、まだ空白が無ければ其の 1 件を出す
        // —— 押せば空白が付いて帯が消える。出さないと「消えない帯」と「消し方の無い帯」の
        // 差が人に判らない。
        return values.filter { $0.hasPrefix(partial) }
    }

    /// 候補を選んだ後の入力欄の中身。`<command> <name> `(末尾の空白 = 書き終えた合図で、
    /// 候補の帯が消える)。**送らない**。2 段目を持つ command で始まっていなければ何も変えない。
    static func replacing(_ text: String, with name: String) -> String {
        guard let cmd = command(in: text) else { return text }
        return "\(cmd) \(name) "
    }
}
