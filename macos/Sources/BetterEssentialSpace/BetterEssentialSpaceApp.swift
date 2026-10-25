import AppKit
import BetterEssentialSpaceCore
import SwiftUI

@main
struct BetterEssentialSpaceApp: App {
    @State private var appModel = AppModel()
    @AppStorage("appearance") private var appearance = "system"

    init() {
        FontLoader.registerBundledFonts()
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(colorScheme)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsScreen()
                .environment(appModel)
                .environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(colorScheme)
                .frame(width: 520)
        }
    }
}
