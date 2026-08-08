import SwiftUI
import XCTest
@testable import RemoteMini

/// The pure decisions lifted out of `ConversationView`'s body so they can be asserted
/// directly: SwiftUI's view modifiers aren't reachable from `XCTest`, but the values
/// they compute are, once separated from the view lifecycle around them.
///
/// N4's `.onChange(of: scenePhase)` guard used to be one of them
/// (`shouldResumeOnForeground`, Sprint 4 Evaluator RED 2 item c). Sprint 8 moved it to
/// `ForegroundResume` when the List screen turned out to need the same rule.
///
/// その2本は `ForegroundResumeTests` へ**移せなかった** —— 片方が主張していた辺
/// (`.background -> .active`)を iOS が一度も配らない事が実測で判り、規則ごと
/// 書き直したから。移動ではなく置換なので、此処に残骸を残さない為に消してある。
/// 経緯は `ios/Sources/Screens/Shared/ForegroundResume.swift` の doc に全文。
final class ConversationViewTests: XCTestCase {
    // MARK: - Sprint 5: the send banner's colour is the ONLY thing `kind` may change

    /// An unrecognized `kind` must land on the neutral colour -- not the success one
    /// (which would dress an unknown outcome as "sent") and not the failure one (which
    /// would dress a possibly-fine outcome as an error). `ResultDisplay.tone` already
    /// maps unknown to `.warn`; this asserts the view agrees, i.e. that the degradation
    /// survives all the way to what the user actually sees.
    func testAnUnrecognizedKindIsColouredExactlyLikeAWarning() {
        let unknown = ResultDisplay(kind: "brand-new-state", text: "t", keepText: nil)

        XCTAssertEqual(ConversationView.color(for: unknown.tone), ConversationView.color(for: .warn))
        XCTAssertNotEqual(ConversationView.color(for: unknown.tone), ConversationView.color(for: .ok))
        XCTAssertNotEqual(ConversationView.color(for: unknown.tone), ConversationView.color(for: .error))
    }

    /// Negative control for the assertion above: the colour map has to actually
    /// distinguish something. A constant colour would satisfy the first line of the
    /// previous test forever.
    func testTheColourMapIsNotConstantNegativeControl() {
        let colours = [ConversationView.color(for: .ok),
                       ConversationView.color(for: .warn),
                       ConversationView.color(for: .error)]

        XCTAssertEqual(Set(colours.map { String(describing: $0) }).count, 3)
    }

    // MARK: - Sprint 8 (§2.56): 回るのは押した鍵だけ

    /// 選択肢のボタンは複数並ぶ。全部回す実装でも「飛んでいる間に何か出る」という
    /// 検査は緑で通るので、**どれが回るか**を別に測る。
    ///
    /// この規則を view body の中に `viewModel.inFlightChoiceKey == button.key` と
    /// 直接書くと、画面の規則なのにどの検査からも触れない —— S8-5 で見付けたのは
    /// その裏側(規則は正しいのに画面に繋がっていなかった)で、同じ穴の両側。
    func testOnlyThePressedKeySpins() {
        XCTAssertTrue(ConversationView.spins(key: "2", inFlight: "2"))
        XCTAssertFalse(ConversationView.spins(key: "1", inFlight: "2"),
                       "★他の鍵は回らない。回ると「どれを押したか」が消える")
        XCTAssertFalse(ConversationView.spins(key: "escape", inFlight: "enter"))
    }

    /// 何も飛んでいなければ、どの鍵も回らない。`!= nil` 型の誤実装だけでなく、
    /// 「常に true」型もここで落ちる。
    func testNoKeySpinsWhenNothingIsInFlight() {
        XCTAssertFalse(ConversationView.spins(key: "1", inFlight: nil))
        XCTAssertFalse(ConversationView.spins(key: "2", inFlight: nil))
        XCTAssertFalse(ConversationView.spins(key: "", inFlight: nil))
    }
}
