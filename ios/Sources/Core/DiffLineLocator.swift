import Foundation

/// Computes the standard unified-diff line numbers for the lines inside one hunk,
/// from its raw header string(`@@ -a,b +c,d @@`、時に末尾へ git が関数名の文脈を
/// 続ける)。
///
/// ★机は行番号を送っていない -- `sessiondiff.mjs`/`wire.mjs` の `diffBody` は
///   `header`(生文字列)と `lines: [{kind, text}]` しか持たない。`DiffHunkView` の
///   doc「頭書きは机の生の文字列のまま出す(電話は解釈しない)」はそのまま生きていて、
///   此処で解くのは対照表 #6(行コメント)の為だけ -- header の**表示**は
///   引き続き生文字列のまま、解いた数字は裏でしか使わない。
///
/// ★純関数。副作用も状態も持たない -- 検査は文字列を渡して数の配列を見るだけで済む。
enum DiffLineLocator {
    /// `@@ -a[,b] +c[,d] @@` の `a`/`c` を読む。`nil` = 此の形に一致しない
    /// (見た事のない header)。合わない時は推測せず「番号が無い」へ倒す -- 呼ぶ側
    /// (`DiffHunkView`)はコメントの口自体を出さない。
    static func startLines(header: String) -> (old: Int, new: Int)? {
        guard let regex = Self.headerRegex else { return nil }
        let range = NSRange(header.startIndex..., in: header)
        guard let match = regex.firstMatch(in: header, options: [], range: range),
              let oldRange = Range(match.range(at: 1), in: header),
              let newRange = Range(match.range(at: 2), in: header),
              let old = Int(header[oldRange]),
              let new = Int(header[newRange])
        else {
            return nil
        }
        return (old, new)
    }

    /// `lines` と**同じ順・同じ数**で行番号を返す(対応する index が其のまま使える)。
    /// header が解けなければ全部 `nil`(= 番号なし)。
    ///
    /// ★`del` は旧側の番号、`ctx`/`add` は新側の番号 -- ctx は両側に実在するが、
    ///   新側を選ぶのは「変更後のファイルを眺めている読者」の視点に合わせる為
    ///   (GitHub/GitLab の行コメントも同じ選び方)。`unknown`(将来 机が増やすかもしれない
    ///   種類、`DiffLineKind` の doc)は ctx と同じ扱いにする -- 未知の種類を理由に
    ///   番号ごと諦めない。
    static func lineNumbers(header: String, lines: [DiffLine]) -> [Int?] {
        guard let start = startLines(header: header) else {
            return lines.map { _ in nil }
        }
        var old = start.old
        var new = start.new
        return lines.map { line in
            switch line.kind {
            case .del:
                let n = old
                old += 1
                return n
            case .add:
                let n = new
                new += 1
                return n
            case .ctx, .unknown:
                let n = new
                old += 1
                new += 1
                return n
            }
        }
    }

    private static let headerRegex = try? NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
    )
}
