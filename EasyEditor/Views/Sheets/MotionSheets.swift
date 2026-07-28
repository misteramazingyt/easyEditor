import SwiftUI

/// In/Out entrance-exit animation panel, looping Animation panel, and
/// Compositing panel for connected clips (never the main track).

// MARK: - Shared bits

private let panelBackground = Color(red: 0.06, green: 0.07, blue: 0.1)

private struct PanelHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline)
            }
            Spacer()
            Text(title.uppercased()).font(.subheadline.weight(.bold)).kerning(1.5)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "checkmark").font(.headline)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold)).kerning(1.2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.0f"
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                FieldLabel(label)
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
        }
    }
}

// MARK: - In/Out panel

struct InOutSheet: View {
    @EnvironmentObject private var editor: EditorState
    @State private var editingEnd = false   // false = BEGINNING, true = END

    private var clipID: UUID? { editor.selectedClipID }
    private var settings: InOutSettings { editor.selectedClip?.inOut ?? InOutSettings(isEnabled: false) }
    private var config: EndConfig { editingEnd ? settings.end : settings.begin }

    var body: some View {
        VStack(spacing: 14) {
            PanelHeader(title: "In/Out")
            ScrollView {
                VStack(spacing: 16) {
                    enableRow
                    presetRow
                    globalRow
                    endPicker
                    anchorSection
                    easingSection
                    durationSection
                    animateSection
                    focusSection
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }
        }
        .foregroundStyle(.white)
        .presentationDetents([.large])
        .presentationBackground(panelBackground)
    }

    private var enableRow: some View {
        Toggle("Enable In/Out", isOn: Binding(
            get: { editor.selectedClip?.inOut?.isEnabled ?? false },
            set: { on in
                editor.beginGesture()
                editor.updateInOut(id) { $0.isEnabled = on }
            }
        ))
    }

    private var presetRow: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                FieldLabel("Speed Preset")
                presetMenu(selection: settings.speedPreset.rawValue,
                           options: SpeedPreset.allCases.map(\.rawValue)) { raw in
                    guard let preset = SpeedPreset(rawValue: raw) else { return }
                    editor.beginGesture()
                    editor.updateInOut(id) { $0.applySpeedPreset(preset) }
                }
            }
            VStack(spacing: 4) {
                FieldLabel("Motion Preset")
                presetMenu(selection: settings.motionPreset.rawValue,
                           options: MotionPresetChoice.allCases.map(\.rawValue)) { raw in
                    guard let preset = MotionPresetChoice(rawValue: raw) else { return }
                    editor.beginGesture()
                    editor.updateInOut(id) { $0.applyMotionPreset(preset) }
                }
            }
        }
    }

    private var globalRow: some View {
        Toggle("Global", isOn: Binding(
            get: { settings.isGlobal },
            set: { on in
                editor.beginGesture()
                editor.updateInOut(id) { $0.isGlobal = on }
            }
        ))
    }

    private var endPicker: some View {
        Picker("End", selection: $editingEnd) {
            Text("BEGINNING").tag(false)
            Text("END").tag(true)
        }
        .pickerStyle(.segmented)
    }

    private var anchorSection: some View {
        VStack(spacing: 6) {
            FieldLabel("Anchor Point")
            anchorGrid
        }
    }

    private var easingSection: some View {
        VStack(spacing: 6) {
            FieldLabel("Easing")
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    Text("IN").font(.caption2).foregroundStyle(.secondary)
                    easingMenu(config.easeIn) { curve in
                        setConfig(markSpeedCustom: true) { $0.easeIn = curve }
                    }
                }
                Divider().frame(height: 30)
                VStack(spacing: 4) {
                    Text("OUT").font(.caption2).foregroundStyle(.secondary)
                    easingMenu(config.easeOut) { curve in
                        setConfig(markSpeedCustom: true) { $0.easeOut = curve }
                    }
                }
            }
        }
    }

    private var durationSection: some View {
        ValueSlider(label: "Duration (frames)",
                    value: Binding(
                        get: { config.durationFrames },
                        set: { v in setConfig(markSpeedCustom: true) { $0.durationFrames = v.rounded() } }
                    ),
                    range: 1...120) { editing in
            if editing { editor.beginGesture() }
        }
    }

    private var animateSection: some View {
        VStack(spacing: 8) {
            FieldLabel("Animate")
            animateTiles
            animateOverrides
        }
    }

    private var animateTiles: some View {
        HStack(spacing: 10) {
            animateTile("Scale", "square.resize",
                        isOn: config.animateScale) { on in
                setConfig(markMotionCustom: true) { $0.animateScale = on }
            }
            animateTile("Rotation", "rotate.right",
                        isOn: config.animateRotation) { on in
                setConfig(markMotionCustom: true) { $0.animateRotation = on }
            }
            animateTile("Position", "arrow.up.and.down.and.arrow.left.and.right",
                        isOn: config.animatePosition) { on in
                setConfig(markMotionCustom: true) { $0.animatePosition = on }
            }
        }
    }

    @ViewBuilder
    private var animateOverrides: some View {
        if config.animateScale {
            ValueSlider(label: editingEnd ? "Scale out to" : "Scale in from",
                        value: Binding(
                            get: { config.scaleValue },
                            set: { v in setConfig(markMotionCustom: true) { $0.scaleValue = v } }
                        ),
                        range: 0...2, format: "%.2f") { if $0 { editor.beginGesture() } }
        }
        if config.animateRotation {
            ValueSlider(label: "Rotation (degrees)",
                        value: Binding(
                            get: { config.rotationDegrees },
                            set: { v in setConfig(markMotionCustom: true) { $0.rotationDegrees = v.rounded() } }
                        ),
                        range: 0...720) { if $0 { editor.beginGesture() } }
        }
        if config.animatePosition {
            ValueSlider(label: "Distance (× screen)",
                        value: Binding(
                            get: { config.positionDistance },
                            set: { v in setConfig(markMotionCustom: true) { $0.positionDistance = v } }
                        ),
                        range: 0.2...2, format: "%.2f") { if $0 { editor.beginGesture() } }
        }
    }

    private var focusSection: some View {
        VStack(spacing: 4) {
            FieldLabel("Focus (main track)")
            presetMenu(selection: (editor.selectedClip?.focus ?? .none).rawValue,
                       options: FocusStyle.allCases.map(\.rawValue)) { raw in
                guard let style = FocusStyle(rawValue: raw) else { return }
                editor.beginGesture()
                editor.setFocus(id, style)
            }
        }
    }

    private var id: UUID { clipID ?? UUID() }

    private func setConfig(markSpeedCustom: Bool = false, markMotionCustom: Bool = false,
                           _ change: @escaping (inout EndConfig) -> Void) {
        let isEnd = editingEnd
        editor.updateInOut(id) { io in
            if isEnd { change(&io.end) } else { change(&io.begin) }
            if markSpeedCustom { io.speedPreset = .custom }
            if markMotionCustom { io.motionPreset = .custom }
        }
    }

    private func presetMenu(selection: String, options: [String],
                            onPick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) { onPick(option) }
            }
        } label: {
            HStack {
                Text(selection.uppercased()).font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.down").font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
        .foregroundStyle(.white)
    }

    private func easingMenu(_ current: EasingCurve,
                            onPick: @escaping (EasingCurve) -> Void) -> some View {
        Menu {
            ForEach(EasingCurve.allCases) { curve in
                Button(curve.displayName) { onPick(curve) }
            }
        } label: {
            HStack {
                Text(current.displayName.uppercased())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                Image(systemName: "chevron.down").font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
        .foregroundStyle(.white)
    }

    private var anchorGrid: some View {
        let rows: [[AnchorPoint]] = [
            [.topLeft, .top, .topRight],
            [.left, .center, .right],
            [.bottomLeft, .bottom, .bottomRight],
        ]
        return VStack(spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 1) {
                    ForEach(row) { anchor in
                        Button {
                            setConfig(markMotionCustom: true) { $0.anchor = anchor }
                            Haptics.selection()
                        } label: {
                            Image(systemName: config.anchor == anchor ? "plus" : "circle.fill")
                                .font(.system(size: config.anchor == anchor ? 15 : 5))
                                .foregroundStyle(config.anchor == anchor ? .blue : .white.opacity(0.5))
                                .frame(width: 56, height: 40)
                                .background(.white.opacity(0.05))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func animateTile(_ label: String, _ systemImage: String,
                             isOn: Bool, onToggle: @escaping (Bool) -> Void) -> some View {
        Button {
            editor.beginGesture()
            onToggle(!isOn)
            Haptics.selection()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title3)
                Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).kerning(1)
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
}

// MARK: - Looping Animation panel

struct AnimationSheet: View {
    @EnvironmentObject private var editor: EditorState

    private var id: UUID { editor.selectedClipID ?? UUID() }
    private var settings: LoopAnimationSettings {
        editor.selectedClip?.loopFx ?? LoopAnimationSettings()
    }

    var body: some View {
        VStack(spacing: 14) {
            PanelHeader(title: "Animation")
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 4) {
                        FieldLabel("Animation Preset")
                        Menu {
                            ForEach(LoopPreset.allCases) { preset in
                                Button(preset.rawValue) {
                                    editor.beginGesture()
                                    editor.updateLoop(id) { $0.preset = preset }
                                }
                            }
                        } label: {
                            HStack {
                                Text(settings.preset.rawValue.uppercased())
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.down").font(.caption)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 12)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .foregroundStyle(.white)
                    }

                    Toggle("Global", isOn: Binding(
                        get: { settings.isGlobal },
                        set: { on in
                            editor.beginGesture()
                            editor.updateLoop(id) { $0.isGlobal = on }
                        }
                    ))

                    if settings.preset != .none {
                        VStack(spacing: 14) {
                            FieldLabel("\(settings.preset.rawValue) settings")

                            if settings.preset == .oscillation {
                                Picker("Mode", selection: Binding(
                                    get: { settings.mode },
                                    set: { mode in
                                        editor.beginGesture()
                                        editor.updateLoop(id) { $0.mode = mode }
                                    }
                                )) {
                                    ForEach(OscillationMode.allCases) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }

                            HStack(spacing: 14) {
                                ValueSlider(label: "Amount", value: Binding(
                                    get: { settings.amount },
                                    set: { v in editor.updateLoop(id) { $0.amount = v.rounded() } }
                                ), range: 1...100) { if $0 { editor.beginGesture() } }
                                ValueSlider(label: "Speed", value: Binding(
                                    get: { settings.speed },
                                    set: { v in editor.updateLoop(id) { $0.speed = v.rounded() } }
                                ), range: 5...200) { if $0 { editor.beginGesture() } }
                            }

                            HStack(spacing: 12) {
                                VStack(spacing: 4) {
                                    FieldLabel("Easing")
                                    Menu {
                                        ForEach(EasingCurve.allCases) { curve in
                                            Button(curve.displayName) {
                                                editor.beginGesture()
                                                editor.updateLoop(id) { $0.easing = curve }
                                            }
                                        }
                                    } label: {
                                        menuLabel(settings.easing.displayName)
                                    }
                                }
                                VStack(spacing: 4) {
                                    FieldLabel("Loop Type")
                                    Menu {
                                        ForEach(LoopType.allCases) { type in
                                            Button(type.rawValue) {
                                                editor.beginGesture()
                                                editor.updateLoop(id) { $0.loopType = type }
                                            }
                                        }
                                    } label: {
                                        menuLabel(settings.loopType.rawValue)
                                    }
                                }
                            }

                            ValueSlider(label: "Phase offset", value: Binding(
                                get: { settings.phase },
                                set: { v in editor.updateLoop(id) { $0.phase = v } }
                            ), range: 0...5, format: "%.2f") { if $0 { editor.beginGesture() } }
                        }
                        .padding(14)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }
        }
        .foregroundStyle(.white)
        .presentationDetents([.large])
        .presentationBackground(panelBackground)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack {
            Text(text.uppercased()).font(.subheadline.weight(.semibold))
            Spacer()
            Image(systemName: "chevron.down").font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
    }
}

// MARK: - Compositing panel

struct CompositingSheet: View {
    @EnvironmentObject private var editor: EditorState

    private var id: UUID { editor.selectedClipID ?? UUID() }
    private var settings: CompositingSettings {
        editor.selectedClip?.compositing ?? CompositingSettings(effect: .none)
    }

    var body: some View {
        VStack(spacing: 14) {
            PanelHeader(title: "Compositing")
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        FieldLabel("Effects")
                        HStack(spacing: 10) {
                            ForEach(CompositingEffect.allCases) { effect in
                                effectCell(effect)
                            }
                        }
                    }

                    if settings.effect != .none {
                        VStack(spacing: 14) {
                            FieldLabel("\(settings.effect.rawValue) settings")
                            if settings.effect == .dropShadow {
                                HStack(spacing: 14) {
                                    ValueSlider(label: "Offset X", value: binding(\.offsetX),
                                                range: -80...80) { if $0 { editor.beginGesture() } }
                                    ValueSlider(label: "Offset Y", value: binding(\.offsetY),
                                                range: -80...80) { if $0 { editor.beginGesture() } }
                                }
                            }
                            HStack(spacing: 14) {
                                ValueSlider(label: "Blur", value: binding(\.blur),
                                            range: 0...100) { if $0 { editor.beginGesture() } }
                                ValueSlider(label: "Opacity", value: binding(\.opacity),
                                            range: 0...1, format: "%.2f") { if $0 { editor.beginGesture() } }
                            }
                            if settings.effect == .dropShadow || settings.effect == .outline {
                                ValueSlider(label: "Spread", value: binding(\.spread),
                                            range: 0...40) { if $0 { editor.beginGesture() } }
                            }
                            if settings.effect != .blur {
                                ColorPicker("Color", selection: Binding(
                                    get: { Color.fromHex(settings.colorHex, fallback: .black) },
                                    set: { color in
                                        if let hex = color.toHex() {
                                            editor.updateCompositing(id) { $0.colorHex = hex }
                                        }
                                    }
                                ))
                            }
                        }
                        .padding(14)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }
        }
        .foregroundStyle(.white)
        .presentationDetents([.medium, .large])
        .presentationBackground(panelBackground)
    }

    private func binding(_ keyPath: WritableKeyPath<CompositingSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { v in editor.updateCompositing(id) { $0[keyPath: keyPath] = v } })
    }

    private func effectCell(_ effect: CompositingEffect) -> some View {
        let isOn = settings.effect == effect
        return Button {
            editor.beginGesture()
            editor.updateCompositing(id) { $0.effect = effect }
            Haptics.selection()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: effect.systemImage)
                    .font(.system(size: 18))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(isOn ? Color.blue.opacity(0.3) : .white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isOn ? Color.blue : .clear, lineWidth: 1.5))
                Text(effect.rawValue)
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
