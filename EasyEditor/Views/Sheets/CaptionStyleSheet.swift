import SwiftUI

/// What generated captions should look like, before going and making them.
///
/// The size lives here rather than being something you fix afterwards: the
/// tube caption's whole argument is that the box holds still while the words
/// change, and a box you have to resize per caption would give that away.
struct CaptionStyleSheet: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss
    let onGenerate: () -> Void

    @AppStorage("captionSkin") private var skinRaw = CaptionSkin.plain.rawValue
    @AppStorage("captionWidth") private var width = 0.86
    @AppStorage("captionAspect") private var aspect = 4.2
    @AppStorage("captionStrength") private var strength = 0.9

    private var skin: CaptionSkin { CaptionSkin(rawValue: skinRaw) ?? .plain }

    /// The defaults every generated caption is built from, and the sheet edits.
    static var stored: TextStyleModel {
        let defaults = UserDefaults.standard
        let skin = CaptionSkin(rawValue: defaults.string(forKey: "captionSkin") ?? "") ?? .plain
        guard skin == .tube else { return .caption }
        var tube = TubeCaptionStyle()
        if defaults.object(forKey: "captionWidth") != nil {
            tube.widthFraction = defaults.double(forKey: "captionWidth")
        }
        if defaults.object(forKey: "captionAspect") != nil {
            tube.aspect = defaults.double(forKey: "captionAspect")
        }
        if defaults.object(forKey: "captionStrength") != nil {
            tube.strength = defaults.double(forKey: "captionStrength")
        }
        return .tubeCaption(tube)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Style", selection: $skinRaw) {
                        ForEach(CaptionSkin.allCases) { option in
                            Label(option.title, systemImage: option.systemImage)
                                .tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(skin == .tube
                         ? "A little tube of its own, the same size for every line."
                         : "A bubble that hugs the words, as TikTok does it.")
                }

                if skin == .tube {
                    Section {
                        preview
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.black)
                    }

                    Section("Size") {
                        slider("Width", value: $width, range: 0.4...1,
                               format: { "\(Int($0 * 100))% of frame" })
                        slider("Shape", value: $aspect, range: 2.2...7,
                               format: { String(format: "%.1f : 1", $0) })
                        slider("Glass", value: $strength, range: 0...1,
                               format: { "\(Int($0 * 100))%" })
                    }
                }

                Section {
                    Button {
                        dismiss()
                        onGenerate()
                    } label: {
                        Label("Generate captions", systemImage: "captions.bubble")
                    }
                    .disabled(editor.isGeneratingCaptions)
                }
            }
            .navigationTitle("Captions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// The box at the size being chosen, against the frame it will sit in.
    private var preview: some View {
        GeometryReader { geo in
            let frameWidth = geo.size.width * 0.62
            let frameHeight = frameWidth * 16 / 9
            let boxWidth = frameWidth * width
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    .frame(width: frameWidth, height: frameHeight)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: 0.016, green: 0.026, blue: 0.014))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(red: 0.55, green: 0.68, blue: 1).opacity(0.5),
                                      lineWidth: 1))
                    .overlay(
                        Text("THE QUICK BROWN FOX")
                            .font(.system(size: max(6, boxWidth / 15),
                                          weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.78, green: 0.85, blue: 1))
                            .padding(4)
                            .minimumScaleFactor(0.4)
                    )
                    .frame(width: boxWidth, height: boxWidth / aspect)
                    .offset(y: frameHeight * 0.32)
            }
            .frame(width: geo.size.width, height: frameHeight + 24)
        }
        .frame(height: 260)
        .padding(.vertical, 12)
    }

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
