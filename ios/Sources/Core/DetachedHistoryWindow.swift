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
///      約束が破れた時に電話が無限に同じ窓を読む形にはしない —— 進まなければ其の向きを端と確定する。
///   3. 要求した錨は必ず窓の中に在る。無ければ机の契約違反なので、窓を開いた/動いたと言わない。
///
/// ★2026-09-04 の Codex レビューで High 2 件を含む 5 件を直した。特に:
///   - 走行中に `close()` が来ると、遅れて返った応答が**閉じた窓を蘇らせて**いた(世代で塞いだ)。
///   - 前進の判定が**両端の組**を較べていたので、反対側の端だけが動いた応答を「進んだ」と読んでいた。
@MainActor
final class DetachedHistoryWindow {
    /// 遷移の結果。画面は此の値だけを見て文言を決める(`Bool` を持ち回らない)。
    enum Outcome: Equatable {
        /// 窓が開いた / 動いた。
        case moved
        /// 其の向きの端に着いた(旗が下りた、または机が進まなかった)。窓は据え置き。
        case atEdge
        /// 錨が消えた(机が 409 `anchor_gone`、または返ってきた窓に其の錨が居ない)。呼び手は live へ戻す。
        case anchorGone
        /// 走行中の再入、または応答が届く前に窓が閉じられた。窓は触っていない。
        case busy
        /// 届かなかった。文言は呼び手が持つ(`ConversationViewModel` の既存の写像と揃える)。
        case failed
    }

    /// 歩く向き。**前進の判定に要る**(Codex 所見 F4): 古い側へ歩いた時に見るべきなのは
    /// 窓の古い端だけで、新しい端が動いた事は其の向きの前進の証拠にならない。
    private enum Direction { case older, newer }

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
    /// 走行中の排他。
    private(set) var isWalking = false
    /// ★世代(Codex 所見 F1)。`close()` と `open()` が進める。応答を書き戻す前に、待つ前の世代と
    ///   比べる —— 一致しなければ、其の応答が答えている質問は既に取り下げられている。
    ///   `isWalking` だけでは足りない: あれは「新しい呼び出しを断る」印で、
    ///   **既に飛んでいる応答が戻ってくる**のを止めない。
    private var generation = 0

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
        generation += 1
        let mine = generation
        defer { isWalking = false }
        let result = await client.around(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID,
                                         anchor: anchor, limit: Self.span)
        guard generation == mine else { return .busy }   // 待っている間に閉じられた / 開き直された
        switch result {
        case .success(let r):
            // 不変条件 3。机は「要求した錨は窓の中に在る」と約束している。破れていたら
            // 開いたと言わない —— 開いたと言って中身に無いと、画面は強調する行を探して見つけられない。
            guard r.anchor == anchor, r.history.contains(where: { $0.anchor == anchor }) else {
                return .anchorGone
            }
            entries = r.history
            openedAt = anchor
            olderAvailable = r.olderAvailable
            newerAvailable = r.newerAvailable
            liveArrived = 0
            return .moved
        case .failure(.anchorGone), .failure(.notFound):
            return .anchorGone
        case .failure:
            // ★接続断は `.failed`。**開いているかで読み分けない**(Codex 所見 F2) —— 同じ 1 つの
            //   失敗値を状態で別の意味に読むと、「錨が消えた」と「電波が切れた」が入れ替わる。
            return .failed
        }
    }

    /// 古い側へ 1 窓ぶん歩く。端の錨で読み直す(机の前進の約束を使う)。
    func walkOlder() async -> Outcome {
        await walk(.older)
    }

    /// 新しい側へ 1 窓ぶん歩く。
    func walkNewer() async -> Outcome {
        await walk(.newer)
    }

    private func walk(_ direction: Direction) async -> Outcome {
        guard isOpen else { return .failed }
        guard !isWalking else { return .busy }
        let available = direction == .older ? olderAvailable : newerAvailable
        let edge = direction == .older ? entries.first?.anchor : entries.last?.anchor
        guard available, let edge else { return .atEdge }
        isWalking = true
        generation += 1
        let mine = generation
        defer { isWalking = false }
        let result = await client.around(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID,
                                         anchor: edge, limit: Self.span)
        guard generation == mine, isOpen else { return .busy }
        switch result {
        case .success(let r):
            // 不変条件 3 は歩く時も同じ(Codex 所見 F3): 頼んだ錨を含まない窓は、別の場所の窓。
            guard r.anchor == edge, r.history.contains(where: { $0.anchor == edge }) else {
                return .anchorGone
            }
            // ★不変条件 2 の**守り**。見るのは**歩いた向きの端だけ**(Codex 所見 F4)——
            //   両端の組を較べると、反対側だけが動いた応答を「進んだ」と読み、
            //   2 つの窓を往復し続ける形が通ってしまう。
            let movedEdge = direction == .older ? r.history.first?.anchor : r.history.last?.anchor
            guard let movedEdge, movedEdge != edge else {
                // 机が前進を約束していても信じ切らない。進まなかった向きは**其の場で端に確定**する
                // (Codex 所見 F5)—— 旗を立てたまま `.atEdge` を返すと、押す度に机を叩き続ける
                // ボタンが画面に残る。机の旗そのものは書き換えず、此方の可用性だけを閉じる。
                if direction == .older { olderAvailable = false } else { newerAvailable = false }
                return .atEdge
            }
            entries = r.history
            olderAvailable = r.olderAvailable
            newerAvailable = r.newerAvailable
            return .moved
        case .failure(.anchorGone), .failure(.notFound):
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
    /// 世代を進めるので、飛んでいる応答が戻っても書き戻さない。
    func close() {
        generation += 1
        entries = []
        openedAt = nil
        olderAvailable = false
        newerAvailable = false
        liveArrived = 0
    }
}
