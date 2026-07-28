import SwiftUI
import CoreImage

/// Renders the project to MP4 and saves it to Photos.
struct ExportSheet: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case idle, building, exporting, saving, done, failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var progress: Double = 0
    @State private var exportService = ExportService()

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(.white.opacity(0.25)).frame(width: 36, height: 4).padding(.top, 8)
            Text("Export").font(.headline)

            HStack {
                Label(editor.project.aspect.rawValue, systemImage: "aspectratio")
                Spacer()
                Label(TimeFormat.clock(editor.project.duration), systemImage: "clock")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)

            Picker("Aspect", selection: Binding(
                get: { editor.project.aspect },
                set: { v in
                    editor.beginGesture()
                    editor.project.aspect = v
                }
            )) {
                ForEach(AspectPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .disabled(phase != .idle)

            switch phase {
            case .idle:
                Button {
                    Task { await run() }
                } label: {
                    Label("Export & Save to Photos", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
            case .building, .exporting, .saving:
                VStack(spacing: 8) {
                    ProgressView(value: phase == .exporting ? progress : nil)
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 24)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") {
                        exportService.cancel()
                        phase = .idle
                    }
                    .font(.caption)
                }
            case .done:
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Try Again") { phase = .idle }
                    .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .presentationDetents([.height(320)])
        .interactiveDismissDisabled(phase == .building || phase == .exporting || phase == .saving)
    }

    private var statusText: String {
        switch phase {
        case .building: return "Preparing composition…"
        case .exporting: return "Rendering \(Int(progress * 100))%"
        case .saving: return "Saving to Photos…"
        default: return ""
        }
    }

    private func run() async {
        phase = .building
        progress = 0
        let engine = CompositionEngine()
        let project = editor.project
        do {
            let overlays = await engine.renderOverlayImages(project: project)
            let built = try await engine.build(project: project, overlayImages: overlays)
            phase = .exporting
            let url = try await exportService.export(built: built,
                                                     projectName: project.name) { p in
                progress = p
            }
            phase = .saving
            try await PhotoLibraryService().saveVideo(at: url)
            phase = .done
            Haptics.success()
        } catch {
            phase = .failed(error.localizedDescription)
            Haptics.warning()
        }
    }
}
