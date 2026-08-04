import SwiftUI

/// Sprint 1 wires only Key-entry; List/Conversation arrive in Sprint 2-3 per
/// `.harness/spec-native-shell-2026-08-05.md` §6. The placeholder shown after a
/// successful Key-entry is intentionally minimal -- building List here would be
/// scope creep into Sprint 2's deliverable.
struct RootView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        NavigationStack {
            Group {
                if appState.isLoadingCredentials {
                    ProgressView()
                } else if let credentials = appState.credentials {
                    SignedInPlaceholderView(baseURL: credentials.baseURL)
                } else {
                    KeyEntryView(onSaved: appState.setCredentials)
                }
            }
        }
        .task { await appState.loadStoredCredentials() }
    }
}

private struct SignedInPlaceholderView: View {
    let baseURL: URL

    var body: some View {
        VStack(spacing: 12) {
            Text("接続済み")
                .font(.title2.weight(.semibold))
            Text(baseURL.absoluteString)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            Text("一覧画面は Sprint 2 で実装")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
