import Foundation

/// 机の roots の 3 本の口(2026-09-03、対照表 #11)。読む 2 本(`list` / `paths`)は `interactiveTimeout`、
/// 始める 1 本(`start`)は `writeTimeout`。素の `URLSession` は使わない(`session-guard.test.mjs` が門で落とす)。
protocol RootsBrowsing {
    /// `GET /api/roots` — 台帳の root(index + 札)。台帳が無ければ `roots: []` + `reason: no_roots`。
    func list(baseURL: URL, apiKey: String) async -> Result<RootsResponse, SessionsFetchError>
    /// `GET /api/roots/<i>/paths?q=&limit=` — 其の root の下の **dir だけ**(root からの相対 path)。
    func paths(baseURL: URL, apiKey: String, rootIndex: Int, query: String, limit: Int) async -> Result<PathCompletionResponse, SessionsFetchError>
    /// `POST /api/roots/<i>/new` `{ "path": "<相対 or 空>" }` — 其処で新しい会話を始める。
    func start(baseURL: URL, apiKey: String, rootIndex: Int, path: String) async -> StartInRootOutcome
}

struct RootsClient: RootsBrowsing {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    private func get(_ url: URL, apiKey: String) async -> Result<(Int, Data), SessionsFetchError> {
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
        guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        return .success((http.statusCode, data))
    }

    func list(baseURL: URL, apiKey: String) async -> Result<RootsResponse, SessionsFetchError> {
        let url = baseURL.appendingPathComponent("api/roots")
        switch await get(url, apiKey: apiKey) {
        case .failure(let e): return .failure(e)
        case .success(let (status, data)):
            switch status {
            case 200:
                guard let body = try? JSONDecoder().decode(RootsResponse.self, from: data) else {
                    return .failure(.contractViolation(ResponseContractViolation(status: 200, code: nil)))
                }
                return .success(body)
            case 401: return .failure(.unauthorized)
            default:
                let code = try? JSONDecoder().decode(RecoveryCode.self, from: data).code
                return .failure(.contractViolation(ResponseContractViolation(status: status, code: code)))
            }
        }
    }

    func paths(baseURL: URL, apiKey: String, rootIndex: Int, query: String, limit: Int) async -> Result<PathCompletionResponse, SessionsFetchError> {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/roots/\(rootIndex)/paths"),
            resolvingAgainstBaseURL: false
        )
        // ★空の問いでも `q=` を送る(`PathCompletionClient` と同じ理由: 空 = 直下だけ、が此の口の入口)。
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else { return .failure(.unreachable) }
        switch await get(url, apiKey: apiKey) {
        case .failure(let e): return .failure(e)
        case .success(let (status, data)):
            switch status {
            case 200:
                guard let body = try? JSONDecoder().decode(PathCompletionResponse.self, from: data) else {
                    return .failure(.contractViolation(ResponseContractViolation(status: 200, code: nil)))
                }
                return .success(body)
            case 401: return .failure(.unauthorized)
            default:
                // 404 = 其の index の root が無い(台帳が書き換わった)。`code` は来ない(復旧語彙ではない)。
                let code = try? JSONDecoder().decode(RecoveryCode.self, from: data).code
                return .failure(.contractViolation(ResponseContractViolation(status: status, code: code)))
            }
        }
    }

    func start(baseURL: URL, apiKey: String, rootIndex: Int, path: String) async -> StartInRootOutcome {
        let url = baseURL.appendingPathComponent("api/roots/\(rootIndex)/new")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BackendSession.writeTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let path: String }
        request.httpBody = try? JSONEncoder().encode(Body(path: path))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unreachable
        }
        guard let http = response as? HTTPURLResponse else { return .unreachable }
        struct Wire: Decodable { let reason: String? }
        let wire = try? JSONDecoder().decode(Wire.self, from: data)
        return StartInRootOutcome.from(status: http.statusCode, reason: wire?.reason)
    }
}
