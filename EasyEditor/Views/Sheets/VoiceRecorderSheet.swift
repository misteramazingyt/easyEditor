import SwiftUI

/// Records a voiceover that lands on the voice lane at the playhead
/// position captured when the sheet opened.
struct VoiceRecorderSheet: View {
    let projectID: UUID
    let startTime: Double
    let onFinish: (_ fileName: String, _ duration: Double, _ at: Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceRecorder()

    var body: some View {
        VStack(spacing: 24) {
            Capsule().fill(.white.opacity(0.25)).frame(width: 36, height: 4).padding(.top, 8)
            Text("Voiceover").font(.headline)
            Text("Records from \(TimeFormat.clock(startTime)) on the timeline")
                .font(.caption).foregroundStyle(.secondary)

            // Level meter
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.08))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(recorder.isRecording ? Color.red : Color.blue)
                            .frame(width: geo.size.width * CGFloat(recorder.level))
                            .animation(.linear(duration: 0.05), value: recorder.level)
                    }
            }
            .frame(height: 8)
            .padding(.horizontal, 32)

            Text(TimeFormat.clock(recorder.elapsed))
                .font(.system(size: 40, weight: .bold).monospacedDigit())

            Button {
                if recorder.isRecording {
                    if let (fileName, duration) = recorder.stop() {
                        onFinish(fileName, duration, startTime)
                        Haptics.success()
                    }
                    dismiss()
                } else {
                    Task { await recorder.start(projectID: projectID) }
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white.opacity(0.6), lineWidth: 3)
                        .frame(width: 72, height: 72)
                    RoundedRectangle(cornerRadius: recorder.isRecording ? 6 : 28)
                        .fill(.red)
                        .frame(width: recorder.isRecording ? 30 : 56,
                               height: recorder.isRecording ? 30 : 56)
                        .animation(.snappy(duration: 0.2), value: recorder.isRecording)
                }
            }
            .buttonStyle(.plain)

            if recorder.permissionDenied {
                Text("Microphone access is off. Enable it in Settings → EasyEditor.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .presentationDetents([.height(340)])
        .interactiveDismissDisabled(recorder.isRecording)
        .onDisappear { recorder.discard() }
    }
}
