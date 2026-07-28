import SwiftUI

/// Adds a Title (big, centered) or Text caption (lower third) to the
/// purple titles lane at the playhead.
struct TextEditorSheet: View {
    let isTitle: Bool
    let onAdd: (TextPayload, OverlayPlacement) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var string = ""
    @State private var color: Color = .white
    @State private var withPlate = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(isTitle ? "Your title" : "Your caption", text: $string, axis: .vertical)
                        .font(.title3.weight(isTitle ? .bold : .regular))
                        .focused($focused)
                }
                Section("Style") {
                    ColorPicker("Text color", selection: $color)
                    Toggle("Background plate", isOn: $withPlate)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.07, green: 0.08, blue: 0.12))
            .navigationTitle(isTitle ? "Add Title" : "Add Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        var style = isTitle ? TextStyleModel.title : TextStyleModel.caption
                        style.colorHex = color.toHex() ?? "#FFFFFF"
                        style.backgroundHex = withPlate ? "#000000AA" : nil
                        let payload = TextPayload(
                            string: string.isEmpty ? (isTitle ? "Title" : "Text") : string,
                            style: style)
                        onAdd(payload, isTitle ? .title : .caption)
                        dismiss()
                    }
                    .disabled(string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                withPlate = !isTitle
                focused = true
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }
}
