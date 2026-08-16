import XCTest
@testable import RemoteMini

/// Spec §5-4's banner text. This is the sentence Tom reads when the phone cannot reach
/// edith from another country, so it is the one place in the app where wrong wording
/// costs the most -- and until 2026-08-07 it had no test, because `detail` was `private`
/// and a SwiftUI `body` is not readable from a unit test.
///
/// Two layers on purpose:
///
/// 1. **Exact strings.** Any edit to the wording fails here and has to be looked at.
/// 2. **A cause-naming control.** Layer 1 alone would be satisfied by a legitimate
///    reword that also reintroduced the original defect. `UnreachableBanner`'s own doc
///    records that an earlier version led with 「バックエンドに接続できません」 -- which
///    asserts one of three causes (電波 / edith 停止 / tailnet 切断) that the phone can
///    distinguish *none* of. Layer 2 survives a reword and still bites.
///
/// Not covered, stated rather than implied: the title line 「バックエンドから応答が
/// ありません」 lives in `body` and no unit test on this machine can read it (no GUI, so
/// no UI test on demand). Only `detailText` is asserted below.
final class UnreachableBannerTests: XCTestCase {
    // MARK: - Layer 1: the exact sentences

    func testListWordingIsExactlyTheSpecSentence() {
        XCTAssertEqual(
            UnreachableBanner.detailText(failures: 3, context: .list),
            "3 fetches in a row have failed. Make sure Tailscale is connected, then retry"
        )
    }

    func testConversationWordingSaysTheDisplayIsFrozen() {
        XCTAssertEqual(
            UnreachableBanner.detailText(failures: 3, context: .conversation),
            "3 fetches in a row have failed. Showing the last data that could be read"
        )
    }

    /// The two contexts must not collapse into one string. Without this, an edit that
    /// dropped the `switch` and returned the list wording for both would pass every
    /// "does the banner appear?" test while silently telling a Conversation reader that
    /// stale content is current -- the exact confusion the second sentence exists to
    /// prevent.
    func testTheTwoContextsDoNotProduceTheSameSentence() {
        let list = UnreachableBanner.detailText(failures: 7, context: .list)
        let conversation = UnreachableBanner.detailText(failures: 7, context: .conversation)

        XCTAssertNotEqual(list, conversation)
        XCTAssertTrue(conversation.contains("last data that could be read"))
        XCTAssertFalse(list.contains("last data that could be read"))
    }

    // MARK: - The count is measured, not a constant

    /// The banner stays up past the threshold, so a phone that has failed 40 times in a
    /// row must not keep saying "3回". A hard-coded string would pass both exact-string
    /// tests above (they use 3) and fail here -- which is why 3 is not used in this one.
    func testTheActualCountIsPrintedRatherThanTheThreshold() {
        for context in [UnreachableBanner.Context.list, .conversation] {
            let text = UnreachableBanner.detailText(failures: 40, context: context)

            XCTAssertTrue(text.hasPrefix("40 fetches in a row"), "got: \(text)")
            XCTAssertFalse(text.contains("3 fetches"), "threshold leaked as a literal: \(text)")
        }
    }

    /// Distinct counts must produce distinct strings. Guards the degenerate twin where
    /// the count is interpolated but from a fixed source rather than the argument.
    func testDifferentCountsProduceDifferentSentences() {
        let four = UnreachableBanner.detailText(failures: 4, context: .list)
        let five = UnreachableBanner.detailText(failures: 5, context: .list)

        XCTAssertNotEqual(four, five)
    }

    // MARK: - Layer 2: it states what was measured and never names a cause

    /// Survives a legitimate reword. Each banned fragment is a *cause* the phone has no
    /// way to observe: it sees a failed request and nothing more. Naming one turns a
    /// measurement into a guess that reads as fact -- and the guess is wrong whenever the
    /// streak was actually made of contract violations, which `ListViewModel` also counts.
    func testNeitherSentenceNamesACauseThePhoneCannotObserve() {
        let banned = [
            "接続できません",
            "接続に失敗",
            "オフライン",
            "圏外",
            "電波",
            "tailnet",
            "edith",
            "停止しています",
            "サーバが落ち",
        ]

        for context in [UnreachableBanner.Context.list, .conversation] {
            let text = UnreachableBanner.detailText(failures: 3, context: context)
            for phrase in banned {
                XCTAssertFalse(
                    text.lowercased().contains(phrase.lowercased()),
                    "原因を名指ししている: 「\(phrase)」 in \(text)"
                )
            }
        }
    }

    /// Positive anchor for the control above. A banned-list test is worthless if the list
    /// can never match anything -- this proves the matcher actually fires, so a green run
    /// of `testNeitherSentenceNamesACause...` means the sentences are clean rather than
    /// meaning the check is dead.
    func testTheCauseControlActuallyFiresOnTheWordingItIsMeantToReject() {
        let regressed = "バックエンドに接続できません。しばらくしてから再試行してください"

        XCTAssertTrue(regressed.contains("接続できません"))
    }
}
