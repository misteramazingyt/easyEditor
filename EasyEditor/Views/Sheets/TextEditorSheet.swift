import SwiftUI

/// Adds a Title (big, centered) or Text caption (lower third) to the timeline
/// at the playhead — TikTok-style fonts and treatments.
struct TextEditorSheet: View {
    let isTitle: Bool
    let onAdd: (TextPayload, OverlayPlacement) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var string = ""
    @State private var color: Color = .white
    @State private var fontIndex = 0
    @State private var treatment: Treatment = .classic
    @FocusState private var focused: Bool

    private enum Treatment: String, CaseIterable {
        case classic = "Classic"   // clean + soft shadow
        case plate = "Bubble"      // per-line rounded background
        case outline = "Outline"   // heavy black stroke
    }

    /// (label, bold PS name for titles, medium PS name for captions)
    private static let fonts: [(label: String, title: String, caption: String)] = [
        ("TikTok", "TikTokSans-Bold", "TikTokSans-SemiBold"),
        ("Black", "TikTokSans-Black", "TikTokSans-Bold"),
        ("Typewriter", "AmericanTypewriter-Bold", "AmericanTypewriter"),
        ("Handwriting", "BradleyHandITCTT-Bold", "BradleyHandITCTT-Bold"),
        ("Serif", "Georgia-Bold", "Georgia"),
        ("Rounded", "ArialRoundedMTBold", "ArialRoundedMTBold"),
    ]

    private var selectedFontName: String {
        let entry = Self.fonts[fontIndex]
        return isTitle ? entry.title : entry.caption
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                preview
                TextField(isTitle ? "Your title" : "Your caption", text: $string, axis: .vertical)
                    .font(.title3)
                    .focused($focused)
                    .padding(10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)

                fontChips

                Picker("Style", selection: $treatment) {
                    ForEach(Treatment.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                ColorPicker("Text color", selection: $color)
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .background(Color(red: 0.06, green: 0.07, blue: 0.1))
            .navigationTitle(isTitle ? "Add Title" : "Add Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { add() }
                        .disabled(string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                treatment = isTitle ? .classic : .plate
                focused = true
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.black)
            Text(string.isEmpty ? (isTitle ? "Title" : "Your caption") : string)
                .font(.custom(selectedFontName, size: isTitle ? 26 : 19))
                .foregroundStyle(treatment == .outline ? .white : color)
                .shadow(color: treatment == .classic ? .black.opacity(0.5) : .clear,
                        radius: 2, y: 1)
                .shadow(color: treatment == .outline ? .black : .clear, radius: 1)
                .shadow(color: treatment == .outline ? .black : .clear, radius: 2)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(treatment == .plate ? Color.black.opacity(0.7) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .lineLimit(2)
        }
        .frame(height: 84)
        .padding(.horizontal, 16)
    }

    private var fontChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(Self.fonts.enumerated()), id: \.offset) { index, entry in
                    Button {
                        fontIndex = index
                        Haptics.selection()
                    } label: {
                        Text(entry.label)
                            .font(.custom(entry.title, size: 14))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(fontIndex == index ? Color.blue.opacity(0.35) : .white.opacity(0.07),
                                        in: Capsule())
                            .overlay(Capsule()
                                .strokeBorder(fontIndex == index ? Color.blue : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func add() {
        var style = isTitle ? TextStyleModel.title : TextStyleModel.caption
        style.fontName = selectedFontName
        style.colorHex = color.toHex() ?? "#FFFFFF"
        switch treatment {
        case .classic:
            style.backgroundHex = nil
            style.hasShadow = true
            style.outline = nil
        case .plate:
            style.backgroundHex = "#000000B4"
            style.hasShadow = false
            style.outline = nil
        case .outline:
            style.backgroundHex = nil
            style.hasShadow = false
            style.outline = true
        }
        let payload = TextPayload(
            string: string.trimmingCharacters(in: .whitespacesAndNewlines),
            style: style)
        onAdd(payload, isTitle ? .title : .caption)
        dismiss()
    }
}
