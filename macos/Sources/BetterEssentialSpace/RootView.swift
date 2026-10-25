import BetterEssentialSpaceCore
import SwiftUI

/// Switches between the bootstrap prompt and the main UI.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.phase {
            case .loading:
                ProgressView("Opening Better Essential Space…")
            case .needsToken(let message):
                LoginView(message: message)
            case .ready:
                ContentView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.lastError ?? "")
        }
        .task { model.bootstrap() }
    }
}
