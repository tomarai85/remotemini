import XCTest

/// End-to-end UI tests for the List screen (Sprint 2 brief §5-b). Drives the real
/// app process through the `RC_UI_FIXTURE` launch-environment gate (see
/// `SessionsListingFactory`/`RootView`) -- no network stub, no `UI_TESTING` compile
/// condition. `app.launchEnvironment` is exactly the mechanism `RootView` reads via
/// `ProcessInfo.processInfo.environment["RC_UI_FIXTURE"]`, so this is the same code
/// path a real launch takes, just with a known env var set.
final class RemoteMiniUITests: XCTestCase {
    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = fixture
        app.launch()
        return app
    }

    /// Any element with this identifier, regardless of SwiftUI's choice of
    /// accessibility element type for it (container vs. leaf) -- `.otherElements`
    /// alone misses some SwiftUI view kinds, `.any` does not.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - list-normal: the ordinary list, not the empty/fault banners

    func testListNormalShowsTheListNotTheEmptyOrFaultBanner() {
        let app = launch(fixture: "list-normal")

        XCTAssertTrue(element(app, "list.scanLine").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "list.empty").exists)
        XCTAssertFalse(element(app, "list.paneFault").exists)
        XCTAssertFalse(element(app, "list.unreachable").exists)
        // One row per `RouteLabel.Kind` in the fixture (`SessionsListingFixture.sampleRows`)
        // -- the choice row's title is distinctive enough to assert directly.
        XCTAssertTrue(app.staticTexts["承認待ちの一件"].waitForExistence(timeout: 5))
    }

    // MARK: - list-panefault: the fault banner, with its real reason/detail text

    func testListPaneFaultShowsTheFaultBannerText() {
        let app = launch(fixture: "list-panefault")

        XCTAssertTrue(element(app, "list.paneFault").waitForExistence(timeout: 10))
        // The identifier marks which phase rendered; the banner's actual copy is
        // checked directly against `SessionsListingFixture`'s `.paneFault` case so a
        // regression that renders the *wrong* fault text (right phase, wrong words)
        // is still caught, not just "some banner appeared."
        XCTAssertTrue(app.staticTexts["pane-scan-timeout"].exists)
        XCTAssertTrue(app.staticTexts["tmux ペインの走査がタイムアウトしました。"].exists)
        XCTAssertFalse(element(app, "list.empty").exists)
    }

    // MARK: - list-empty: "会話がありません", only reachable with no paneFault

    func testListEmptyShowsTheNoConversationsMessage() {
        let app = launch(fixture: "list-empty")

        let empty = element(app, "list.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertEqual(empty.label, "会話がありません")
        XCTAssertFalse(element(app, "list.paneFault").exists)
        XCTAssertFalse(element(app, "list.unreachable").exists)
    }
}
