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

    init(healthz: HealthzChecking = HealthzClient(),
         sessionsProbe: SessionsAuthChecking = SessionsAuthProbe(),
         store: CredentialStore = KeychainCredentialStore(),
         onSaved: @escaping (Credentials) -> Void) {
        self.healthz = healthz
        self.sessionsProbe = sessionsProbe
        self.store = store
        self.onSaved = onSaved
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
