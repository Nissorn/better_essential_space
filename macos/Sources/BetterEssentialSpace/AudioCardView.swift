import AVFoundation
import BetterEssentialSpaceCore
import SwiftUI

/// The "Audio" card body (issue 09): renders AudioLibrary's download state
/// machine — download button with the recording's size, spinner + cancel
/// while fetching, a player once the file is local, retry after a failure.
struct AudioCardView: View {
    let record: Record
    let library: AudioLibrary

    /// View-lifetime by design: playback stops on navigation and player ticks
    /// churn this object only, never AppModel or AudioLibrary.
    @State private var player = RecordPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch library.state(for: record) {
            case .notDownloaded:
                Button {
                    Task { try? await library.ensureDownloaded(record) }
                } label: {
                    Label(downloadLabel, systemImage: "arrow.down.circle")
                }
                .buttonStyle(SecondaryButtonStyle())

            case .downloading:
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading…")
                        .font(ND.ui(14))
                        .foregroundStyle(ND.textSecondary)
                    Spacer()
                    Button("Cancel") {
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
                    Button {
                        Task { try? await library.ensureDownloaded(record) }
                    } label: {
                        Label("Retry download", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(.top, 14)
        .onDisappear { player.stop() }
    }

    private var downloadLabel: String {
        let size = record.audioSizeBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "audio"
        return "Download audio (\(size))"
    }

    private func playerControls(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    player.hasAudio ? player.toggle() : player.play(fileURL: url)
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

    // Observer cleanup also runs from deinit (a nonisolated context), so the
    // handles are deliberately unchecked for isolation; every other access is
    // on the main actor.
    nonisolated(unsafe) private var avPlayer: AVPlayer?
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?

    /// Loads the local file and starts playback from the beginning.
    func play(fileURL: URL) {
        stop()
        let player = AVPlayer(url: fileURL)
        avPlayer = player
        hasAudio = true
        durationSeconds = Self.seconds(of: player.currentItem?.duration)
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
            object: player.currentItem,
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
    func stop() {
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
    }

    deinit {
        if let timeObserver {
            avPlayer?.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    private static func seconds(of duration: CMTime?) -> Double? {
        guard let duration, duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            return nil
        }
        return duration.seconds
    }
}
