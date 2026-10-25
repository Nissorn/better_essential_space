import BetterEssentialSpaceCore
import SwiftUI
import UniformTypeIdentifiers

/// Sign-in screen: native email + password + OTP login (M2), with the M1 token-file
/// import kept as a fallback.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    let message: String?

    @State private var email = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Sign in with a Nothing Account")
                .font(.title2.bold())
            if let message {
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            switch model.loginStage {
            case .idle:
                credentialsForm
            case .working:
                ProgressView("Contacting the account service…")
            case .otp(let maskedEmail):
                otpForm(maskedEmail: maskedEmail)
            }
            DisclosureGroup("Import a token file instead (advanced)") {
                VStack(spacing: 8) {
                    Button("Import token file…") { isImporting = true }
                    Text("For accounts captured from Essential Space. Needs `access_token`, ideally a `refresh_token`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            DisclosureGroup("What does the app need on this Mac?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("• ~/.better-essential-space/legacy-api-key — the records-host key (fetching Records fails without it).")
                    Text("• ~/.better-essential-space/account-signing-key — signs every account request, login included.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460, alignment: .leading)
                .padding(.top, 4)
            }
        }
        .padding(40)
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
        Form {
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            Button("Continue") {
                Task { await model.logIn(email: email, password: password) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty)
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }

    private func otpForm(maskedEmail: String) -> some View {
        VStack(spacing: 12) {
            Text("Enter the code sent to \(maskedEmail)")
                .font(.body)
                .foregroundStyle(.secondary)
            TextField("6-digit code", text: $otp)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            HStack {
                Button("Use a different account") { model.cancelLogin() }
                Button("Verify") {
                    Task { await model.submitOTP(otp) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(otp.isEmpty)
            }
        }
    }
}
