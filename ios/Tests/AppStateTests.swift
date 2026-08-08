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

    private final class FakeCredentialStore: CredentialStore {
        private var stored: Credentials?
        private let recorder: Recorder
        var clearThrows = false

        init(stored: Credentials? = nil, recorder: Recorder = Recorder()) {
            self.stored = stored
            self.recorder = recorder
        }

        func load() throws -> Credentials? { stored }

        func save(_ credentials: Credentials) throws {
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
        let state = AppState(store: FakeCredentialStore(stored: Self.creds), notices: notices)
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
        let state = AppState(store: FakeCredentialStore(stored: Self.creds),
                             notices: RecordingNoticeStore())
        state.setCredentials(Self.creds)

        state.clearCredentials()

        XCTAssertEqual(state.signOutNotice?.baseURL, Self.url)
    }

    /// ★③ 断りが消えるのは**接続に成功した時**。
    func testASuccessfulConnectionClearsTheNotice() {
        let notices = RecordingNoticeStore(notice: SignOutNotice(reason: .keyRejected, baseURL: Self.url))
        let state = AppState(store: FakeCredentialStore(), notices: notices)

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
        let state = AppState(store: FakeCredentialStore(stored: nil), notices: notices)

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
        let state = AppState(store: FakeCredentialStore(stored: Self.creds), notices: notices)

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
        let state = AppState(store: FakeCredentialStore(stored: Self.creds, recorder: recorder),
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
        let state = AppState(store: store, notices: RecordingNoticeStore())
        state.setCredentials(Self.creds)

        state.clearCredentials()

        XCTAssertNil(state.credentials)
        XCTAssertEqual(state.signOutNotice?.reason, .keyRejected)
    }
}
