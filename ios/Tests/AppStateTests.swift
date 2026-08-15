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

    /// 拒否の記録。書かれた順を `Recorder` に載せる(順序を見る対照が要る)。
    /// 消す側も別の名前で積むのは `RecordingNoticeStore` と同じ流儀 —— 「書いた」と
    /// 「降ろした」が同じ文字列だと、⑳が緑になったまま `nil` 代入を取り違える。
    private final class RecordingSeedLedger: SeedLedgerStoring {
        private var digest: String?
        private let recorder: Recorder

        init(rejectedSeedDigest: String? = nil, recorder: Recorder = Recorder()) {
            self.digest = rejectedSeedDigest
            self.recorder = recorder
        }

        var rejectedSeedDigest: String? {
            get { digest }
            set {
                digest = newValue
                recorder.events.append(newValue == nil ? "ledger-cleared" : "ledger-written")
            }
        }
    }

    private final class FakeCredentialStore: CredentialStore {
        private var stored: Credentials?
        private let recorder: Recorder
        var clearThrows = false

        /// Keychain が**読めない**時。`nil`(空)と同じ物にしないのが此の旗の全部。
        var loadThrows = false

        /// Keychain へ**書けない**時。種を蒔く側だけが使う —— 書けなくても此の起動は
        /// 通り、次の起動でもう一度同じ値を書きに行く(`plantSeedIfNeeded` の doc)。
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

        /// アプリを**通さずに** Keychain の項目が消える。`clear()` と違って
        /// `recorder` に何も積まないのが此の関数の全部 —— 消えた事をアプリは
        /// 知らないし、拒否が在った証拠もどこにも残らない。
        /// 実在する経路2本を模す(⑯):
        ///   - simulator: `ios/Tests/Core/KeychainCredentialStoreTests.swift` の
        ///     `tearDownWithError` が**本物の** Keychain を同じ service/account で消す。
        ///     simulator の Keychain は端末ごとに共有なので、検査を回す度に消える。
        ///   - 実機: 暗号化なしバックアップからの復元は `UserDefaults` を戻すが
        ///     Keychain 項目は戻さない。
        func wipeOutOfBand() {
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

        state.clearCredentials(rejected: Self.creds)

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

        state.clearCredentials(rejected: Self.creds)

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

        state.clearCredentials(rejected: Self.creds)

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

        state.clearCredentials(rejected: Self.creds)

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
    // | 「一度拒まれた」旗1本で塞ぐ(鍵を回して焼き直しても二度と入らない) | ⑪ |
    // | Keychain が読めない起動を「空」と読んで手入力の鍵を潰す | ⑫ |
    // | 刻印が無いのに何かを蒔く / 蒔けずに固まる | ⑬ |
    // | 蒔いた事を台帳へ書く(金庫だけ独りで空になった電話が戻れなくなる) | ⑭ |
    // | 金庫を消してから拒否を記録する(間で殺されると輪に戻る) | ⑭-b |
    // | 一度きりの保存失敗を次の起動へ持ち越す | ⑮ |
    // | 拒否と無関係に金庫だけ消えた電話を、台帳が止め続ける | ⑯ |
    // | 入れ替えた**後**に届いた古い要求の 401 で、今の鍵を落とす / 記録する | ⑰ |
    // | 手で打った鍵の拒否まで台帳に書く(束の種と無関係な指紋が残る) | ⑱ |
    // | 拒まれたと覚えている鍵が金庫に残ったまま、それで繋ぎに行く | ⑲ |
    // | 同じ鍵が通った後も拒否を持ち続ける(種の道だけ塞がったまま) | ⑳ |
    //
    // ★2026-08-15、台帳が覚える物を「蒔いた種」から**「拒まれた種」**へ反転させた
    // (理由の観測値は `SeedLedgerStoring` の doc)。⑭/⑮ は其の反転で主張が変わった
    // 2本で、#56 までの主張(順序・記録の有無)は**もう欠陥ではない形**を測っていた。

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
        first.clearCredentials(rejected: Self.creds)

        // 2回目の起動(同じ束・同じ記録)。
        let second = makeState(store: store, notices: notices, provisioning: provisioning, seedLedger: ledger)
        await second.loadStoredCredentials()

        XCTAssertNil(second.credentials, "★拒まれた種を蒔き直す実装を落とす(輪から出られなくなる)")
        XCTAssertEqual(second.signOutNotice?.reason, .keyRejected,
                       "断りが残り、鍵入力画面が理由を持って出る")
    }

    /// ★⑪ 机で鍵を回して焼き直した**別の**種は蒔ける。
    ///
    /// これが渡米中に鍵が変わった時の唯一の復旧路。「一度拒まれた」旗1本で塞ぐ実装だと、
    /// 焼き直した電話が二度と自動では入れず、手入力しか残らない。
    func testANewStampAfterAKeyRotationIsPlanted() async {
        let ledger = InMemorySeedLedger(rejectedSeedDigest: SeedDigest.of(Self.creds))
        let rotated = Credentials(baseURL: Self.url, apiKey: "rotated")

        let state = makeState(store: FakeCredentialStore(stored: nil),
                              notices: RecordingNoticeStore(),
                              provisioning: FakeProvisioning(seed: rotated),
                              seedLedger: ledger)

        await state.loadStoredCredentials()

        XCTAssertEqual(state.credentials, rotated,
                       "★旗1本で塞ぐ実装を落とす(鍵を回したら渡米先で入れなくなる)")
        XCTAssertEqual(ledger.rejectedSeedDigest, SeedDigest.of(Self.creds),
                       "★蒔いた事を台帳に書き込む実装を落とす(拒否の記録が上書きで消える)")
    }

    /// ★⑫ Keychain が**読めない**起動では何も蒔かない。
    ///
    /// 元の `try? store.load()` は「読めなかった」を `nil` に潰していた。潰したまま
    /// 種を蒔くと、一時的に読めない1回の起動で **Tom が手で入れた鍵が種に置き換わる**。
    /// 読めない時は何もしないのが正しい(次の起動で読めれば元に戻る)。
    func testAnUnreadableKeychainIsNotTreatedAsEmpty() async {
        let recorder = Recorder()
        let store = FakeCredentialStore(stored: nil, recorder: recorder)
        store.loadThrows = true

        let state = makeState(store: store,
                              notices: RecordingNoticeStore(recorder: recorder),
                              provisioning: FakeProvisioning(seed: Self.creds))

        await state.loadStoredCredentials()

        XCTAssertNil(state.credentials, "★読めない金庫を空と読む実装を落とす")
        // ★台帳を見ても此処は測れない(2026-08-15 に反転させた後)。今の台帳は
        //   「拒まれた種」しか持たず、蒔いても一文字も動かない —— 蒔いた/蒔かないの
        //   差が出るのは**金庫への書き込み**だけなので、そこを見る。
        XCTAssertFalse(recorder.events.contains("keychain-saved"),
                       "★読めない金庫へ種を書きに行く実装を落とす(手入力の鍵が種に化ける)")
        XCTAssertFalse(state.isLoadingCredentials)
    }

    /// ⑬ 刻印が無い焼き方(simulator / 対照)は今まで通り鍵入力画面へ。
    func testWithoutAStampNothingChanges() async {
        let recorder = Recorder()
        let state = makeState(store: FakeCredentialStore(stored: nil, recorder: recorder),
                              notices: RecordingNoticeStore(recorder: recorder),
                              provisioning: NoProvisioning())

        await state.loadStoredCredentials()

        XCTAssertNil(state.credentials)
        XCTAssertTrue(recorder.events.isEmpty,
                      "種が無い起動は金庫も台帳も触らない(何かを蒔く/消す実装を落とす)")
    }

    /// ★⑭ 種を蒔く道は、台帳に**一文字も書かない**。
    ///
    /// #56 までは此処が「蒔いた種を記録する」検査で、順序(Keychain → 台帳)を固定して
    /// いた。2026-08-15 に記録する物を「拒まれた種」へ反転させた事で、**書く手その物が
    /// 消えた** —— 冪等だから記録が要らない(次の起動でも金庫が空なら同じ値を書くだけ)。
    ///
    /// 消えた手の検査を消すだけにすると、「蒔く時にも台帳を触る」実装へ戻る道が開く。
    /// 戻ると何が壊れるかは⑯が測っている(金庫だけが独りで空になった電話が、台帳の
    /// 記録に止められて鍵入力欄から出られない)。だから**触らない事**を此処で固定する。
    ///
    /// 2手目の `notice-cleared` は実測(2026-08-11)で現れた本物の手 —— 種が入って
    /// 資格情報が載った起動は、鍵入力画面へ行かないので**出す先の無い断りを掃く**
    /// (`loadStoredCredentials()` の else 側)。鍵を回して焼き直した電話が、消えた鍵に
    /// ついての古い断りを持ち回らないのが此の1手。列ごと固定するのは、間に3手目が
    /// 生えた日も落とす為。
    func testPlantingASeedDoesNotTouchTheLedger() async {
        let recorder = Recorder()
        let ledger = RecordingSeedLedger(recorder: recorder)
        let state = makeState(store: FakeCredentialStore(stored: nil, recorder: recorder),
                              notices: RecordingNoticeStore(recorder: recorder),
                              provisioning: FakeProvisioning(seed: Self.creds),
                              seedLedger: ledger)

        await state.loadStoredCredentials()

        XCTAssertEqual(recorder.events, ["keychain-saved", "notice-cleared"],
                       "★蒔いた事を台帳へ書く実装を落とす(金庫だけ消えた電話が二度と戻れない)")
        XCTAssertNil(ledger.rejectedSeedDigest, "拒否は起きていないので記録も無い")
    }

    /// ★⑭-b 拒否の記録は Keychain を消すより**先**。
    ///
    /// ⑥(断りが先)と同じ型の欠陥。順序が逆でも他は全部緑で、差が出るのは間で
    /// 殺された時だけ —— 逆順だと「金庫は空 + 拒否の記録は無い」に落ち、次の起動が
    /// **拒まれたばかりの同じ種を蒔き直す**。⑩が塞いだ輪が、殺され方1つで復活する。
    /// 今の順なら最悪でも「拒まれた鍵が金庫に残る + 記録は在る」で、それは
    /// `loadStoredCredentials()` の掃除(⑲)が拾う。
    func testTheRejectionIsRecordedBeforeTheKeychainIsCleared() {
        let recorder = Recorder()
        let state = makeState(store: FakeCredentialStore(stored: Self.creds, recorder: recorder),
                              notices: RecordingNoticeStore(recorder: recorder),
                              provisioning: FakeProvisioning(seed: Self.creds),
                              seedLedger: RecordingSeedLedger(recorder: recorder))
        state.setCredentials(Self.creds)
        recorder.events.removeAll()

        state.clearCredentials(rejected: Self.creds)

        XCTAssertEqual(recorder.events, ["notice-saved", "ledger-written", "keychain-cleared"],
                       "★金庫を消してから記録する実装を落とす(間で殺されると輪に戻る)")
    }

    /// ★⑮ Keychain へ**書けなかった**種は、次の起動でもう一度蒔かれる。
    ///
    /// ⑭ は「蒔く道が台帳を触らない」を見ている。此処が見るのは其の**帰結** ——
    /// 触らないから、一度きりの保存失敗が次の起動に持ち越されない。#56 の設計
    /// (蒔いた事を記録する)では、`try?` が保存の失敗を握り潰した瞬間に記録だけが付き、
    /// 次の起動は「もう蒔いた」と読んで蒔かず、Keychain は空のままなので**鍵の入力欄が
    /// 出る** —— 直しに来た形が、一度きりの保存失敗で復活していた。
    ///
    /// 此の起動を memory の資格情報で通すのも変えない(`KeyEntryViewModel.submit()` が
    /// Keychain の失敗を握り潰すのと同じ判断)。書けない事は使えない事ではない。
    func testASeedThatCouldNotBeSavedIsPlantedAgainOnTheNextLaunch() async {
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
        XCTAssertFalse(recorder.events.contains("keychain-saved"),
                       "前提: 保存は本当に失敗している(検査が空振りしていない)")
        XCTAssertNil(ledger.rejectedSeedDigest,
                     "保存の失敗は拒否ではない(401 でもないのに種の道を塞ぐ実装を落とす)")

        // 次の起動。記録が付いていないので、同じ種をもう一度蒔ける。
        store.saveThrows = false
        let second = makeState(store: store,
                               notices: RecordingNoticeStore(recorder: recorder),
                               provisioning: FakeProvisioning(seed: Self.creds),
                               seedLedger: ledger)
        await second.loadStoredCredentials()

        XCTAssertEqual(try? store.load(), Self.creds,
                       "★一度の保存失敗を持ち越す実装を落とす(2回目で Keychain に載る)")
        XCTAssertEqual(second.credentials, Self.creds)
    }

    /// ★⑯ 拒否と**無関係に** Keychain だけ消えた電話は、種を蒔き直して復帰する。
    ///
    /// ⑩ と対の検査。⑩ は「拒まれた種を蒔き直さない」、此処は「拒まれていない種は
    /// 蒔き直す」。2本一緒でないと、台帳が**何を根拠に**止めているかが固定されない ——
    /// ⑩ だけだと「Keychain が空 + 台帳に何か在る」で止める実装が緑になり、
    /// 其れが 2026-08-15 に観測した錠そのもの。
    ///
    /// ★何故此れが空想でないか。台帳の doc は「台帳と Keychain は入れ直しで一緒に
    /// 消える」を前提に置いていたが、偽だった。実在する2本は `wipeOutOfBand()` の doc。
    /// 実測(2026-08-15): 束の中に種が在り `storeReadable=true` で、台帳だけが `set` の
    /// 電話が、鍵入力画面から永久に出られなかった。回転以外に復帰路が無い。
    func testAKeychainThatLostItsItemWithoutARejectionIsSeededAgain() async {
        let ledger = InMemorySeedLedger()
        let provisioning = FakeProvisioning(seed: Self.creds)
        let store = FakeCredentialStore(stored: nil)
        let notices = RecordingNoticeStore()

        // 1回目の起動 → 蒔かれる。
        let first = makeState(store: store, notices: notices, provisioning: provisioning, seedLedger: ledger)
        await first.loadStoredCredentials()
        XCTAssertEqual(first.credentials, Self.creds, "前提: 1回目は蒔けている")

        // 401 は**起きていない**。アプリを通さずに Keychain の項目だけが消える。
        store.wipeOutOfBand()

        // 2回目の起動(同じ束・同じ台帳)。
        let second = makeState(store: store, notices: notices, provisioning: provisioning, seedLedger: ledger)
        await second.loadStoredCredentials()

        XCTAssertEqual(second.credentials, Self.creds,
                       "★種が束に在るのに欄を出す実装を落とす(鍵を回すまで復帰路が無い)")
        XCTAssertNil(second.signOutNotice, "拒否は起きていないので断りも出ない")
    }

    /// ★⑰ 入れ替えた**後**に届いた古い 401 は捨てる。
    ///
    /// 要求は非同期に返るので、此の順序は空想ではない —— 鍵を打ち直した直後、
    /// 前の鍵で出していた要求の 401 が後から届く。`self.credentials` を見て記録する
    /// 実装だと、其の 401 が**今使っている鍵**を落とし、更に束の種を「拒まれた」と
    /// 覚える。使えている鍵で鍵入力画面へ落ち、種の道まで塞がる形。
    func testA401ForAKeyThatIsNoLongerInUseIsIgnored() {
        let old = Self.creds
        let new = Credentials(baseURL: Self.url, apiKey: "new")
        let ledger = InMemorySeedLedger()
        let notices = RecordingNoticeStore()
        let state = makeState(store: FakeCredentialStore(stored: new),
                              notices: notices,
                              provisioning: FakeProvisioning(seed: old),
                              seedLedger: ledger)
        state.setCredentials(new)

        state.clearCredentials(rejected: old)

        XCTAssertEqual(state.credentials, new, "★今の鍵まで落とす実装を落とす")
        XCTAssertNil(state.signOutNotice, "使えている鍵に断りは付かない")
        XCTAssertNil(notices.load(), "ディスクにも書かない(次の起動で理由だけ生き残る)")
        XCTAssertNil(ledger.rejectedSeedDigest,
                     "★古い 401 で種の道を塞ぐ実装を落とす(束の種が二度と蒔けなくなる)")
    }

    /// ⑱ 手で打った鍵の拒否は台帳に書かない。
    ///
    /// 蒔く経路は種しか通らないので、手入力の鍵の拒否を覚えても止める先が無い ——
    /// 束の種と無関係な指紋が `UserDefaults` に残るだけになる。
    func testARejectedHandTypedKeyIsNotRecordedInTheLedger() {
        let typed = Credentials(baseURL: Self.url, apiKey: "typed")
        let ledger = InMemorySeedLedger()
        let state = makeState(store: FakeCredentialStore(stored: typed),
                              notices: RecordingNoticeStore(),
                              provisioning: FakeProvisioning(seed: Self.creds),
                              seedLedger: ledger)
        state.setCredentials(typed)

        state.clearCredentials(rejected: typed)

        XCTAssertEqual(state.signOutNotice?.reason, .keyRejected, "前提: 拒否は本当に起きている")
        XCTAssertNil(ledger.rejectedSeedDigest,
                     "★拒まれた鍵を種かどうか見ずに書く実装を落とす")
    }

    /// ★⑲ 拒まれたと覚えている鍵が金庫に残っていたら、起動時に掃く。
    ///
    /// `clearCredentials(rejected:)` は台帳へ書いた**後**に金庫を消すので(⑭-b)、
    /// 間で殺されると此の形で残る。掃かずに使うと、起動する度に 401 を貰って断りが
    /// 出る電話になる —— 拒否を覚えているのに拒まれた鍵で繋ぎに行く、という
    /// 一番説明の付かない状態。
    func testARejectedKeyLeftInTheKeychainIsSweptOnLaunch() async {
        let recorder = Recorder()
        let store = FakeCredentialStore(stored: Self.creds, recorder: recorder)
        let ledger = InMemorySeedLedger(rejectedSeedDigest: SeedDigest.of(Self.creds))
        let notices = RecordingNoticeStore(notice: SignOutNotice(reason: .keyRejected, baseURL: Self.url),
                                           recorder: recorder)

        let state = makeState(store: store,
                              notices: notices,
                              provisioning: FakeProvisioning(seed: Self.creds),
                              seedLedger: ledger)

        await state.loadStoredCredentials()

        XCTAssertNil(state.credentials,
                     "★拒まれたと覚えている鍵で繋ぎに行く実装を落とす")
        XCTAssertTrue(recorder.events.contains("keychain-cleared"),
                      "★画面から外すだけの実装を落とす(次の起動でまた同じ所に戻る)")
        XCTAssertEqual(state.signOutNotice?.reason, .keyRejected,
                       "鍵入力画面は理由を持って出る")
    }

    /// ★⑳ 同じ鍵が**通った**ら、拒否の記録は降ろす。
    ///
    /// 拒否は過去の事実であって今の状態ではない。残したままだと、机側で鍵を戻した日に
    /// **種の道だけが塞がったまま**になる —— 打てば動くので、塞がっている事に気付く
    /// 機会も無い(次に金庫が独りで空になるまで表に出ない)。
    func testAKeyThatWorksAgainClearsTheRejection() async {
        let ledger = InMemorySeedLedger(rejectedSeedDigest: SeedDigest.of(Self.creds))
        let state = makeState(store: FakeCredentialStore(stored: nil),
                              notices: RecordingNoticeStore(),
                              provisioning: FakeProvisioning(seed: Self.creds),
                              seedLedger: ledger)

        // 机側で鍵を戻した後、同じ値が `healthz` と `/api/sessions` の2段を通った。
        state.setCredentials(Self.creds)

        XCTAssertNil(ledger.rejectedSeedDigest,
                     "★通った鍵の拒否を持ち続ける実装を落とす")

        // 種の道も同時に開く。此処まで見ないと、記録を消しただけで
        // 別の所(蒔く側)に旗が残っている実装が緑になる。
        let second = makeState(store: FakeCredentialStore(stored: nil),
                               notices: RecordingNoticeStore(),
                               provisioning: FakeProvisioning(seed: Self.creds),
                               seedLedger: ledger)
        await second.loadStoredCredentials()

        XCTAssertEqual(second.credentials, Self.creds, "次の起動で同じ種が蒔ける")
    }
}
