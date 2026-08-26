import XCTest
@testable import RemoteMini

/// 2026-08-26。**初回起動でだけ失敗する**形を二度と作らない為の錨。
final class TimeoutBudgetTests: XCTestCase {
    /// ★実測に基づく下限。simulator の**初回** TLS ハンドシェイクが 6030ms かかり、
    /// 8 秒では間に合わず「机に届きません」になった(2回目以降は 74ms)。
    /// curl が速いのは接続を使い回すからで、アプリは毎回新規に張る ——
    /// **同じ URL でも測っている物が違う**。
    func testInteractiveTimeoutLeavesRoomForAColdHandshake() {
        XCTAssertGreaterThanOrEqual(BackendSession.interactiveTimeout, 15,
            "初回の TLS(実測 6s)に握手の余地が無い = Tom が最初に開いた時だけ失敗する")
    }

    /// 上げすぎない。黙った線で永久に待つのは、失敗しないより悪い。
    func testInteractiveTimeoutStillGivesUp() {
        XCTAssertLessThanOrEqual(BackendSession.interactiveTimeout, 45)
    }

    /// 読みは書きより短い、という関係そのものを守る(片方だけ動かした日に気付く)。
    func testReadsGiveUpSoonerThanWrites() {
        XCTAssertLessThan(BackendSession.interactiveTimeout, BackendSession.writeTimeout)
    }
}
