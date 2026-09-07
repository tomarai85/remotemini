import Foundation

protocol SubagentsFetching {
    /// `GET /api/sessions/<id>/subagents` — 其の会話の下で何が走っているかを読む(対照表 #8)。
    /// 引数無し: 上限は机側の定数(`SUBAGENT_MAX`)で決まっていて、電話は指定しない
    /// (`DiffFetching` と同じ判断 —— 天井を 2 箇所に置かない)。
    func fetch(baseURL: URL, apiKey: String, sessionID: String) async -> Result<SubagentsBody, SessionsFetchError>
    /// `POST /api/sessions/<id>/subagents/<agentId>/stop` — 名指した 1 本を机が止める(対照表 #8「半分その二」、
    /// 2026-09-06)。机はパネルを開き、印を動かし、詳細で prompt と道具列を照合してから `x` を押す。断りも成功も
    /// **同じ形の本文**で返る(200 = `stopped:"observed"` / 409 = `stopped:false` + `reason` + `error`)。
    /// 本文は送らない(机は読まない)。
    func stop(baseURL: URL, apiKey: String, sessionID: String, agentID: String) async -> Result<SubagentStopBody, SessionsFetchError>
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

    func stop(baseURL: URL, apiKey: String, sessionID: String, agentID: String) async -> Result<SubagentStopBody, SessionsFetchError> {
        // agentId は列挙が返した物をそのまま path に入れる(字種は机の正規表現 `[A-Za-z0-9_-]{1,128}` と同じ。
        // 外れる物は path に組めないので 404 側に倒す = 机の「そんな口は無い」と同じ読み)。
        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/subagents/\(agentID)/stop")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 机の driver は「パネルを開く → 最大 4 周 → x → 数える」で数秒〜十数秒掛かる。対話の既定より長く取る。
        request.timeoutInterval = max(BackendSession.interactiveTimeout, 60)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

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

        guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        switch http.statusCode {
        case 200, 409:
            // ★409 は「断った」であって輸送の失敗ではない。本文が理由と文を運ぶので、成功と同じ型に読む。
            guard let decoded = try? JSONDecoder().decode(SubagentStopBody.self, from: data) else {
                return .failure(.malformedBody)
            }
            return .success(decoded)
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
    }
}
