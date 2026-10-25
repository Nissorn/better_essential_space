import BetterEssentialSpaceCore
import SwiftUI

/// Settings: account preferences and session state (spec's settings screen).
/// No `Section` (its table-backed overload in the macOS 26 SDK fights the
/// plain ViewBuilder one inside List for this content shape).
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            header("Session")
            if let overview = model.sessionOverview {
                row("Nothing Account", overview.accountUUID ?? "unknown")
                row("Access Token expires", expiryText(overview.accessTokenExpiresAt))
                row("Refresh Token", overview.hasRefreshToken ? "available" : "missing (re-import a full token file)")
            } else {
                Text("No session. Import a token file first.")
                    .foregroundStyle(.secondary)
            }
            Button("Re-fetch preferences") {
                Task { await model.loadPreferences() }
            }
            Button("Sign out", role: .destructive, action: model.signOut)

            header("Essential Space preferences")
            if let preferences = model.preferences {
                row("User ID", preferences.userId)
                row("Memory feature enabled", preferences.useMemory ? "yes" : "no")
                row("Agreed to terms", preferences.hasAgreedToTerms ? "yes" : "no")
                row("Updated at", preferences.updatedAt)
            } else {
                Text("Not loaded yet.")
                    .foregroundStyle(.secondary)
            }

            header("Runtime key files")
            row("Legacy API key", "~/.better-essential-space/legacy-api-key")
            row("Account signing key", "~/.better-essential-space/account-signing-key")
        }
        .listStyle(.inset)
        .padding()
    }

    private func expiryText(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 8)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
