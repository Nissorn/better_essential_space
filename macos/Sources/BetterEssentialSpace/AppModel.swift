import BetterEssentialSpaceCore
import Foundation
import Observation

/// Snapshot of the session shown in Settings.
struct SessionOverview: Equatable, Sendable {
    var accountUUID: String?
    var accessTokenExpiresAt: Date?
    var hasRefreshToken: Bool
}

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case needsToken(String?)
        case ready
    }

    /// Where the in-app Authflow login stands (issue 04). `idle` shows the
    /// email + password form; `otp` waits for the emailed code.
    enum LoginStage: Equatable {
        case idle
        case working
        case otp(maskedEmail: String)
    }

    private(set) var phase: Phase = .loading
    private(set) var records: [Record] = []
    private(set) var collections: [CollectionSummary] = []
    private(set) var preferences: Preferences?
    private(set) var sessionOverview: SessionOverview?
    private(set) var lastError: String?
    private(set) var loginStage: LoginStage = .idle

    func dismissError() {
        lastError = nil
    }

    func show(error: Error) {
        lastError = (error as? ESError)?.errorDescription ?? error.localizedDescription
    }

    let accountSession: AccountSession
    private let client: ESClient
    private let authflow: AuthflowClient
    private var pendingStateToken: String?
    private var loadTask: Task<Void, Never>?

    init(
        accountSession: AccountSession = AccountSession(),
        authflow: AuthflowClient = AuthflowClient(),
        client: ESClient? = nil
    ) {
        self.accountSession = accountSession
        self.authflow = authflow
        self.client = client ?? ESClient(accountSession: accountSession)
    }

    // MARK: Bootstrap (token import -> Keychain -> authenticated fetches)

    func bootstrap() {
        refreshSessionOverview()
        if accountSession.isSignedIn {
            phase = .ready
            reload()
        } else {
            phase = .needsToken(nil)
        }
    }

    func importTokens(from url: URL) {
        do {
            _ = try accountSession.importTokenFile(at: url)
            lastError = nil
            refreshSessionOverview()
            phase = .ready
            reload()
        } catch {
            lastError = (error as? ESError)?.errorDescription ?? error.localizedDescription
        }
    }

    func signOut() {
        accountSession.clearTokens()
        records = []
        collections = []
        preferences = nil
        sessionOverview = nil
        lastError = nil
        pendingStateToken = nil
        loginStage = .idle
        phase = .needsToken(nil)
    }

    // MARK: In-app Authflow login (M2: email + password -> OTP -> tokens)

    func logIn(email: String, password: String) async {
        loginStage = .working
        do {
            switch try await authflow.startLogin(email: email, password: password) {
            case .otp(let challenge):
                pendingStateToken = challenge.stateToken
                loginStage = .otp(maskedEmail: challenge.maskedDestination)
            case .finished(let sessionID):
                await finishLogin(sessionID: sessionID)
            }
        } catch {
            loginStage = .idle
            show(error: error)
        }
    }

    func submitOTP(_ code: String) async {
        guard let stateToken = pendingStateToken else {
            loginStage = .idle
            return
        }
        let maskedEmail = otpMaskedEmail
        loginStage = .working
        do {
            let sessionID = try await authflow.submitOTP(code, stateToken: stateToken)
            // The state token is consumed from here on; failures below restart the form.
            await finishLogin(sessionID: sessionID)
        } catch {
            loginStage = .otp(maskedEmail: maskedEmail)
            show(error: error)
        }
    }

    func cancelLogin() {
        pendingStateToken = nil
        loginStage = .idle
    }

    private func finishLogin(sessionID: String) async {
        loginStage = .working
        do {
            let tokens = try await authflow.completeLogin(sessionID: sessionID)
            try accountSession.storeTokens(tokens)
            pendingStateToken = nil
            loginStage = .idle
            lastError = nil
            refreshSessionOverview()
            phase = .ready
            reload()
        } catch {
            pendingStateToken = nil
            loginStage = .idle
            show(error: error)
        }
    }

    private var otpMaskedEmail: String {
        if case .otp(let masked) = loginStage { return masked }
        return ""
    }

    // MARK: Data loading

    /// Starts a load, superseding any in-flight one.
    func reload() {
        loadTask?.cancel()
        loadTask = Task { await loadAll() }
    }

    func loadAll() async {
        await loadPreferences()
        await loadRecords()
        await loadCollections()
    }

    func loadRecords() async {
        do {
            var fetched: [Record] = []
            var pageNo = 1
            while true {
                try Task.checkCancellation()
                let page = try await client.fetchCardPage(pageNo: pageNo)
                fetched.append(contentsOf: page.pageData.compactMap { try? Record(card: $0) })
                if !page.hasNextPage { break }
                guard pageNo < 500 else {
                    throw ESError.invalidResponse("card list pagination ran past 500 pages")
                }
                pageNo += 1
            }
            records = fetched.sorted { $0.createdAt > $1.createdAt }
            lastError = nil
        } catch is CancellationError {
            // superseded by a newer load — keep whatever state it left
        } catch {
            handle(error)
        }
    }

    func loadPreferences() async {
        do {
            preferences = try await client.fetchPreferences()
        } catch {
            // Preferences are secondary; a Record-list failure is the one that surfaces.
            if isSessionExpired(error) { handle(error) }
        }
    }

    /// Collections are secondary like preferences — only a dead session surfaces.
    /// Oldest-created first, so the sidebar keeps creation order.
    func loadCollections() async {
        do {
            try Task.checkCancellation()
            collections = try await client.fetchCollections().sorted {
                ($0.clientCreateTime ?? 0, $0.collectionId ?? "")
                    < ($1.clientCreateTime ?? 0, $1.collectionId ?? "")
            }
        } catch is CancellationError {
            // superseded by a newer load
        } catch {
            if isSessionExpired(error) { handle(error) }
        }
    }

    // MARK: Collections

    /// Records of one Collection (nil = all). Membership comes from each Card's
    /// `card_collection_cross_ref` (notes/03).
    func filteredRecords(collectionID: String?) -> [Record] {
        guard let collectionID else { return records }
        return records.filter { $0.collectionIds.contains(collectionID) }
    }

    /// The count shown on a Collection: cross-refs of the loaded Records, falling
    /// back to the server's own count (observed stale in the capture).
    func recordCount(in collection: CollectionSummary) -> Int {
        guard let id = collection.collectionId else { return 0 }
        let local = records.count { $0.collectionIds.contains(id) }
        return local > 0 ? local : (collection.count ?? 0)
    }

    func collectionNames(for record: Record) -> [String] {
        record.collectionIds.compactMap { id in
            collections.first { $0.collectionId == id }?.name
        }
    }

    // MARK: Internals

    private func refreshSessionOverview() {
        let tokens = accountSession.storedTokens()
        sessionOverview = SessionOverview(
            accountUUID: accountSession.claims?.uuid,
            accessTokenExpiresAt: accountSession.claims?.expiresAt,
            hasRefreshToken: tokens?.refreshToken?.isEmpty == false
        )
    }

    private func isSessionExpired(_ error: Error) -> Bool {
        if case ESError.sessionExpired = error { return true }
        if case ESError.notSignedIn = error { return true }
        return false
    }

    private func handle(_ error: Error) {
        if error is CancellationError { return }
        if isSessionExpired(error) {
            accountSession.clearTokens()
            records = []
            collections = []
            preferences = nil
            sessionOverview = nil
            phase = .needsToken((error as? ESError)?.errorDescription)
        } else {
            lastError = (error as? ESError)?.errorDescription ?? error.localizedDescription
        }
    }
}
