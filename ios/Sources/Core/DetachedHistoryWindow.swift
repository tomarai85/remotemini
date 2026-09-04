import Foundation

/// 錨で開いた**離脱窓**の状態機械(対照表 #3 の後追い、2026-09-04)。
///
/// なぜ `ConversationViewModel` の中に書かないか: 会話の画面が持つ状態は「末尾の窓 + ライブの追記」で、
/// 離脱窓は其れと**両立しない**別の不変条件を持つ(下記)。同じ型の中に 2 つの不変条件を置くと、
/// 片方の前提で書いた行がもう片方の状態で走る。2000 行の型に足す判断は其の事故を確実にするので、
/// 状態と遷移だけを此処へ切り出し、画面側は「今どちらのモードか」だけを見る。
///
/// ★不変条件(検査が守る):
///   1. 開いている間、ライブ(SSE)の項目は**窓に混ぜない**。窓は転写の途中を指していて末尾と隣接して
///      いないので、混ぜると存在しない並びを作る。届いた数だけ数える。
///   2. 端の錨で読み直すと**必ず進む**。机が其れを約束する(`readHistoryAround`、Codex 所見 F5)が、
///      約束が破れた時に電話が無限に同じ窓を読む形にはしない —— 進まなければ端と判定して止まる。
///   3. 要求した錨は必ず窓の中に在る。無ければ机の契約違反なので、窓を開いたと言わない。
@MainActor
final class DetachedHistoryWindow {
    /// 遷移の結果。画面は此の値だけを見て文言を決める(`Bool` を持ち回らない)。
    enum Outcome: Equatable {
        /// 窓が開いた / 動いた。
        case moved
        /// 其の向きの端に着いた(旗が下りた、または机が進まなかった)。窓は据え置き。
        case atEdge
        /// 錨が消えた(机が 409、または転写が書き換わった)。呼び手は live へ戻す。
        case anchorGone
        /// 走行中の再入。窓は触っていない。
        case busy
        /// 届かなかった。文言は呼び手が持つ(`ConversationViewModel` の既存の写像と揃える)。
        case failed
    }

    /// 1 回に読む項目数。末尾の窓の既定(50)より小さいのは、離脱窓は**読む為**の窓で
    /// 「追記を待つ」窓ではないから。小さいほど端へ着くまでの往復は増えるが、1 回の待ちは短い。
    static let span = 40

    private let client: HistoryFetching
    private let baseURL: URL
    private let apiKey: String
    private let sessionID: String

    /// 窓の中身。空 = まだ開いていない。
    private(set) var entries: [HistoryEntry] = []
    /// 此の窓を開く切っ掛けになった錨(検索の当たり)。強調と「戻る」の的。
    private(set) var openedAt: String?
    private(set) var olderAvailable = false
    private(set) var newerAvailable = false
    /// 離脱している間に**ライブで届いた**項目の数。窓には入れない(不変条件 1)。
    private(set) var liveArrived = 0
    /// 走行中の排他。`ConversationViewModel.isJumping` と同じ理由 —— 遅れて返った古い応答が
    /// 新しい窓を上書きするのを、世代ではなく「受け付けない」で塞ぐ。
    private(set) var isWalking = false

    /// 開いているか。画面のモード分岐は此れだけを見る。
    var isOpen: Bool { openedAt != nil }

    init(client: HistoryFetching, baseURL: URL, apiKey: String, sessionID: String) {
        self.client = client
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sessionID = sessionID
    }

    /// 錨を中心に窓を開く。既に開いていても、別の錨なら開き直す(検索の当たりを続けて押した時)。
    func open(at anchor: String) async -> Outcome {
        guard !isWalking else { return .busy }
        isWalking = true
        defer { isWalking = false }
        switch await client.around(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID,
                                   anchor: anchor, limit: Self.span) {
        case .success(let r):
            // 不変条件 3。机は「要求した錨は窓の中に在る」と約束している。破れていたら
            // 開いたと言わない —— 開いたと言って中身に無いと、画面は強調する行を探して見つけられない。
            guard r.history.contains(where: { $0.anchor == anchor }) else { return .anchorGone }
            entries = r.history
            openedAt = anchor
            olderAvailable = r.olderAvailable
            newerAvailable = r.newerAvailable
            liveArrived = 0
            return .moved
        case .failure(.notFound):
            return .anchorGone
        case .failure(.unreachable):
            // 机は消えた錨を 409 で断り、client の写像では `.unreachable` に落ちる(接続断と同じ穴)。
            // 開く前なら「届かない」、開いた後なら「錨が消えた」の方が読み手の次の行動に合うが、
            // 此処で区別する材料が無いので**開く前は failed**に倒す(嘘の方を作らない)。
            return isOpen ? .anchorGone : .failed
        case .failure:
            return .failed
        }
    }

    /// 古い側へ 1 窓ぶん歩く。端の錨で読み直す(机の前進の約束を使う)。
    func walkOlder() async -> Outcome {
        await walk(edge: entries.first?.anchor, available: olderAvailable)
    }

    /// 新しい側へ 1 窓ぶん歩く。
    func walkNewer() async -> Outcome {
        await walk(edge: entries.last?.anchor, available: newerAvailable)
    }

    private func walk(edge: String?, available: Bool) async -> Outcome {
        guard isOpen else { return .failed }
        guard !isWalking else { return .busy }
        guard available, let edge else { return .atEdge }
        isWalking = true
        defer { isWalking = false }
        let before = (entries.first?.anchor, entries.last?.anchor)
        switch await client.around(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID,
                                   anchor: edge, limit: Self.span) {
        case .success(let r):
            guard !r.history.isEmpty else { return .atEdge }
            let after = (r.history.first?.anchor, r.history.last?.anchor)
            // ★不変条件 2 の**守り**。机が前進を約束していても、電話が其れを信じ切る形にはしない。
            //   同じ両端が返ったら旗の値に関わらず端と扱う —— 信じると、机の回帰が電話側で
            //   「押しても何も起きないボタン」ではなく**無限の往復**になる。
            guard after != before else { return .atEdge }
            entries = r.history
            olderAvailable = r.olderAvailable
            newerAvailable = r.newerAvailable
            return .moved
        case .failure(.notFound):
            return .anchorGone
        case .failure(.unreachable):
            return .anchorGone
        case .failure:
            return .failed
        }
    }

    /// ライブで 1 件届いた。**窓には入れない**(不変条件 1)。画面は此の数を「下に N 件」と出す。
    func noteLiveArrival(_ count: Int = 1) {
        guard isOpen, count > 0 else { return }
        liveArrived += count
    }

    /// live へ戻す。呼び手(`ConversationViewModel`)が末尾の窓を読み直す前に此れを呼び、
    /// 離脱窓の状態を捨てる。**残すと、戻った後の画面が古い旗で「もっと古く」を出す。**
    func close() {
        entries = []
        openedAt = nil
        olderAvailable = false
        newerAvailable = false
        liveArrived = 0
    }
}
