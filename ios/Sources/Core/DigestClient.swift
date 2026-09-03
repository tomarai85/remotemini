import Foundation

/// 留守中に机で何が起きたかを 1 画面で読む為の型と取り口。2026-08-26 新設。
///
/// なぜ要るか(実測): 常駐が `attention=input / action=soon` のまま **60 分**座っていた。
/// Tom は待たれている事を知らない。`digest-notify.sh` が Discord へ 1 回鳴らす様にしたが、
/// **鳴った後に電話を開いた時、そこに「何が起きたか」が無い**と、結局 履歴を遡る事になる。
/// ここはその 1 画面ぶんを持つ。
///
/// ★**文面を電話側で組み立てない。** サーバが `line` を作って返す。
///   理由コードから日本語を作る所を両側に持つと、語彙が 2 箇所に分かれて必ず片方だけ腐る
///   —— `AccountClient` の `blocked` が同じ判断で、2026-08-08 の監査 S8-22 が実際に
///   踏んだ形(電話が英語の理由トークンをそのまま帯に描いていた)。
///   だから此処が持つのは**表示の材料**であって、文章ではない。
///
/// ★**`counts` が `nil` の時に 0 と描かない。** サーバは窓の全部を読めなかった時
///   (走査の予算を使い切った等)に `complete=false` と `counts=null` を返す。
///   0 と描くと「静かだった」に見えるが、実際は「数えられなかった」。
///   `rc-backend/src/digest.mjs` が `counts: null` を返す事に意味を持たせているので、
///   受け側もその区別を捨てない。
struct SessionDigest: Equatable {
    /// 窓の全部を読めたか。`false` なら `counts` は信用しない。
    let complete: Bool
    /// 読めなかった理由(サーバの語)。読めた時は `nil`。
    let incompleteReason: String?
    /// 何分の窓を見たか。
    let windowMinutes: Int
    /// Tom の発言 / 机の返答 / 道具の呼び出しの件数。**読めなかった時は `nil`**。
    let counts: Counts?
    /// 触られた file の代表(全部ではない。総数は `fileTargetsTotal`)。
    let fileTargets: [String]
    let fileTargetsTotal: Int
    /// 机が最後に言った事。無ければ `nil`。
    let lastAssistant: String?
    /// 今どういう状態か。`unknown` は**画面で急かさない**(役に立たない急かしは信号を殺す)。
    let attention: Attention
    /// 今すぐ動く必要が在るか。
    let action: ActionLevel
    /// ★サーバが作った 1 行。電話はこれを描くだけ。
    let line: String
    /// 会話が**今 何で走っているか**(2026-09-02)。転写の最新レコードから机が拾う。
    /// ★古い机は此の項目を送らないので optional。無い事は異常ではない。
    var session: Session? = nil

    struct Session: Equatable {
        let model: String?
        let gitBranch: String?
        let version: String?
        /// 直近の応答が抱えていた文脈の大きさ(token)。机が `message.usage` の入力 3 種を
        /// 足した物(2026-09-03、対照表 #14-16 の残り)。★古い机は送らないので optional。
        var contextTokens: Int? = nil
        /// 画面に出す 1 行。**在る物だけ**を「·」で繋ぐ。全部無ければ nil(帯を出さない)。
        var line: String? {
            let parts = [model, gitBranch, contextTokens.map { "\(Self.compact($0)) ctx" }]
                .compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        /// 帯に載る短い数。1,000 未満は其のまま、10 万未満は小数 1 桁の k、其れ以上は整数の k。
        /// ★丸めは四捨五入(切り捨てだと 99,950 が「99.9k」で、100k の帯に見えない)。
        static func compact(_ n: Int) -> String {
            if n < 1_000 { return "\(n)" }
            let tenths = (n + 50) / 100                      // 38,717 -> 387 -> "38.7k"
            if tenths < 1_000 { return "\(tenths / 10).\(tenths % 10)k" }
            return "\((n + 500) / 1_000)k"                   // 99,950 -> "100k"(「100.0k」を出さない)
        }
    }

