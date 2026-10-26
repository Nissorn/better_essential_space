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

    /// Per-Record push state for text edits as the UI shows it (issue 10).
    /// The optimistic edit is always already in `records`.
    enum EditSyncState: Equatable {
        case idle
        case pushing
        /// Keep the optimistic edit; Retry re-sends it.
        case failed(String)
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
    /// Download orchestration for Record audio (issue 09). Lives as long as the
    /// model so downloads survive selection changes; states are keyed by gcsKey.
    let audio: AudioLibrary
    private let client: ESClient
    private let authflow: AuthflowClient
    private let cacheURL: URL
    private let audioStore: AudioStore
    /// Edits the server has not confirmed, per Record: the merged delta, so a
    /// reload can re-apply it over the fresh server copy. Persisted with the
    /// snapshot so it also survives a relaunch.
    private var pendingEdits: [Record.ID: CardTextEdit] = [:]
    private var pushes: [Record.ID: PushState] = [:]
    private var pendingStateToken: String?
    private var loadTask: Task<Void, Never>?

    init(
        accountSession: AccountSession = AccountSession(),
        authflow: AuthflowClient = AuthflowClient(),
        client: ESClient? = nil,
        cacheURL: URL = RecordCache.defaultURL,
        audioStore: AudioStore = AudioStore()
    ) {
        self.accountSession = accountSession
        let resolvedClient = client ?? ESClient(accountSession: accountSession)
        self.client = resolvedClient
        self.authflow = authflow
        self.cacheURL = cacheURL
        self.audioStore = audioStore
        self.audio = AudioLibrary(client: resolvedClient, store: audioStore)
    }

    // MARK: Bootstrap (token import -> Keychain -> authenticated fetches)

    func bootstrap() {
        refreshSessionOverview()
        if accountSession.isSignedIn {
            loadCachedSnapshot()
            phase = .ready
            reload()
        } else {
            phase = .needsToken(nil)
        }
    }

    /// Shows the last snapshot instantly when it belongs to the signed-in
    /// account; the reload that follows replaces it with fresh data.
    private func loadCachedSnapshot() {
        guard records.isEmpty,
              let snapshot = RecordCache.load(from: cacheURL),
              snapshot.accountUUID == accountSession.claims?.uuid
        else { return }
        records = snapshot.records
        collections = snapshot.collections
        pendingEdits = snapshot.pendingEdits ?? [:]
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
        for case .inFlight(_, let task) in pushes.values {
            task.cancel()
        }
        pushes = [:]
        pendingEdits = [:]
        audio.reset()
        audioStore.removeAll()
        accountSession.clearTokens()
        RecordCache.remove(at: cacheURL)
        records = []
        collections = []
        preferences = nil
        sessionOverview = nil
        lastError = nil
        pendingStateToken = nil
        loginStage = .idle
        phase = .needsToken(nil)
    }

    // MARK: Text editing (issue 10)

    /// Transport state of one Record's pending edit; absent = nothing in flight
    /// and nothing failed.
    private enum PushState {
        /// At most one update request per Record. `sent` is the document it
        /// carries, so its completion can tell whether newer edits arrived.
        case inFlight(sent: String, task: Task<Void, Never>)
        /// The edit stays in `records` and `pendingEdits`; Retry re-sends it.
        case failed(String)
    }

    func editSyncState(for id: Record.ID) -> EditSyncState {
        switch pushes[id] {
        case nil: .idle
        case .inFlight: .pushing
        case .failed(let message): .failed(message)
        }
    }

    /// The single write path (issue 10). Optimistic: the edited Record is
    /// visible and persisted BEFORE any network. The Record is read from the
    /// model at commit time, so an edit always lands on the latest local copy.
    /// clientUpdateTime derives from record.updatedAt (stamped by `applying`),
    /// so last-write-wins with the phone app is the server's documented
    /// behaviour expressed through one clock.
    func save(_ edit: CardTextEdit, recordID: Record.ID) {
        guard let current = records.first(where: { $0.id == recordID }) else { return }
        let edit = Self.normalized(edit, against: current)
        let updated: Record
        do {
            updated = try current.applying(edit)
        } catch {
            show(error: error) // a raced edit (a topic vanished in a reload)
            return
        }
        guard updated.clientRequestResponse != current.clientRequestResponse else { return }
        pendingEdits[recordID] = pendingEdits[recordID]?.merged(with: edit) ?? edit
        upsert(updated)
        persistSnapshot()
        requestPush(recordID)
    }

    /// Retry re-sends the CURRENT optimistic record — no stored payload,
    /// nothing to lose.
    func retryEditPush(for id: Record.ID) {
        requestPush(id)
    }

    /// Titles are trimmed; a title that trims to empty keeps the current one
    /// (an empty topic title would also drop the topic from the decode).
    private static func normalized(_ edit: CardTextEdit, against record: Record) -> CardTextEdit {
        func trimmed(_ value: String) -> String? {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        var edit = edit
        edit.title = edit.title.flatMap(trimmed)
        edit.mainTopics = edit.mainTopics?.map { topic in
            let currentTitle = record.mainTopics.first { $0.id == topic.id }?.title ?? topic.title
            return MainTopic(id: topic.id, title: trimmed(topic.title) ?? currentTitle, content: topic.content)
        }
        return edit
    }

    private func requestPush(_ id: Record.ID) {
        if case .inFlight = pushes[id] { return } // its completion sends the newer document
        startPush(id)
    }

    private func startPush(_ id: Record.ID) {
        guard let record = records.first(where: { $0.id == id }) else {
            pushes[id] = nil
            return
        }
        let client = client
        let task = Task { [weak self] in
            let result: Result<Card?, Error>
            do {
                result = .success(try await client.updateCard(record))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return } // signed out meanwhile
            self?.finishPush(of: record, result: result)
        }
        pushes[id] = .inFlight(sent: record.clientRequestResponse, task: task)
    }

    private func finishPush(of sent: Record, result: Result<Card?, Error>) {
        let id = sent.id
        pushes[id] = nil
        let isLatest = records.first { $0.id == id }?.clientRequestResponse == sent.clientRequestResponse
        switch result {
        case .failure(let error):
            if pendingEdits[id] != nil {
                pushes[id] = .failed(Self.presentableEditError(error))
            }
        case .success(let echo) where isLatest:
            // The server echo wins when it decodes; the pushed value always lands.
            pendingEdits[id] = nil
            upsert(echo.flatMap { try? Record(card: $0) } ?? sent)
            persistSnapshot()
        case .success:
            // Newer edits arrived while this request was in flight: send them
            // now, and drop this echo so it cannot overwrite them.
            if pendingEdits[id] != nil { startPush(id) }
        }
    }

    /// A reload must not silently discard an edit the server has not
    /// confirmed: each pending edit is re-applied over the fresh server copy,
    /// and dropped once that copy already says the same.
    private func rebasingPendingEdits(onto fetched: [Record]) -> [Record] {
        var rebased = fetched
        for (id, edit) in pendingEdits {
            guard let index = rebased.firstIndex(where: { $0.id == id }) else {
                dropPendingEdit(id) // the Record left the account
                continue
            }
            do {
                let edited = try rebased[index].applying(edit)
                if edited.clientRequestResponse == rebased[index].clientRequestResponse {
                    dropPendingEdit(id)
                } else {
                    rebased[index] = edited
                }
            } catch {
                dropPendingEdit(id)
                show(error: error)
            }
        }
        return rebased
    }

    private func dropPendingEdit(_ id: Record.ID) {
        pendingEdits[id] = nil
        if case .failed = pushes[id] { pushes[id] = nil }
    }

    private func upsert(_ record: Record) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
            records.sort { $0.createdAt > $1.createdAt }
        }
    }

    private static func presentableEditError(_ error: Error) -> String {
        (error as? ESError)?.errorDescription ?? error.localizedDescription
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
        persistSnapshot()
    }

    /// Persists the current state for the next launch's instant start. A failed
    /// load keeps the previous `records`/`collections` in place, so this never
    /// caches a network failure as empty data.
    private func persistSnapshot() {
        guard let accountUUID = accountSession.claims?.uuid else { return }
        try? RecordCache.save(
            CachedSnapshot(
                accountUUID: accountUUID,
                records: records,
                collections: collections,
                pendingEdits: pendingEdits.isEmpty ? nil : pendingEdits
            ),
            to: cacheURL
        )
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
            records = rebasingPendingEdits(onto: fetched.sorted { $0.createdAt > $1.createdAt })
            lastError = nil
            for id in pendingEdits.keys {
                requestPush(id)
            }
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

    /// Records as the sidebar shows them: the Collection filter first, then the
    /// (case-insensitive) search query over every user-visible text field.
    func visibleRecords(collectionID: String?, searchQuery: String) -> [Record] {
        var result = filteredRecords(collectionID: collectionID)
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.matches(searchQuery: query) }
        }
        return result
    }

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
            audio.reset()
            audioStore.removeAll()
            accountSession.clearTokens()
            RecordCache.remove(at: cacheURL)
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
