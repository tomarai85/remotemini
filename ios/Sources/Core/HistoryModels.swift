import Foundation

/// Decodable models for `GET /api/sessions/<id>/history`, shaped from the real
/// observed response (Sprint 3 brief §0), not the spec's prose.
struct HistoryResponse: Decodable, Equatable {
    let history: [HistoryEntry]
    /// ★Brief §0-a-1, "the single easiest thing to get wrong this sprint": empty
    /// history has TWO real wire shapes. `server.mjs`'s `/history` handler returns
    /// `{"history": []}` (the `truncated` key entirely absent) when the conversation
    /// file doesn't exist yet, and `{"history": [], "truncated": false}` (key
    /// present) once it does but is empty -- both observed in the same 39-session
    /// sweep (§0, 1 of each).
    ///
    /// A non-optional `Bool` fails decoding outright on the first shape -- the whole
    /// conversation would refuse to open. `Bool?` would decode both shapes, but then
    /// a THIRD state ("don't know") leaks into the view's branching, when "key
    /// absent" and "key present, false" mean the exact same thing to the phone: don't
    /// show "load earlier." Decoded as `decodeIfPresent(...) ?? false`, not left
    /// `Optional` -- see `HistoryModelsTests.testTruncatedKeyAbsentDecodesToFalse`,
    /// which feeds a body with the key missing, not just one where it's `false`
    /// (feeding only the latter would stay green even with the non-optional mistake).
    let truncated: Bool

    /// Not part of the wire shape -- only `Decodable`'s synthesized `init(from:)`
    /// needs `CodingKeys`; fixtures and tests use this memberwise form directly.
    init(history: [HistoryEntry], truncated: Bool) {
        self.history = history
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case history, truncated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        history = try container.decode([HistoryEntry].self, forKey: .history)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// 錨を中心にした窓(`?around=`、2026-09-04)。**末尾の窓とは別の型**。
///
/// `HistoryResponse` と分けた理由は `TranscriptSearchResponse` と同じ: 一致するのは `history` だけで、
/// 「まだ在るか」の言い方が違う。末尾の窓は `truncated`(手前にまだ在る、の 1 方向)だが、此の窓は
/// **両端**を持つので `olderAvailable` / `newerAvailable` の 2 つが要る。同じ型で受けると、窓の
/// `olderAvailable` が `loadEarlierState` へ流れ込む道が残る —— 2026-09-01 に探索の口で塞いだのと同じ形。
///
/// `anchor` は机が返す**正規化した**錨(要求した錨と同じ物)。机は「要求した錨が窓の中に必ず在る」事を
/// 約束し、旗が立っている側の端の錨は要求した錨より必ず外側にある(= 端の錨で読み直せば必ず進む)。
/// 其の約束が無いと、電話は同じ窓を延々と読み直す(Codex 所見 F5、2026-09-03)。
struct HistoryAroundResponse: Decodable, Equatable {
    let history: [HistoryEntry]
    let anchor: String
    /// 此の窓より**古い**側にまだ項目が在る。端(`history.first`)の錨で読み直せば進む。
    let olderAvailable: Bool
    /// 此の窓より**新しい**側にまだ項目が在る。端(`history.last`)の錨で読み直せば進む。
    let newerAvailable: Bool

    init(history: [HistoryEntry], anchor: String, olderAvailable: Bool, newerAvailable: Bool) {
        self.history = history
        self.anchor = anchor
        self.olderAvailable = olderAvailable
        self.newerAvailable = newerAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case history, anchor, olderAvailable, newerAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        history = try container.decode([HistoryEntry].self, forKey: .history)
        anchor = try container.decode(String.self, forKey: .anchor)
        // ★旗は `decodeIfPresent ?? false`。机が転写の無い会話へ返す空の窓は旗を持たない形が在り得るが、
        //   「鍵が無い」と「false」は電話には同じ意味(其の側に読み足す物は無い)。`Bool?` にすると
        //   「解らない」の第 3 の状態が画面の分岐へ漏れる —— `HistoryResponse.truncated` と同じ判断。
        olderAvailable = try container.decodeIfPresent(Bool.self, forKey: .olderAvailable) ?? false
        newerAvailable = try container.decodeIfPresent(Bool.self, forKey: .newerAvailable) ?? false
    }
}

/// 探索がどこまで見たか。**`Bool` のまま画面へ流さない**。
///
/// ★`searchedToStart` は線の綴りで、画面が答える問いは「見つかりませんと言い切って
///   いいか」。`true`/`false` を view まで運ぶと、読む側は毎回その写像を頭の中で
///   やり直す事になり、1 箇所で逆に読めば **0 件の 2 意味が静かに入れ替わる**。
///   名前が付いていれば、逆に書いた時に文が意味を成さなくなる。
enum TranscriptScanCoverage: Equatable {
    /// 会話の最初まで見た。ここでの 0 件だけが「この会話には無い」と言い切れる。
    case wholeConversation
    /// 走査は途中で止まった(件数の上限 か 後方読みの上限)。0 件は
    /// 「**走査した範囲に**無かった」までしか言えない。
    case boundedScan
}

/// `GET /api/sessions/<id>/history?q=<語>` の応答。**`HistoryResponse` とは別の型**。
///
/// ★何故 分けるか(2026-09-01)。同じルート・同じ status・同じ `history` 鍵だが、
///   `truncated` の**意味が違う**。素の履歴では「これより前が在る」、探索では
///   `truncated: !r.reachedStart` = 「最初まで見ていない」(`src/server.mjs` の探索分岐)。
///   ところが電話側の `HistoryResponse.truncated` は
///   `ConversationViewModel.resolveLoadEarlierState` の入力で、「以前を読む」ボタンの
///   状態を決める。探索応答を `HistoryResponse` で受けると
///   **探索の走査距離が転写の読み進みボタンを動かす**。型が 1 本なら、その配線は
///   書いた本人にも見えない。
///
/// ★だから `truncated` を**復号しない**。探索文脈では `!searchedToStart` の写しでしか
///   なく、2 本 置けば必ず片方が先に古くなる。読まない事は
///   `test/wire-key-agreement.test.mjs` の `serverOnly: ["truncated"]` で宣言してある
///   ので、「読み落とし」と「読まないと決めた」は其処で区別が付く。
struct TranscriptSearchResponse: Decodable, Equatable {
    let history: [HistoryEntry]
    /// 走査した範囲で見つかった**総数**。返る行(`history`)は `limit` で切られるので、
    /// `matched > history.count` は普通に起きる —— それが「全部は見せていない」の唯一の証拠。
    let matched: Int
    let coverage: TranscriptScanCoverage

    /// 線に出ない形。fixture と検査が直に組む為の入口。
    init(history: [HistoryEntry], matched: Int, coverage: TranscriptScanCoverage) {
        self.history = history
        self.matched = matched
        self.coverage = coverage
    }

    private enum CodingKeys: String, CodingKey {
        case history, matched, searchedToStart
    }

    /// ★`matched` と `searchedToStart` は**必須鍵**。`decodeIfPresent ?? …` にしない。
    ///
    /// 理由が上の `HistoryResponse.truncated` と**逆向き**である事が要点:
    /// あちらは「鍵の不在」と「false」が電話にとって同じ意味(どちらも『以前を読む』を
    /// 出さない)なので緩く受けてよい。此方は違う。`matched` の不在が意味するのは
    /// **「このサーバは探索していない」** —— `q` を落とした / 古い机に当たった /
    /// 経路が素の履歴側へ落ちた、のいずれか。緩く受けて `?? 0` にすると 0 件の面が出、
    /// `history` を素直に読めば **直近の履歴窓をそのまま「一致」として描く**。
    /// 探した覚えのない 50 行が「7 件 見つかりました」の顔で並ぶのが、この画面で
    /// 一番出してはいけない嘘なので、そこは復号ごと失敗させる(= `.malformedBody`)。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        history = try container.decode([HistoryEntry].self, forKey: .history)
        matched = try container.decode(Int.self, forKey: .matched)
        coverage = try container.decode(Bool.self, forKey: .searchedToStart)
            ? .wholeConversation
            : .boundedScan
    }
}

struct HistoryEntry: Decodable, Equatable {
    let role: EntryRole
    /// The message body, rendered as-is (brief §3-a: no Markdown interpretation, no
    /// truncation in v1). For a `.tool` entry this is a short one-line tool label
    /// (e.g. `"⚙ Bash"`, `sessions.mjs`'s `toolNames`), not prose -- brief §0-a-2.
    let text: String
    let display: EntryDisplay
    /// 錨(対照表 #3、2026-09-03)= 机の転写での其の項目の位置(`<行の byte 位置>:<行内番号>`)。
    /// 素の履歴と探索の当たりで**同じ項目は同じ錨**。ライブ(SSE)の項目には無い(nil)。
    /// 電話は中身を解釈しない —— 一致だけを見る(机の並びの鍵で、意味は机の物)。
    let anchor: String?
    /// 探索の当たりにだけ載る「末尾から何番目か」(最新 = 0)。此の数 + 1 まで limit を伸ばして
    /// 履歴を読めば其の項目が入る(机の `searchHistoryFromPath`)。素の履歴では nil。
    let fromEnd: Int?
    /// 道具の結果の**切り詰めた**写し(対照表 #41、2026-09-04)。`.tool` の項目にだけ、机が転写の
    /// `tool_result` を対にできた時だけ載る(机の `TOOL_OUTPUT_PREVIEW_MAX` = 600 byte / 6 行、ANSI と CR は
    /// 机で落とす)。電話は畳んで持ち、押した時だけ開く。ライブ(SSE)の行には無い(結果は後の record で届く)。
    let output: String?
    /// 机が上限で切った(= 全文ではない)。`output` が無い時は無い。
    let outputTruncated: Bool?
    /// 道具が失敗した結果(`is_error`)。`output` が無い時は無い。
    let outputError: Bool?

