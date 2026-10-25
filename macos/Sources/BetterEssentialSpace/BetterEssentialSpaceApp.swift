import BetterEssentialSpaceCore
import SwiftUI

@main
struct BetterEssentialSpaceApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsScreen()
                .environment(appModel)
                .frame(width: 460)
        }
    }
}
