import BetterEssentialSpaceCore
import SwiftUI
import UniformTypeIdentifiers

/// Sign-in screen: native email + password + OTP login (M2), with the M1
/// token-file import kept as a fallback. Centered card on the gradient canvas.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    let message: String?

    @State private var email = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var isImporting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ND.accentGradient)
                        .frame(width: 34, height: 5)
                    Text("Better Essential Space")
                        .font(ND.title)
                        .foregroundStyle(ND.textPrimary)
                    Text("Sign in with a Nothing Account")
                        .font(ND.ui(14))
                        .foregroundStyle(ND.textSecondary)
                    if let message {
                        Text(message)
                            .font(ND.ui(13))
                            .foregroundStyle(ND.error)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }
                }

                switch model.loginStage {
                case .idle:
                    credentialsForm
                case .working:
                    ProgressView()
                        .tint(ND.accent)
                        .frame(minHeight: 170)
                case .otp(let maskedEmail):
                    otpForm(maskedEmail: maskedEmail)
                }

                VStack(spacing: 14) {
                    disclosure("Import a token file instead (advanced)") {
                        VStack(spacing: 12) {
                            Button("Import token file…") { isImporting = true }
                                .buttonStyle(SecondaryButtonStyle())
                            Text("For accounts captured from Essential Space. Needs `access_token`, ideally a `refresh_token`.")
                                .font(ND.ui(13))
                                .foregroundStyle(ND.textTertiary)
                                .frame(maxWidth: 400)
                        }
                        .padding(.top, 10)
                    }
                    disclosure("What does the app need on this Mac?") {
                        VStack(alignment: .leading, spacing: 10) {
                            requirement("~/.better-essential-space/legacy-api-key", "records-host key — fetching Records fails without it")
                            requirement("~/.better-essential-space/account-signing-key", "signs every account request, login included")
                        }
                        .padding(.top, 10)
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.importTokens(from: url) }
            case .failure(let error):
                model.show(error: error)
            }
        }
    }

    private var credentialsForm: some View {
        VStack(spacing: 24) {
            NDField(title: "Email", text: $email)
            NDField(title: "Password", text: $password, secure: true)
            Button("Continue") {
                Task { await model.logIn(email: email, password: password) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(PrimaryButtonStyle(expands: true))
            .disabled(email.isEmpty || password.isEmpty)
            .opacity(email.isEmpty || password.isEmpty ? 0.35 : 1)
        }
        .card(padding: 28)
        .frame(width: 380)
    }

    private func otpForm(maskedEmail: String) -> some View {
        VStack(spacing: 20) {
            Text("Enter the code sent to \(maskedEmail)")
                .font(ND.ui(14))
                .foregroundStyle(ND.textSecondary)
            TextField("", text: $otp)
                .textFieldStyle(.plain)
                .font(ND.display(34))
                .foregroundStyle(ND.textPrimary)
                .multilineTextAlignment(.center)
                .monospaced()
                .frame(width: 240)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ND.accentGradient)
                        .frame(height: 2)
                }
            HStack(spacing: 12) {
                Button("Use a different account") { model.cancelLogin() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Verify") {
                    Task { await model.submitOTP(otp) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(otp.isEmpty)
                .opacity(otp.isEmpty ? 0.35 : 1)
            }
        }
        .card(padding: 28)
        .frame(width: 380)
    }

    private func disclosure(_ title: String, content: @escaping () -> some View) -> some View {
        DisclosureGroup {
            content()
        } label: {
            Text(title)
                .font(ND.ui(13, weight: .medium))
                .foregroundStyle(ND.textTertiary)
        }
        .buttonStyle(.plain)
    }

    private func requirement(_ path: String, _ purpose: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(path)
                .font(ND.mono(12))
                .foregroundStyle(ND.textSecondary)
            Text(purpose)
                .font(ND.ui(13))
                .foregroundStyle(ND.textTertiary)
        }
    }
}
