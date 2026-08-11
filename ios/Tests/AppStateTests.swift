import XCTest
@testable import RemoteMini

/// DESIGN §2.65。401 で鍵を落とす時、`AppState` は**捨てるだけでなく理由を残す**。
///
/// 想定している誤実装と、それを落とす対照:
///
/// | 誤実装 | 落とす対照 |
/// |---|---|
/// | 401 で鍵だけ捨てて断りを残さない(直す前の姿) | ① |
/// | 断りに URL を入れ忘れる | ② |
/// | 断りを消す条件を「画面を見た」にする / 消し忘れる | ③ |
/// | 起動時に断りを読まない(ディスクに在るのに出ない) | ④ |
/// | 鍵が在るのに残った断りを掃かない | ⑤ |
/// | Keychain を消してから断りを書く(順序が逆) | ⑥ |
///
/// ★⑥は「どちらでも同じに見える」型の欠陥。順序が逆でも①〜⑤は全部緑になる ——
/// **間で殺された時にだけ**差が出るからで、その時に残るのが「鍵も断りも無い」= 直す前と
/// 同じ白紙。今の順序なら最悪でも「鍵が在る + 断りが残る」に落ち、それは⑤が掃く。
@MainActor
final class AppStateTests: XCTestCase {
    private static let url = URL(string: "https://example.invalid")!
    private static let creds = Credentials(baseURL: url, apiKey: "k")

    /// 事の**順序**まで見える偽物。`events` に起きた事を起きた順で積む。
    private final class Recorder {
        var events: [String] = []
    }

    /// ★組み立てはこの1本を通す(2026-08-11)。`AppState.init` の既定は**本物**
    /// (`BundleProvisioning` = 焼いた `Info.plist` / `UserDefaultsSeedLedger` = 開発機の
    /// `UserDefaults`)なので、既定のまま単体を書くと、`build.sh` で刻んだ機械の上でだけ
    /// 検査が本物の種を拾って別の筋道を通る —— 結果が「その機械で誰が最後に焼いたか」で
    /// 変わる検査は計器ではない。既定を安全側に固定するのは `AppState.forLaunch()` の
    /// fixture 分岐と同じ判断。
    private func makeState(store: CredentialStore,
                           notices: SignOutNoticeStoring,
                           provisioning: ProvisioningSource = NoProvisioning(),
                           seedLedger: SeedLedgerStoring = InMemorySeedLedger()) -> AppState {
        AppState(store: store, notices: notices, provisioning: provisioning, seedLedger: seedLedger)
    }

    /// 焼き込みの種を1つ持つ口。
    private struct FakeProvisioning: ProvisioningSource {
        var seed: Credentials?
    }

    /// 蒔いた記録。書かれた順を `Recorder` に載せる(順序を見る対照が要る)。
    private final class RecordingSeedLedger: SeedLedgerStoring {
        private var digest: String?
        private let recorder: Recorder

        init(plantedSeedDigest: String? = nil, recorder: Recorder = Recorder()) {
            self.digest = plantedSeedDigest
            self.recorder = recorder
        }

        var plantedSeedDigest: String? {
            get { digest }
            set {
                digest = newValue
                recorder.events.append("ledger-written")
            }
        }
    }

    private final class FakeCredentialStore: CredentialStore {
        private var stored: Credentials?
        private let recorder: Recorder
        var clearThrows = false

        /// Keychain が**読めない**時。`nil`(空)と同じ物にしないのが此の旗の全部。
        var loadThrows = false

        /// Keychain へ**書けない**時。種を蒔く側だけが使う —— 書けなかった種に
        /// 「蒔いた」の記録を付けると、次の起動で欄が出る(`plantSeedIfNeeded` の doc)。
        var saveThrows = false

        init(stored: Credentials? = nil, recorder: Recorder = Recorder()) {
            self.stored = stored
            self.recorder = recorder
        }

        func load() throws -> Credentials? {
            if loadThrows { throw KeychainError.unexpectedStatus(-25300) }
            return stored
        }

        func save(_ credentials: Credentials) throws {
            if saveThrows { throw KeychainError.unexpectedStatus(-25299) }
            stored = credentials
            recorder.events.append("keychain-saved")
        }

