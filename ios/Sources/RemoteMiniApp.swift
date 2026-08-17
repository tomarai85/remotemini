import SwiftUI

@main
struct RemoteMiniApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // 意匠の正本は RCTheme。tint と明暗を根に1回だけ通す(散らさない)。
                .tint(RCTheme.accent)
                .preferredColorScheme(RCTheme.colorScheme)
        }
    }
}
