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
}
