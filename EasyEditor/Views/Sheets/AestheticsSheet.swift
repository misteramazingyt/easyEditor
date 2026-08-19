import SwiftUI

/// Project-wide look, picked by eye: every tile is the same frame wearing the
/// treatment, so you choose the depth of an effect by seeing it rather than by
/// reading its name.
struct AestheticsSheet: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss
    @State private var ntscStatus: NtscRSProcessor.Status = .idle

    private var settings: AestheticSettings {
        editor.project.aesthetic ?? AestheticSettings()
    }

    /// None, the two device shaders, then every ntsc-rs look.
    private enum Look: Identifiable {
        case mode(AestheticMode)
        case preset(AestheticPreset)

        var id: String {
            switch self {
            case .mode(let mode): return "mode." + mode.rawValue
            case .preset(let preset): return "preset." + preset.id
            }
        }

        var title: String {
            switch self {
            case .mode(let mode): return mode.title
            case .preset(let preset): return preset.name
            }
        }
    }

    private var looks: [Look] {
        [.mode(.none), .mode(.crt), .mode(.vhs)]
            + AestheticLibrary.presets.map { Look.preset($0) }
    }

    private let columns = [GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 20) {
                    gallery
                    if settings.mode != .none {
                        strengthSection
                        causticsSection
                        engineStatus
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
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

    // MARK: Gallery

    private var gallery: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(looks) { look in
                tile(look)
            }
        }
        .padding(.top, 4)
    }

    private func isSelected(_ look: Look) -> Bool {
        switch look {
        case .mode(let mode): return settings.mode == mode
        case .preset(let preset):
            return settings.mode == .ntsc && settings.presetID == preset.id
        }
    }

    private func select(_ look: Look) {
        editor.updateAesthetic { current in
            switch look {
            case .mode(let mode):
                current.mode = mode
            case .preset(let preset):
                current.mode = .ntsc
                current.presetID = preset.id
            }
        }
        Haptics.selection()
    }

    private func tile(_ look: Look) -> some View {
        let selected = isSelected(look)
        return Button { select(look) } label: {
            VStack(spacing: 6) {
                preview(look)
                    .aspectRatio(4 / 3, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(selected ? Color.accentColor : .white.opacity(0.12),
                                      lineWidth: selected ? 2.5 : 1))
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(5)
                        }
                    }
                Text(look.title)
                    .font(.system(size: 10, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? .white : .white.opacity(0.65))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func preview(_ look: Look) -> some View {
        switch look {
        case .mode(let mode):
            ShaderPreview(mode: mode)
        case .preset(let preset):
            if let image = AestheticPreview.bundled(preset.id) {
                Image(uiImage: image).resizable()
            } else {
                Self.placeholder("antenna.radiowaves.left.and.right")
            }
        }
    }

    /// CRT and VHS are rendered on the device, so their tiles fill in a beat
    /// after the sheet opens rather than holding it up.
    private struct ShaderPreview: View {
        let mode: AestheticMode
        @State private var image: UIImage?

        var body: some View {
            Group {
                if let image {
                    Image(uiImage: image).resizable()
                } else {
                    AestheticsSheet.placeholder(mode.systemImage)
                }
            }
            .task(id: mode) { image = await AestheticPreview.rendered(mode: mode) }
        }
    }

    /// No still to show yet — hold the shape rather than leave a hole in the
    /// grid.
    fileprivate static func placeholder(_ systemImage: String) -> some View {
        ZStack {
            Color.white.opacity(0.06)
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.5))
        }
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

    // MARK: Engine status

    /// When ntsc-rs won't take a preset it quietly runs its own defaults, and
    /// every look on the wheel comes out the same. That is worth saying out
    /// loud rather than leaving you to wonder why nothing changes.
    @ViewBuilder
    private var engineStatus: some View {
        let healthy = settings.mode != .ntsc || ntscStatus.isHealthy
        HStack(spacing: 6) {
            Image(systemName: healthy ? "checkmark.seal" : "exclamationmark.triangle.fill")
            Text(statusLine).lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(healthy ? Color.secondary : .orange)
        .task {
            while !Task.isCancelled {
                ntscStatus = NtscRSProcessor.shared.status
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private var statusLine: String {
        switch settings.mode {
        case .none: return ""
        case .crt, .vhs:
            return AestheticKernel.shared.isAvailable
                ? "Rendered on the GPU."
                : "Shaders unavailable — showing a filter-chain stand-in."
        case .ntsc:
            return ntscStatus.isHealthy
                ? "Rendered by ntsc-rs, from this preset."
                : ntscStatus.blurb
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold)).kerning(1.2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
