import Foundation

/// `SubagentsView` の状態機(対照表 #8「半分その一」、2026-09-05)。
/// `DiffViewModel` の写し —— 読むだけの脇の画面で、poll も送信も持たないので、
/// `.notFound`/`.unauthorized` の app 全体のルーティングは持ち込まず、失敗は
/// 此の画面の中で完結する 1 文の帯にする(同じ判断の理由はあちらの頭書き)。
@MainActor
final class SubagentsViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded(SubagentsBody)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading

    private let client: SubagentsFetching
    private let baseURL: URL
    private let apiKey: String
    private let sessionID: String

    init(client: SubagentsFetching = SubagentsClient(), baseURL: URL, apiKey: String, sessionID: String) {
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
            // 画面を閉じた瞬間に「読めませんでした」を一瞬見せない(`DiffViewModel` と同じ)。
            break
        case .failure(let error):
            phase = .failed(Self.text(for: error))
        }
    }

    /// 誤りごとに固定の1文。電話が状況ごとの説明を創作しない —— 何が届いたかだけを言う。
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
        case .anchorGone:
            // 錨の窓だけが作る値。此の口は 409 を返さないので到達しないが、網羅は崩さない。
            return "That part of the history changed."
        case .cancelled:
            // `load()` は此のケースで `phase` を触らない(上を見よ)。網羅を崩すと、
            // 5 つ目の case が生えた日にコンパイラが黙って通す。
            return ""
        }
    }
}
