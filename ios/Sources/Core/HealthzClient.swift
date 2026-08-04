import Foundation

struct HealthzResult: Equatable {
    let ok: Bool
    let pid: Int
    let uptimeSeconds: Int
    let version: String
}

enum HealthzError: Error, Equatable {
    case unreachable
    case unexpectedStatus(Int)
    case malformedBody
}

protocol HealthzChecking {
    func check(baseURL: URL) async -> Result<HealthzResult, HealthzError>
}

/// `GET /healthz` -- the unauthenticated liveness probe (the `/healthz` branch in `server.mjs`). Used
/// by Key-entry to tell "wrong URL" apart from "wrong key" (spec §2-1/§5-1): this
/// call never carries the API key, so a failure here can only mean the URL itself is
/// unreachable.
struct HealthzClient: HealthzChecking {
    private let session: URLSession

    init(session: URLSession = BackendSession.shared.session) {
        self.session = session
    }

    func check(baseURL: URL) async -> Result<HealthzResult, HealthzError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("healthz"))
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failure(.unreachable)
        }

        // N6 (spec §3-3 step 1): status is checked before the body is trusted.
        guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        guard http.statusCode == 200 else { return .failure(.unexpectedStatus(http.statusCode)) }
        guard let result = Self.decode(data) else { return .failure(.malformedBody) }
        return .success(result)
    }

    private static func decode(_ data: Data) -> HealthzResult? {
        struct Wire: Decodable { let ok: Bool; let pid: Int; let uptime: Int; let version: String }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        return HealthzResult(ok: wire.ok, pid: wire.pid, uptimeSeconds: wire.uptime, version: wire.version)
    }
}
