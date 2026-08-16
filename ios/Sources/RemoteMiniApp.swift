import SwiftUI

@main
struct RemoteMiniApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // アプリアイコン(藍黒 × 青紫)と同じ系統を全画面の tint に(RCTheme)。
                .tint(RCTheme.accent)
        }
    }
}
