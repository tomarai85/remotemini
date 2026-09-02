import Foundation

/// Decodable models for `GET /api/sessions/<id>/diff` (対照表 #4、2026-09-02)。
/// 鍵名は `rc-backend/src/wire.mjs` の `diffBody` を**その字**で写す
/// (`test/wire-key-agreement.test.mjs` の PAIRS が両側を突き合わせる)。
struct SessionDiffBody: Decodable, Equatable {
    let files: [DiffFile]
    /// 切ったか(1 ファイル / 全体 / ファイル数のどれかの天井に当たったか)。
    /// `sessiondiff.mjs` の `capFiles` の doc の通り、**数(`added`/`removed`)は
    /// 切っても嘘を吐かない** -- この電話は其れを信じて「+42 -18(表示は途中まで)」と
    /// 言ってよい。
    let truncated: Bool
    /// 生の diff の bytes(切る前の量)。0 は「差分が無い」であって「読めなかった」
    /// ではない -- 其れは `reason` が別に言う。
    let totalBytes: Int
    /// 読めない理由。`no_cwd` / `cwd_missing` / `not_a_repo` / `git_failed` の
    /// いずれか、無ければ `nil`。**値では分岐しない** -- `DiffView` は之を
    /// 「異常ではなく状態」の一文へ言い換えるだけで、綴りごとに文言を持たない
    /// (`ResultDisplay` が `kind` の綴りを増やしても文を壊れないままにするのと
    /// 同じ判断)。鍵の不在と `null` はどちらも「理由なし」として同じに読む
    /// (`decodeIfPresent` の既定挙動 -- `HistoryResponse.truncated` と同じ緩さ)。
    let reason: String?

    init(files: [DiffFile], truncated: Bool, totalBytes: Int, reason: String?) {
        self.files = files
        self.truncated = truncated
        self.totalBytes = totalBytes
        self.reason = reason
    }
}

struct DiffFile: Decodable, Equatable, Identifiable {
    let path: String
    /// index の側か(`git diff --cached` で撃った物か)。**同じ `path` が2行に
    /// 分かれて出る事が在る**(stage 済みの変更に、さらに手が入っている作業木)。
    let staged: Bool
    let binary: Bool
    /// 切る前の全文から数えた値(`capFiles` の doc)。`hunks` が切られていても
    /// 此処は嘘を吐かない。
    let added: Int
    let removed: Int
    /// 此のファイルの本文**だけ**が切られたか(`SessionDiffBody.truncated` とは別の事実 --
    /// 全体は切れていなくても、1 ファイルの天井にだけ当たる事が在る)。
    let truncated: Bool
    let hunks: [DiffHunk]

    /// `path` だけでは一意でない(上の `staged` の註)。一覧描画の identity は
    /// 両方を畳んだ物にする。
    var id: String { "\(staged ? "staged" : "unstaged")::\(path)" }

    init(path: String, staged: Bool, binary: Bool, added: Int, removed: Int, truncated: Bool, hunks: [DiffHunk]) {
        self.path = path
        self.staged = staged
        self.binary = binary
        self.added = added
        self.removed = removed
        self.truncated = truncated
        self.hunks = hunks
    }
}

struct DiffHunk: Decodable, Equatable {
    /// `@@ -a,b +c,d @@` の頭書き。電話は解釈せず、そのまま表示する行として使う。
    let header: String
    let lines: [DiffLine]

    init(header: String, lines: [DiffLine]) {
        self.header = header
        self.lines = lines
    }
}

struct DiffLine: Decodable, Equatable, Identifiable {
    let kind: DiffLineKind
    let text: String

    /// `ForEach` 用。行の中身は重複し得る(同じ空行が複数在る等)ので、
    /// 表示上の並び順そのものを identity に混ぜる呼び出し側(`DiffView`)が id を作る --
    /// 此処では持たない(モデルは並び位置を知らない)。
    var id: String { "\(kind.rawValue):\(text)" }

    init(kind: DiffLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// `add` / `del` / `ctx` の 3 値。`EntryRole`(`HistoryModels.swift`)と同じ判断で
/// **文字列のまま緩く受ける** -- 未知の値で decode を落とすと、机が新しい種類の行
/// (例えば `no-newline` を独立させる)を足しただけで転写の diff 全体が読めなくなる。
enum DiffLineKind: String, Equatable {
    case add, del, ctx, unknown
}

extension DiffLineKind: Decodable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DiffLineKind(rawValue: raw) ?? .unknown
    }
}
