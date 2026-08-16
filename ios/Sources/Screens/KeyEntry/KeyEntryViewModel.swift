import Foundation

@MainActor
final class KeyEntryViewModel: ObservableObject {
    /// 接続を押した後に走る**段**。順番に2つ在り、片方ずつしか走らない(DESIGN §2.68)。
    ///
    /// `CaseIterable` なのは飾りではない: 単体検査が `Probe.allCases.count` と
    /// 「実際に呼ばれた口の数」を突き合わせる。段を1つ足して呼び忘れる / 呼んだのに
    /// 段を足し忘れる、のどちらでも赤くなる。
    enum Probe: CaseIterable {
        /// 1段目。`healthz` —— この URL にサーバが居るか。
        case url
        /// 2段目。`/api/sessions` —— その鍵が通るか。
        case key
    }

    @Published var baseURLText: String = ""
    @Published var apiKeyText: String = ""
    /// 今どの段に居るか。走っていなければ `nil`。
    ///
    /// ★`isChecking: Bool` と別に持たない。2つ持つと「`isChecking == true` なのに
    /// `probe == nil`」という**在ってはならない状態が書ける**ので、真偽の方を
    /// 段から導く(下の計算プロパティ)。
    @Published private(set) var probe: Probe?
    @Published var errorMessage: String?

    /// 画面側の条件式を1つも書き換えずに済ませる為の計算プロパティ。
    var isChecking: Bool { probe != nil }

    /// 今出す「確かめています」の一文。走っていなければ `nil`。
    ///
    /// ★秒数を字で書かない(DESIGN §2.54 / §2.56 と同じ約束)。本当に待つ長さは
    /// `HealthzClient` と `SessionsAuthProbe` が `request.timeoutInterval` に入れて
    /// いる値なので、そこから引く。定数が動いた時に文だけ古いままになる経路を作らない。
    var inFlightText: String? {
        guard let probe else { return nil }
        switch probe {
        case .url:
            return Self.urlProbeInFlightText(timeout: BackendSession.interactiveTimeout)
        case .key:
            return Self.keyProbeInFlightText(timeout: BackendSession.interactiveTimeout)
        }
    }

    /// 1段目の文。
    ///
    /// ★2段を1つの文(「最大16秒」)に畳まない。畳むと**どちらが詰まったか**が消える ——
    /// 旅先ではそこが分かれ道で、1段目で止まるなら tailnet か edith 自体、2段目で
    /// 止まるなら edith は起きていて rc-backend が詰まっている。直し方が別物。
    ///
    /// 続く失敗の文(「サーバに届きません。URL を確認してください」)と語を揃えてある。
    static func urlProbeInFlightText(timeout: TimeInterval) -> String {
        "Checking the server is reachable… (waiting up to \(Int(timeout))s)"
    }

    /// 2段目の文。
    ///
    /// ここへ来た時点で 1段目は**通っている**ので、これは推測ではなく観測の報告。
    /// 「電話は自分が見た物だけを言う」(DESIGN §2.56)がそのまま守れる。
    static func keyProbeInFlightText(timeout: TimeInterval) -> String {
        "Checking the key works… (waiting up to \(Int(timeout))s)"
    }

    private let clients: KeyEntryClients
    private let onSaved: (Credentials) -> Void

    /// - Parameter clients: 背後の3つの口。**既定値は無い**(`ios/Sources/Core/KeyEntryClients.swift`)。
    ///   呼ぶ側が `.live` か `.fixture(stallingAt:)` かを必ず名指しする。
    ///
    /// - Parameter initialBaseURL: 401 で落とされた時に使っていた URL(DESIGN §2.65)。
    ///   **届いた上で 401 が返った**ので URL が正しい事は観測済み。打ち直させない為に
    ///   欄へ入れて開く。`nil`(初回)なら従来どおり空。
    ///
    ///   ★鍵の側は絶対に入れない。拒まれた鍵を欄に残すと、Tom は「入っているから合って
    ///   いる」と読んで押し、また拒まれる —— 直そうとした迷子を一段深くする。
    ///
    ///   ★引数の位置が `clients` と `onSaved` の**間**なのは呼び出し側の都合。既存の
    ///   呼び出しは全部末尾 closure を使っているので、末尾に足すと全部壊れる。
    init(clients: KeyEntryClients,
         initialBaseURL: URL? = nil,
         onSaved: @escaping (Credentials) -> Void) {
        self.clients = clients
        self.onSaved = onSaved
        self.baseURLText = initialBaseURL?.absoluteString ?? ""
    }

    /// Spec §2-1: healthz first (proves the URL), then `/api/sessions` (proves the
    /// key). Only on both passing does anything reach the Keychain.
    func submit() async {
        errorMessage = nil
        guard let url = Self.normalizeBaseURL(baseURLText) else {
            errorMessage = "The URL is malformed (enter one starting with https://)"
            return
        }
        let apiKey = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            errorMessage = "Enter the key"
            return
        }

        probe = .url
        defer { probe = nil }

        switch await clients.healthz.check(baseURL: url) {
        case .failure:
            errorMessage = "Can't reach the server. Check the URL"
            return
        case .success(let result):
            // Sprint 1 DoD diagnostic line, grepped for via `devicectl --console`.
            // Deliberately just these two fields -- no key, no credentials, ever.
            print("healthz ok:\(result.ok) pid:\(result.pid)")
        }

        probe = .key

        switch await clients.sessionsProbe.check(baseURL: url, apiKey: apiKey) {
        case .unreachable:
            errorMessage = "Can't reach the server. Check the URL"
        case .unauthorized:
            errorMessage = "The key is wrong"
        case .authorized:
            let credentials = Credentials(baseURL: url, apiKey: apiKey)
            do {
                try clients.store.save(credentials)
                onSaved(credentials)
            } catch {
                errorMessage = "Could not save on this device"
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
