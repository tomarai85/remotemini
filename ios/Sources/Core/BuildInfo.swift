import Foundation

/// 電話に入っている物が**どの commit か**を、電話を見るだけで言い切る為の版。
///
/// ★2026-08-08(監査 X2-7)に中身を入れ替えた。それまでは
/// `CFBundleShortVersionString` と `CFBundleVersion` を読んで `v0.1 (1)` と出していたが、
/// その2つは `ios/project.yml` に**直値で書かれた定数**で、最初のビルドから一度も
/// 変わっていない —— つまり画面に出ていた「版」は、どのビルドでも同じ文字列だった。
/// 検査(`BuildInfoTests`)も「v で始まる」「括弧が付く」という**形**しか測っていなかったので、
/// 何をビルドしても永久に緑だった。
///
/// この型の元の doc には「実機に入っている物が『今ビルドした物』かを、電話を見るだけで
/// 言い切れるようにする」と書いてあった。**書いてある意図を実装が満たしていない**という
/// 形は、同じ監査の R2-3(誤った前提が検査として固定されていた)と同型。意味の無い文字列を
/// 2画面目にも出すのは、嘘を大きくするだけなので、出す先を増やす前に中身を実物にした。
///
/// 何を名乗るか: `git rev-parse --short HEAD` + 作業木が汚れていれば `-dirty`。
/// **机側(rc-backend)が `/healthz` の `version` で名乗っている物と同じ形**にしてある
/// (`rc-backend/src/server.mjs` の `DEPLOYED_REV`)。同じ repo の同じ commit なので、
/// 両方が同じ文字列を出していれば「電話と机は同じ物で動いている」が目で確定する。
/// 日時にしなかったのはその為 —— 日時は「いつ焼いたか」の代理でしかなく、突き合わせられない。
///
/// 読めない時に別の値を名乗らない、も机側から借りている。机側の comment に曰く
/// 「配備したのに再起動を忘れた場合、古いプロセスは古い版を名乗り続ける = それが正しい
/// (嘘の新版を名乗らない)。読めなければ "unknown"。黙って別の値を名乗らない。」
enum BuildInfo {
    /// `ios/project.yml` の `info.properties` が持つ鍵。`CFBundleVersion` に相乗りさせて
    /// いないのは、あちらが App Store 提出時に「点区切りの整数で単調増加」を要求される枠で、
    /// commit の sha を入れると規約違反の値になる為。役が違う物は別の鍵にする。
    static let revKey = "RCBuildRev"

    /// 読めなかった時の名乗り。**空文字にしない** —— 空だと「版の行が出ていない」と
    /// 「版が読めなかった」が画面上で同じになる。
    static let unknown = "unknown"

    static var line: String {
        "rev " + displayRev(Bundle.main.object(forInfoDictionaryKey: revKey) as? String)
    }

    /// Info.plist の生値 → 画面に出す文字列。view body から出した純関数なのは
    /// `ConversationView.color(for:)` 等と同じ理由(画面の規則なのに検査から触れなくなる)。
    ///
    /// ★`${` を含む値を `unknown` に落とすのが要点で、これは**実測に基づく**分岐:
    /// `ios/project.yml` は値を `"${RC_BUILD_REV}"` と書いて環境変数から差し込むが、
    /// xcodegen 2.45.3 は変数が**未定義の時に失敗せず**、`${RC_BUILD_REV}` という
    /// 文字列をそのまま Info.plist に書く(鍵を消しも空にもしない)。`${VAR:-既定値}`
    /// の形も解釈されず、そのまま literal になる。つまり「差し込みが働かなかった」は
    /// 例外ではなく**もっともらしい文字列**として届く。此処で潰さないと、画面に
    /// `rev ${RC_BUILD_REV}` と出て、それが版だと読まれる。
    static func displayRev(_ raw: String?) -> String {
        guard let raw else { return unknown }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return unknown }
        if trimmed.contains("${") { return unknown }
        return trimmed
    }
}
