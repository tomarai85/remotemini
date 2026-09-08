import XCTest

/// 一覧の「名前を変える」と「MacBook へ戻す」が、押した時に**本当に机の口を叩く**事(2026-09-08)。
///
/// 何が壊れていたか: alert の button の action は `Task { … }` を積むだけで、本体は次の
/// main actor の番に走る。`isPresented` を `renameTarget != nil` から作った Binding にしていたので、
/// button を押した瞬間 SwiftUI が閉じる為に `false` を書き戻し、其の setter が `renameTarget = nil`
/// を実行する —— `Task` の本体が走る頃には対象が nil で、`guard let` が黙って return していた。
/// **押しても何も起きない**。しかも alert は閉じるので、成功とまったく同じ画面になる。
/// (`DiffView` が 2026-09-03 に同じ形を踏んで `presenting:` へ移し、其の註が「`ListView` の
///  rename が同じ形だ」と 2 度名指ししていた。直しは此方へ持って来られていなかった)
///
/// 何故「断る fixture」で測るか: 成功する fixture では「呼ばれなかった」と「呼ばれて成功した」が
/// 同じ画面(一覧を読み直すだけ)になる。断らせると、**呼ばれた時だけ**「Can't rename」が出る ——
/// 帯の有無が「口が叩かれたか」の観測になる。
final class ListRenameUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RC_UI_FIXTURE"] = "list-normal"
        app.launchEnvironment["RC_UI_RENAME_FIXTURE"] = "rejected"
        app.launch()
        return app
    }

    func testSavingARenameReachesTheDesk() throws {
        let app = launch()
        let row = app.buttons.matching(identifier: "list.row").firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("一覧に行が無い = 測っていない")
        }

        row.press(forDuration: 1.0)                       // 長押し = 行の操作
        let rename = app.buttons["Rename"]
        guard rename.waitForExistence(timeout: 5) else {
            throw XCTSkip("行の操作が開かない = 測っていない")
        }
        rename.tap()

        let save = app.alerts.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "錨: 名前の alert が出ていない")
        save.tap()

        // 断る fixture なので、口が叩かれたなら此の帯が出る。出ない = 押しても何も起きていない。
        XCTAssertTrue(app.alerts["Can't rename"].waitForExistence(timeout: 8),
                      "★保存を押しても机の口が叩かれていない(閉じるだけの no-op)")
    }
}
