import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import UIKit
import VideoToolbox

/// Where the keyed camera sits on the canvas. Unit coordinates, y down;
/// scale 1 = the camera frame aspect-fills the canvas.
struct CameraFraming: Equatable {
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var scale: Double = 1

    static let identity = CameraFraming()
}

/// Lets the capture queue read framing the UI writes on the main thread.
final class CameraFramingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CameraFraming.identity

    func store(_ newValue: CameraFraming) {
        lock.lock(); value = newValue; lock.unlock()
    }

    func current() -> CameraFraming {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Thread-safe holder for the latest keyed camera frame, so the capture queue
/// and the Metal preview never touch the same CIImage reference at once.
final class LiveFrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CIImage?

    func store(_ newImage: CIImage?) {
        lock.lock(); image = newImage; lock.unlock()
    }

    func latest() -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        return image
    }
}

/// Records the front camera with the background removed (Vision person
/// segmentation) straight into a **HEVC-with-alpha** QuickTime movie, so the
/// resulting clip keeps real transparency when it lands on a timeline layer.
///
/// Devices that can't encode HEVC with alpha fall back to plain H.264 plus a
/// render-time `.person` cutout — the composite looks the same, it's just
/// re-segmented on playback instead of baked in.
final class LiveRecordingService: NSObject, ObservableObject,
                                  AVCaptureVideoDataOutputSampleBufferDelegate,
                                  AVCaptureAudioDataOutputSampleBufferDelegate {

    enum State: String { case idle, armed, recording, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: Double = 0
    @Published var errorMessage: String?

    /// Position and size of the camera on the canvas. Edited live from the
    /// preview's bounding box and baked into the recording, so what you frame
    /// is what gets written.
    @Published var framing = CameraFraming.identity {
        didSet { framingBox.store(framing) }
    }

    /// Latest keyed frame, for the on-screen overlay.
    let frames = LiveFrameBuffer()
    private let framingBox = CameraFramingBox()

    // MARK: Capture

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.easyeditor.capture.session")
    private let sampleQueue = DispatchQueue(label: "com.easyeditor.capture.samples")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var isConfigured = false

    // MARK: Writer (touched on sampleQueue once recording starts)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var renderSize = CGSize(width: 1080, height: 1920)
    private var isWriting = false
    private var sessionStarted = false
    private var recordedDuration = CMTime.zero
    private var segmentStart: CMTime?
    private var lastOutPTS = CMTime.zero
    private var appendedFrames = 0
    private var lastPublishedElapsed = -1.0

    /// True when the writer had to fall back to opaque H.264.
    private(set) var usedAlphaCodec = true

    // MARK: - Arm / disarm

    /// Ask for camera + mic access and start the capture session so the user
    /// can frame themselves before recording.
    func arm(renderSize: CGSize) async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            await MainActor.run { errorMessage = "Camera access is off. Enable it in Settings → EasyEditor." }
            return false
        }
        _ = await AVAudioApplication.requestRecordPermission()
        self.renderSize = renderSize

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording,
                                         options: [.defaultToSpeaker, .allowBluetooth,
                                                   .mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            Log.audio.error("Recording session setup failed: \(error.localizedDescription)")
        }

        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else { return continuation.resume(returning: false) }
                let configured = self.configureIfNeeded()
                if configured, !self.session.isRunning {
                    self.session.startRunning()
                }
                continuation.resume(returning: configured)
            }
        }
        await MainActor.run {
            if ok {
                state = .armed
            } else {
                errorMessage = "Couldn't start the camera."
            }
        }
        return ok
    }

    /// Stop the camera and drop back to playback audio.
    func disarm() {
        frames.store(nil)
        state = .idle
        elapsed = 0
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .moviePlayback)
        try? audioSession.setActive(true)
    }

    private func configureIfNeeded() -> Bool {
        if isConfigured { return true }
        session.beginConfiguration()
        // 720p keeps per-frame segmentation comfortably inside a 30 fps budget;
        // the frame is scaled up to the project canvas on the way out.
        session.sessionPreset = .hd1280x720

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: .front),
              let cameraInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(cameraInput) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(cameraInput)
        try? camera.lockForConfiguration()
        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        camera.unlockForConfiguration()

        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(videoOutput)

        audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        // Deliver upright, mirrored frames: Vision segments an upright person
        // far better, and a mirrored selfie is what people expect to see.
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
        session.commitConfiguration()
        isConfigured = true
        return true
    }

    // MARK: - Recording control

    /// Begin writing to `url`. Returns false if the writer can't be created.
    func startRecording(to url: URL) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let newWriter = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            errorMessage = "Couldn't create the recording file."
            return false
        }

        let width = Int(renderSize.width), height = Int(renderSize.height)
        // HEVC with alpha — the whole point: transparency survives to the file.
        let alphaSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                kVTCompressionPropertyKey_AlphaChannelMode as String:
                    kVTAlphaChannelMode_PremultipliedAlpha as String,
                AVVideoAverageBitRateKey: width * height * 6,
            ],
        ]
        let opaqueSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let canAlpha = newWriter.canApply(outputSettings: alphaSettings, forMediaType: .video)
        usedAlphaCodec = canAlpha
        if !canAlpha {
            Log.recording.info("HEVC-with-alpha unavailable — recording opaque + render-time cutout")
        }

        let video = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: canAlpha ? alphaSettings : opaqueSettings)
        video.expectsMediaDataInRealTime = true
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard newWriter.canAdd(video) else {
            errorMessage = "This device can't record with that setup."
            return false
        }
        newWriter.add(video)

        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 96_000,
        ])
        audio.expectsMediaDataInRealTime = true
        if newWriter.canAdd(audio) { newWriter.add(audio) }

        guard newWriter.startWriting() else {
            errorMessage = "Couldn't start recording: \(newWriter.error?.localizedDescription ?? "unknown")"
            return false
        }

        sampleQueue.async { [weak self] in
            guard let self else { return }
            self.writer = newWriter
            self.videoInput = video
            self.audioInput = audio
            self.adaptor = pixelAdaptor
            self.sessionStarted = false
            self.recordedDuration = .zero
            self.segmentStart = nil
            self.lastOutPTS = .zero
            self.appendedFrames = 0
            self.isWriting = true
        }
        state = .recording
        elapsed = 0
        lastPublishedElapsed = -1
        return true
    }

    func pause() {
        state = .paused
        sampleQueue.async { [weak self] in
            guard let self else { return }
            self.isWriting = false
            self.recordedDuration = self.lastOutPTS
            self.segmentStart = nil
        }
    }

    func resume() {
        state = .recording
        sampleQueue.async { [weak self] in
            self?.isWriting = true
        }
    }

    /// Stop and finalize. Returns the recorded duration, or nil if nothing usable.
    func finish() async -> Double? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            sampleQueue.async { [weak self] in
                guard let self else { return continuation.resume(returning: nil) }
                self.isWriting = false
                guard let writer = self.writer, self.appendedFrames > 0 else {
                    self.writer?.cancelWriting()
                    self.resetWriter()
                    return continuation.resume(returning: nil)
                }
                let duration = self.lastOutPTS.seconds
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting {
                    let ok = writer.status == .completed
                    if !ok {
                        Log.recording.error("Writer finish failed: \(writer.error?.localizedDescription ?? "?")")
                    }
                    self.sampleQueue.async {
                        self.resetWriter()
                        continuation.resume(returning: ok ? duration : nil)
                    }
                }
            }
        }
    }

    private func resetWriter() {
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        sessionStarted = false
        segmentStart = nil
    }

    // MARK: - Capture delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            handleAudio(sampleBuffer)
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Key the person out of the background, then fit the result to the
        // project canvas over transparency — preview and file get the same image.
        let raw = CIImage(cvPixelBuffer: buffer)
        var keyed = raw
        if let mask = CutoutService.personMask(buffer: buffer, scaledTo: raw.extent) {
            keyed = CutoutService.masked(raw, with: mask)
        }
        let canvas = CGRect(origin: .zero, size: renderSize)
        let framing = framingBox.current()
        let fill = max(canvas.width / keyed.extent.width, canvas.height / keyed.extent.height)
        let scale = fill * max(0.05, framing.scale)
        let scaled = keyed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Framing is y-down (UI space); Core Image is y-up.
        let target = CGPoint(x: canvas.width * framing.centerX,
                             y: canvas.height * (1 - framing.centerY))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: target.x - scaled.extent.midX,
            y: target.y - scaled.extent.midY))
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
        let composed = centered.composited(over: clear).cropped(to: canvas)

        frames.store(composed)

        guard isWriting, let writer, writer.status == .writing,
              let input = videoInput, input.isReadyForMoreMediaData,
              let adaptor, let pool = adaptor.pixelBufferPool else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
        }
        if segmentStart == nil { segmentStart = pts }
        let outPTS = CMTimeAdd(recordedDuration, CMTimeSubtract(pts, segmentStart ?? pts))

        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
        guard let destination = maybeBuffer else { return }
        ciContext.render(composed, to: destination, bounds: canvas,
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        if adaptor.append(destination, withPresentationTime: outPTS) {
            lastOutPTS = outPTS
            appendedFrames += 1
            publishElapsed(outPTS.seconds)
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, sessionStarted, let writer, writer.status == .writing,
              let input = audioInput, input.isReadyForMoreMediaData,
              let segmentStart else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // Skip audio that predates this segment's first video frame.
        guard CMTimeCompare(pts, segmentStart) >= 0 else { return }
        let outPTS = CMTimeAdd(recordedDuration, CMTimeSubtract(pts, segmentStart))
        if let retimed = Self.retimed(sampleBuffer, to: outPTS) {
            input.append(retimed)
        }
    }

    /// Shift a sample buffer's timing so pauses don't leave gaps.
    private static func retimed(_ sample: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil,
                                                    entriesNeededOut: &count) == noErr, count > 0 else {
            return nil
        }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings,
                                                    entriesNeededOut: &count) == noErr else {
            return nil
        }
        let first = timings[0].presentationTimeStamp
        for i in 0..<count {
            timings[i].presentationTimeStamp = CMTimeAdd(
                pts, CMTimeSubtract(timings[i].presentationTimeStamp, first))
            timings[i].decodeTimeStamp = .invalid
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timings,
            sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    /// ~10 Hz is plenty for a HUD and keeps SwiftUI off the capture path.
    private func publishElapsed(_ seconds: Double) {
        guard seconds - lastPublishedElapsed >= 0.1 || seconds < lastPublishedElapsed else { return }
        lastPublishedElapsed = seconds
        DispatchQueue.main.async { [weak self] in
            self?.elapsed = seconds
        }
    }
}
