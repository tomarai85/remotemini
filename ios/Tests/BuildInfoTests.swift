import XCTest
@testable import RemoteMini

/// ★2026-08-08(監査 X2-7)に中身を入れ替えた。
///
/// 元の検査はこう書いてあった —— `line` が「v で始まる」「括弧を含む」「? を含まない」。
/// 3本とも**形しか測っていない**。当時の `BuildInfo` は `ios/project.yml` に直値で
/// 書かれた `CFBundleShortVersionString: "0.1"` と `CFBundleVersion: "1"` を読んで
/// 常に `v0.1 (1)` を返していたので、**どの commit を焼いてもこの3本は緑**だった。
/// 版が何も識別していないという欠陥そのものが、検査の盲点の中に在った。
///
/// だからここでは形ではなく**判断**を測る: 生値 → 画面に出す文字列、の対応。
/// `Bundle.main` を読む `line` を直接測っても、検査の実行時に入っている plist の値に
/// 縛られて「差し込みが働かなかった時どう出るか」は一生測れない。純関数に切り出して
/// あるのはその為(`ConversationView.color(for:)` 等と同じ形)。
///
/// 差し込みが**実際に**働いたかは此処では測れない(単体は plist を選べない)。
/// それは `BuildIdentityUITests` が「画面の版が unknown でない」で測る —— あの主張は
/// `ios/tools/build.sh` の export が働いた時にしか緑にならないので、自分で錨になっている。
final class BuildInfoTests: XCTestCase {
    func testARealRevIsShownAsIs() {
        XCTAssertEqual(BuildInfo.displayRev("5bf8add"), "5bf8add")
        XCTAssertEqual(BuildInfo.displayRev("5bf8add-dirty"), "5bf8add-dirty")
        XCTAssertEqual(BuildInfo.displayRev("5bf8add-unknown-dirt"), "5bf8add-unknown-dirt")
    }

    /// ★これが本命。xcodegen 2.45.3 は `RC_BUILD_REV` が未定義でも落ちず、鍵も消さず、
    /// `${RC_BUILD_REV}` という**文字列**を Info.plist に書く(2026-08-08 実測)。
    /// つまり差し込みの失敗は、例外ではなく「もっともらしい版」として画面に届く。
    func testAnUnsubstitutedPlaceholderIsNotAVersion() {
        XCTAssertEqual(BuildInfo.displayRev("${RC_BUILD_REV}"), BuildInfo.unknown)
        XCTAssertEqual(BuildInfo.displayRev("${RC_BUILD_REV:-abc}"), BuildInfo.unknown)
    }

    func testMissingOrBlankIsUnknownRatherThanEmpty() {
        XCTAssertEqual(BuildInfo.displayRev(nil), BuildInfo.unknown)
        XCTAssertEqual(BuildInfo.displayRev(""), BuildInfo.unknown)
        XCTAssertEqual(BuildInfo.displayRev("   \n"), BuildInfo.unknown)
    }

    /// 版が読めなかった事が、画面上で「版の行が出ていない」と同じ見た目にならない事。
    /// 空文字を返す実装だと帯の行が消えて、欠落と読めなくなる。
    func testUnknownIsAWordAndNotAnEmptyString() {
        XCTAssertFalse(BuildInfo.unknown.isEmpty, "読めなかった事を名乗る語が空だと欠落と区別できない")
        XCTAssertEqual(BuildInfo.unknown, "unknown", "机側(/healthz の version)と同じ語を使う")
    }

    /// 画面に出る形。前置きが在るのは、帯の中で「これは版の行だ」と読める為。
    func testTheLineCarriesTheRevBehindAPrefix() {
        let line = BuildInfo.line
        XCTAssertTrue(line.hasPrefix("rev "), "版の行は rev で始まる: \(line)")
        XCTAssertEqual(line, "rev " + BuildInfo.displayRev(
            Bundle.main.object(forInfoDictionaryKey: BuildInfo.revKey) as? String
        ), "line は displayRev の結果をそのまま載せる(別経路で組み立てない)")
    }
}
