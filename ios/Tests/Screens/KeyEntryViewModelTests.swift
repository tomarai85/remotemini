import XCTest
@testable import RemoteMini

@MainActor
final class KeyEntryViewModelTests: XCTestCase {
    private final class FakeHealthzChecker: HealthzChecking {
        var result: Result<HealthzResult, HealthzError> = .success(HealthzResult(ok: true, pid: 1, uptimeSeconds: 1, version: "1"))
        private(set) var callCount = 0
        func check(baseURL: URL) async -> Result<HealthzResult, HealthzError> {
            callCount += 1
            return result
        }
    }

    private final class FakeSessionsAuthChecker: SessionsAuthChecking {
        var outcome: SessionsAuthProbe.Outcome = .authorized
        private(set) var callCount = 0
        func check(baseURL: URL, apiKey: String) async -> SessionsAuthProbe.Outcome {
            callCount += 1
            return outcome
        }
    }

    private final class FakeCredentialStore: CredentialStore {
        private(set) var saved: Credentials?
        func load() throws -> Credentials? { nil }
        func save(_ credentials: Credentials) throws { saved = credentials }
        func clear() throws { saved = nil }
    }

    /// 3つの口を束ねるだけ。既定は素通しの作り物で、覗きたい口だけ名指しで差し替える。
    ///
    /// ★`.live` は此処に一度も出ない。単体検査は開発機の上で走るので、本物の
    /// `KeychainCredentialStore` を握らせた時点で Tom の鍵を読む / 消す経路が生える
    /// (`ios/Sources/Core/KeyEntryClients.swift`)。束が既定値を持たないので、
    /// 書き忘れは緑ではなく**コンパイル失敗**になる。
    private func fakes(healthz: HealthzChecking = FakeHealthzChecker(),
                       sessionsProbe: SessionsAuthChecking = FakeSessionsAuthChecker(),
                       store: CredentialStore = FakeCredentialStore()) -> KeyEntryClients {
        KeyEntryClients(healthz: healthz, sessionsProbe: sessionsProbe, store: store)
    }

    func testHealthzFailureShortCircuitsBeforeProbingSessions() async {
        let healthz = FakeHealthzChecker()
        healthz.result = .failure(.unreachable)
        let sessionsProbe = FakeSessionsAuthChecker()
        var savedCredentials: Credentials?
        let viewModel = KeyEntryViewModel(clients: fakes(healthz: healthz, sessionsProbe: sessionsProbe)) {
            savedCredentials = $0
        }
        viewModel.baseURLText = "https://unit-test.invalid"
        viewModel.apiKeyText = "fixture-key"

        await viewModel.submit()

        XCTAssertEqual(viewModel.errorMessage, "Can't reach the server. Check the URL")
        XCTAssertEqual(sessionsProbe.callCount, 0, "must not probe the key when the URL itself is unreachable")
        XCTAssertNil(savedCredentials)
    }

    func testWrongKeyShowsTheWrongKeyMessage() async {
        let sessionsProbe = FakeSessionsAuthChecker()
        sessionsProbe.outcome = .unauthorized
        let store = FakeCredentialStore()
        var savedCredentials: Credentials?
        let viewModel = KeyEntryViewModel(clients: fakes(sessionsProbe: sessionsProbe, store: store)) {
            savedCredentials = $0
        }
        viewModel.baseURLText = "https://unit-test.invalid"
        viewModel.apiKeyText = "wrong-fixture-key"

        await viewModel.submit()

        XCTAssertEqual(viewModel.errorMessage, "The key is wrong")
        XCTAssertNil(store.saved)
        XCTAssertNil(savedCredentials)
    }

    func testBothPassingSavesToTheStoreAndInvokesTheCallback() async {
        let store = FakeCredentialStore()
        var savedCredentials: Credentials?
        let viewModel = KeyEntryViewModel(clients: fakes(store: store)) {
            savedCredentials = $0
        }
        viewModel.baseURLText = "https://unit-test.invalid"
        viewModel.apiKeyText = "correct-fixture-key"

        await viewModel.submit()

        let expected = Credentials(baseURL: URL(string: "https://unit-test.invalid")!, apiKey: "correct-fixture-key")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(store.saved, expected)
        XCTAssertEqual(savedCredentials, expected)
    }

