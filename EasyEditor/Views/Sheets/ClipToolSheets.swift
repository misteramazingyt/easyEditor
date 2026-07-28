import SwiftUI

/// Small TikTok-style tool sheets for the selected clip: speed (0.1×–10×),
/// volume, filters, adjust (temp/tint/hue/vignette/…), opacity.

// MARK: - Shared chrome

private struct ToolSheetChrome<Content: View>: View {
    let title: String
    let onReset: (() -> Void)?
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                if let onReset {
                    Button {
                        onReset()
                    } label: {
                        Label("Reset", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                } else {
                    Spacer().frame(width: 60)
                }
                Spacer()
                Text(title).font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.headline)
                }
                .frame(width: 60, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            content
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .presentationDetents([.height(230)])
        .presentationBackground(Color(red: 0.07, green: 0.08, blue: 0.12))
    }
}

// MARK: - Speed (0.1x – 10x, log scale like TikTok)

struct SpeedSheet: View {
    @EnvironmentObject private var editor: EditorState

    private var clipID: UUID? { editor.selectedClipID }

    private var speed: Double {
        editor.selectedClip?.speed ?? 1
    }

    var body: some View {
        ToolSheetChrome(title: "Speed — \(TimeFormat.speed(speed))", onReset: {
            if let id = clipID { editor.mutate(id) { $0.speed = 1 } }
        }) {
            VStack(spacing: 14) {
                Slider(value: Binding(
                    get: { log10(speed) },
                    set: { v in
                        guard let id = clipID else { return }
                        let newSpeed = (pow(10, v) * 20).rounded() / 20
                        editor.mutateLive(id) { $0.speed = min(10, max(0.1, newSpeed)) }
                    }
                ), in: -1...1) { editing in
                    if editing { editor.beginGesture() }
                }
                .padding(.horizontal, 20)

                HStack(spacing: 8) {
                    ForEach([0.5, 1.0, 2.0, 5.0, 10.0], id: \.self) { preset in
                        Button(TimeFormat.speed(preset)) {
                            guard let id = clipID else { return }
                            editor.mutate(id) { $0.speed = preset }
                            Haptics.selection()
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(abs(speed - preset) < 0.01 ? Color.blue : .white.opacity(0.08),
                                    in: Capsule())
                        .foregroundStyle(.white)
                    }
                }
            }
        }
    }
}

// MARK: - Volume

struct VolumeSheet: View {
    @EnvironmentObject private var editor: EditorState

    var body: some View {
        ToolSheetChrome(title: "Volume", onReset: {
            if let id = editor.selectedClipID {
                editor.mutate(id) { $0.volume = 1; $0.isMuted = false }
            }
        }) {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: Binding(
                        get: { editor.selectedClip?.volume ?? 1 },
                        set: { v in
                            if let id = editor.selectedClipID {
                                editor.mutateLive(id) { $0.volume = v; $0.isMuted = false }
                            }
                        }
                    ), in: 0...2) { editing in
                        if editing { editor.beginGesture() }
                    }
                    Image(systemName: "speaker.wave.3.fill")
                }
                .padding(.horizontal, 20)

