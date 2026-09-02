import Foundation

/// 電話から**新しい会話を始める**(2026-08-31、調査の4位)。
///
/// ── 何故 之が無かったか ────────────────────────────────────────────────────
/// 机の worker は `--resume` 固定で、**既に在る会話にしか入れなかった**。
/// 競合(omnara / vibe-kanban / claude-squad …)は全社 持っていて、
/// 此の製品だけが構造的に持たない唯一の能力だった。
///
/// ── 何処で始めるか ────────────────────────────────────────────────────────
/// **既に在る会話と同じ場所**。「この会話と同じ場所で、もう1本」が電話から一番自然な始め方。
///
/// ★2026-09-02: 元の理由(「`@` のパス補完がまだ無い以上、電話で path を打たせるのは
///   盲打ち」)は**消えた** —— 補完は `PathCompletionClient` として入った。だが補完が
///   効くのは会話の cwd の下で、任意のディレクトリを 0 から選ぶ道(対照表 #11)は
///   机側に一覧の口が無い。よって現状は「まだ作っていない」であって「作らないと決めた」
///   ではない(`ios/Sources/Screens/List/ListView.swift` の同じ註と対)。
enum NewSessionOutcome: Equatable {
    /// 机が受け付けた。★**会話の id はまだ無い** —— Claude Code が jsonl を書き、
    /// 登録簿が拾って初めて一覧に出る。電話は一覧を引き直して新しい行を見つける。
    case started
    /// 此の会話には作業場所が無い(登録簿が cwd を持たない / dir が消えた)。
    case noWorkingDirectory
    /// 机が tmux の window を作れなかった。
    case deskRefused
    case unauthorized
    case unreachable

    /// 机が返す `reason` のうち、**電話が分岐に使う物だけ**を此処に書く。
    ///
    /// ★`code` ではなく `reason` なのは、`code` が 401/404 の**復旧語彙専用**だから ——
    ///   電話は其の鍵で画面を移すので、別の意味を同じ名前で流すと遷移の判断が壊れる
    ///   (2026-08-31、門が捕まえた)。
    ///
    /// ★語を電話のコードへ書くのは、線の語彙の突き合わせ(`wire-vocabulary-agreement`)が
    ///   「サーバが吐く語を電話が知らない」を赤にする為 —— 知らない語で分岐すると、
    ///   サーバ側の綴りが変わった日に**電話は黙って別の枝へ落ちる**。
    ///   書いておけば、綴りが割れた瞬間に検査が止める。
    enum WireCode {
        /// 其の会話に作業場所が無い(登録簿が cwd を持たない / dir が消えた)。
        /// 机は `cwd_unknown` と `cwd_gone` の 2 状況で同じ `code` を返す ——
        /// 電話から見ると次の一手は同じ(其の会話からは始められない)なので畳んでよい。
        static let noCwd = "no_cwd"
        /// 机が tmux の window を作れなかった。
        static let tmuxFailed = "tmux_failed"
    }

    static func from(status: Int, code: String?) -> NewSessionOutcome {
        switch status {
        case 202: return .started
        case 401: return .unauthorized
        // ★409 は `NO_CWD` しか返さないので `code` で分けない。分けた振りをする
        //   三項(両側が同じ値)を書くと、読む人は「他の 409 が在る」と誤読する。
        case 409: return .noWorkingDirectory
        default:  return code == WireCode.tmuxFailed ? .deskRefused : .unreachable
        }
    }

    /// 画面に出す一文。★「始めました」で終わらせない —— **一覧に出るまで間が在る**
    ///   (机が Claude Code を起こし、登録簿が拾うまで)。其の間を黙ると、
    ///   押した人は「効かなかった」と読んで二度押しする。
    var text: String {
        switch self {
        case .started:            return "Starting — it will appear in the list shortly."
        case .noWorkingDirectory: return "That session has no working directory on the desk."
        case .deskRefused:        return "The desk couldn't open a new window."
        case .unauthorized:       return "The desk rejected the key."
        case .unreachable:        return "Couldn't reach the desk."
        }
    }
}

protocol NewSessionStarting {
    func startNear(baseURL: URL, apiKey: String, sessionID: String) async -> NewSessionOutcome
}

/// `POST /api/sessions/<id>/new` — 其の会話と同じ場所で、新しい会話を始める。
struct NewSessionClient: NewSessionStarting {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func startNear(baseURL: URL, apiKey: String, sessionID: String) async -> NewSessionOutcome {
        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/new")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BackendSession.writeTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unreachable
        }
        guard let http = response as? HTTPURLResponse else { return .unreachable }
        struct Wire: Decodable { let reason: String? }
        let wire = try? JSONDecoder().decode(Wire.self, from: data)
        return NewSessionOutcome.from(status: http.statusCode, code: wire?.reason)
    }
}

struct NewSessionFixture: NewSessionStarting {
    var outcome: NewSessionOutcome = .started
    func startNear(baseURL: URL, apiKey: String, sessionID: String) async -> NewSessionOutcome {
        outcome
    }
}