        func clear() throws {
            recorder.events.append("keychain-cleared")
            if clearThrows { throw KeychainError.unexpectedStatus(-1) }
            stored = nil
        }
    }

    private final class RecordingNoticeStore: SignOutNoticeStoring {
        private var notice: SignOutNotice?
        private let recorder: Recorder

        init(notice: SignOutNotice? = nil, recorder: Recorder = Recorder()) {
            self.notice = notice
            self.recorder = recorder
        }

        func load() -> SignOutNotice? { notice }

        func save(_ notice: SignOutNotice?) {
            self.notice = notice
            recorder.events.append(notice == nil ? "notice-cleared" : "notice-saved")
        }
    }

    /// ★① 401 で鍵は消え、断りが残る。直す前の実装(捨てるだけ)を落とす。
    func testA401LeavesAReasonBehindRatherThanJustDroppingTheKey() {
        let notices = RecordingNoticeStore()
        let state = makeState(store:FakeCredentialStore(stored: Self.creds), notices: notices)
        state.setCredentials(Self.creds)

        state.clearCredentials()

        XCTAssertNil(state.credentials, "鍵は落ちる(此処は元からの契約)")
        XCTAssertEqual(state.signOutNotice?.reason, .keyRejected,
                       "★理由を残さない実装を落とす(白紙の鍵画面に戻る)")
        XCTAssertEqual(notices.load()?.reason, .keyRejected,
                       "★memory だけに置く実装を落とす(殺されたら消える)")
    }

    /// ② 断りは、拒まれた時に使っていた URL を持って行く。
    func testTheNoticeCarriesTheURLThatWasBeingUsed() {
        let state = makeState(store:FakeCredentialStore(stored: Self.creds),
                             notices: RecordingNoticeStore())
        state.setCredentials(Self.creds)

        state.clearCredentials()

        XCTAssertEqual(state.signOutNotice?.baseURL, Self.url)
    }

    /// ★③ 断りが消えるのは**接続に成功した時**。
    func testASuccessfulConnectionClearsTheNotice() {
        let notices = RecordingNoticeStore(notice: SignOutNotice(reason: .keyRejected, baseURL: Self.url))
        let state = makeState(store:FakeCredentialStore(), notices: notices)

        // ★錨。下の2本は「無い」しか言わないので、種が置けていなくても緑になる
        // (vacuous-scan の言う「前提が壊れても赤くならない検査」)。掃く対象が
        // 実際に在った事を、同じ口(`notices.load()`)で先に固定する。
        XCTAssertEqual(notices.load()?.baseURL, Self.url, "前提: 掃く対象が実際に在る")

        state.setCredentials(Self.creds)

        XCTAssertNil(state.signOutNotice)
        XCTAssertNil(notices.load(), "★画面から消すだけの実装を落とす(次に開くとまた出る)")
    }

    /// ④ 起動時、鍵が無ければディスクの断りを出す。
    ///
    /// これが此の器の主目的の筋道 —— 「断りを読む → 鍵を探しに別の app へ行く →
    /// iOS に殺される → 戻る」。戻った電話が通るのが此処。
    func testOnLaunchWithoutCredentialsTheStoredNoticeIsSurfaced() async {
        let notices = RecordingNoticeStore(notice: SignOutNotice(reason: .keyRejected, baseURL: Self.url))
        let state = makeState(store:FakeCredentialStore(stored: nil), notices: notices)

        await state.loadStoredCredentials()

        XCTAssertEqual(state.signOutNotice?.baseURL, Self.url,
                       "★起動時に読まない実装を落とす(書いてあるのに出ない)")
        XCTAssertFalse(state.isLoadingCredentials)
    }

    /// ★⑤ 鍵が在るのに断りが残っていたら掃く。
    ///
    /// これは `clearCredentials()` の途中(断りを書いた後、Keychain を消す前)で
    /// 殺された痕。この電話は鍵入力画面へ行かないので断りを出す先が無く、放っておくと
    /// **次に本当に落とされた時の断り**と区別が付かなくなる。
    func testAStaleNoticeIsSweptWhenCredentialsAreStillThere() async {
        let notices = RecordingNoticeStore(notice: SignOutNotice(reason: .keyRejected, baseURL: Self.url))
        let state = makeState(store:FakeCredentialStore(stored: Self.creds), notices: notices)

        await state.loadStoredCredentials()

        XCTAssertNotNil(state.credentials)
        XCTAssertNil(state.signOutNotice)
        XCTAssertNil(notices.load(), "★掃かない実装を落とす(古い断りが次の断りに化ける)")
    }