    init(role: EntryRole, text: String, display: EntryDisplay, anchor: String? = nil, fromEnd: Int? = nil,
         output: String? = nil, outputTruncated: Bool? = nil, outputError: Bool? = nil) {
        self.role = role
        self.text = text
        self.display = display
        self.anchor = anchor
        self.fromEnd = fromEnd
        self.output = output
        self.outputTruncated = outputTruncated
        self.outputError = outputError
    }

    /// Brief §0-a-3: `who` is S-group -- computed server-side by `whoOf(role)` and
    /// shipped verbatim. Swift renders `display.who`, never reconstructs a display
    /// name from `role` itself: two implementations of "what does this role show as"
    /// is exactly the kind of duplicate that goes silently stale when only one side
    /// gets fixed.
    struct EntryDisplay: Decodable, Equatable {
        let who: String

        init(who: String) {
            self.who = who
        }
    }
}

/// Brief §0-a-2: 3 known values on the wire (`user`/`assistant`/`tool`). An
/// unrecognized value must fall back to `.unknown` and MUST NOT fail decoding --
/// the same judgment `SessionsModels.swift`'s `RouteLabel.Kind` already makes for an
/// unrecognized route `kind`: an old phone talking to a server that has grown a 4th
/// role must render *something*, not go blank.
enum EntryRole: String, Equatable {
    case user, assistant, tool, unknown
}

extension EntryRole: Decodable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EntryRole(rawValue: raw) ?? .unknown
    }
}
