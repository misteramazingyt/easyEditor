import Foundation
import AVFoundation
import Combine

/// Owns the AVPlayer for the editor preview. Rebuilds the player item when the
/// project changes (preserving the playhead) and publishes time at 30 Hz.
@MainActor
final class PlaybackController: ObservableObject {

    let player = AVPlayer()

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var hasContent = false

    /// Called when the current item transitions to .failed (bad composition etc.).
    var onItemFailed: ((String) -> Void)?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var isScrubbing = false
    private var seekInFlight = false
    private var pendingSeek: Double?

    init() {
        player.actionAtItemEnd = .pause
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = max(0, time.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                self.isPlaying = false
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func install(_ built: BuiltComposition?) {
        let resumeTime = currentTime
        let wasPlaying = isPlaying
        player.pause()
        guard let built else {
            player.replaceCurrentItem(with: nil)
            hasContent = false
            isPlaying = false
            return
        }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .timeDomain
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "unknown error"
            Log.playback.error("Player item failed: \(message)")
            Task { @MainActor in
                self?.hasContent = false
                self?.onItemFailed?(message)
            }
        }
        player.replaceCurrentItem(with: item)
        hasContent = true
        let clamped = min(resumeTime, max(0, built.duration - 0.05))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        if wasPlaying {
            player.play()
        } else {
            isPlaying = false
        }
    }

    func playPause() {
        guard hasContent else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if let item = player.currentItem,
               currentTime >= item.duration.seconds - 0.05 {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = 0
            }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Scrub: coalesces rapid seeks so the player never falls behind the drag.
    func scrub(to seconds: Double) {
        guard hasContent else { return }
        isScrubbing = true
        pause()
        currentTime = max(0, seconds)
        requestSeek(to: currentTime)
    }

    func endScrub() {
        isScrubbing = false
    }

    private func requestSeek(to seconds: Double) {
        if seekInFlight {
            pendingSeek = seconds
            return
        }
        seekInFlight = true
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.requestSeek(to: next)
                }
            }
        }
    }
}
