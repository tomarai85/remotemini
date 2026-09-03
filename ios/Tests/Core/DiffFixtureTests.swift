import XCTest
@testable import RemoteMini

/// `DiffFetchingFixture`(DEBUG の作り物)の `busyThenSample` は **instance ごと**に数える(Codex #6 の Medium)。
/// process 全体の static だと、同じ process で 2 つ目の view model を作った時に 1 回目から sample が返り、
/// UI 検査が「押したら効いた」を測れなくなる。
final class DiffFixtureTests: XCTestCase {
    private let url = URL(string: "https://unit-test.invalid")!

    private func reason(_ r: Result<SessionDiffBody, SessionsFetchError>) -> String? {
        if case .success(let b) = r { return b.reason }
        return "failure"
    }

    private func fetch(_ f: DiffFetchingFixture) async -> String? {
        let r = await f.fetch(baseURL: url, apiKey: "k", sessionID: "s")
        return reason(r)
    }

    func test_busyThenSampleは1回目だけbusy() async {
        let f = DiffFetchingFixture(state: .busyThenSample)
        let first = await fetch(f)
        let second = await fetch(f)
        let third = await fetch(f)
        XCTAssertEqual(first, "busy")
        XCTAssertNil(second)
        XCTAssertNil(third)
    }

    func test_別のinstanceは独立に数える() async {
        let a = DiffFetchingFixture(state: .busyThenSample)
        _ = await fetch(a)
        _ = await fetch(a)
        let b = DiffFetchingFixture(state: .busyThenSample)
        let firstOfB = await fetch(b)
        XCTAssertEqual(firstOfB, "busy", "2 つ目の instance が 1 回目から sample を返した(process 全体で数えている)")
    }

    func test_busyは何度でもbusy() async {
        let f = DiffFetchingFixture(state: .busy)
        for _ in 0..<3 {
            let r = await fetch(f)
            XCTAssertEqual(r, "busy")
        }
    }
}
