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

    func testHealthzFailureShortCircuitsBeforeProbingSessions() async {
        let healthz = FakeHealthzChecker()
        healthz.result = .failure(.unreachable)
        let sessionsProbe = FakeSessionsAuthChecker()
        var savedCredentials: Credentials?
        let viewModel = KeyEntryViewModel(healthz: healthz, sessionsProbe: sessionsProbe, store: FakeCredentialStore()) {
            savedCredentials = $0
        }
        viewModel.baseURLText = "https://unit-test.invalid"
        viewModel.apiKeyText = "fixture-key"

        await viewModel.submit()

        XCTAssertEqual(viewModel.errorMessage, "サーバに届きません。URL を確認してください")
        XCTAssertEqual(sessionsProbe.callCount, 0, "must not probe the key when the URL itself is unreachable")
        XCTAssertNil(savedCredentials)
    }

    func testWrongKeyShowsTheWrongKeyMessage() async {
        let sessionsProbe = FakeSessionsAuthChecker()
        sessionsProbe.outcome = .unauthorized
        let store = FakeCredentialStore()
        var savedCredentials: Credentials?
        let viewModel = KeyEntryViewModel(healthz: FakeHealthzChecker(), sessionsProbe: sessionsProbe, store: store) {
            savedCredentials = $0
        }
        viewModel.baseURLText = "https://unit-test.invalid"
        viewModel.apiKeyText = "wrong-fixture-key"

        await viewModel.submit()

        XCTAssertEqual(viewModel.errorMessage, "鍵が違います")
        XCTAssertNil(store.saved)
        XCTAssertNil(savedCredentials)
    }

    func testBothPassingSavesToTheStoreAndInvokesTheCallback() async {
        let store = FakeCredentialStore()
        var savedCredentials: Credentials?
        let viewModel = KeyEntryViewModel(healthz: FakeHealthzChecker(), sessionsProbe: FakeSessionsAuthChecker(), store: store) {
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
        let viewModel = KeyEntryViewModel(healthz: healthz, sessionsProbe: sessionsProbe, store: FakeCredentialStore()) { _ in }
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
        let unreachableVM = KeyEntryViewModel(healthz: unreachableHealthz, sessionsProbe: FakeSessionsAuthChecker(), store: FakeCredentialStore()) { _ in }
        unreachableVM.baseURLText = "https://unit-test.invalid"
        unreachableVM.apiKeyText = "fixture-key"
        await unreachableVM.submit()

        let wrongKeyProbe = FakeSessionsAuthChecker()
        wrongKeyProbe.outcome = .unauthorized
        let wrongKeyVM = KeyEntryViewModel(healthz: FakeHealthzChecker(), sessionsProbe: wrongKeyProbe, store: FakeCredentialStore()) { _ in }
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
        let viewModel = KeyEntryViewModel(healthz: FakeHealthzChecker(),
                                          sessionsProbe: FakeSessionsAuthChecker(),
                                          store: FakeCredentialStore(),
                                          initialBaseURL: URL(string: "https://unit-test.invalid")!) { _ in }

        XCTAssertEqual(viewModel.baseURLText, "https://unit-test.invalid")
    }

    /// ★鍵の側は入れない。
    ///
    /// 拒まれた鍵を欄に残すと、Tom は「入っているから合っている」と読んでそのまま押し、
    /// また拒まれる —— 直そうとした迷子を一段深くする。`initialBaseURL` を足した時に
    /// 「ついでに鍵も」と伸ばす実装をここで落とす。
    func testTheRejectedKeyIsNotBroughtBackWithTheURL() {
        let viewModel = KeyEntryViewModel(healthz: FakeHealthzChecker(),
                                          sessionsProbe: FakeSessionsAuthChecker(),
                                          store: FakeCredentialStore(),
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
        let seeded = KeyEntryViewModel(healthz: FakeHealthzChecker(),
                                       sessionsProbe: FakeSessionsAuthChecker(),
                                       store: FakeCredentialStore(),
                                       initialBaseURL: URL(string: "https://unit-test.invalid")!) { _ in }
        XCTAssertEqual(seeded.baseURLText, "https://unit-test.invalid", "前提: 欄は埋まり得る")

        let viewModel = KeyEntryViewModel(healthz: FakeHealthzChecker(),
                                          sessionsProbe: FakeSessionsAuthChecker(),
                                          store: FakeCredentialStore()) { _ in }

        XCTAssertEqual(viewModel.baseURLText, "")
        XCTAssertEqual(viewModel.apiKeyText, "")
    }
}
