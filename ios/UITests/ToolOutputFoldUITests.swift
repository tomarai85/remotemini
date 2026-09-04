import XCTest

/// 対照表 #41(2026-09-04): 道具の結果は tool の chip の下に**畳んで**持ち、押した時だけ開く。
/// 作り物 `conversation-3roles` の tool 行は机が対にした出力(切り詰め印つき)を持つ。
final class ToolOutputFoldUITests: XCTestCase {

    func testToolOutputIsFoldedUntilTappedAndFoldsBack() {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = "conversation-3roles"
        app.launch()

        let toggle = app.descendants(matching: .any).matching(identifier: "conversation.tool.toggle").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "出力を持つ tool 行の chip が無い")
        XCTAssertEqual(toggle.value as? String, "collapsed")
        let output = app.descendants(matching: .any).matching(identifier: "conversation.tool.output").firstMatch
        XCTAssertFalse(output.exists, "既定で開いている(畳む筈)")
        // chip の文字は残っている(Button で包んで label に畳んでいない)
        XCTAssertTrue(app.staticTexts["⚙ Bash"].exists)

        toggle.tap()
        XCTAssertTrue(output.waitForExistence(timeout: 5), "押しても出力が開かない")
        XCTAssertTrue(output.label.contains("booking-1"), output.label)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "conversation.tool.output.more").firstMatch.exists,
                      "机が切った印が無い(fixture は outputTruncated: true)")
        XCTAssertEqual(toggle.value as? String, "expanded")

        toggle.tap()
        XCTAssertTrue(waitGone(output, timeout: 5), "もう一度押しても畳まれない")
        XCTAssertEqual(toggle.value as? String, "collapsed")
    }

    private func waitGone(_ el: XCUIElement, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: el)], timeout: timeout) == .completed
    }
}
