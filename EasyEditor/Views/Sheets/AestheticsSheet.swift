import SwiftUI

/// Project-wide look: a treated backdrop under everything, light spilling off
/// the picture onto it, and a lighter dose of the same treatment over the top.
struct AestheticsSheet: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    private var settings: AestheticSettings {
        editor.project.aesthetic ?? AestheticSettings()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 20) {
                    modeSection
                    if settings.mode == .ntsc {
                        presetSection
                    }
                    if settings.mode != .none {
                        strengthSection
                        causticsSection
                    }
                    VStack(spacing: 4) {
                        label("Preview build")
                        Text(editor.buildSummary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .foregroundStyle(.white)
        .presentationDetents([.large])
        .presentationBackground(Color(red: 0.05, green: 0.06, blue: 0.09))
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline) }
            Spacer()
            Text("AESTHETICS").font(.subheadline.weight(.bold)).kerning(2)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "checkmark").font(.headline) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Mode

    private var modeSection: some View {
        VStack(spacing: 8) {
            label("Background")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(AestheticMode.allCases) { mode in
                    modeTile(mode)
                }
            }
            Text(modeBlurb)
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modeBlurb: String {
        switch settings.mode {
        case .none: return "No treatment — the canvas stays black."
        case .crt: return "Hard scanlines, aperture grille and phosphor glow."
        case .vhs: return "Smeared colour, unstable line, head-switch tear."
        case .ntsc: return "Broadcast signal: dot crawl and ringing, set by the preset below."
        }
    }

    private func modeTile(_ mode: AestheticMode) -> some View {
        let isOn = settings.mode == mode
        return Button {
            editor.updateAesthetic { current in
                current.mode = mode
                if mode != .none, current.presetID == nil {
                    current.presetID = AestheticLibrary.presets.first?.id
                }
            }
            Haptics.selection()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: mode.systemImage).font(.system(size: 18))
                Text(mode.title).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isOn ? .blue : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isOn ? Color.blue : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: Presets

    private var presetSection: some View {
        VStack(spacing: 8) {
            label("ntsc-rs preset")
            if AestheticLibrary.presets.isEmpty {
                Text("No presets found in the bundle.")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AestheticLibrary.presets) { preset in
                            presetChip(preset)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                Text("Parameters come from the ntsc-rs presets; the render is a real-time emulation of them.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func presetChip(_ preset: AestheticPreset) -> some View {
        let isOn = settings.presetID == preset.id
        return Button {
            editor.updateAesthetic { $0.presetID = preset.id }
            Haptics.selection()
        } label: {
            Text(preset.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(isOn ? Color.blue.opacity(0.35) : .white.opacity(0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Color.blue : .clear, lineWidth: 1.2))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: Strength & caustics

    private var strengthSection: some View {
        VStack(spacing: 4) {
            HStack {
                label("Aesthetic strength")
                Text("\(Int(settings.strength * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { settings.strength },
                set: { value in editor.updateAesthetic { $0.strength = value } }
            ), in: 0...1) { editing in
                if editing { editor.beginGesture() }
            }
        }
    }

    private var causticsSection: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                HStack {
                    label("Spill onto the background")
                    Text("\(Int(settings.caustics * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { settings.caustics },
                    set: { value in editor.updateAesthetic { $0.caustics = value } }
                ), in: 0...1) { editing in
                    if editing { editor.beginGesture() }
                }
            }
            Toggle(isOn: Binding(
                get: { settings.excludeCameraTakes },
                set: { value in editor.updateAesthetic { $0.excludeCameraTakes = value } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep camera takes out of the spill").font(.subheadline)
                    Text("Your own footage doesn't smear its glow across the room.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold)).kerning(1.2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
