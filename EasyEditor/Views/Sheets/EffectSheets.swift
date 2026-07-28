import SwiftUI

// MARK: - Effects browser (TikTok effect grid)

struct EffectsSheet: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss
    @State private var category = "Basic"

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 10)]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer().frame(width: 44)
                Spacer()
                Text("Effects").font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "checkmark").font(.headline)
                }
                .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Picker("Category", selection: $category) {
                ForEach(EffectPreset.categories, id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    effectCell(nil)
                    ForEach(EffectPreset.allCases.filter { $0.category == category }) { preset in
                        effectCell(preset)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .foregroundStyle(.white)
        .presentationDetents([.height(360)])
        .presentationBackground(Color(red: 0.07, green: 0.08, blue: 0.12))
    }

    private func effectCell(_ preset: EffectPreset?) -> some View {
        let isOn = editor.selectedClip?.effect == preset
        return Button {
            if let id = editor.selectedClipID {
                editor.mutate(id) { $0.effect = preset }
                Haptics.selection()
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: preset?.systemImage ?? "circle.slash")
                    .font(.system(size: 22))
                    .frame(width: 72, height: 58)
                    .background(isOn ? Color.blue.opacity(0.35) : .white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isOn ? Color.blue : .clear, lineWidth: 2))
                Text(preset?.displayName ?? "None")
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Retouch

struct RetouchSheet: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    if let id = editor.selectedClipID {
                        editor.mutate(id) { $0.adjustments.retouch = nil }
                    }
                } label: {
                    Label("Reset", systemImage: "arrow.uturn.backward").font(.caption)
                }
                Spacer()
                Text("Retouch").font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "checkmark").font(.headline)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Text("Softens skin and smooths detail")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Image(systemName: "face.dashed")
                Slider(value: Binding(
                    get: { editor.selectedClip?.adjustments.retouch ?? 0 },
                    set: { v in
                        if let id = editor.selectedClipID {
                            editor.mutateLive(id) { $0.adjustments.retouch = v }
                        }
                    }
                ), in: 0...1) { editing in
                    if editing { editor.beginGesture() }
                }
                Image(systemName: "face.smiling")
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .presentationDetents([.height(200)])
        .presentationBackground(Color(red: 0.07, green: 0.08, blue: 0.12))
    }
}

// MARK: - Mask

struct MaskSheet: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    private var mask: MaskSettings? {
        editor.selectedClip?.mask
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    if let id = editor.selectedClipID {
                        editor.mutate(id) { $0.mask = nil }
                    }
                } label: {
                    Label("None", systemImage: "circle.slash").font(.caption)
                }
                Spacer()
                Text("Mask").font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "checkmark").font(.headline)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            HStack(spacing: 10) {
                ForEach(MaskShape.allCases) { shape in
                    let isOn = mask?.shape == shape
                    Button {
                        if let id = editor.selectedClipID {
                            editor.mutate(id) { clip in
                                var settings = clip.mask ?? MaskSettings()
                                settings.shape = shape
                                clip.mask = settings
                            }
                            Haptics.selection()
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: shape.systemImage)
                                .font(.system(size: 17))
                                .frame(width: 56, height: 42)
                                .background(isOn ? Color.blue.opacity(0.35) : .white.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(isOn ? Color.blue : .clear, lineWidth: 2))
                            Text(shape.displayName).font(.system(size: 9))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if mask != nil {
                Group {
                    maskSlider("Size", keyPath: \.size, range: 0.1...1)
                    maskSlider("Feather", keyPath: \.feather, range: 0...0.5)
                    maskSlider("Horizontal", keyPath: \.centerX, range: 0...1)
                    maskSlider("Vertical", keyPath: \.centerY, range: 0...1)
                }
                .padding(.horizontal, 20)
                Toggle("Invert", isOn: Binding(
                    get: { mask?.isInverted ?? false },
                    set: { v in
                        if let id = editor.selectedClipID {
                            editor.mutate(id) { $0.mask?.isInverted = v }
                        }
                    }
                ))
                .padding(.horizontal, 20)
            } else {
                Text("Pick a shape to mask this clip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .presentationDetents([.height(420)])
        .presentationBackground(Color(red: 0.07, green: 0.08, blue: 0.12))
    }

    private func maskSlider(_ label: String,
                            keyPath: WritableKeyPath<MaskSettings, Double>,
                            range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { mask?[keyPath: keyPath] ?? range.lowerBound },
                set: { v in
                    if let id = editor.selectedClipID {
                        editor.mutateLive(id) { $0.mask?[keyPath: keyPath] = v }
                    }
                }
            ), in: range) { editing in
                if editing { editor.beginGesture() }
            }
        }
    }
}
