import Foundation

/// `@` を打った時に机が返す候補(2026-09-02)。
///
/// ★**2鍵しか無い**のが要点。机の `src/wire.mjs` の `pathItem` が同じ判断を書いている ——
///   電話が要るのは「入力欄へ差す文字列」と「其れが dir なら続けて降りられるか」だけで、
///   大きさ・時刻・権限・絶対 path は会話の作業場所の中身を認証の外へ運ぶ材料にしかならない。
struct PathSuggestion: Decodable, Equatable {
    /// 会話の作業場所(cwd)からの**相対** path。絶対 path は線に出ない。
    let path: String
    let kind: PathKind
}

/// 候補の種別。
///
/// ★`unrecognized` を持つのは `EntryRole` と同じ理由 —— 机が語を1つ増やした日に、
///   復号ごと落ちて候補列が丸ごと消えるより、知らない語を「降りられない物」として
///   出す方が良い。★但し **`file` に化かさない**: `file` に丸めると、電話は
///   「差したら終わり」の扱いをするので、実は dir だった物で人が止まる。
enum PathKind: String, Equatable {
    case file, dir, unrecognized
}

extension PathKind: Decodable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PathKind(rawValue: raw) ?? .unrecognized
    }
}

/// `GET /api/sessions/<id>/paths` の応答。
///
/// ★`truncated` = 机が**上限に当たって途中で止めた**。除外した dir(`node_modules` 等)や、
///   問いが空の時に直下だけを返す事は打ち切りではない —— あれは範囲の定義で、
///   机の `src/paths.mjs` が其の区別を持っている。此処で意味を足さない。
///   画面は真の時に候補列の末尾へ「…」を出す(隠さない)。
///
/// ★`reason` は**成功時も `null` で載る**欄。机が答えられなかった理由の語で、
///   電話は其れを分岐に使う(`PathCompletionReason`)。鍵の有無で分けない形にしたのは、
///   区別に意味が無い所に区別を作らない為(机側の `pathsBody` の註)。
struct PathCompletionResponse: Decodable, Equatable {
    let paths: [PathSuggestion]
    let truncated: Bool
    let reason: String?

    /// 線に出ない形。fixture と検査が直に組む為の入口(`TranscriptSearchResponse` と同じ)。
    init(paths: [PathSuggestion], truncated: Bool, reason: String?) {
        self.paths = paths
        self.truncated = truncated
        self.reason = reason
    }

    /// ★`paths` と `truncated` は**必須鍵**、`reason` だけが省略可。
    ///
    ///   `truncated` を `?? false` で緩く受けないのは、緩く受けた時の嘘が
    ///   **「全部見せた」**になるから —— 「もっと在る」を「之で全部」と描くのが、
    ///   この画面で一番出してはいけない形。鍵が消えたら復号ごと落として、
    ///   候補列を出さない側に倒す(`TranscriptSearchResponse.matched` と同じ判断)。
    ///
    ///   `reason` を省略可にしたのは、**机が答えられた時に載る値が `null`** だから。
    ///   鍵の不在と `null` を電話が区別する道は無いし、区別する必要も無い。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paths = try container.decode([PathSuggestion].self, forKey: .paths)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    private enum CodingKeys: String, CodingKey {
        case paths, truncated, reason
    }
}

/// 机が名乗る断りの語のうち、**電話が分岐に使う物だけ**を此処に書く。
///
/// ★語を電話のコードへ literal で書くのは、線の語彙の突き合わせが
///   「サーバが吐く語を電話が知らない」を赤に出来る様にする為 ——
///   知らない語で分岐すると、机側の綴りが変わった日に電話は黙って別の枝へ落ちる
///   (`NewSessionOutcome.WireCode` と同じ判断)。
enum PathCompletionReason {
    /// 其の会話に作業場所が無い(転写が cwd を名乗っていない)。
    /// 机の `src/paths.mjs` の `PATHS_NO_CWD` と、new の道の `no_cwd` と**同じ綴り**。
    static let noCwd = "no_cwd"
    /// 作業場所は判るが、机がそこを開けない(消えた / 権限が無い)。
    static let unreadable = "cwd_unreadable"
}
