import XCTest
@testable import RemoteMini

/// `DiffViewModel.load()` の相(phase)遷移。`DiffFetching` を fake で差し替える --
/// `DiffClient` そのものの status 分岐は `DiffClientTests` の役目、此処は
/// 「client の結果を phase へ正しく畳んでいるか」だけを見る。
@MainActor
final class DiffViewModelTests: XCTestCase {
    private struct FakeDiffFetching: DiffFetching {
        let result: Result<SessionDiffBody, SessionsFetchError>
        func fetch(baseURL: URL, apiKey: String, sessionID: String) async -> Result<SessionDiffBody, SessionsFetchError> {
            result
        }
    }

    private static let baseURL = URL(string: "https://unit-test.invalid")!
    private static let sampleResponse = SessionDiffBody(
        files: [DiffFile(path: "a.txt", staged: false, binary: false, added: 1, removed: 0, truncated: false, hunks: [])],
        truncated: false, totalBytes: 5, reason: nil
    )

    private func makeViewModel(_ result: Result<SessionDiffBody, SessionsFetchError>) -> DiffViewModel {
        DiffViewModel(
            client: FakeDiffFetching(result: result),
            baseURL: Self.baseURL, apiKey: "x", sessionID: "sess-0001"
        )
    }

    func testStartsInLoadingPhase() {
        let vm = makeViewModel(.success(Self.sampleResponse))

        XCTAssertEqual(vm.phase, .loading)
    }

    func testSuccessMovesToLoadedWithTheResponse() async {
        let vm = makeViewModel(.success(Self.sampleResponse))

        await vm.load()

        XCTAssertEqual(vm.phase, .loaded(Self.sampleResponse))
    }

    func testUnreachableFailureMovesToFailedWithAFixedSentence() async {
        let vm = makeViewModel(.failure(.unreachable))

        await vm.load()

        XCTAssertEqual(vm.phase, .failed("Couldn't reach the desk."))
    }

    func testNotFoundFailureMovesToFailedWithItsOwnSentence() async {
        let vm = makeViewModel(.failure(.notFound))

        await vm.load()

        // notFound / unreachable がどちらも同じ文へ潰れていない事の直接的な確認
        // (`ConversationViewModel` の `.notFound` 相と違う設計判断であることの記録:
        // 此の画面は独立した画面遷移を持たないので、文だけが分かれる)。
        XCTAssertEqual(vm.phase, .failed("That conversation is gone."))
    }

    func testUnauthorizedFailureMovesToFailedWithItsOwnSentence() async {
        let vm = makeViewModel(.failure(.unauthorized))

        await vm.load()

        guard case .failed(let text) = vm.phase else {
            return XCTFail("expected .failed, got \(vm.phase)")
        }
        XCTAssertTrue(text.contains("Sign-in expired"))
    }

    /// ★誰かが取り消した要求は、此の画面に「読めませんでした」を出させない
    /// (`SessionsFetchError.cancelled` の doc、`ConversationViewModel` と同じ判断)。
    func testCancelledFailureLeavesPhaseUntouched() async {
        let vm = makeViewModel(.failure(.cancelled))

        await vm.load()

        XCTAssertEqual(vm.phase, .loading, "cancelled は phase を動かしてはいけない")
    }

    // MARK: - 陰性対照: 誤りごとの文が潰れていない

    func testNotFoundAndUnreachableProduceDifferentSentencesNegativeControl() async {
        let notFound = makeViewModel(.failure(.notFound))
        await notFound.load()
        let unreachable = makeViewModel(.failure(.unreachable))
        await unreachable.load()

        XCTAssertNotEqual(notFound.phase, unreachable.phase)
    }
}
