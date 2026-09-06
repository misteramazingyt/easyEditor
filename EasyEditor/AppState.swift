import Foundation
import SwiftUI

/// Project library: list, create, rename, delete. Each open editor session
/// gets its own `EditorState`; saves flow back through here.
@MainActor
final class AppState: ObservableObject {

    @Published var projects: [VideoProject] = []
    /// Result/failure message for a share-sheet import (drives an alert).
    @Published var importAlert: String?

    private let store = ProjectStore()

    init() {
        projects = store.loadProjects()
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    @discardableResult
    func createProject(name: String? = nil) -> VideoProject {
        let number = projects.count + 1
        let project = VideoProject(name: name ?? "Project \(number)")
        add(project)
        return project
    }

    /// Put a project into the library. The only way one gets in: everything
    /// else may update what is already there, never conjure it back.
    func add(_ project: VideoProject) {
        projects.insert(project, at: 0)
        store.saveProjects(projects)
    }

    /// An editor writing its work back.
    ///
    /// This updates an existing project and will not create one. An editor can
    /// still be closing — flushing a last save — while you delete the project
    /// from the list, and an insert here would quietly bring it back; that is
    /// why deleted projects returned after a restart.
    ///
    /// The name is not the editor's to write either. It holds whatever the
    /// project was called when it opened, so a rename made in the list would
    /// be overwritten by a stale copy on the way out. The list owns the name;
    /// the editor owns the contents.
    func save(_ project: VideoProject) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
        updated.name = projects[i].name
        updated.modifiedAt = Date()
        projects[i] = updated
        store.saveProjects(projects)
    }

    func rename(_ project: VideoProject, to name: String) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[i].name = name
        projects[i].modifiedAt = Date()
        store.saveProjects(projects)
    }

    func delete(_ project: VideoProject) {
        projects.removeAll { $0.id == project.id }
        store.deleteMedia(projectID: project.id)
        store.saveProjects(projects)
    }

    // MARK: - Incoming files (GreenDeck .gdproj via the share sheet)

    func handleIncomingFile(_ url: URL) {
        guard url.pathExtension.lowercased() == "gdproj" else { return }
        Task {
            do {
                let result = try await GreenDeckImportService.importProject(from: url)
                add(result.project)
                var message = "Imported “\(result.project.name)” — \(result.imported) clip\(result.imported == 1 ? "" : "s")"
                if result.skipped > 0 {
                    message += " (\(result.skipped) skipped)"
                }
                importAlert = message
                Log.app.info("GreenDeck import: \(message)")
            } catch {
                importAlert = "Import failed: \(error.localizedDescription)"
                Log.app.error("GreenDeck import failed: \(error.localizedDescription)")
            }
        }
    }
}
