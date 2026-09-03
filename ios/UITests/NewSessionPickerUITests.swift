import XCTest

/// 一覧の `+` → roots の下から dir を選ぶ → 「Start here」(対照表 #11、2026-09-03、Tom 裁定 = roots の下だけ)。
///
/// fixture 1 状態 = 検査 1 本(`RC_UI_ROOTS_FIXTURE`)。測るのは配線と規約:
///   - dir を押しても**何も始まらない**(`roots.notice` が出ない)= 「押しても送らない」
///   - 起動は `roots.start` だけ
///   - 台帳が無い面 / 外を指した時の断りが**文で**出る
final class NewSessionPickerUITests: XCTestCase {

    private func launch(roots: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = "list-normal"
        app.launchEnvironment["RC_UI_ROOTS_FIXTURE"] = roots
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func photograph(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openPicker(_ app: XCUIApplication) {
        let plus = element(app, "list.newSession")
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "一覧の工具帯に `+` が無い")
        plus.tap()
        XCTAssertTrue(element(app, "roots.sheet").waitForExistence(timeout: 5), "picker の面が出ない")
    }

    func testPickingADirectoryDrillsDownAndOnlyStartHereStarts() {
        let app = launch(roots: "roots-sample")
        openPicker(app)
        XCTAssertTrue(element(app, "roots.root.0").waitForExistence(timeout: 5), "root の 1 本目が無い")
        XCTAssertTrue(element(app, "roots.root.1").exists)
        photograph(app, "roots-list")

        element(app, "roots.root.0").tap()
        let here = element(app, "roots.here")
        XCTAssertTrue(here.waitForExistence(timeout: 5))
        XCTAssertEqual(here.label, "~/Infra")
        XCTAssertTrue(element(app, "roots.entry.ios").waitForExistence(timeout: 5), "root 直下の dir が並ばない")
        XCTAssertTrue(element(app, "roots.entry.rc-backend").exists)
        XCTAssertFalse(element(app, "roots.entry.ios/Sources").exists, "直下だけのはずが深い物が混じった")

        element(app, "roots.entry.ios").tap()
        XCTAssertTrue(element(app, "roots.entry.ios/Sources").waitForExistence(timeout: 5), "降りていない")
        XCTAssertEqual(element(app, "roots.here").label, "~/Infra/ios")
        // ★押しても送らない: dir を 2 回押した今、結果の文は 1 つも出ていない
        XCTAssertFalse(element(app, "roots.notice").exists, "dir を押しただけで何かが始まった")
        photograph(app, "roots-drilled")

        element(app, "roots.up").tap()
        XCTAssertTrue(element(app, "roots.entry.ios").waitForExistence(timeout: 5), "上へ戻れない")
        XCTAssertEqual(element(app, "roots.here").label, "~/Infra")

        element(app, "roots.entry.research").tap()
        XCTAssertTrue(element(app, "roots.noEntries").waitForExistence(timeout: 5), "空の dir の面が無い")
        element(app, "roots.start").tap()
        let notice = element(app, "roots.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "Start here の結果が出ない")
        XCTAssertTrue(notice.label.hasPrefix("Starting"), notice.label)
        photograph(app, "roots-started")
    }

    func testNoRootsShowsTheEmptyFaceInsteadOfAnEmptyList() {
        let app = launch(roots: "roots-none")
        openPicker(app)
        XCTAssertTrue(element(app, "roots.empty").waitForExistence(timeout: 5), "台帳が無い面が出ない")
        XCTAssertFalse(element(app, "roots.root.0").exists)
        XCTAssertFalse(element(app, "roots.start").exists, "始める物が無いのに Start が在る")
        photograph(app, "roots-none")
    }

    func testOutsideRootsRejectionIsShownAsText() {
        let app = launch(roots: "roots-outside")
        openPicker(app)
        XCTAssertTrue(element(app, "roots.root.0").waitForExistence(timeout: 5))
        element(app, "roots.root.0").tap()
        XCTAssertTrue(element(app, "roots.start").waitForExistence(timeout: 5))
        element(app, "roots.start").tap()
        let notice = element(app, "roots.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("outside"), notice.label)
        photograph(app, "roots-outside")
    }
}
