import SwiftUI

@main
struct RemoteMiniApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // 意匠の正本は RCTheme。tint と明暗と書体の系を根に1回だけ通す(散らさない)。
                .tint(RCTheme.accent)
                .preferredColorScheme(RCTheme.colorScheme)
                // glassTerm(端末の血)だけ monospaced。他は nil = 標準のまま。
                .fontDesign(RCTheme.fontDesign)
        }
    }
}
