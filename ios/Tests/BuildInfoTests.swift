import XCTest
@testable import RemoteMini

/// 骨格の検査。狙いは「XCTest が本当に走って、落ちる時に落ちる」事の確認で、
/// 中身の正しさはまだ主張しない。負の対照(意図的に落ちる検査)を別途1本置いて、
/// 緑が「走った上での緑」である事を毎回確かめる。
final class BuildInfoTests: XCTestCase {
    func testBuildLineNamesBothVersionFields() {
        let line = BuildInfo.line
        XCTAssertTrue(line.hasPrefix("v"), "版の行は v で始まる: \(line)")
        XCTAssertTrue(line.contains("("), "ビルド番号が括弧で付く: \(line)")
        XCTAssertFalse(line.contains("?"), "Info.plist から版が読めていない: \(line)")
    }
}
