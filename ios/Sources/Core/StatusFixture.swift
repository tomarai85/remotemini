import Foundation

#if DEBUG

/// UI 検査用の permission mode の作り物。2026-09-02 新設(対照表 #16)。
///
/// ★`DigestFetchingFixture`(model/branch の帯)と同じ置き場に倣うが、値の選び方は
///   `DiffFetchingFixture` / `DiffFactory` に倣う: **独立した環境変数**
///   `RC_UI_STATUS_FIXTURE` を読む —— `RC_UI_FIXTURE` に相乗りさせない
///   (この repo の規約。相乗りさせると、複数の fixture が同じ1つの綴りを取り合い、
///   片方が変えたら他方も黙って変わる)。
struct PermissionModeFetchingFixture: PermissionModeFetching {
    let mode: String?

    func fetch(baseURL: URL, apiKey: String, sessionID: String) async
        -> Result<String?, SessionsFetchError>
    { .success(mode) }
}

enum StatusFactory {
    /// `RC_UI_STATUS_FIXTURE` の値をそのまま permission mode として使う。
    ///
    /// ★既定は**出さない**(`nil`) —— `DigestFetchingFixture` と違う判断を意図的にした。
    ///   最初は「未設定なら `bypassPermissions`」にしていたが、それだと**この帯を知らない
    ///   既存の UI 検査全部**にチップ1本ぶんの高さが黙って足され、着地系(スクロール位置)
    ///   の検査が数十 pt ずれて赤くなった(実測 2026-09-02、
    ///   `testOpeningALongConversationLandsAtTheNewestLine` が
    ///   `LANDING-DISTANCE=settled -37.0` で落ちた — 新しい行1本ぶんの高さと符合する)。
    ///   静かなチップという此の機能の性格そのものが「既定では画面を変えない」を要求する:
    ///   撮りたい時だけ `RC_UI_STATUS_FIXTURE` を明示する。
    static var fixtureMode: String? {
        guard let raw = ProcessInfo.processInfo.environment["RC_UI_STATUS_FIXTURE"], !raw.isEmpty else {
            return nil
        }
        return raw == "none" ? nil : raw
    }
}

#endif
