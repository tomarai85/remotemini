import SwiftUI
import XCTest
@testable import RemoteMini

/// `ConversationView.shouldResumeOnForeground` -- the pure decision behind N4's
/// `.onChange(of: scenePhase)` guard (brief §1-a item 5). Extracted specifically so
/// this can be asserted directly (Sprint 4 Evaluator RED 2, item c): SwiftUI's
/// `.onChange(of:)` closure itself isn't reachable from `XCTest`, but the boolean it
/// computes is, once separated from the view lifecycle around it.
final class ConversationViewTests: XCTestCase {
    // MARK: - The genuine edge: backgrounded, now returning

    func testBackgroundToActiveEdgeTriggersForegroundResume() {
        XCTAssertTrue(ConversationView.shouldResumeOnForeground(oldPhase: .background, newPhase: .active))
    }

    // MARK: - The edge the guard exists to reject (ConversationView.swift's own doc
    // comment: app LAUNCH itself routes through .inactive -> .active, which would
    // otherwise fire a redundant resync on every screen appearance)

    func testInactiveToActiveDoesNotTriggerForegroundResumeNegativeControl() {
        XCTAssertFalse(
            ConversationView.shouldResumeOnForeground(oldPhase: .inactive, newPhase: .active),
            "app launch's own .inactive -> .active transition must not read as a background-resume"
        )
    }
}
