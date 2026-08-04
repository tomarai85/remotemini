import Foundation

/// The server URL + API key pair entered on Key-entry (spec §2-1). Held in memory by
/// `AppState` once loaded; the only durable copy lives in the Keychain
/// (`KeychainCredentialStore`). Never logged, never included in a diagnostic line --
/// see callers.
struct Credentials: Equatable {
    let baseURL: URL
    let apiKey: String
}

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedStoredValue
}

protocol CredentialStore {
    func load() throws -> Credentials?
    func save(_ credentials: Credentials) throws
    func clear() throws
}
