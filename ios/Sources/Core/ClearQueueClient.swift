import Foundation

protocol QueueClearing {
    func clearQueue(baseURL: URL, apiKey: String, sessionID: String) async -> ClearQueueOutcome
}

/// `DELETE /api/sessions/<id>/queue` — 待っている送信を捨てる。**走っている番は止めない**
/// (止めるのは `interrupt` の側。サーバの route 註釈が2つを1つのボタンに畳むなと書いている)。
///
/// 本文は送らない(`InterruptClient` と同じ理由: サーバは path 以外を読まない)。
///
/// ★409 をエラーに丸めない。此の道の 409 は**設計された断り**で、2種居る:
/// 宛先を確定できない(別の会話の行列を捨てうる)/ 机で開かれている会話
/// (行列は Claude Code の TUI が持っていて、電話からは観測も取消もできない)。
/// どちらもサーバが人向けの文で理由を返すので、其れをそのまま見せる。
struct ClearQueueClient: QueueClearing {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func clearQueue(baseURL: URL, apiKey: String, sessionID: String) async -> ClearQueueOutcome {
        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/queue")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = BackendSession.writeTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return .error("取り消されました")
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .error("取り消されました")
        } catch {
            return .error("机に届きません")
        }
        guard let http = response as? HTTPURLResponse else { return .error("机に届きません") }

        struct Wire: Decodable { let dropped: Int?; let error: String? }
        let wire = try? JSONDecoder().decode(Wire.self, from: data)
        return ClearQueueOutcome.from(
            status: http.statusCode, dropped: wire?.dropped, serverError: wire?.error)
    }
}
