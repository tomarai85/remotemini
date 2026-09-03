import Foundation

protocol PermissionModeFetching {
    func fetch(baseURL: URL, apiKey: String, sessionID: String) async
        -> Result<String?, SessionsFetchError>
}

/// `GET /api/sessions/<id>/status` を取りに行く口。2026-09-02 新設(対照表 #16)。
///
/// ★読むのは `permissionMode` **1鍵だけ**。此の会話が机で bypass / plan / default /
///   acceptEdits のどれで走っているかは、公式が接続端末に出す物(対照表 #16)で、
///   電話には今まで何も出ていなかった。★**選ぶ操作ではない** —— D4(#17)の裁定
///   「自動化に安全確認を押させない」には触れない、転写から読むだけの1本
///   (`rc-backend/src/sessions.mjs` の `permissionModeOf`)。
///
/// ★形は `DigestFetcher` に揃える(この repo が明文化している規約):
///   - `BackendSession` を通す。**素の `URLSession` は書けない** ——
///     `rc-backend/test/session-guard.test.mjs` が `ios/Sources/` を走査して、
///     他の file が `URLSession` と綴っていたら commit の門が落とす。
///   - N6: **本文を信じる前に status を見る**。
///   - error の語彙を**新設しない**。`SessionsFetchError` を再利用する。
///
/// ★404 が2つの意味を持つ罠も `HistoryClient`/`DigestFetcher` と同じ扱いにする:
///   `SESSION_NOT_FOUND`(その会話がもう無い)と `NO_SUCH_ROUTE`(此方が URL を
///   組み違えた)が同じ status で来る。
struct StatusClient: PermissionModeFetching {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func fetch(baseURL: URL, apiKey: String, sessionID: String) async
        -> Result<String?, SessionsFetchError>
    {
        guard !sessionID.isEmpty,
              sessionID.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#").inverted) != nil,
              sessionID.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#")) == nil
        else {
            return .failure(.unreachable)
        }

        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/status")

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
            let code = try? JSONDecoder().decode(RecoveryCode.self, from: data).code
            guard code == RecoveryCode.sessionNotFound else {
                return .failure(.contractViolation(ResponseContractViolation(status: 404, code: code)))
            }
            return .failure(.notFound)
        default:
            return .failure(.unreachable)
        }

        guard let env = try? JSONDecoder().decode(StatusEnvelope.self, from: data) else {
            return .failure(.malformedBody)
        }
        return .success(env.permissionMode)
    }
}

/// ★`Decodable` の名前は**サーバの key と1文字も違えない**(`wire-key-agreement` が
///   突き合わせる対象)。読むのは `permissionMode` だけ —— 残りの鍵(`route` / `pane` /
///   `screen` / `activity` / `limited` / `choice` / `source` / `worker` / `state` /
///   `queued` / `errored`)は既に poll 等が別の型で読んでいる、か、まだどの画面も
///   要らない診断値なので、此処でもう1本受けると同じ事実の2本目の写しを作る事になる
///   (`rc-backend/test/wire-key-agreement.test.mjs` の `StatusEnvelope` の serverOnly 註)。
struct StatusEnvelope: Decodable {
    let permissionMode: String?
}
