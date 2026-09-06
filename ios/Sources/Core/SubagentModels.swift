import Foundation

/// Decodable models for `GET /api/sessions/<id>/subagents`(対照表 #8「半分その一」、2026-09-05)。
/// 鍵名は `rc-backend/src/wire.mjs` の `subagentsBody` を**その字**で写す
/// (`test/wire-key-agreement.test.mjs` の PAIRS が両側を突き合わせる)。
///
/// ★空配列に意味が3つ在るので、`subagents` だけを見て「何も走っていない」と言わない:
///   `directory == "absent"`   = 本当に1本も居ない
///   `directory == "unreadable"` = 読めなかった(居るかもしれない)
///   `parent == "unreadable"`  = 居るが、終わったかを知らない(各行が `unknown`)
/// 判定は机が `display.note` に文として畳んであるので、**電話は其の文を描く**。
/// 綴りで分岐すると、机と電話の 2 箇所に同じ判断が散る(`ResultDisplay` と同じ判断)。
struct SubagentsBody: Decodable, Equatable {
    let subagents: [SubagentRow]
    /// `read` / `absent` / `unreadable`。**値で分岐しない** —— 画面に出すのは `display.note`。
    let directory: String
    /// `read` / `unreadable` / `unscanned`。同上。
    let parent: String
    /// 上限(机側の `SUBAGENT_MAX`)に当たって切ったか。切った事は必ず名乗る。
    let truncated: Bool
    /// 状態ごとの件数。**読めた時しか来ない**(`null` が正常値)。
    /// 数を書けば読み手は其の数を信じるので、机は信じてよい時だけ書く。
    let counts: SubagentCounts?
    let display: SubagentsDisplay

    init(subagents: [SubagentRow], directory: String, parent: String,
         truncated: Bool, counts: SubagentCounts?, display: SubagentsDisplay) {
        self.subagents = subagents
        self.directory = directory
        self.parent = parent
        self.truncated = truncated
        self.counts = counts
        self.display = display
    }
}

struct SubagentsDisplay: Decodable, Equatable {
    /// 机が決めた1文。空配列の意味も、切った事も、此処に畳んである。
    let note: String
}

struct SubagentCounts: Decodable, Equatable {
    let finished: Int
    let running: Int
    let stalled: Int
    let unknown: Int
}

struct SubagentRow: Decodable, Equatable, Identifiable {
    /// `agent-<agentId>.jsonl` の `<agentId>`。一覧の中で一意。
    let agentId: String
    /// `Explore` / `general-purpose` など。meta が壊れていれば `nil`。
    let agentType: String?
    /// 呼んだ側が書いた1行の要約。**人が最初に読みたいのは之**。
    let description: String?
    let model: String?
    /// `finished` / `running` / `stalled` / `unknown`。
    /// ★`unknown` を `running` や `finished` に丸めない —— 「分からない」を「作業中」と
    ///   書くと、読み手には観測値と区別が付かない。表示語は `display.state` が持つ。
    let state: String
    /// 其の状態をどう決めたか(`parent-completed` / `no-result-active` / `scan-budget` …)。
    /// 電話は描かない。机の判断の跡を線に残す為の欄。
    let reason: String?
    /// meta が `read` / `absent` / `malformed` のどれだったか。
    let meta: String?
    /// 子の転写が最後に伸びた時刻。`nil` = 読めなかった。
    let lastActivityIso: String?
    let display: SubagentRowDisplay

    var id: String { agentId }
}

struct SubagentRowDisplay: Decodable, Equatable {
    /// `Working` / `Finished` / `No sign of life recently` / `Could not tell`。
    let state: String
}