    struct Counts: Equatable {
        let user: Int
        let assistant: Int
        let tool: Int
    }

    /// サーバの語彙をそのまま持つ。**知らない値を握り潰さない** ——
    /// 新しい状態が増えた時に「既知のどれか」へ丸めると、画面は嘘を描き続ける。
    enum Attention: String, Equatable {
        case choice, input, none, unknown
        /// 表に無い値が来た時。**`unknown` と同じにしない**(あちらはサーバが
        /// 「判らない」と言った状態で、これは「此方が知らない」状態)。
        case unrecognized
    }

    enum ActionLevel: String, Equatable {
        case now, soon, none, unknown
        case unrecognized
    }

    /// 画面が急かしてよいか。★`unknown` と `unrecognized` では急かさない。
    var shouldUrge: Bool {
        switch (attention, action) {
        case (.choice, .now), (.input, .now): return true
        case (.choice, .soon), (.input, .soon): return true
        default: return false
        }
    }
}

// MARK: - 線の上の形(サーバの JSON をそのまま受ける)

/// ★`Decodable` の名前は**サーバの key と 1 文字も違えない**。この repo は
///   「サーバの組み立てと電話の受けで語彙がずれる」を検査で縛っている
///   (`wire-vocabulary-agreement-controls.sh`)。
private struct DigestEnvelope: Decodable {
    struct Digest: Decodable {
        struct Window: Decodable {
            let minutes: Int?
        }
        struct Counts: Decodable {
            let user: Int
            let assistant: Int
            let tool: Int
        }
        let complete: Bool?
        let incompleteReason: String?
        let window: Window?
        let counts: Counts?          // ★ null が来る。`0` に潰さない
        let fileTargets: [String]?
        let fileTargetsTotal: Int?
        let lastAssistant: String?
        // ★`session` は **`digest` の中**(サーバ `digestOf` の戻りに在る)。
        //   最初 外側に置いて `wire-key-agreement` に捕まった —— 復号は通るので
        //   画面が黙って痩せるだけで、検査が無ければ気付けなかった。
        let session: Session?
        struct Session: Decodable {
            let model: String?
            let gitBranch: String?
            let version: String?
            let contextTokens: Int?
        }
    }
    struct Action: Decodable {
        let level: String?
        let reason: String?
    }
    let digest: Digest?
    let attention: String?
    let action: Action?
    let line: String?
}

enum DigestDecodeError: Error, Equatable {
    /// 形が違う(JSON ではない / 期待した入れ物が無い)。
    case shape
}

enum DigestParser {
    /// サーバの応答 1 件を読む。**足りない物を作らない** —— 欠けていたら
    /// `complete=false` 側へ倒し、`counts` は `nil` のまま返す。
    static func parse(_ data: Data) throws -> SessionDigest {
        guard let env = try? JSONDecoder().decode(DigestEnvelope.self, from: data),
              let d = env.digest else { throw DigestDecodeError.shape }

        let counts: SessionDigest.Counts? = d.counts.map {
            .init(user: $0.user, assistant: $0.assistant, tool: $0.tool)
        }
        // ★`complete` が来ていない = 古いサーバか壊れた応答。**完全だと決めつけない**。
        let complete = (d.complete ?? false) && counts != nil

        return SessionDigest(
            complete: complete,
            incompleteReason: d.incompleteReason,
            windowMinutes: d.window?.minutes ?? 0,
            counts: counts,
            fileTargets: d.fileTargets ?? [],
            fileTargetsTotal: d.fileTargetsTotal ?? (d.fileTargets?.count ?? 0),
            lastAssistant: d.lastAssistant,
            attention: SessionDigest.Attention(rawValue: env.attention ?? "") ?? .unrecognized,
            action: SessionDigest.ActionLevel(rawValue: env.action?.level ?? "") ?? .unrecognized,
            line: env.line ?? "",
            session: d.session.map {
                .init(model: $0.model, gitBranch: $0.gitBranch, version: $0.version, contextTokens: $0.contextTokens)
            }
        )
    }
}
