import Foundation

/// One pending line-comment on a diff line(対照表 #6、2026-09-02:「leave inline
/// comments on specific lines, and send them to Claude with your next message」)。
///
/// ★composed on the phone only -- never sent by itself. It rides along with the
///   NEXT message the user actually sends from the composer (`DiffCommentFormatter`
///   does the riding, `ConversationViewModel.send()` is the only caller). Same
///   「押しても送らない」規約として写真添付(`AttachClient`)・slash チップ・`@` 補完
///   と並ぶ4件目 -- 此処で組む操作(`DiffView` の alert の Save)は 1 回も
///   ネットワークへ触れない。
///
/// ★held **in memory only**, owned by `ConversationViewModel`(此の型自身は
///   `Codable` を持たない)。此の会話を離れれば消える -- 今日の未コミットの差分への
///   行コメントは、次のコミットは元より次回起動でも意味を失うので、残す理由が無い
///   (design doc の「no desk state」)。
struct DiffComment: Identifiable, Equatable {
    let id: UUID
    let path: String
    /// index の側か。`DiffFile.id` と同じ理由 -- 同じ `path` が stage 済み / 未 stage の
    /// 両方に出る事が在るので、行の宛先は此れも含めて初めて一意になる。
    let staged: Bool
    /// `DiffLineLocator` が hunk の生の header から計算した行番号。机は行番号を
    /// 送っていない(`wire.mjs` の `diffBody` に無い欄)。`add`/`ctx` は新側、`del` は
    /// 旧側の番号(GitHub/GitLab の行コメントと同じ慣習)。
    let line: Int
    /// `line` だけでは一意にならない -- 同じ数字が旧側(`del`)と新側(`ctx`/`add`)の
    /// 両方に立ち得る(1つの hunk 内で旧行11・新行11が同時に実在する形は珍しくない)。
    /// 識別には `kind` まで要る。
    let kind: DiffLineKind
    /// 其の行の中身そのもの(記号は既に机が落としている)。組む時にそのまま引用する --
    /// 読む側(Claude)が此の1件の為だけに diff を開き直さずに済む。
    let quotedText: String
    var text: String

    init(
        id: UUID = UUID(),
        path: String,
        staged: Bool,
        line: Int,
        kind: DiffLineKind,
        quotedText: String,
        text: String
    ) {
        self.id = id
        self.path = path
        self.staged = staged
        self.line = line
        self.kind = kind
        self.quotedText = quotedText
        self.text = text
    }
}
