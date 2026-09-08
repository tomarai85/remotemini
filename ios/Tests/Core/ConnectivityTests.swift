import XCTest
@testable import RemoteMini

/// 机に届かない事の唯一の語彙(2026-09-08、案 D)。棚卸しが挙げた「同じ 1 つの障害に 3 系統の言い方」を 1 本の梯子に畳む規則。
final class ConnectivityTests: XCTestCase {
    func testTheLadderIsOrderedByWhatIsBroken() {
        // 通信が死んでいる時に「遅れている」と言うと、直す先(Tailscale)を間違える。届かないが最強。
        let all = Connectivity.stage(unreachableFailures: 3, lagging: true, noResponse: true, lastConfirmed: "12:00:00")
        XCTAssertEqual(all, .unreachable(failures: 3, onList: false))
        let two = Connectivity.stage(unreachableFailures: nil, lagging: true, noResponse: true, lastConfirmed: "12:00:00")
        XCTAssertEqual(two, .noResponse(lastConfirmed: "12:00:00"))
        let one = Connectivity.stage(unreachableFailures: nil, lagging: true, noResponse: false, lastConfirmed: "12:00:00")
        XCTAssertEqual(one, .lagging(lastConfirmed: "12:00:00"))
        XCTAssertNil(Connectivity.stage(unreachableFailures: nil, lagging: false, noResponse: false, lastConfirmed: "12:00:00"))
    }

    func testSeverityRisesWithTheStage() {
        XCTAssertEqual(Connectivity.message(for: .lagging(lastConfirmed: "12:00:00")).severity, .caution)
        XCTAssertEqual(Connectivity.message(for: .noResponse(lastConfirmed: "12:00:00")).severity, .alarm)
        XCTAssertEqual(Connectivity.message(for: .unreachable(failures: 2, onList: true)).severity, .alarm)
    }

    /// 題は「何が起きているか」、詳細は「何をすればよいか」。順序は段で変えない。
    func testTitleSaysWhatHappenedAndDetailSaysWhatToDo() {
        let list = Connectivity.message(for: .unreachable(failures: 4, onList: true))
        XCTAssertEqual(list.title, "Can't reach the desk")
        XCTAssertTrue(list.detail.contains("4 fetches"))
        XCTAssertTrue(list.detail.contains("Tailscale"))
        // ★案 C と同じ文言(「もう一度」でなく、何を読み直すか)
        XCTAssertTrue(list.detail.contains("read the list again"))
    }

    /// 会話では押す物が違う —— 見えている物の由来を言う(一覧の再読み込みを勧めない)。
    func testTheConversationVariantExplainsWhatIsOnScreenInstead() {
        let conv = Connectivity.message(for: .unreachable(failures: 4, onList: false))
        XCTAssertEqual(conv.title, "Can't reach the desk")
        XCTAssertTrue(conv.detail.contains("last data that could be read"))
        XCTAssertFalse(conv.detail.contains("read the list again"))
    }

    /// ★否定対照: 3 段が同じ文を返すなら梯子は意味を持たない。題は 3 通りとも違う。
    func testTheThreeStagesDoNotShareOneSentence() {
        let titles = Set([
            Connectivity.message(for: .unreachable(failures: 1, onList: false)).title,
            Connectivity.message(for: .lagging(lastConfirmed: "12:00:00")).title,
            Connectivity.message(for: .noResponse(lastConfirmed: "12:00:00")).title,
        ])
        XCTAssertEqual(titles.count, 3)
    }
}
