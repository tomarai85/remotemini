import Foundation

/// The account the backend is currently running Claude under, as reported by
/// `fleet-account`. A bare string: the server hands back whatever the script prints
/// (`server.mjs`'s `/api/account` handler does `execFileSync(FLEET_ACCOUNT).trim()`
/// and wraps it in `{account}`), and this type does not try to parse it into a
/// structure the script never promised.
struct AccountState: Equatable {
    let account: String
}

enum AccountError: Error, Equatable {
    case unreachable
    case cancelled
    case unauthorized
    /// The script itself failed on the backend (500 from either handler). The server
    /// puts the reason in `error`; it is carried so the phone can say *what* broke
    /// rather than "something went wrong".
    case backend(String)
    case unexpectedStatus(Int)
    case malformedBody
}

protocol AccountReading {
    func current(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError>
}

protocol AccountAdvancing {
    func next(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError>
}

/// `GET /api/account` and `POST /api/account/next` -- REQUIREMENTS §4-5 / §5-8
/// ("アカウント切替が UI からスムーズにできる", Tom verbatim 2026-07-28).
///
/// Both server handlers shipped long before this client existed; `server.mjs` says so
/// in as many words ("native app から1回も呼ばれていない"). This type is the missing
/// half, and deliberately nothing more than the two calls.
///
/// ★Why `next` is not retried anywhere in this file, and must not be: the server's own
/// comment on that handler records the reason -- `fleet-account --next` has a side
/// effect *before* it can time out, so a 500 does not mean "the account did not
/// advance". An automatic retry would step the account twice while reporting one
/// failure. The phone's answer to a failed switch is to re-read `current`, which this
/// client also provides, and let the person see where it actually landed.
///
/// ★Why the two capabilities are separate protocols: reading is safe and can be done
/// on every appearance of the screen; advancing mutates fleet-wide state. A view model
/// that only needs to display the account should not be handed the ability to change
/// it. `AccountClient` conforms to both; the seams are for the callers.
struct AccountClient: AccountReading, AccountAdvancing {
    /// `BackendSession`, not `URLSession` -- same constraint as every other client here.
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func current(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/account"))
        request.httpMethod = "GET"
        request.timeoutInterval = BackendSession.interactiveTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return await perform(request)
    }

    func next(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/account/next"))
        request.httpMethod = "POST"
        // The write timeout, not the interactive one: the backend caps `fleet-account`
        // at 10s (`FLEET_ACCOUNT_TIMEOUT_MS`), so a phone-side deadline shorter than
        // that would abandon a call that is still going to change the account.
        request.timeoutInterval = BackendSession.writeTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return await perform(request)
    }

    private func perform(_ request: URLRequest) async -> Result<AccountState, AccountError> {
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

        // Status before body, as everywhere else in this layer.
        guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        switch http.statusCode {
        case 200:
            guard let state = Self.decodeAccount(data) else { return .failure(.malformedBody) }
            return .success(state)
        case 401:
            return .failure(.unauthorized)
        case 500:
            // The server always attaches `error` on this route's failure path. If it is
            // missing, say so rather than inventing a reason.
            return .failure(.backend(Self.decodeError(data) ?? "サーバが理由を返しませんでした"))
        default:
            return .failure(.unexpectedStatus(http.statusCode))
        }
    }

    private static func decodeAccount(_ data: Data) -> AccountState? {
        struct Wire: Decodable { let account: String }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        // An empty string is not an account. `fleet-account` printing nothing means the
        // fleet could not name one, and showing a blank label reads as "no account is
        // set" -- which is a different, quieter lie than saying the body was malformed.
        let trimmed = wire.account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AccountState(account: trimmed)
    }

    private static func decodeError(_ data: Data) -> String? {
        struct Wire: Decodable { let error: String }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        let trimmed = wire.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
