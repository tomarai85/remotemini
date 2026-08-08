import SwiftUI

/// Sprint 1 scope: load-or-not-loaded credentials, nothing else. List/Conversation
/// state arrives with Sprint 2+ per `.harness/spec-native-shell-2026-08-05.md` §6.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var credentials: Credentials?
    @Published private(set) var isLoadingCredentials = true

    /// 鍵入力画面へ渡す「なぜ此処に居るか」。資格情報が在る間は必ず `nil`
    /// (`SignOutNotice` / DESIGN §2.65)。
    @Published private(set) var signOutNotice: SignOutNotice?

    private let store: CredentialStore
    private let notices: SignOutNoticeStoring

    init(store: CredentialStore = KeychainCredentialStore(),
         notices: SignOutNoticeStoring = UserDefaultsSignOutNoticeStore()) {
        self.store = store
        self.notices = notices
    }

    /// `RootView` が起動時に組む1体。既定は本物(Keychain + `UserDefaults`)で、
    /// UI 検査が種を渡した時だけ、鍵を持たない金庫と断りを1つ持った器に差し替わる。
    ///
    /// ★差し替えを此処に置くのは、`RootView` の既存2つの fixture が `AppState` を
    /// **迂回**する形だから。鍵入力画面は「`AppState` が鍵は無いと答えた」時にだけ
    /// 現れる面なので、迂回では作れない —— 迂回して直接 `KeyEntryView` を描くと、
    /// 測れるのは view だけで、断りが disk から画面まで**通る**事は測れないままになる。
    static func forLaunch() -> AppState {
        #if DEBUG
        if let fixture = SignOutNoticeFixture.fromEnvironment() {
            return AppState(store: NoStoredCredentials(),
                            notices: InMemorySignOutNoticeStore(notice: fixture.notice))
        }
        // 断りは付かない面(初回の顔)だが、鍵を持たない金庫を渡すのは同じ。
        // 本物の `KeychainCredentialStore` のままだと、開発機に資格情報が残っている日は
        // `loadStoredCredentials()` がそれを拾って**一覧画面**が出る —— 鍵入力画面を
        // 撮りに来た検査が、機械の状態次第で別の画面を撮る事になる。
        // `ios/Sources/Core/KeyEntryProbeFixture.swift`。
        if KeyEntryProbeFixture.fromEnvironment() != nil {
            return AppState(store: NoStoredCredentials(),
                            notices: InMemorySignOutNoticeStore())
        }
        #endif
        return AppState()
    }

    func loadStoredCredentials() async {
        credentials = try? store.load()
        if credentials == nil {
            signOutNotice = notices.load()
        } else {
            // ★鍵が在るのに断りが残っているのは、`clearCredentials()` の途中で殺された痕
            //   (断りを書いた直後、Keychain を消す前)。この電話は鍵入力画面へ行かないので
            //   出す先が無く、放っておくと**次に本当に落ちた時の断り**と見分けが付かなくなる。
            notices.save(nil)
            signOutNotice = nil
        }
        isLoadingCredentials = false
    }

    func setCredentials(_ credentials: Credentials) {
        // 断りを消す条件は**接続の成功ただ一つ**。画面を見た事では消さない
        // (`SignOutNoticeStoring.save` の doc)。
        notices.save(nil)
        signOutNotice = nil
        self.credentials = credentials
    }

    /// Brief §4-b: on a 401 from the List screen, drop credentials from both the
    /// Keychain and memory, returning `RootView` to Key-entry. `try?` here mirrors
    /// `KeyEntryViewModel.submit()`'s existing tolerance of a Keychain failure --
    /// even if the durable copy can't be removed, the in-memory credentials are
    /// cleared regardless, so the app does not keep *using* a key the server just
    /// rejected.
    ///
    /// ★2026-08-08(監査 X2-6、DESIGN §2.65)。捨てるだけでなく**理由と URL を残す**。
    /// 一覧の 401 も会話の 401 も `RootView` の `onUnauthorized` からここ1箇所に集まる
    /// ので、出所ごとに書く必要は無い —— どの画面で拒まれても、Tom にとっての意味は
    /// 「通っていた鍵が通らなくなった」で同じ。
    ///
    /// ★断りを書くのが Keychain を消すより**先**である事に意味が在る。逆にすると、
    /// 間で殺された電話は「鍵が無い + 断りも無い」= 直す前と同じ白紙に戻る。
    /// この順なら最悪でも「鍵が在る + 断りが残る」に落ち、それは上の
    /// `loadStoredCredentials()` が掃く。
    func clearCredentials() {
        let notice = SignOutNotice(reason: .keyRejected, baseURL: credentials?.baseURL)
        notices.save(notice)
        signOutNotice = notice
        try? store.clear()
        credentials = nil
    }
}