    /// ★⑥ 断りを書くのが Keychain を消すより**先**。
    ///
    /// 順序が逆でも①〜⑤は全部緑になる。差が出るのは間で殺された時だけで、逆順だと
    /// 「鍵も断りも無い」= 直す前と同じ白紙が残り、⑤の掃除でも救えない(記録が無い)。
    /// だから起きた順そのものを見る。
    func testTheNoticeIsWrittenBeforeTheKeychainIsCleared() {
        let recorder = Recorder()
        let state = makeState(store:FakeCredentialStore(stored: Self.creds, recorder: recorder),
                             notices: RecordingNoticeStore(recorder: recorder))
        state.setCredentials(Self.creds)
        recorder.events.removeAll()

        state.clearCredentials()

        XCTAssertEqual(recorder.events, ["notice-saved", "keychain-cleared"],
                       "★逆順の実装を落とす(間で殺されると理由ごと消える)")
    }

    /// ⑦ Keychain の消去が失敗しても、断りと memory 上の鍵の扱いは変わらない。
    ///
    /// `try?` で握り潰しているのは元からの設計(サーバが拒んだ鍵を使い続けない方が
    /// 大事)。そこに断りを載せた事で、失敗経路だけ理由が消えていないかを見る。
    func testAFailingKeychainClearStillLeavesTheReasonBehind() {
        let store = FakeCredentialStore(stored: Self.creds)
        store.clearThrows = true
        let state = makeState(store:store, notices: RecordingNoticeStore())
        state.setCredentials(Self.creds)

        state.clearCredentials()

        XCTAssertNil(state.credentials)
        XCTAssertEqual(state.signOutNotice?.reason, .keyRejected)
    }

    // MARK: - 焼き込みの種(2026-08-11)
    //
    // ★此処から下が「初回起動が鍵の入力欄だった」欠陥の対照。想定している誤実装:
    //
    // | 誤実装 | 落とす対照 |
    // |---|---|
    // | 種を蒔かない(直す前の姿 = 打つ画面から始まる) | ⑧ |
    // | Keychain に保存せず memory にだけ載せる(次の起動でまた打たされる) | ⑧ |
    // | 既に在る鍵を種で上書きする | ⑨ |
    // | 401 で落とした鍵と同じ種を蒔き直す(拒否と断りの間で回る) | ⑩ |
    // | 「一度蒔いた」旗1本で塞ぐ(鍵を回して焼き直しても二度と入らない) | ⑪ |
    // | Keychain が読めない起動を「空」と読んで手入力の鍵を潰す | ⑫ |
    // | 刻印が無いのに何かを蒔く / 蒔けずに固まる | ⑬ |
    // | 記録を書いてから保存する(書けなかった種を蒔いた事にする) | ⑭ |
    // | 保存の失敗を握り潰して記録だけ付ける(次の起動で欄が出る) | ⑮ |

    /// ★⑧ 鍵の無い電話が、打たずに一覧へ着く。**この直しの本体**。
    func testAnEmptyKeychainIsSeededFromTheStampSoTheFirstScreenIsNotTheForm() async {
        let store = FakeCredentialStore(stored: nil)
        let state = makeState(store: store,
                              notices: RecordingNoticeStore(),
                              provisioning: FakeProvisioning(seed: Self.creds))

        await state.loadStoredCredentials()

        XCTAssertEqual(state.credentials, Self.creds,
                       "★種を蒔かない実装を落とす(初回起動が Base URL と API Key の入力欄になる)")
        XCTAssertNil(state.signOutNotice, "初回の顔に断りは付かない")
        let persisted = try? store.load()
        XCTAssertEqual(persisted, Self.creds,
                       "★memory にだけ載せる実装を落とす(次の起動でまた打たされる)")
    }

