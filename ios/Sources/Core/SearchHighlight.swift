import Foundation
import SwiftUI

/// 検索の当たり語の**強調**(2026-09-03、対照表 #42「検索の一致箇所ハイライト」)。
///
/// 結果の面は行の本文を切らない(切ると画面外の一致が偽陽性に見える —— `searchRows` の註)。
/// 其の代わり長い行では「なぜ当たったか」を読み直す事になる。当たった語を色で立てれば、目は其処へ行く。
///
/// ★純関数にして view から出したのは `SessionFilter` と同じ理由。一致の規則は机の `searchHistoryFromPath`
///   (`toLowerCase().includes`)に**合わせる**: 大文字小文字を同一視した部分一致、全部の出現。
///   机と違う規則で塗ると「当たったのに塗られない行」が出て、塗りが嘘になる。
enum SearchHighlight {

    /// `text` の中で `query` が現れる範囲(大文字小文字を同一視、重ならない全出現)。空の問いは空。
    static func ranges(in text: String, of query: String) -> [Range<String.Index>] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let r = text.range(of: q, options: [.caseInsensitive], range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    static func count(in text: String, of query: String) -> Int {
        ranges(in: text, of: query).count
    }

    /// 当たり語だけを太字 + 色にした本文。当たりが無ければ素の文字列と同じ見え方。
    static func attributed(_ text: String, query: String, color: Color) -> AttributedString {
        var a = AttributedString(text)
        for r in ranges(in: text, of: query) {
            guard let lower = AttributedString.Index(r.lowerBound, within: a),
                  let upper = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lower..<upper].foregroundColor = color
            a[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return a
    }
}
