import Foundation

/// 一覧の**絞り込み**(2026-09-03、対照表 #24「一覧の検索・絞り込み」)。
///
/// 机への往復は無い —— 既に手元に在る行の題名と副題(机が組む `RowDisplay.subtitle`)を文字で絞るだけ。
/// 移動中に 40 本の一覧を目で走査する代わりに、覚えている語を 1 つ打てば足りる、が此の機能の全部。
///
/// ★純関数にして view から出したのは `SlashArgument` / `PathMention` と同じ理由 —— 出る/出ないの規則が
///   view body の中に在ると検査から一度も触れない。
/// ★一致は `localizedStandardContains`(大文字小文字・アクセント・全角半角を同一視。Finder の検索と同じ規則)。
///   前方一致にしないのは、題名は机が付ける要約で、覚えているのは途中の語だから。
enum SessionFilter {

    /// 空白だけの問いは「絞らない」。
    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 題名か副題のどちらかに問いを含む(文字列の規則そのもの。行の型を知らない = 単体検査が素の文字列で組める)。
    static func matches(title: String, subtitle: String, query: String) -> Bool {
        let q = normalized(query)
        if q.isEmpty { return true }
        return title.localizedStandardContains(q) || subtitle.localizedStandardContains(q)
    }

    /// 行の並びを絞る。順は変えない(絞った後も机の並び順 = 更新順のまま)。
    static func apply(_ rows: [SessionRow], query: String) -> [SessionRow] {
        let q = normalized(query)
        if q.isEmpty { return rows }
        return rows.filter { matches(title: $0.title, subtitle: $0.display.subtitle, query: q) }
    }
}
