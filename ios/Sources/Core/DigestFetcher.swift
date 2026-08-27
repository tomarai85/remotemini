import Foundation

protocol DigestFetching {
    func fetch(baseURL: URL, apiKey: String, sessionID: String) async
        -> Result<SessionDigest, SessionsFetchError>
}

/// `GET /api/sessions/<id>/digest` を取りに行く口。2026-08-26 新設。
///
/// ★形は `HistoryClient` に揃える(この repo が明文化している規約):
///   - `BackendSession` を通す。**素の `URLSession` は書けない** ——
///     `rc-backend/test/session-guard.test.mjs` が `ios/Sources/` を走査して、
///     他の file が `URLSession` と綴っていたら commit の門が落とす。
///   - N6: **本文を信じる前に status を見る**。
///   - error の語彙を**新設しない**。`SessionsFetchError` を再利用する ——
///     語彙を 2 つ持つと、以後 毎 sprint どちらかを選ぶ事になる(brief §3-c)。
///
/// ★404 が 2 つの意味を持つ罠も `HistoryClient` と同じ扱いにする:
///   `SESSION_NOT_FOUND`(その会話がもう無い)と `NO_SUCH_ROUTE`(此方が URL を
///   組み違えた)が同じ status で来る。status だけで分けると、**此方の不具合を
///   「あなたの会話は消えました」と利用者に伝える**事になる。
struct DigestFetcher: DigestFetching {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func fetch(baseURL: URL, apiKey: String, sessionID: String) async
        -> Result<SessionDigest, SessionsFetchError>
    {
        // ★`sessionID` をそのまま path に混ぜない。`appendingPathComponent` は
        //   `/` を通してしまうので、id の形を先に検める(此処だけが外から来る値)。
        guard !sessionID.isEmpty,
              sessionID.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#").inverted) != nil,
              sessionID.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#")) == nil
        else {
            return .failure(.unreachable)
        }

        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/digest")

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

        // N6: 本文を信じる前に status。
        guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        switch http.statusCode {
        case 200:
            break
        case 401:
            return .failure(.unauthorized)
        case 404:
            // ★2 つの 404 を分ける。`HistoryClient` と同じ判断で、理由も同じ。
            let code = try? JSONDecoder().decode(RecoveryCode.self, from: data).code
            guard code == RecoveryCode.sessionNotFound else {
                return .failure(.contractViolation(ResponseContractViolation(status: 404, code: code)))
            }
            return .failure(.notFound)
        default:
            return .failure(.unreachable)
        }

        guard let decoded = try? DigestParser.parse(data) else {
            return .failure(.malformedBody)
        }
        return .success(decoded)
    }
}