    /// ⑨ 既に鍵が在る電話は、種で上書きされない。
    func testAnExistingKeyIsNeverOverwrittenByTheStamp() async {
        let typed = Credentials(baseURL: URL(string: "https://typed.invalid")!, apiKey: "typed")
        let state = makeState(store: FakeCredentialStore(stored: typed),
                              notices: RecordingNoticeStore(),
                              provisioning: FakeProvisioning(seed: Self.creds))

        await state.loadStoredCredentials()

        XCTAssertEqual(state.credentials, typed, "★手で入れた鍵を種が踏む実装を落とす")
    }

    /// ★⑩ 401 で落とした後の起動は、同じ種を蒔き直さない。
    ///
    /// 蒔き直すと、電話は「拒まれる鍵で 401 → 断り → 起動 → また同じ鍵」で回り続け、
    /// **Tom が唯一持っている説明(断り)が毎回上書きされて消える**。
    func testARejectedSeedIsNotPlantedAgainOnTheNextLaunch() async {
        let ledger = InMemorySeedLedger()
        let provisioning = FakeProvisioning(seed: Self.creds)
        let store = FakeCredentialStore(stored: nil)
        let notices = RecordingNoticeStore()

        // 1回目の起動 → 蒔かれる。
        let first = makeState(store: store, notices: notices, provisioning: provisioning, seedLedger: ledger)
        await first.loadStoredCredentials()
        XCTAssertNotNil(first.credentials, "前提: 1回目は蒔けている")

        // サーバが 401 を返した。
        first.clearCredentials()

        // 2回目の起動(同じ束・同じ記録)。
        let second = makeState(store: store, notices: notices, provisioning: provisioning, seedLedger: ledger)
        await second.loadStoredCredentials()

        XCTAssertNil(second.credentials, "★拒まれた種を蒔き直す実装を落とす(輪から出られなくなる)")
        XCTAssertEqual(second.signOutNotice?.reason, .keyRejected,
                       "断りが残り、鍵入力画面が理由を持って出る")
    }

    /// ★⑪ 机で鍵を回して焼き直した**別の**種は蒔ける。
    ///
    /// これが渡米中に鍵が変わった時の唯一の復旧路。「一度蒔いた」旗1本で塞ぐ実装だと、
    /// 焼き直した電話が二度と自動では入れず、手入力しか残らない。
    func testANewStampAfterAKeyRotationIsPlanted() async {
        let ledger = InMemorySeedLedger(plantedSeedDigest: SeedDigest.of(Self.creds))
        let rotated = Credentials(baseURL: Self.url, apiKey: "rotated")

        let state = makeState(store: FakeCredentialStore(stored: nil),
                              notices: RecordingNoticeStore(),
                              provisioning: FakeProvisioning(seed: rotated),
                              seedLedger: ledger)

        await state.loadStoredCredentials()

        XCTAssertEqual(state.credentials, rotated,
                       "★旗1本で塞ぐ実装を落とす(鍵を回したら渡米先で入れなくなる)")
        XCTAssertEqual(ledger.plantedSeedDigest, SeedDigest.of(rotated))
    }

    /// ★⑫ Keychain が**読めない**起動では何も蒔かない。
    ///
    /// 元の `try? store.load()` は「読めなかった」を `nil` に潰していた。潰したまま
    /// 種を蒔くと、一時的に読めない1回の起動で **Tom が手で入れた鍵が種に置き換わる**。
    /// 読めない時は何もしないのが正しい(次の起動で読めれば元に戻る)。
    func testAnUnreadableKeychainIsNotTreatedAsEmpty() async {
        let store = FakeCredentialStore(stored: nil)
        store.loadThrows = true
        let ledger = InMemorySeedLedger()

        let state = makeState(store: store,
                              notices: RecordingNoticeStore(),
                              provisioning: FakeProvisioning(seed: Self.creds),
                              seedLedger: ledger)

        await state.loadStoredCredentials()

        XCTAssertNil(state.credentials, "★読めない金庫を空と読む実装を落とす")
        XCTAssertNil(ledger.plantedSeedDigest, "蒔いていないので記録も付かない(次の起動で蒔ける)")
        XCTAssertFalse(state.isLoadingCredentials)
    }

