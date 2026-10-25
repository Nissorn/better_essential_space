import BetterEssentialSpaceCore
import Foundation
import Observation

/// Download orchestration for Record audio: the signed-URL protocol, the disk
/// cache, and one deduplicating task per gcsKey. States live here for the
/// app's lifetime — a download begun for one Record finishes even while
/// another is selected. It never holds an AVPlayer (that is view-lifetime
/// state, owned by RecordPlayer) and never touches AppModel.records.
@MainActor @Observable
final class AudioLibrary {
    /// One state per gcsKey. "No audio at all" is not a state — the view hides
    /// the Audio card when `record.audioFile == nil`.
    enum DownloadState: Equatable {
        case notDownloaded
        case downloading
        case ready(URL)
        /// User-presentable message; Retry re-enters `ensureDownloaded`.
        case failed(String)
    }

    private var states: [String: DownloadState] = [:]
    private var downloads: [String: Task<URL, Error>] = [:]
    private let client: ESClient
    private let store: AudioStore

    init(client: ESClient, store: AudioStore = AudioStore()) {
        self.client = client
        self.store = store
    }

    /// Disk-first: a file already on disk reads .ready even with no library
    /// history, so the button reappears as a player the moment bytes exist.
    func state(for record: Record) -> DownloadState {
        guard let gcsKey = record.audioFile?.gcsKey, !gcsKey.isEmpty else { return .notDownloaded }
        if let url = store.existingURL(forGcsKey: gcsKey) {
            return .ready(url)
        }
        return states[gcsKey] ?? .notDownloaded
    }

    /// Disk hit → immediate URL. Otherwise one download per gcsKey, shared by
    /// every concurrent caller (signUrls are never cached — one sign POST per
    /// download miss). Failures land in `state(for:)` as .failed, so callers
    /// may ignore the throw and render state instead.
    @discardableResult
    func ensureDownloaded(_ record: Record) async throws -> URL {
        guard let file = record.audioFile, let gcsKey = file.gcsKey, !gcsKey.isEmpty else {
            throw ESError.invalidResponse("this Record has no audio file to download")
        }
        if let url = store.existingURL(forGcsKey: gcsKey) { return url }
        if let existing = downloads[gcsKey] { return try await existing.value }

        states[gcsKey] = .downloading
        // Detached: the multi-MB atomic write must not run on the main actor.
        let download = Task.detached(priority: .userInitiated) { [client, store] in
            let data = try await client.downloadAudio(for: file)
            return try store.store(data, gcsKey: gcsKey)
        }
        downloads[gcsKey] = download
        defer { downloads[gcsKey] = nil }
        do {
            let url = try await download.value
            states[gcsKey] = .ready(url)
            return url
        } catch is CancellationError {
            states[gcsKey] = .notDownloaded
            throw CancellationError()
        } catch {
            states[gcsKey] = .failed(Self.presentable(error))
            throw error
        }
    }

    func cancelDownload(for record: Record) {
        guard let gcsKey = record.audioFile?.gcsKey else { return }
        downloads[gcsKey]?.cancel()
        downloads[gcsKey] = nil
        if states[gcsKey] != nil {
            states[gcsKey] = .notDownloaded
        }
    }

    /// Sign-out hygiene: cancels everything and forgets every state. The
    /// caller owns wiping the store itself (AppModel.signOut).
    func reset() {
        for download in downloads.values {
            download.cancel()
        }
        downloads = [:]
        states = [:]
    }

    /// Errors in the user's vocabulary: GCS 403/404 mean the recording is gone
    /// from Nothing's cloud; Foundation's stable offline wording maps to plain
    /// "you are offline"; everything else reads from the typed description.
    private static func presentable(_ error: Error) -> String {
        switch error {
        case ESError.httpStatus(403, _, _), ESError.httpStatus(404, _, _):
            return "This recording is no longer available on Nothing's cloud."
        case ESError.requestFailed(URLError(.notConnectedToInternet).localizedDescription):
            return "You appear to be offline — reconnect and try again."
        default:
            return (error as? ESError)?.errorDescription ?? error.localizedDescription
        }
    }
}
