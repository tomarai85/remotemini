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
    private let provisioning: ProvisioningSource
    private let seedLedger: SeedLedgerStoring

    init(store: CredentialStore = KeychainCredentialStore(),
         notices: SignOutNoticeStoring = UserDefaultsSignOutNoticeStore(),
         provisioning: ProvisioningSource = BundleProvisioning(),
         seedLedger: SeedLedgerStoring = UserDefaultsSeedLedger()) {
        self.store = store
        self.notices = notices
        self.provisioning = provisioning
        self.seedLedger = seedLedger
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
        // 焼いた種を**握らせる**面。初回起動が一覧に着く事を測る唯一の口で、
        // 本物の刻印は使わない(`ios/Sources/Core/ProvisioningFixture.swift`)。
        if let fixture = ProvisioningFixture.fromEnvironment() {
            return AppState(store: InMemoryCredentialStore(),
                            notices: InMemorySignOutNoticeStore(),
                            provisioning: fixture,
                            seedLedger: InMemorySeedLedger())
        }
        if let fixture = SignOutNoticeFixture.fromEnvironment() {
            return AppState(store: NoStoredCredentials(),
                            notices: InMemorySignOutNoticeStore(notice: fixture.notice),
                            provisioning: NoProvisioning(),
                            seedLedger: InMemorySeedLedger())
        }
        // 断りは付かない面(初回の顔)だが、鍵を持たない金庫を渡すのは同じ。
        // 本物の `KeychainCredentialStore` のままだと、開発機に資格情報が残っている日は
        // `loadStoredCredentials()` がそれを拾って**一覧画面**が出る —— 鍵入力画面を
        // 撮りに来た検査が、機械の状態次第で別の画面を撮る事になる。
        // `ios/Sources/Core/KeyEntryProbeFixture.swift`。
        if KeyEntryProbeFixture.fromEnvironment() != nil {
            return AppState(store: NoStoredCredentials(),
                            notices: InMemorySignOutNoticeStore(),
                            provisioning: NoProvisioning(),
                            seedLedger: InMemorySeedLedger())
        }
        #endif
        return AppState()
    }

    /// ★鍵入力画面を経由せずに資格情報が入る唯一の筋道が此処(2026-08-11)。
    ///
    /// 順序に意味が在る:
    /// 1. Keychain を読む。**読めなかった**(throw)と**空だった**(nil)を分ける。
    /// 2. 空だった時にだけ、焼き込まれた種を蒔く。
    ///
    /// ★1 を分けるのが此の直しで一番危ない所。元は `try? store.load()` で、
    /// 「読めなかった」も `nil` に潰れていた。潰したまま種を蒔く実装にすると、
    /// Keychain が一時的に読めない起動で **Tom が手で入れた鍵を焼き込みの種が
    /// 上書きする**。読めない時は何もしないのが正しい —— 次の起動で読めれば元に戻る。
    func loadStoredCredentials() async {
        var stored: Credentials?
        var storeIsReadable = true
        do {
            stored = try store.load()
        } catch {
            storeIsReadable = false
        }

        if stored == nil && storeIsReadable {
            stored = plantSeedIfNeeded()
        }

        credentials = stored
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

    /// 焼き込まれた種を1回だけ蒔く。蒔いたら `credentials` に載せて返す。
    ///
    /// ★「1回だけ」の判定は**種の指紋**で行う(`SeedLedgerStoring` の doc に、
    /// 断りを門にした最初の設計を捨てた理由が在る)。同じ種は二度蒔かない ——
    /// 401 で落とした鍵をまた蒔けば、電話は拒まれる鍵と断りの間で回り続ける。
    /// 逆に、机で鍵を回して焼き直した**別の**種は蒔ける。それが渡米中に鍵が変わった
    /// 時の唯一の復旧路で、旗1本の「もう蒔いた」だと此処が塞がる。
    ///
    /// ★記録は Keychain へ書いた**後**に付ける。間で殺されても次の起動で同じ値を
    /// もう一度書くだけ(冪等)。逆順にすると、書けなかった種を「蒔いた」と記録して
    /// 二度と蒔かなくなる。
    private func plantSeedIfNeeded() -> Credentials? {
        guard let seed = provisioning.seed else { return nil }
        let digest = SeedDigest.of(seed)
        guard seedLedger.plantedSeedDigest != digest else { return nil }
        do {
            try store.save(seed)
        } catch {
            // 書けなくても此の起動は memory の資格情報で通す。`KeyEntryViewModel.submit()` が
            // Keychain の失敗を握り潰すのと同じ判断 —— 保存できない事は使えない事ではない。
            // ★但し記録は付けない。上の doc が言っている通り、書けなかった種を「蒔いた」と
            //   記録すると次の起動で二度と蒔かず、**欄が出る**(= 此の #64 が直しに来た形)。
            //   `try?` で握り潰していた頃は此処を素通りして記録が付いていた(2026-08-11 に是正)。
            //
            // ★払った代償を隠さない: Keychain が**恒久的に**書けない上に鍵が 401 で拒まれる、
            //   の両方が同時に起きた電話は、起動の度に種を蒔き直す(記録が付かないので)。
            //   断りは其の起動の中では画面に出るが、次の起動で掃かれて残らない。
            //   それでも此方を取るのは、恒久的に書けない電話では**手で打った鍵も保存できず**
            //   (`KeyEntryViewModel.submit()` も同じ握り潰し)、旧実装が代わりに見せるのは
            //   「打っても翌起動で消える欄」だから —— 直る見込みの無い欄より、毎回繋がる方が良い。
            //   一過性の失敗(此方が普通)では、次の起動で書けて記録も付き、輪は1回で閉じる。
            return seed
        }
        seedLedger.plantedSeedDigest = digest
        return seed
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
