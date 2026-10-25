import BetterEssentialSpaceCore
import SwiftUI

/// Switches between the login screen and the main UI, on the shared gradient canvas.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.phase {
            case .loading:
                ProgressView("Opening Better Essential Space…")
                    .tint(ND.accent)
                    .font(ND.ui())
                    .foregroundStyle(ND.textSecondary)
            case .needsToken(let message):
                LoginView(message: message)
            case .ready:
                ContentView()
            }
        }
        .appCanvas()
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
