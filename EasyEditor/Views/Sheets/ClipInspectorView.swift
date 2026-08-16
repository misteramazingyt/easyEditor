import SwiftUI

/// Per-clip editing tools: actions (split/duplicate/delete), speed, volume,
/// filters, color adjustments, rotate/flip — the TikTok editor tool set.
struct ClipInspectorView: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let clip = editor.selectedClip {
                    inspector(for: clip)
                } else {
                    ContentUnavailableView("No clip selected",
                                           systemImage: "rectangle.dashed",
                                           description: Text("Tap a clip in the timeline first."))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var title: String {
        switch editor.selectedClip?.kind {
        case .video: return "Video Clip"
        case .image: return "Image"
        case .title: return "Text"
        case .music: return "Music"
        case .voiceover: return "Voiceover"
        case .sfx: return "Sound Effect"
        case nil: return "Clip"
        }
    }

    @ViewBuilder
    private func inspector(for clip: TimelineClip) -> some View {
        List {
            Section {
                HStack(spacing: 12) {
                    actionButton("Split", "scissors") { editor.splitClip(clip.id) }
                    actionButton("Duplicate", "plus.square.on.square") { editor.duplicateClip(clip.id) }
                    actionButton("Delete", "trash", role: .destructive) {
                        editor.deleteClip(clip.id)
                        dismiss()
                    }
                }
                .listRowBackground(Color.clear)
                if clip.groupID != nil {
                    Button {
                        editor.ungroupClip(clip.id)
                    } label: {
                        Label("Ungroup", systemImage: "rectangle.split.3x1")
                    }
                }
            }

            if clip.canAdjustSpeed {
                Section("Speed — \(TimeFormat.speed(clip.speed))") {
                    Slider(value: Binding(
                        get: { editor.selectedClip?.speed ?? 1 },
                        set: { v in editor.mutateLive(clip.id) { $0.speed = v } }
                    ), in: 0.3...3, step: 0.05) { editing in
                        if editing { editor.beginGesture() }
                    }
                    HStack {
                        ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { preset in
                            Button(TimeFormat.speed(preset)) {
                                editor.mutate(clip.id) { $0.speed = preset }
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                }
            }

            if clip.hasAudio {
                Section("Volume") {
                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(value: Binding(
                            get: { editor.selectedClip?.volume ?? 1 },
                            set: { v in editor.mutateLive(clip.id) { $0.volume = v } }
                        ), in: 0...2) { editing in
                            if editing { editor.beginGesture() }
                        }
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    Toggle("Mute", isOn: Binding(
                        get: { editor.selectedClip?.isMuted ?? false },
                        set: { v in editor.mutate(clip.id) { $0.isMuted = v } }
                    ))
                }
            }

            if clip.kind == .video {
                Section("Filter") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(FilterPreset.allCases) { preset in
                                Button {
                                    editor.mutate(clip.id) { $0.filter = preset }
                                    Haptics.selection()
                                } label: {
                                    Text(preset.displayName)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(clip.filter == preset ? Color.blue : .white.opacity(0.08),
                                                    in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Adjust") {
                    adjustmentSlider("Brightness", value: Binding(
                        get: { editor.selectedClip?.adjustments.brightness ?? 0 },
                        set: { v in editor.mutateLive(clip.id) { $0.adjustments.brightness = v } }
                    ), range: -0.5...0.5)
                    adjustmentSlider("Contrast", value: Binding(
                        get: { editor.selectedClip?.adjustments.contrast ?? 1 },
                        set: { v in editor.mutateLive(clip.id) { $0.adjustments.contrast = v } }
                    ), range: 0.5...1.5)
                    adjustmentSlider("Saturation", value: Binding(
                        get: { editor.selectedClip?.adjustments.saturation ?? 1 },
                        set: { v in editor.mutateLive(clip.id) { $0.adjustments.saturation = v } }
                    ), range: 0...2)
                    Button("Reset adjustments") {
                        editor.mutate(clip.id) { $0.adjustments = Adjustments() }
                    }
                }

                Section("Orientation") {
                    HStack(spacing: 12) {
                        actionButton("Rotate", "rotate.right") {
                            editor.mutate(clip.id) { $0.rotationQuarterTurns += 1 }
                        }
                        actionButton(clip.isFlippedH ? "Unflip" : "Flip", "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                            editor.mutate(clip.id) { $0.isFlippedH.toggle() }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }

            if clip.kind == .title, let payload = clip.text {
                Section("Text") {
                    TextField("Text", text: Binding(
                        get: { editor.selectedClip?.text?.string ?? "" },
                        set: { v in editor.mutateLive(clip.id) { $0.text?.string = v } }
                    ), axis: .vertical)
                    ColorPicker("Color", selection: Binding(
                        get: { Color.fromHex(payload.style.colorHex) },
                        set: { c in
                            if let hex = c.toHex() {
                                editor.mutate(clip.id) { $0.text?.style.colorHex = hex }
                            }
                        }
                    ))
                    adjustmentSlider("Size", value: Binding(
                        get: { editor.selectedClip?.text?.style.fontSize ?? 72 },
                        set: { v in editor.mutateLive(clip.id) { $0.text?.style.fontSize = v } }
                    ), range: 24...160)
                }
            }

            if clip.kind == .image || clip.kind == .title {
                Section("Position") {
                    adjustmentSlider("Horizontal", value: Binding(
                        get: { editor.selectedClip?.placement?.centerX ?? 0.5 },
                        set: { v in editor.mutateLive(clip.id) { $0.placement?.centerX = v } }
                    ), range: 0...1)
                    adjustmentSlider("Vertical", value: Binding(
                        get: { editor.selectedClip?.placement?.centerY ?? 0.5 },
                        set: { v in editor.mutateLive(clip.id) { $0.placement?.centerY = v } }
                    ), range: 0...1)
                    adjustmentSlider("Scale", value: Binding(
                        get: { editor.selectedClip?.placement?.widthFraction ?? 0.6 },
                        set: { v in editor.mutateLive(clip.id) { $0.placement?.widthFraction = v } }
                    ), range: 0.1...1)
                    adjustmentSlider("Opacity", value: Binding(
                        get: { editor.selectedClip?.placement?.opacity ?? 1 },
                        set: { v in editor.mutateLive(clip.id) { $0.placement?.opacity = v } }
                    ), range: 0.05...1)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
    }

    private func adjustmentSlider(_ label: String, value: Binding<Double>,
                                  range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { editing in
                if editing { editor.beginGesture() }
            }
        }
    }

    private func actionButton(_ label: String, _ systemImage: String,
                              role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? .red : .white)
    }
}

extension Color {
    /// "#RRGGBB" from a SwiftUI color (best effort).
    func toHex() -> String? {
        guard let components = UIColor(self).cgColor.components else { return nil }
        let r = components.count > 0 ? components[0] : 0
        let g = components.count > 1 ? components[1] : r
        let b = components.count > 2 ? components[2] : r
        return String(format: "#%02X%02X%02X",
                      Int(max(0, min(1, r)) * 255),
                      Int(max(0, min(1, g)) * 255),
                      Int(max(0, min(1, b)) * 255))
    }
}