    func testNonHTTPSURLIsRejectedBeforeAnyNetworkCall() async {
        let healthz = FakeHealthzChecker()
        let sessionsProbe = FakeSessionsAuthChecker()
        let viewModel = KeyEntryViewModel(clients: fakes(healthz: healthz, sessionsProbe: sessionsProbe)) { _ in }
        viewModel.baseURLText = "http://unit-test.invalid" // not https
        viewModel.apiKeyText = "fixture-key"

        await viewModel.submit()

        XCTAssertEqual(healthz.callCount, 0)
        XCTAssertEqual(sessionsProbe.callCount, 0)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testUnreachableAndWrongKeyMessagesAreDistinctNegativeControl() async {
        // Negative control: the easy mistake is routing every failure branch to one
        // generic error string, which would make "URL is wrong" and "key is wrong"
        // indistinguishable to the user -- spec §5-1 explicitly requires separating
        // them. Prove the two messages actually differ, not the same string reached
        // two ways.
        let unreachableHealthz = FakeHealthzChecker()
        unreachableHealthz.result = .failure(.unreachable)
        let unreachableVM = KeyEntryViewModel(clients: fakes(healthz: unreachableHealthz)) { _ in }
        unreachableVM.baseURLText = "https://unit-test.invalid"
        unreachableVM.apiKeyText = "fixture-key"
        await unreachableVM.submit()

        let wrongKeyProbe = FakeSessionsAuthChecker()
        wrongKeyProbe.outcome = .unauthorized
        let wrongKeyVM = KeyEntryViewModel(clients: fakes(sessionsProbe: wrongKeyProbe)) { _ in }
        wrongKeyVM.baseURLText = "https://unit-test.invalid"
        wrongKeyVM.apiKeyText = "fixture-key"
        await wrongKeyVM.submit()

        XCTAssertNotEqual(unreachableVM.errorMessage, wrongKeyVM.errorMessage)
    }

    /// 401 で戻された時、URL 欄は前の値で開く(DESIGN §2.65 / 監査 X2-6)。
    ///
    /// 電話で tailnet の URL を打ち直させないのがこの直しの半分。届いた上で 401 が
    /// 返った以上、URL が正しい事はサーバが証明している。
    func testTheURLThatWasBeingUsedComesBackInTheField() {
        let viewModel = KeyEntryViewModel(clients: fakes(),
                                          initialBaseURL: URL(string: "https://unit-test.invalid")!) { _ in }

        XCTAssertEqual(viewModel.baseURLText, "https://unit-test.invalid")
    }

    /// ★鍵の側は入れない。
    ///
    /// 拒まれた鍵を欄に残すと、Tom は「入っているから合っている」と読んでそのまま押し、
    /// また拒まれる —— 直そうとした迷子を一段深くする。`initialBaseURL` を足した時に
    /// 「ついでに鍵も」と伸ばす実装をここで落とす。
    func testTheRejectedKeyIsNotBroughtBackWithTheURL() {
        let viewModel = KeyEntryViewModel(clients: fakes(),
                                          initialBaseURL: URL(string: "https://unit-test.invalid")!) { _ in }

        // ★錨。下の主張は「空」= 否定なので、`initialBaseURL` が丸ごと無視される実装でも
        // 緑になる。URL の側が現に運ばれている事を先に固定して初めて、鍵が空である事が
        // 「運ばなかった」の意味になる。
        XCTAssertEqual(viewModel.baseURLText, "https://unit-test.invalid", "前提: URL は運ばれている")
        XCTAssertEqual(viewModel.apiKeyText, "", "★鍵まで復元する実装を落とす")
    }

    /// 初回(断り無し)は従来どおり空で開く。
    ///
    /// ★「空」だけを見る検査は、欄が**何をしても空**な実装(初期値の受け口が死んでいる、
    /// `@Published` が繋がっていない等)でも緑になる。同じ型を同じ場で1体、URL を
    /// 渡して組み、そちらが埋まる事を先に固定する —— これで下の空が
    /// 「渡されなかったから空」の意味になる。
    func testTheFirstVisitStillOpensEmpty() {
        let seeded = KeyEntryViewModel(clients: fakes(),
                                       initialBaseURL: URL(string: "https://unit-test.invalid")!) { _ in }
        XCTAssertEqual(seeded.baseURLText, "https://unit-test.invalid", "前提: 欄は埋まり得る")

        let viewModel = KeyEntryViewModel(clients: fakes()) { _ in }

        XCTAssertEqual(viewModel.baseURLText, "")
        XCTAssertEqual(viewModel.apiKeyText, "")
    }

    // MARK: - 「確かめています」の一文(監査 X2-8 / DESIGN §2.68)

    /// 飛んでいる**最中**の画面を覗く為の口。
    ///
    /// ★時計で測らない。「0.2 秒待ってから読む」形にすると、機械が混んだ日は読む側が
    /// 先に走って**何も起きていない事**を緑と読む。呼ばれた瞬間に此方が能動的に覗くので
    /// 競争の余地が無く、`probeCount` が「現に覗いた」を後から言える ——
    /// 走らなかった検査は緑になる。`ConversationViewModelTests.ProbingSendClient` と同じ形。
    ///
    /// `@MainActor` なのは覗く先が MainActor の ViewModel だから。
    private final class ProbingHealthzChecker: HealthzChecking {
        var result: Result<HealthzResult, HealthzError> = .success(HealthzResult(ok: true, pid: 1, uptimeSeconds: 1, version: "1"))
        var whileInFlight: (@MainActor () -> Void)?
        private(set) var probeCount = 0

        func check(baseURL: URL) async -> Result<HealthzResult, HealthzError> {
            if let whileInFlight {
                await MainActor.run { whileInFlight() }
                probeCount += 1
            }
            return result
        }
    }

    private final class ProbingSessionsAuthChecker: SessionsAuthChecking {
        var outcome: SessionsAuthProbe.Outcome = .authorized
        var whileInFlight: (@MainActor () -> Void)?
        private(set) var probeCount = 0

        func check(baseURL: URL, apiKey: String) async -> SessionsAuthProbe.Outcome {
            if let whileInFlight {
                await MainActor.run { whileInFlight() }
                probeCount += 1
            }
            return outcome
        }
    }

    /// ★段ごとに**別の**文が出る。
    ///
    /// 直す前、接続を押した後は丸い印だけで最大16秒無言だった。2段を1つの文
    /// (「最大16秒」)に畳む直し方もあるが、畳むとどちらが詰まったかが消える ——
    /// 旅先ではそこが分かれ道で、1段目なら tailnet か edith 自体、2段目なら edith は
    /// 起きていて rc-backend が詰まっている。
    func testEachStageSaysWhichStageItIsWhileItIsRunning() async {
        let healthz = ProbingHealthzChecker()
        let sessionsProbe = ProbingSessionsAuthChecker()
        var duringURLStage: String?
        var duringKeyStage: String?
        let viewModel = KeyEntryViewModel(clients: fakes(healthz: healthz, sessionsProbe: sessionsProbe)) { _ in }
        healthz.whileInFlight = { [weak viewModel] in duringURLStage = viewModel?.inFlightText }
        sessionsProbe.whileInFlight = { [weak viewModel] in duringKeyStage = viewModel?.inFlightText }
        viewModel.baseURLText = "https://unit-test.invalid"
        viewModel.apiKeyText = "fixture-key"

        await viewModel.submit()

        XCTAssertEqual(healthz.probeCount, 1, "前提: 1段目の最中に現に覗いた")
        XCTAssertEqual(sessionsProbe.probeCount, 1, "前提: 2段目の最中に現に覗いた")
        XCTAssertEqual(duringURLStage,
                       KeyEntryViewModel.urlProbeInFlightText(timeout: BackendSession.interactiveTimeout))
        XCTAssertEqual(duringKeyStage,
                       KeyEntryViewModel.keyProbeInFlightText(timeout: BackendSession.interactiveTimeout))
        XCTAssertNotEqual(duringURLStage, duringKeyStage, "★2段を同じ文に畳む実装を落とす")
        XCTAssertNil(viewModel.inFlightText, "終わったら消える(答えが出た後も待っている顔をしない)")
    }

    /// ★名前の在る段は全部走り、走る段には全部名前が在る。
    ///
    /// 段を1つ足して口を呼び忘れる / 口を呼んで段を足し忘れる、のどちらでも赤くなる。
    /// `Probe` を `CaseIterable` にしてあるのは此の一行の為。
    func testEveryNamedStageActuallyRuns() async {
        let healthz = FakeHealthzChecker()
        let sessionsProbe = FakeSessionsAuthChecker()
        let viewModel = KeyEntryViewModel(clients: fakes(healthz: healthz, sessionsProbe: sessionsProbe)) { _ in }
        viewModel.baseURLText = "https://unit-test.invalid"
        viewModel.apiKeyText = "fixture-key"

        await viewModel.submit()

        XCTAssertEqual(KeyEntryViewModel.Probe.allCases.count, 2, "前提: 段は2つ")
        XCTAssertEqual(healthz.callCount + sessionsProbe.callCount,
                       KeyEntryViewModel.Probe.allCases.count,
                       "★段と実際に走る口がずれた実装を落とす")
    }

    /// ★秒数を字で書かない(DESIGN §2.54 / §2.56 と同じ約束)。
    ///
    /// 本当に待つ長さは `HealthzClient` / `SessionsAuthProbe` が
    /// `request.timeoutInterval` に入れている値。文の側に写しを作ると、定数が動いた日に
    /// 画面だけ古い秒数を言い続ける —— 嘘は無言より悪い。
    func testTheSentencesAreBuiltFromTheTimeoutTheyAreGiven() {
        XCTAssertTrue(KeyEntryViewModel.urlProbeInFlightText(timeout: 30).contains("30"))
        XCTAssertTrue(KeyEntryViewModel.urlProbeInFlightText(timeout: 45).contains("45"))
        XCTAssertNotEqual(KeyEntryViewModel.urlProbeInFlightText(timeout: 30),
                          KeyEntryViewModel.urlProbeInFlightText(timeout: 45),
                          "★秒数を字で書いた実装を落とす")

        XCTAssertTrue(KeyEntryViewModel.keyProbeInFlightText(timeout: 30).contains("30"))
        XCTAssertNotEqual(KeyEntryViewModel.keyProbeInFlightText(timeout: 30),
                          KeyEntryViewModel.keyProbeInFlightText(timeout: 45))
    }

    /// ★確かめている間、両方の欄は触れない(画面側は `viewModel.isChecking` で伏せる)。
    ///
    /// 打てる欄を残すと、返って来た「鍵が違います」が**画面に見えている鍵**の話では
    /// なくなる。此処が測るのはその真偽が**2段とも**立っている事。
    ///
    /// ★同時に、真偽を段から導いてある事も固定する。別々の変数で持つと
    /// 「`isChecking == true` なのに文が出ない」という在ってはならない状態が書ける。
    func testTheFieldsStayLockedAcrossBothStages() async {
        let healthz = ProbingHealthzChecker()
        let sessionsProbe = ProbingSessionsAuthChecker()
        var lockedDuringURLStage = false
        var lockedDuringKeyStage = false
        let viewModel = KeyEntryViewModel(clients: fakes(healthz: healthz, sessionsProbe: sessionsProbe)) { _ in }
        healthz.whileInFlight = { [weak viewModel] in lockedDuringURLStage = viewModel?.isChecking ?? false }
        sessionsProbe.whileInFlight = { [weak viewModel] in lockedDuringKeyStage = viewModel?.isChecking ?? false }
        viewModel.baseURLText = "https://unit-test.invalid"
        viewModel.apiKeyText = "fixture-key"

        XCTAssertFalse(viewModel.isChecking, "前提: 押す前は触れる")

        await viewModel.submit()

        XCTAssertEqual(healthz.probeCount, 1, "前提: 1段目の最中に現に覗いた")
        XCTAssertEqual(sessionsProbe.probeCount, 1, "前提: 2段目の最中に現に覗いた")
        XCTAssertTrue(lockedDuringURLStage, "★1段目の間に打ち替えられる実装を落とす")
        XCTAssertTrue(lockedDuringKeyStage, "★2段目の間に打ち替えられる実装を落とす")
        XCTAssertFalse(viewModel.isChecking, "終わったら戻る")
    }
}
