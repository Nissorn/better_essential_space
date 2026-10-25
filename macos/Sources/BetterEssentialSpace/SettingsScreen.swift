import BetterEssentialSpaceCore
import SwiftUI

/// Settings: appearance, account preferences, and session state.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                card("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    .padding(.top, 12)
                }

                card("Session") {
                    VStack(alignment: .leading, spacing: 0) {
                        if let overview = model.sessionOverview {
                            row("Nothing Account", overview.accountUUID ?? "unknown")
                            row("Access Token expires", expiryText(overview.accessTokenExpiresAt))
                            row(
                                "Refresh Token",
                                overview.hasRefreshToken ? "available" : "missing (sign in again)",
                                isSignal: !overview.hasRefreshToken
                            )
                        } else {
                            Text("No session. Sign in from the main window.")
                                .font(ND.ui(14))
                                .foregroundStyle(ND.textTertiary)
                                .padding(.top, 10)
                        }
                        HStack(spacing: 12) {
                            Button("Re-fetch preferences") {
                                Task { await model.loadPreferences() }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            Button("Sign out", action: model.signOut)
                                .buttonStyle(SecondaryButtonStyle())
                                .tint(ND.error)
                        }
                        .padding(.top, 16)
                    }
                }

                card("Essential Space preferences") {
                    VStack(alignment: .leading, spacing: 0) {
                        if let preferences = model.preferences {
                            row("User ID", preferences.userId)
                            row("Memory feature enabled", preferences.useMemory ? "yes" : "no")
                            row("Agreed to terms", preferences.hasAgreedToTerms ? "yes" : "no")
                            row("Updated at", preferences.updatedAt)
                        } else {
                            Text("Not loaded yet.")
                                .font(ND.ui(14))
                                .foregroundStyle(ND.textTertiary)
                                .padding(.top, 10)
                        }
                    }
                }

                card("Key overrides (advanced)") {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Both Nothing app keys are bundled with the app. A plain-text value in a file below overrides the bundled key — the fix path if Nothing rotates them.")
                            .font(ND.ui(13))
                            .foregroundStyle(ND.textTertiary)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        monoRow("Legacy API key", "~/.better-essential-space/legacy-api-key")
                        monoRow("Account signing key", "~/.better-essential-space/account-signing-key")
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollContentBackground(.hidden)
        .appCanvas()
    }

    private func expiryText(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title)
            content()
        }
        .card(padding: 20)
    }

    private func row(_ label: String, _ value: String, isSignal: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(ND.ui(14))
                .foregroundStyle(ND.textPrimary)
            Spacer()
            Text(value)
                .font(ND.mono(12))
                .foregroundStyle(isSignal ? ND.error : ND.textSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 7)
    }

    private func monoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(ND.ui(14))
                .foregroundStyle(ND.textPrimary)
            Spacer()
            Text(value)
                .font(ND.mono(12))
                .foregroundStyle(ND.textTertiary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 7)
    }
}
