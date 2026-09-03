import Foundation

/// 机の **roots**(2026-09-03、対照表 #11「任意のディレクトリで新規セッション」、Tom 裁定 = roots の下だけ)。
///
/// 机は台帳(`~/.rc-backend/roots`)に書かれた場所の**下だけ**で新しい会話を始める。電話に来るのは
/// 其の一覧の **index と札**(`~/Infra`)だけで、絶対 path は線に出ない(`PathSuggestion` が
/// 相対 path しか持たないのと同じ判断)。index は台帳の行順で、電話は其れで
/// `/api/roots/<i>/paths`(dir だけ歩く)と `/api/roots/<i>/new`(root からの相対 path で始める)を指す。
struct DeskRoot: Decodable, Equatable, Identifiable {
    let index: Int
    let label: String
    var id: Int { index }
}

/// `GET /api/roots` の応答。`roots` は必須鍵、`reason` だけ省略可(`PathCompletionResponse` と同じ判断:
/// 鍵が消えたら復号ごと落として、空の一覧を「台帳が空」と描く側に倒さない)。
/// 台帳が無い / 空の時は `roots: []` + `reason: "no_roots"`(200。答えられている = 受ける場所が 0 件)。
struct RootsResponse: Decodable, Equatable {
    let roots: [DeskRoot]
    let reason: String?

    init(roots: [DeskRoot], reason: String?) {
        self.roots = roots
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case roots, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = try c.decode([DeskRoot].self, forKey: .roots)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }

    /// 机が「受ける場所は無い」と答えた(台帳が無い / 空)。
    var hasNoRoots: Bool { roots.isEmpty && reason == RootsWire.noRoots }
}

/// 机が返す `reason` のうち、**電話が分岐に使う語だけ**(`NewSessionOutcome.WireCode` と同じ規約:
/// 線の語彙の突き合わせが「サーバが吐く語を電話が知らない」を赤にするので、綴りは此処に居る)。
/// `code` ではなく `reason` なのは、`code` が 401/404 の復旧語彙専用だから。
enum RootsWire {
    static let outsideRoots = "outside_roots"
    static let noRoots = "no_roots"
    static let cwdGone = "cwd_gone"
    static let tmuxFailed = "tmux_failed"
}

/// `POST /api/roots/<i>/new` の結果。
enum StartInRootOutcome: Equatable {
    /// 机が受け付けた。**会話の id はまだ無い** —— 一覧を引き直して新しい行を見つける。
    case started
    /// 選んだ dir が台帳の root の外(symlink や `..` で抜けた実体を含む)。
    case outsideRoots
    /// 台帳が無い / 空 = 机は何処も受けない。
    case noRoots
    /// 選んだ dir が机に無い(一覧を出した後に消えた)。
    case cwdGone
    /// 其の index の root が無い(台帳が書き換わった)。一覧を引き直す。
    case rootGone
    /// 机が tmux の window を作れなかった。
    case deskRefused
    case unauthorized
    case unreachable

    static func from(status: Int, reason: String?) -> StartInRootOutcome {
        switch status {
        case 202: return .started
        case 401: return .unauthorized
        case 404: return .rootGone
        case 409: return .cwdGone
        case 400:
            switch reason {
            case RootsWire.outsideRoots: return .outsideRoots
            case RootsWire.noRoots: return .noRoots
            // ★知らない 400 を「始まった」にも「外」にも丸めない。
            default: return .unreachable
            }
        default: return reason == RootsWire.tmuxFailed ? .deskRefused : .unreachable
        }
    }

    /// 画面に出す一文(`NewSessionOutcome.text` の流儀。`.started` は同じ文を再利用する)。
    var text: String {
        switch self {
        case .started:       return NewSessionOutcome.started.text
        case .outsideRoots:  return "That folder is outside the desk's allowed roots."
        case .noRoots:       return "No directories are allowed on the desk yet."
        case .cwdGone:       return "That folder is no longer on the desk."
        case .rootGone:      return "That root is no longer on the desk. Pull to refresh the list."
        case .deskRefused:   return NewSessionOutcome.deskRefused.text
        case .unauthorized:  return NewSessionOutcome.unauthorized.text
        case .unreachable:   return NewSessionOutcome.unreachable.text
        }
    }
}
