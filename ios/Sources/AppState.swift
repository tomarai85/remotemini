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

    /// 資格情報が**無い**時、なぜ無いか。在る間は `nil`(DESIGN §2.100)。
    ///
    /// ★`SignOutNotice` を置き換える物ではない。あちらは 401 を**跨いで disk に残る**
    /// 事実(理由 + URL)で、此方は**今回の起動の観測**を4通りに畳んだ物。断りだけでは
    /// 「束に種が無い」「金庫が読めない」の2つが名乗れず、其の2つが正に 2026-08-15 に
    /// Tom が白紙のフォームとして読んだ状態だった。
    @Published private(set) var disconnected: DisconnectedReason?

    /// 鍵入力画面へ落ちる道は4本在って、**次の一手が全部違う**(DESIGN §2.100)。
    /// 器は意味だけを運び、文言は持たない —— 文を決めるのは画面
    /// (`SignOutNotice.Reason` と同じ役割分担)。
    enum DisconnectedReason: Equatable {
        /// 束が接続先を持たずに焼かれている。`RC_NO_SEED=1` の焼き方と、
        /// `shots.sh` の様に `build.sh` の刻む段を通らない焼き方が此処へ来る。
        /// **2026-08-15 に Tom が見た白紙のフォームは此れだった**(束の `Info.plist` に
        /// `RCBaseURL` が無い事を実測)。名乗っていれば其の場で「焼き方が違う」と判った。
        case seedAbsent

        /// 焼き込まれた種を机が 401 で拒んだ。台帳(`SeedLedgerStoring`)が同じ種を
        /// 蒔き直さない様に止めている状態。
        case seedRejected

        /// Keychain が読めない起動。**種も蒔いていない**(読めない時に蒔くと、手で
        /// 入れた鍵を種が上書きする)。次の起動で読めれば黙って戻る。
        case storeUnreadable

        /// 通っていた鍵が拒まれた(`SignOutNotice`)。手で入れ直すのが唯一の道。
        case keyRejected

        /// 説明が付かない組み合わせ。**到達しない筈**だが、到達した時に嘘の理由を
        /// 名乗らない為に置く —— `build.sh` の `build_rev` が「判らなかった事を
        /// 『汚れている』と言い換えない」為に持っている枠と同じ趣旨。
        case unexplained
    }

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

        // ★拒まれた鍵が金庫に残っている電話を掃く。`clearCredentials(rejected:)` は
        //   台帳へ書いた**後**に金庫を消すので、間で殺されると此の形で残る。掃かずに
        //   使うと、起動する度に 401 を貰って断りが出る電話になる(拒否は覚えているのに
        //   拒まれた鍵で繋ぎに行く、という一番説明の付かない状態)。
        if let value = stored, SeedDigest.of(value) == seedLedger.rejectedSeedDigest {
            try? store.clear()
            stored = nil
        }

        if stored == nil && storeIsReadable {
            stored = plantSeedIfNeeded()
        }

        // ★何故此処に計器が要るか(2026-08-15)。此の関数が鍵入力画面を出すに至る道は
        //   4本在って(金庫が読めない / 種が無い / 台帳が同じ種を止めた / 蒔いたが載らない)、
        //   **画面はどの道を通ったかを一文字も名乗らない**。2026-08-15 に Tom が撮った
        //   欄はまさに此れで、束の中に種が在る事を確かめた後でも、外から見て道が絞れず
        //   台帳を手で消して起動し直す所まで行った。値は出さない —— 出すのは
        //   「在ったか/読めたか」の真偽だけで、鍵も URL も此処には現れない。
        #if DEBUG
        print("seed path: bundled=\(provisioning.seed != nil)"
            + " storeReadable=\(storeIsReadable)"
            + " rejected=\(seedLedger.rejectedSeedDigest == nil ? "empty" : "set")"
            + " resolved=\(stored != nil)")
        #endif

        credentials = stored
        if credentials == nil {
            signOutNotice = notices.load()
            disconnected = Self.disconnectedReason(storeIsReadable: storeIsReadable,
                                                   seed: provisioning.seed,
                                                   rejectedSeedDigest: seedLedger.rejectedSeedDigest,
                                                   notice: signOutNotice)
        } else {
            disconnected = nil
            // ★鍵が在るのに断りが残っているのは、`clearCredentials()` の途中で殺された痕
            //   (断りを書いた直後、Keychain を消す前)。この電話は鍵入力画面へ行かないので
            //   出す先が無く、放っておくと**次に本当に落ちた時の断り**と見分けが付かなくなる。
            notices.save(nil)
            signOutNotice = nil
        }
        isLoadingCredentials = false
    }

    /// なぜ鍵が無いかを4通りに畳む。**純関数**にしてあるのは `KeyEntryView.sentence(for:)` と
    /// 同じ理由で、`loadStoredCredentials()` の中に書くと判定の規則なのに検査から触れず、
    /// 「画面に出た文」からしか確かめられなくなるから。
    ///
    /// ★順番に意味が在る。上から順に**具体的な方**が勝つ:
    /// 1. 金庫が読めない起動は他の全部の判定が当てにならない(種も蒔いていない)。
    /// 2. 束の種が拒まれている形は、断りより具体的(次の一手が「机で鍵を戻す」になる)。
    /// 3. 断りは「通っていた鍵が通らなくなった」= 直近に起きた事実。
    /// 4. 残るのは「そもそも接続先を持たずに焼かれた束」。
    ///
    /// ★最後の `.unexplained` は**到達しない筈**の枠。種が在り、拒まれておらず、金庫が
    /// 読める起動は `plantSeedIfNeeded()` が必ず値を返すので此処へは来ない。それでも
    /// 置くのは、来た時に「接続先を持たずに焼かれた」と**嘘を名乗らせない**為。
    static func disconnectedReason(storeIsReadable: Bool,
                                   seed: Credentials?,
                                   rejectedSeedDigest: String?,
                                   notice: SignOutNotice?) -> DisconnectedReason {
        if !storeIsReadable { return .storeUnreadable }
        if let seed, rejectedSeedDigest == SeedDigest.of(seed) { return .seedRejected }
        if notice != nil { return .keyRejected }
        if seed == nil { return .seedAbsent }
        return .unexplained
    }

    /// 「机で鍵を戻した」時の再試行。**拒否の記録だけ**を降ろして読み直す。
    ///
    /// ★何を消して、何を消さないか。消すのは台帳の指紋1本で、金庫は触らない ——
    /// 金庫はこの時点で既に空(`clearCredentials` が消した)なので、消す物が無い。
    /// 断り(`SignOutNotice`)も消さない: 断りが消えるのは**接続が成功した時だけ**という
    /// 規則(`SignOutNoticeStoring.save` の doc)を、押した事で破らない。
    ///
    /// ★輪にならないのは、押すのが人だから。同じ拒否鍵のまま押せば 401 をもう一度貰って
    /// 台帳が書き直されるだけで、機械が勝手に回り続ける形にはならない。
    func retryWithBundledSeed() async {
        seedLedger.rejectedSeedDigest = nil
        isLoadingCredentials = true
        await loadStoredCredentials()
    }

    /// **机が引っ越した時の逃げ道**(2026-08-27 新設)。金庫の中身を捨てて、束に焼かれた
    /// 種を蒔き直す。
    ///
    /// ★なぜ要るか(実機で詰んだ形): 金庫には旧版が蒔いた `edith` の宛先が残っていた。
    ///   edith は 2026-08-20 に譲渡されて存在しない。`loadStoredCredentials()` は
    ///   **空の時だけ**種を蒔くので、新しい種は永久に無視され、電話は消えた機体へ
    ///   話しかけ続ける。実測: `URLError(-1001) host=desk.tailnet.example`。
    ///   アプリを消して入れ直しても直らない —— iOS の Keychain は削除を跨いで生き残る。
    ///   そして**アプリには宛先を変える手段が1つも無かった**。それが本当の欠陥。
    ///
    /// ★暗黙には絶対にやらない。「手で入れた鍵を種が踏まない」は意図的な不変条件で
    ///   (`AppStateTests.testAnExistingKeyIsNeverOverwrittenByTheStamp`)、URL の違いだけを
    ///   根拠に自動で上書きするとその守りが消える。**人が押した時にだけ**走らせる。
    /// **届かなかった時にだけ**自動で乗り換える。起動時の暗黙上書きとは別物:
    /// 「保存された宛先が実際に応答しない」+「束に別の宛先が焼かれている」の
    /// 2つが揃った時だけ走る。片方でも欠けたら何もしない。
    ///
    /// ★起動時に URL の違いだけで上書きしないのは意図的な不変条件
    /// (`testAnExistingKeyIsNeverOverwrittenByTheStamp`)。此処はその条件を満たさない ——
    /// 手で入れた宛先でも、**現に届いていない**なら、束の宛先を試す方が
    /// 「詰んだまま何も出来ない」より良い。乗り換えても駄目なら1回で止まる(呼ぶ側が1回だけ呼ぶ)。
    func reseedIfDeskMoved() async {
        guard let seed = provisioning.seed, let have = credentials,
              have.baseURL != seed.baseURL else { return }
        print("desk moved: stored address did not answer, switching to the baked one")
        await reseedFromBundle()
    }

    func reseedFromBundle() async {
        guard provisioning.seed != nil else { return }
        try? store.clear()
        seedLedger.rejectedSeedDigest = nil
        notices.save(nil)
        isLoadingCredentials = true
        await loadStoredCredentials()
    }

    /// 金庫が読めなかった起動の再試行。観測をやり直すだけで、状態は一つも変えない。
    func reloadStoredCredentials() async {
        isLoadingCredentials = true
        await loadStoredCredentials()
    }

    /// 焼き込まれた種を蒔く。蒔いたら `credentials` に載せて返す。
    ///
    /// ★止めるのは「一度蒔いた種」ではなく**「机が拒んだ種」**(2026-08-15 に反転させた。
    /// 理由の観測値は `SeedLedgerStoring` の doc)。401 で落とした鍵をまた蒔けば電話は
    /// 拒まれる鍵と断りの間で回り続けるが、其の輪は拒否そのもので塞げる。「蒔いた」で
    /// 塞ぐと、金庫だけが独りで空になった電話(検査の後始末・端末の復元)が
    /// **鍵を打つまで戻れない**所に落ちる。
    ///
    /// ★判定を指紋で行うのは前と同じ。机で鍵を回して焼き直した**別の**種は蒔ける ——
    /// それが渡米中に鍵が変わった時の唯一の復旧路で、旗1本だと此処が塞がる。
    ///
    /// ★蒔いた事は**何処にも記録しない**。冪等なので記録が要らない(次の起動でも
    /// 金庫が空なら同じ値をもう一度書くだけ)。記録が無い = 台帳と金庫がずれる余地が無い。
    private func plantSeedIfNeeded() -> Credentials? {
        guard let seed = provisioning.seed else { return nil }
        guard seedLedger.rejectedSeedDigest != SeedDigest.of(seed) else { return nil }
        do {
            try store.save(seed)
        } catch {
            // 書けなくても此の起動は memory の資格情報で通す。`KeyEntryViewModel.submit()` が
            // Keychain の失敗を握り潰すのと同じ判断 —— 保存できない事は使えない事ではない。
            //
            // ★払った代償を隠さない: Keychain が**恒久的に**書けない電話は、起動の度に
            //   種を蒔き直す。鍵が 401 で拒まれていれば台帳が止めるので輪にはならないが、
            //   401 を貰う前の状態(= 断りも無い)では毎回書きに行って毎回失敗する。
            //   それでも此方を取るのは、恒久的に書けない電話では**手で打った鍵も保存できず**
            //   (`KeyEntryViewModel.submit()` も同じ握り潰し)、代わりに見せられるのは
            //   「打っても翌起動で消える欄」だから —— 直る見込みの無い欄より、毎回繋がる方が良い。
            return seed
        }
        return seed
    }

    /// 鍵入力画面が**繋がる事を確かめた後**にだけ呼ばれる(`KeyEntryViewModel.submit()` は
    /// `healthz` と `/api/sessions` の2段を通してから `onSaved` を呼ぶ)。
    /// = 此処に来た資格情報は「机が受け入れた」の観測値。
    func setCredentials(_ credentials: Credentials) {
        // 断りを消す条件は**接続の成功ただ一つ**。画面を見た事では消さない
        // (`SignOutNoticeStoring.save` の doc)。
        notices.save(nil)
        signOutNotice = nil
        // ★拒否の記録も同じ観測で降ろす。同じ値が今**通った**なら、拒否は過去の事実で
        //   あって今の状態ではない —— 残すと、机側で鍵を戻した日に種の道だけが
        //   塞がったままになる(打てば動くので、塞がっている事に気付く機会も無い)。
        if SeedDigest.of(credentials) == seedLedger.rejectedSeedDigest {
            seedLedger.rejectedSeedDigest = nil
        }
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
    /// `loadStoredCredentials()` が掃く。拒否の記録も同じ理由で金庫より先に書く。
    ///
    /// ★**何が拒まれたかを引数で受ける**(2026-08-15)。`self.credentials` を見て
    /// 書くと、既に別の鍵へ入れ替えた後に届いた**古い要求の 401** が、今使っている
    /// 鍵を拒否として記録する。要求は非同期に返るので、此れは有り得る順序であって
    /// 想像上の話ではない。今の鍵と一致しない 401 は**捨てる**のが正しい。
    ///
    /// ★記録するのは拒まれた鍵が**束の種と同じ**時だけ。手で打った鍵の拒否を
    /// 覚えても止める先が無く(蒔く経路は種しか通らない)、無関係な指紋が
    /// `UserDefaults` に残るだけになる。
    func clearCredentials(rejected: Credentials) {
        guard credentials == rejected else { return }
        let notice = SignOutNotice(reason: .keyRejected, baseURL: rejected.baseURL)
        notices.save(notice)
        if provisioning.seed == rejected {
            seedLedger.rejectedSeedDigest = SeedDigest.of(rejected)
        }
        signOutNotice = notice
        try? store.clear()
        credentials = nil
    }
}
