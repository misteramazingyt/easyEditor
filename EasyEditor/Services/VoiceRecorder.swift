import Foundation
import AVFoundation

/// Records voiceover narration to an m4a inside the project's Media directory.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var fileName: String?
    private var projectID: UUID?

    func start(projectID: UUID) async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            permissionDenied = true
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            let name = "voiceover-\(UUID().uuidString).m4a"
            let url = FilePaths.mediaURL(projectID: projectID, fileName: name)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.record()

            self.recorder = recorder
            self.fileName = name
            self.projectID = projectID
            isRecording = true
            elapsed = 0
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let r = self.recorder else { return }
                    r.updateMeters()
                    self.elapsed = r.currentTime
                    // Map -50…0 dB to 0…1 for the level meter.
                    self.level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
                }
            }
        } catch {
            Log.audio.error("Voiceover start failed: \(error.localizedDescription)")
        }
    }

    /// Stops and returns (fileName, duration) if anything usable was captured.
    func stop() -> (fileName: String, duration: Double)? {
        meterTimer?.invalidate()
        meterTimer = nil
        guard let recorder, let fileName else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        // Hand ownership of the file to the caller; discard() must not delete it.
        self.fileName = nil
        isRecording = false
        restorePlaybackSession()
        guard duration > 0.2 else {
            if let projectID {
                try? FileManager.default.removeItem(
                    at: FilePaths.mediaURL(projectID: projectID, fileName: fileName))
            }
            return nil
        }
        return (fileName, duration)
    }

    func discard() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        if let projectID, let fileName {
            try? FileManager.default.removeItem(
                at: FilePaths.mediaURL(projectID: projectID, fileName: fileName))
        }
        recorder = nil
        isRecording = false
        restorePlaybackSession()
    }

    /// Put the shared session back into playback mode after recording so the
    /// editor's preview audio keeps working (and ignores the silent switch).
    private func restorePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}
