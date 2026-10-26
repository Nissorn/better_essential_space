import AVFoundation
import BetterEssentialSpaceCore
import SwiftUI

/// The "Audio" card body: one tap on Play does whatever is missing. Cached
/// files play at once; otherwise the tap downloads (progress bar, Cancel) and
/// playback starts when the file lands. Renders AudioLibrary's state machine.
struct AudioCardView: View {
    let record: Record
    let library: AudioLibrary

    /// View-lifetime by design: playback stops on navigation and player ticks
    /// churn this object only, never AppModel or AudioLibrary.
    @State private var player = RecordPlayer()
    /// The tap-initiated "download, then play" flow. Cancelled on disappear, so
    /// a download that finishes after the user moved on never starts playback.
    @State private var playTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch library.state(for: record) {
            case .notDownloaded:
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: playTapped) {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    if let size = record.audioSizeBytes {
                        Text("Downloads \(size.formatted(.byteCount(style: .file))) on first play")
                            .font(ND.ui(12))
                            .foregroundStyle(ND.textTertiary)
                    }
                }

            case .downloading(let progress):
                HStack(spacing: 12) {
                    ProgressView(value: progress)
                    Text(progress.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Downloading…")
                        .font(ND.mono(12))
                        .monospacedDigit()
                        .foregroundStyle(ND.textSecondary)
                    Button("Cancel") {
                        playTask?.cancel()
                        library.cancelDownload(for: record)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

            case .ready(let url):
                playerControls(url: url)

            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(ND.ui(14))
                        .foregroundStyle(ND.error)
                    Button(action: playTapped) {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(.top, 14)
        .onDisappear {
            playTask?.cancel()
            player.stop()
        }
    }

    private var fallbackDuration: Double? {
        record.audioDurationMS.map { Double($0) / 1000 }
    }

    private func playTapped() {
        playTask?.cancel()
        playTask = Task {
            guard let url = try? await library.ensureDownloaded(record), !Task.isCancelled else { return }
            player.play(fileURL: url, fallbackDuration: fallbackDuration)
        }
    }

    private func playerControls(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    player.hasAudio ? player.toggle() : player.play(fileURL: url, fallbackDuration: fallbackDuration)
                } label: {
                    Label(
                        player.isPlaying ? "Pause" : "Play",
                        systemImage: player.isPlaying ? "pause.fill" : "play.fill"
                    )
                }
                .buttonStyle(SecondaryButtonStyle())
                if let duration = player.durationSeconds {
                    Text("\(timeCode(player.positionSeconds)) / \(timeCode(duration))")
                        .font(ND.mono(12))
                        .monospacedDigit()
                        .foregroundStyle(ND.textTertiary)
                }
            }
            if let duration = player.durationSeconds, duration > 0 {
                Slider(
                    value: Binding(
                        get: { player.positionSeconds },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...duration
                )
                .tint(ND.accent)
            }
            if let message = player.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(ND.ui(13))
                    .foregroundStyle(ND.error)
            }
        }
    }

    private func timeCode(_ seconds: Double) -> String {
        Duration.seconds(max(seconds, 0)).formatted(.time(pattern: .minuteSecond))
    }
}

/// AVPlayer wrapper, one per AudioCardView. Player ticks churn this object's
/// observers only — never AppModel, never AudioLibrary. Torn down on disappear,
/// so playback stops when navigation leaves the Record.
@MainActor @Observable
final class RecordPlayer {
    private(set) var isPlaying = false
    private(set) var hasAudio = false
    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double?
    /// Set when the item failed to load or play; cleared by the next `play`.
    private(set) var errorMessage: String?

    // Observer cleanup also runs from deinit (a nonisolated context), so the
    // handles are deliberately unchecked for isolation; every other access is
    // on the main actor.
    nonisolated(unsafe) private var avPlayer: AVPlayer?
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    nonisolated(unsafe) private var statusObserver: NSKeyValueObservation?
    private var durationTask: Task<Void, Never>?
    private var generation = 0

    /// Loads the local file and starts playback from the beginning. A freshly
    /// created item reports an indefinite duration, so the slider range starts
    /// from the Record's own metadata and is replaced by the asset's real
    /// duration once it loads.
    func play(fileURL: URL, fallbackDuration: Double?) {
        stop()
        let current = generation
        let asset = AVURLAsset(url: fileURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        avPlayer = player
        hasAudio = true
        durationSeconds = fallbackDuration
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.fail(generation: current) }
        }
        durationTask = Task { [weak self] in
            guard let duration = try? await asset.load(.duration),
                  let seconds = Self.seconds(of: duration)
            else { return }
            self?.adoptDuration(seconds, generation: current)
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.positionSeconds = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
        player.play()
        isPlaying = true
    }

    /// Flips the current player between play and pause.
    func toggle() {
        guard let avPlayer else { return }
        if isPlaying {
            avPlayer.pause()
            isPlaying = false
        } else {
            if let duration = durationSeconds, positionSeconds >= duration {
                seek(to: 0)
            }
            avPlayer.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard let avPlayer else { return }
        avPlayer.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        positionSeconds = seconds
    }

    /// Removes every observer and the player itself (called on disappear).
    /// Bumping `generation` orphans any in-flight duration load or status callback.
    func stop() {
        generation += 1
        durationTask?.cancel()
        durationTask = nil
        statusObserver?.invalidate()
        statusObserver = nil
        if let timeObserver {
            avPlayer?.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        avPlayer?.pause()
        avPlayer = nil
        timeObserver = nil
        endObserver = nil
        hasAudio = false
        isPlaying = false
        positionSeconds = 0
        durationSeconds = nil
        errorMessage = nil
    }

    private func adoptDuration(_ seconds: Double, generation: Int) {
        guard generation == self.generation else { return }
        durationSeconds = seconds
    }

    private func fail(generation: Int) {
        guard generation == self.generation else { return }
        stop()
        errorMessage = "This recording can't be played."
    }

    deinit {
        statusObserver?.invalidate()
        if let timeObserver {
            avPlayer?.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    private static func seconds(of duration: CMTime) -> Double? {
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            return nil
        }
        return duration.seconds
    }
}
