import SwiftUI

/// 骨格。画面の中身は `.harness/spec-native-shell-2026-08-05.md` の確定後に入る。
/// この版が存在する理由は1つだけ ---- ビルドから実機インストールまでの経路が
/// 通る事を、画面を作る前に実測で確かめる為。
struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Remote Mini")
                .font(.title2.weight(.semibold))
            Text(BuildInfo.line)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

enum BuildInfo {
    /// 版を画面に出す。実機に入っている物が「今ビルドした物」かを、
    /// 電話を見るだけで言い切れるようにする(配備待ちを prose に手写しした
    /// 2026-08-04 の失敗と同じ型を、器の側でも作らない為)。
    static var line: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(short) (\(build))"
    }
}