                Toggle(isOn: Binding(
                    get: { editor.selectedClip?.isMuted ?? false },
                    set: { v in
                        if let id = editor.selectedClipID {
                            editor.mutate(id) { $0.isMuted = v }
                        }
                    }
                )) {
                    Text("Mute")
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

// MARK: - Filters

struct FilterSheet: View {
    @EnvironmentObject private var editor: EditorState

    var body: some View {
        ToolSheetChrome(title: "Filters", onReset: {
            if let id = editor.selectedClipID { editor.mutate(id) { $0.filter = .none } }
        }) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilterPreset.allCases) { preset in
                        let isOn = editor.selectedClip?.filter == preset
                        Button {
                            if let id = editor.selectedClipID {
                                editor.mutate(id) { $0.filter = preset }
                                Haptics.selection()
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: preset == .none ? "circle.slash" : "camera.filters")
                                    .font(.title3)
                                    .frame(width: 54, height: 44)
                                    .background(isOn ? Color.blue.opacity(0.35) : .white.opacity(0.07),
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(isOn ? Color.blue : .clear, lineWidth: 2))
                                Text(preset.displayName)
                                    .font(.system(size: 10))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Adjust (TikTok parameter row + one slider)

struct AdjustSheet: View {
    @EnvironmentObject private var editor: EditorState

    private enum Param: String, CaseIterable, Identifiable {
        case brightness = "Brightness"
        case contrast = "Contrast"
        case saturation = "Saturation"
        case temp = "Temp"
        case tint = "Tint"
        case hue = "Hue"
        case vignette = "Vignette"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .brightness: return "sun.max"
            case .contrast: return "circle.lefthalf.filled"
            case .saturation: return "drop"
            case .temp: return "thermometer.medium"
            case .tint: return "eyedropper.halffull"
            case .hue: return "paintpalette"
            case .vignette: return "circle.dashed.inset.filled"
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .brightness: return -0.5...0.5
            case .contrast: return 0.5...1.5
            case .saturation: return 0...2
            case .temp, .tint, .hue: return -1...1
            case .vignette: return 0...1
            }
        }
    }

    @State private var param: Param = .brightness

    var body: some View {
        ToolSheetChrome(title: "Adjust", onReset: {
            if let id = editor.selectedClipID {
                editor.mutate(id) { $0.adjustments = Adjustments() }
            }
        }) {
            VStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Param.allCases) { candidate in
                            Button {
                                param = candidate
                                Haptics.selection()
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: candidate.systemImage)
                                        .font(.system(size: 16))
                                        .frame(width: 46, height: 38)
                                        .background(param == candidate ? Color.white.opacity(0.18) : .white.opacity(0.06),
                                                    in: RoundedRectangle(cornerRadius: 9))
                                        .overlay(RoundedRectangle(cornerRadius: 9)
                                            .strokeBorder(param == candidate ? .white : .clear, lineWidth: 1.5))
                                    Text(candidate.rawValue)
                                        .font(.system(size: 9))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Slider(value: binding(for: param), in: param.range) { editing in
                    if editing { editor.beginGesture() }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func binding(for param: Param) -> Binding<Double> {
        Binding(
            get: {
                let adj = editor.selectedClip?.adjustments ?? Adjustments()
                switch param {
                case .brightness: return adj.brightness
                case .contrast: return adj.contrast
                case .saturation: return adj.saturation
                case .temp: return adj.temp ?? 0
                case .tint: return adj.tint ?? 0
                case .hue: return adj.hue ?? 0
                case .vignette: return adj.vignette ?? 0
                }
            },
            set: { value in
                guard let id = editor.selectedClipID else { return }
                editor.mutateLive(id) { clip in
                    switch param {
                    case .brightness: clip.adjustments.brightness = value
                    case .contrast: clip.adjustments.contrast = value
                    case .saturation: clip.adjustments.saturation = value
                    case .temp: clip.adjustments.temp = value
                    case .tint: clip.adjustments.tint = value
                    case .hue: clip.adjustments.hue = value
                    case .vignette: clip.adjustments.vignette = value
                    }
                }
            })
    }
}

// MARK: - Opacity

struct OpacitySheet: View {
    @EnvironmentObject private var editor: EditorState

    var body: some View {
        ToolSheetChrome(title: "Opacity", onReset: {
            if let id = editor.selectedClipID { editor.mutate(id) { $0.opacity = nil } }
        }) {
            HStack {
                Image(systemName: "circle.dotted")
                Slider(value: Binding(
                    get: { editor.selectedClip?.effectiveOpacity ?? 1 },
                    set: { v in
                        if let id = editor.selectedClipID {
                            editor.mutateLive(id) { $0.opacity = v }
                        }
                    }
                ), in: 0.05...1) { editing in
                    if editing { editor.beginGesture() }
                }
                Image(systemName: "circle.fill")
            }
            .padding(.horizontal, 20)
        }
    }
}