    /// ⑬ 刻印が無い焼き方(simulator / 対照)は今まで通り鍵入力画面へ。
    func testWithoutAStampNothingChanges() async {
        let ledger = InMemorySeedLedger()
        let state = makeState(store: FakeCredentialStore(stored: nil),
                              notices: RecordingNoticeStore(),
                              provisioning: NoProvisioning(),
                              seedLedger: ledger)

        await state.loadStoredCredentials()

        XCTAssertNil(state.credentials)
        XCTAssertNil(ledger.plantedSeedDigest)
    }

    /// ★⑭ 記録を付けるのは Keychain へ書いた**後**。
    ///
    /// 逆順だと、保存に失敗した種を「蒔いた」と記録して二度と蒔かなくなる。
    /// この順なら、間で殺されても次の起動で同じ値をもう一度書くだけ(冪等)。
    ///
    /// 3つ目の `notice-cleared` は実測(2026-08-11)で現れた本物の3手目 —— 種が入って
    /// 資格情報が載った起動は、鍵入力画面へ行かないので**出す先の無い断りを掃く**
    /// (`loadStoredCredentials()` の else 側)。鍵を回して焼き直した電話が、消えた鍵に
    /// ついての古い断りを持ち回らないのが此の1手。列ごと固定するのは、間に4手目が
    /// 生えた日も落とす為。
    func testTheLedgerIsWrittenAfterTheKeychain() async {
        let recorder = Recorder()
        let state = makeState(store: FakeCredentialStore(stored: nil, recorder: recorder),
                              notices: RecordingNoticeStore(recorder: recorder),
                              provisioning: FakeProvisioning(seed: Self.creds),
                              seedLedger: RecordingSeedLedger(recorder: recorder))

        await state.loadStoredCredentials()

        XCTAssertEqual(recorder.events, ["keychain-saved", "ledger-written", "notice-cleared"],
                       "★逆順の実装を落とす(書けなかった種を蒔いた事にする)")
    }

    /// ★⑮ Keychain へ**書けなかった**種には記録を付けない。
    ///
    /// ⑭ は「順序」を見ている。此処が見るのは**握り潰し**の方 —— 保存が throw した時、
    /// 順序が正しくても `try?` で素通りすれば記録は付く。付いた瞬間、次の起動は
    /// 「もう蒔いた」と読んで種を蒔かず、Keychain は空のままなので**鍵の入力欄が出る**
    /// (= #64 が直しに来た形が、一度きりの保存失敗で復活する)。
    ///
    /// 此の起動を memory の資格情報で通すのは変えない(`KeyEntryViewModel.submit()` が
    /// Keychain の失敗を握り潰すのと同じ判断)。変えるのは記録の側だけ。
    func testASeedThatCouldNotBeSavedIsNotRecordedAsPlanted() async {
        let recorder = Recorder()
        let store = FakeCredentialStore(stored: nil, recorder: recorder)
        store.saveThrows = true
        let ledger = InMemorySeedLedger()

        let state = makeState(store: store,
                              notices: RecordingNoticeStore(recorder: recorder),
                              provisioning: FakeProvisioning(seed: Self.creds),
                              seedLedger: ledger)

        await state.loadStoredCredentials()

        XCTAssertEqual(state.credentials, Self.creds,
                       "書けない事は使えない事ではない —— 此の起動は通る")
        XCTAssertNil(ledger.plantedSeedDigest,
                     "★保存の失敗を握り潰して記録だけ付ける実装を落とす(次の起動で欄が出る)")
        XCTAssertFalse(recorder.events.contains("keychain-saved"),
                       "前提: 保存は本当に失敗している(検査が空振りしていない)")

        // 次の起動。記録が付いていないので、同じ種をもう一度蒔ける。
        store.saveThrows = false
        let second = makeState(store: store,
                               notices: RecordingNoticeStore(recorder: recorder),
                               provisioning: FakeProvisioning(seed: Self.creds),
                               seedLedger: ledger)
        await second.loadStoredCredentials()

        XCTAssertEqual(try? store.load(), Self.creds, "2回目で Keychain に載る")
        XCTAssertEqual(ledger.plantedSeedDigest, SeedDigest.of(Self.creds))
    }
}
