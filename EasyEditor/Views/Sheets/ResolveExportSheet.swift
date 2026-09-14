import SwiftUI

/// Hand the edit to the desktop: FCPXML plus the media, fetched over the
/// local network from the phone itself.
struct ResolveExportSheet: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var server = ExportServer()

    @State private var package: ProjectPackager.Package?
    @State private var isBuilding = false
    @State private var failure: String?
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            Form {
                if let failure {
                    Section { Text(failure).font(.caption).foregroundStyle(.red) }
                }

                if let package {
                    Section {
                        if let address = server.address {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Open this on your computer")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(address)
                                    .font(.title3.monospaced().weight(.semibold))
                                    .textSelection(.enabled)
                                if server.downloads > 0 {
                                    Label("Fetched \(server.downloads) time"
                                          + (server.downloads == 1 ? "" : "s"),
                                          systemImage: "checkmark.circle")
                                        .font(.caption).foregroundStyle(.green)
                                }
                            }
                        } else {
                            Label("Starting the server…", systemImage: "wifi")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Over the network")
                    } footer: {
                        Text("Both devices on the same Wi-Fi. The server runs only while "
                             + "this screen is open.")
                    }

                    Section {
                        Button {
                            showShare = true
                        } label: {
                            Label("Share the archive instead", systemImage: "square.and.arrow.up")
                        }
                    } footer: {
                        Text("\(package.fileName) · "
                             + String(format: "%.1f MB", Double(package.byteCount) / 1_048_576))
                    }

                    if !package.notes.isEmpty {
                        Section("What doesn't cross over") {
                            ForEach(package.notes, id: \.self) { note in
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Section {
                        Label(isBuilding ? "Packing the project…" : "Preparing…",
                              systemImage: "shippingbox")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } footer: {
                        Text("The timeline as FCPXML 1.8, every file it uses, and a "
                             + "relink script — in one archive.")
                    }
                }
            }
            .navigationTitle("To Resolve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        server.stop()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let package {
                    ShareLink(item: package.url) { Text("Share") }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await build() }
        .onDisappear { server.stop() }
    }

    private func build() async {
        guard package == nil, !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }
        do {
            let made = try await ProjectPackager.makeArchive(for: editor.project)
            package = made
            server.start(package: made, projectName: editor.project.name)
        } catch {
            failure = "Couldn't pack the project: \(error.localizedDescription)"
        }
    }
}
