import SwiftUI

/// Per-clip editing tools: actions (split/duplicate/delete), speed, volume,
/// filters, color adjustments, rotate/flip — the TikTok editor tool set.
struct ClipInspectorView: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss
    @State private var lengthField = ""
    @State private var lengthNote: String?

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

            lengthSection(for: clip)

            if clip.isVisual {
                transformSection(for: clip)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
    }

    /// Type a length rather than dragging for it: "30s", "1.5m", or a bare
    /// number of seconds. Footage clamps to the length of its own file.
    private func lengthSection(for clip: TimelineClip) -> some View {
        Section {
            HStack {
                TextField("30s", text: $lengthField)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { applyLength(clip) }
                Button("Set") { applyLength(clip) }
                    .buttonStyle(.bordered)
                    .disabled(EditorState.parseLength(lengthField) == nil)
            }
            Text(lengthNote ?? "Now \(TimeFormat.clock(clip.effectiveDuration)).")
                .font(.caption)
                .foregroundStyle(lengthNote == nil ? Color.secondary : Color.orange)
        } header: {
            Text("Length")
        }
    }

    private func applyLength(_ clip: TimelineClip) {
        guard let seconds = EditorState.parseLength(lengthField) else { return }
        let actual = editor.setLength(clip.id, seconds: seconds)
        lengthNote = abs(actual - seconds) > 0.05
            ? "Only \(TimeFormat.clock(actual)) of footage — that is the whole file."
            : nil
        lengthField = ""
        Haptics.selection()
    }

    /// The same numbers the canvas box drives, on sliders — and the same
    /// lozenge, so keying here and keying from the editing view are one act.
    @ViewBuilder
    private func transformSection(for clip: TimelineClip) -> some View {
        let live = editor.liveTransform(of: clip)
        Section {
            transformSlider("Horizontal", value: live.centerX, range: -0.25...1.25) { value in
                editor.updateTransform(clip.id, live: true) { $0.centerX = value }
            }
            transformSlider("Vertical", value: live.centerY, range: -0.25...1.25) { value in
                editor.updateTransform(clip.id, live: true) { $0.centerY = value }
            }
            transformSlider("Scale", value: live.scale, range: 0.05...3) { value in
                editor.updateTransform(clip.id, live: true) { $0.scale = value }
            }
            transformSlider("Rotation", value: live.rotation, range: -180...180,
                            format: "%.0f°") { value in
                editor.updateTransform(clip.id, live: true) { $0.rotation = value }
            }
            Button {
                editor.updateTransform(clip.id) { $0 = ClipTransform() }
            } label: {
                Label("Reset framing", systemImage: "arrow.counterclockwise")
            }
        } header: {
            HStack {
                Text("Motion")
                Spacer()
                KeyframeLozenge(marker: editor.motionMarker(of: clip),
                                easing: editor.motionEasing(of: clip),
                                compact: true,
                                onTap: { editor.toggleMotionKey(clip.id) },
                                onEasing: { editor.setMotionEasing(clip.id, $0) })
            }
        } footer: {
            if clip.motionKeys?.isActive == true {
                Text("Keyed. Moving the playhead and changing anything here adds the next keyframe.")
            }
        }
    }

    private func transformSlider(_ label: String, value: Double,
                                 range: ClosedRange<Double>,
                                 format: String = "%.2f",
                                 set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: range) { editing in
                if editing { editor.beginGesture() }
            }
        }
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
