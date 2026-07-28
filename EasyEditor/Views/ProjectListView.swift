import SwiftUI

/// The project library ("book" icon in the editor). Dark, simple, grid of
/// projects with create/rename/delete.
struct ProjectListView: View {
    @EnvironmentObject private var state: AppState
    @State private var openProject: VideoProject?
    @State private var renaming: VideoProject?
    @State private var renameText = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    newProjectCard
                    ForEach(state.projects) { project in
                        projectCard(project)
                    }
                }
                .padding()
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.09))
            .navigationTitle("EasyEditor")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .fullScreenCover(item: $openProject) { project in
                EditorView(project: project)
            }
            .alert("Rename project", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let project = renaming {
                        state.rename(project, to: renameText.isEmpty ? project.name : renameText)
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private var newProjectCard: some View {
        Button {
            openProject = state.createProject()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 40))
                Text("New Project")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 130)
            .background(.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func projectCard(_ project: VideoProject) -> some View {
        Button {
            openProject = project
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "film.stack")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    Spacer()
                    Text(TimeFormat.clock(project.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(project.clips.count) clip\(project.clips.count == 1 ? "" : "s") · \(project.modifiedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameText = project.name
                renaming = project
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                state.delete(project)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

#Preview {
    ProjectListView().environmentObject(AppState())
}
