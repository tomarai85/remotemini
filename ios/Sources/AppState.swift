import SwiftUI

/// Sprint 1 scope: load-or-not-loaded credentials, nothing else. List/Conversation
/// state arrives with Sprint 2+ per `.harness/spec-native-shell-2026-08-05.md` §6.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var credentials: Credentials?
    @Published private(set) var isLoadingCredentials = true

    private let store: CredentialStore

    init(store: CredentialStore = KeychainCredentialStore()) {
        self.store = store
    }

    func loadStoredCredentials() async {
        credentials = try? store.load()
        isLoadingCredentials = false
    }

    func setCredentials(_ credentials: Credentials) {
        self.credentials = credentials
    }

    /// Brief §4-b: on a 401 from the List screen, drop credentials from both the
    /// Keychain and memory, returning `RootView` to Key-entry. `try?` here mirrors
    /// `KeyEntryViewModel.submit()`'s existing tolerance of a Keychain failure --
    /// even if the durable copy can't be removed, the in-memory credentials are
    /// cleared regardless, so the app does not keep *using* a key the server just
    /// rejected.
    func clearCredentials() {
        try? store.clear()
        credentials = nil
    }
}
