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
        projects.insert(project, at: 0)
        store.saveProjects(projects)
        return project
    }

    func save(_ project: VideoProject) {
        if let i = projects.firstIndex(where: { $0.id == project.id }) {
            projects[i] = project
        } else {
            projects.insert(project, at: 0)
        }
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
                save(result.project)
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
