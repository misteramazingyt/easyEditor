import SwiftUI

/// Stack LUTs on a clip, each with its own amount.
///
/// Reads the way stacked adjustment layers do: a base grade at full strength,
/// a look over it at a third. The stack runs bottom to top, and each entry
/// grades what the ones below it produced.
struct LUTSheet: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    @State private var family: String = LUTLibrary.families.first ?? ""
    @State private var showPicker = false

    private var clip: TimelineClip? { editor.selectedClip }
    private var stack: [LUTLayer] { clip?.luts ?? [] }

    var body: some View {
        NavigationStack {
            Group {
                if LUTLibrary.all.isEmpty {
                    ContentUnavailableView("No LUTs bundled", systemImage: "swatchpalette",
                                           description: Text("The LUT pack didn't ship with this build."))
                } else {
                    list
                }
            }
            .navigationTitle("Colour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(clip == nil)
                }
            }
            .sheet(isPresented: $showPicker) { picker }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - The stack

    private var list: some View {
        List {
            if stack.isEmpty {
                Section {
                    Text("No LUTs on this clip. Add one with ＋.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(stack) { layer in
                Section {
                    HStack {
                        Text(LUTLibrary.entry(layer.lut)?.displayName ?? layer.lut)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(layer.opacity * 100))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { layer.opacity },
                        set: { value in setOpacity(layer.id, value) }
                    ), in: 0...1) { editing in
                        if editing { editor.beginGesture() }
                    }
                } header: {
                    Text(LUTLibrary.entry(layer.lut)?.family ?? "")
                }
            }
            .onDelete { offsets in remove(offsets) }
            .onMove { from, to in move(from, to) }

            if !stack.isEmpty {
                Section {
                    Button(role: .destructive) {
                        guard let id = clip?.id else { return }
                        editor.mutate(id) { $0.luts = nil }
                    } label: {
                        Label("Remove all", systemImage: "trash")
                    }
                } footer: {
                    Text("Applied bottom to top; drag to reorder.")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - Choosing one

    private var picker: some View {
        NavigationStack {
            List {
                Picker("Pack", selection: $family) {
                    ForEach(LUTLibrary.families, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                ForEach(LUTLibrary.luts(in: family)) { entry in
                    Button {
                        add(entry)
                        showPicker = false
                    } label: {
                        HStack {
                            Text(entry.name)
                            Spacer()
                            if entry.strength > 0 {
                                Text(String(repeating: "•", count: entry.strength))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add a LUT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showPicker = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Editing

    private func add(_ entry: LUTEntry) {
        guard let id = clip?.id else { return }
        editor.mutate(id) { c in
            var luts = c.luts ?? []
            // A second LUT over a first usually wants dialling back; full
            // strength on top of full strength is rarely what is meant.
            luts.append(LUTLayer(lut: entry.id, opacity: luts.isEmpty ? 1 : 0.5))
            c.luts = luts
        }
        Haptics.selection()
    }

    private func setOpacity(_ layerID: UUID, _ value: Double) {
        guard let id = clip?.id else { return }
        editor.mutateLive(id) { c in
            guard var luts = c.luts,
                  let index = luts.firstIndex(where: { $0.id == layerID }) else { return }
            luts[index].opacity = value
            c.luts = luts
        }
    }

    private func remove(_ offsets: IndexSet) {
        guard let id = clip?.id else { return }
        editor.mutate(id) { c in
            var luts = c.luts ?? []
            luts.remove(atOffsets: offsets)
            c.luts = luts.isEmpty ? nil : luts
        }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        guard let id = clip?.id else { return }
        editor.mutate(id) { c in
            var luts = c.luts ?? []
            luts.move(fromOffsets: from, toOffset: to)
            c.luts = luts
        }
    }
}
