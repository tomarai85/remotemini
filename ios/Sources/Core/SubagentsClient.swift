import Foundation

protocol SubagentsFetching {
    /// `GET /api/sessions/<id>/subagents` — 其の会話の下で何が走っているかを読む(対照表 #8)。
    /// 引数無し: 上限は机側の定数(`SUBAGENT_MAX`)で決まっていて、電話は指定しない
    /// (`DiffFetching` と同じ判断 —— 天井を 2 箇所に置かない)。
    func fetch(baseURL: URL, apiKey: String, sessionID: String) async -> Result<SubagentsBody, SessionsFetchError>
}

/// `DiffClient` と同じ形: protocol + struct、`BackendSession` 経由(`URLSession` 直書きは
/// `rc-backend/test/session-guard.test.mjs` が `ios/Sources/` を走査して門で落とす)、
/// N6(status を先に読んでから本文を信じる)、誤りの語彙は `SessionsFetchError` を再利用。
///
/// ★此の口は**読むだけ**で、机は「読めなかった」も 200 + 状態で返す設計。だから
///   404 は「会話そのものが無い」か「電話が誤った path を組んだ」しか有り得ない
///   (`DiffClient` の 404 の註と同じ理由)。
struct SubagentsClient: SubagentsFetching {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func fetch(baseURL: URL, apiKey: String, sessionID: String) async -> Result<SubagentsBody, SessionsFetchError> {
        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/subagents")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = BackendSession.interactiveTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .failure(.cancelled)
        } catch {
            return .failure(.unreachable)
        }

        // N6: status を先に読んでから本文を信じる。
        guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        switch http.statusCode {
        case 200:
            break
        case 401:
            return .failure(.unauthorized)
        case 404:
            let code = try? JSONDecoder().decode(RecoveryCode.self, from: data).code
            guard code == RecoveryCode.sessionNotFound else {
                return .failure(.contractViolation(ResponseContractViolation(status: 404, code: code)))
            }
            return .failure(.notFound)
        default:
            return .failure(.unreachable)
        }

        guard let decoded = try? JSONDecoder().decode(SubagentsBody.self, from: data) else {
            return .failure(.malformedBody)
        }
        return .success(decoded)
    }
}
