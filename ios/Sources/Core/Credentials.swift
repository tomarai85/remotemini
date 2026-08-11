import Foundation

/// The server URL + API key pair (spec §2-1). Held in memory by `AppState` once loaded.
/// Never logged, never included in a diagnostic line -- see callers.
///
/// Where it durably lives, since 2026-08-11 (#64): TWO places, not one.
///   - the Keychain (`KeychainCredentialStore`) -- the copy this app writes and clears
///   - the app bundle's `Info.plist` (`Provisioning`) -- the seed stamped at build time,
///     read-only from here, and the reason a fresh install is not asked to type anything
/// The doc used to say "the only durable copy lives in the Keychain". That stopped being
/// true when the seed was added; the cost of the second copy is spelled out in
/// `Provisioning` and in DESIGN.md 2.85.
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
