import Foundation

/// `DiffView` の状態機。`ConversationViewModel` の縮小版 -- 此の画面は読むだけの脇の
/// 画面で、poll も送信も持たないので、あちらの `.notFound`/`.unauthorized` の
/// 画面遷移(app 全体のルーティング)は持ち込まない。失敗は此の画面の中で完結する
/// 1 文の帯として持つ(スコープの判断。会話本体を開いた時点で認証/存在は既に
/// 確かめられている -- 此処で 401/404 が起きるのは「その間に切れた/消えた」稀な
/// 窓で、次に会話画面へ戻って読み直せば本来のルーティングが拾う)。
@MainActor
final class DiffViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded(SessionDiffBody)
        /// `SessionsFetchError` を**1 文へ言い換えた**物だけを持つ -- view は enum の
        /// 場合分けを二重に持たない(`ResultDisplay` の「サーバの一文をそのまま描く」
        /// 判断と同じ形を、机ではなく client 層の誤りに対して電話側で踏む)。
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading

    private let client: DiffFetching
    private let baseURL: URL
    private let apiKey: String
    private let sessionID: String

    init(client: DiffFetching = DiffClient(), baseURL: URL, apiKey: String, sessionID: String) {
        self.client = client
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sessionID = sessionID
    }

    func load() async {
        phase = .loading
        switch await client.fetch(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID) {
        case .success(let response):
            phase = .loaded(response)
        case .failure(.cancelled):
            // 誰かが引いた取り消し。呼んだ側が結果を持つ -- 此処で帯を出すと、
            // 画面を閉じた瞬間に一瞬「読めませんでした」が見える形になる
            // (`SessionsFetchError.cancelled` の doc と同じ判断)。
            break
        case .failure(let error):
            phase = .failed(Self.text(for: error))
        }
    }

    /// 誤りごとに固定の1文。`ResponseContractViolation.displayText` と同じ判断で、
    /// 電話が状況ごとの説明を創作しない -- 何が届いたかだけを言う。
    private static func text(for error: SessionsFetchError) -> String {
        switch error {
        case .unauthorized:
            return "Sign-in expired. Reopen this conversation to sign in again."
        case .notFound:
            return "That conversation is gone."
        case .malformedBody:
            return "The response shape is unreadable."
        case .contractViolation(let violation):
            return violation.displayText
        case .unreachable:
            return "Couldn't reach the desk."
        case .cancelled:
            // `load()` は此のケースで `phase` を触らない(上を見よ)。此処へは
            // 到達しない分岐だが、`SessionsFetchError` の4値を網羅する為に残す --
            // 網羅を崩すと、5つ目の case が生えた日にコンパイラが黙って通す。
            return ""
        }
    }
}
