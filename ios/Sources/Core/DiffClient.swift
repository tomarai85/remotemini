import Foundation

protocol DiffFetching {
    /// `GET /api/sessions/<id>/diff` -- 作業木の未コミットの差分を読む(対照表 #4)。
    /// 引数無し(`limit` 等は無い): 天井は机側の定数で決まっていて、電話は指定しない。
    func fetch(baseURL: URL, apiKey: String, sessionID: String) async -> Result<SessionDiffBody, SessionsFetchError>
}

/// `HistoryClient`(Sprint 3)と同じ形: protocol + struct、`BackendSession`
/// (`URLSession` 直書き禁止 -- `rc-backend/test/session-guard.test.mjs` が
/// `ios/Sources/` を走査して commit gate で落とす)、N6(status を先に読んでから
/// 本文を信じる)、`SessionsFetchError` の 4 値をそのまま再利用する
/// (`HistoryClient` の doc 通り: 会話ごとに誤り語彙を1つ増やさない)。
struct DiffClient: DiffFetching {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func fetch(baseURL: URL, apiKey: String, sessionID: String) async -> Result<SessionDiffBody, SessionsFetchError> {
        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/diff")

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
            // `HistoryClient` と同じ判断(Sprint 5 §0-c ②): CODE が決める、status では
            // ない。此の route は cwd が無い会話でも 200 + `reason` で返す設計
            // (`server.mjs` の diff 分岐の頭書き)なので、404 は「会話そのものが無い」か
            // 「電話が誤った path を組んだ」のどちらかしか有り得ない。
            let code = try? JSONDecoder().decode(RecoveryCode.self, from: data).code
            guard code == RecoveryCode.sessionNotFound else {
                return .failure(.contractViolation(ResponseContractViolation(status: 404, code: code)))
            }
            return .failure(.notFound)
        default:
            return .failure(.unreachable)
        }

        guard let decoded = try? JSONDecoder().decode(SessionDiffBody.self, from: data) else {
            return .failure(.malformedBody)
        }
        return .success(decoded)
    }
}
