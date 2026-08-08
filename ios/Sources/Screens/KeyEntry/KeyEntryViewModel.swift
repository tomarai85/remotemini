import Foundation

@MainActor
final class KeyEntryViewModel: ObservableObject {
    @Published var baseURLText: String = ""
    @Published var apiKeyText: String = ""
    @Published var isChecking: Bool = false
    @Published var errorMessage: String?

    private let healthz: HealthzChecking
    private let sessionsProbe: SessionsAuthChecking
    private let store: CredentialStore
    private let onSaved: (Credentials) -> Void

    /// - Parameter initialBaseURL: 401 で落とされた時に使っていた URL(DESIGN §2.65)。
    ///   **届いた上で 401 が返った**ので URL が正しい事は観測済み。打ち直させない為に
    ///   欄へ入れて開く。`nil`(初回)なら従来どおり空。
    ///
    ///   ★鍵の側は絶対に入れない。拒まれた鍵を欄に残すと、Tom は「入っているから合って
    ///   いる」と読んで押し、また拒まれる —— 直そうとした迷子を一段深くする。
    ///
    ///   ★引数の位置が `store` と `onSaved` の**間**なのは呼び出し側の都合。既存の
    ///   呼び出しは全部 `KeyEntryViewModel(healthz:sessionsProbe:store:) { ... }` の形で
    ///   末尾 closure を使っているので、末尾に足すと全部壊れる。
    init(healthz: HealthzChecking = HealthzClient(),
         sessionsProbe: SessionsAuthChecking = SessionsAuthProbe(),
         store: CredentialStore = KeychainCredentialStore(),
         initialBaseURL: URL? = nil,
         onSaved: @escaping (Credentials) -> Void) {
        self.healthz = healthz
        self.sessionsProbe = sessionsProbe
        self.store = store
        self.onSaved = onSaved
        self.baseURLText = initialBaseURL?.absoluteString ?? ""
    }

    /// Spec §2-1: healthz first (proves the URL), then `/api/sessions` (proves the
    /// key). Only on both passing does anything reach the Keychain.
    func submit() async {
        errorMessage = nil
        guard let url = Self.normalizeBaseURL(baseURLText) else {
            errorMessage = "URL の形式が正しくありません(https:// で始まる URL を入力してください)"
            return
        }
        let apiKey = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            errorMessage = "鍵を入力してください"
            return
        }

        isChecking = true
        defer { isChecking = false }

        switch await healthz.check(baseURL: url) {
        case .failure:
            errorMessage = "サーバに届きません。URL を確認してください"
            return
        case .success(let result):
            // Sprint 1 DoD diagnostic line, grepped for via `devicectl --console`.
            // Deliberately just these two fields -- no key, no credentials, ever.
            print("healthz ok:\(result.ok) pid:\(result.pid)")
        }

        switch await sessionsProbe.check(baseURL: url, apiKey: apiKey) {
        case .unreachable:
            errorMessage = "サーバに届きません。URL を確認してください"
        case .unauthorized:
            errorMessage = "鍵が違います"
        case .authorized:
            let credentials = Credentials(baseURL: url, apiKey: apiKey)
            do {
                try store.save(credentials)
                onSaved(credentials)
            } catch {
                errorMessage = "端末に保存できませんでした"
            }
        }
    }

    /// Judgment call (spec §2-1 doesn't say whether to gate client-side before any
    /// network call): rejecting non-HTTPS / hostless input immediately gives faster,
    /// clearer feedback than waiting on a network round trip that would fail anyway.
    /// Flagged in progress.md as a spec gap, not silently assumed.
    static func normalizeBaseURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }
}
