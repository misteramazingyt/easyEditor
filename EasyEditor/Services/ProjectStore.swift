import Foundation

/// Loads and saves projects as JSON in Documents. Deliberately simple —
/// chosen over SwiftData for predictability (same pattern as GreenDeck).
struct ProjectStore {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func loadProjects() -> [VideoProject] {
        guard let data = try? Data(contentsOf: FilePaths.projectsStoreURL) else { return [] }
        do {
            return try decoder.decode([VideoProject].self, from: data)
        } catch {
            Log.store.error("Decode projects failed: \(error.localizedDescription)")
            return []
        }
    }

    func saveProjects(_ projects: [VideoProject]) {
        do {
            let data = try encoder.encode(projects)
            try data.write(to: FilePaths.projectsStoreURL, options: .atomic)
        } catch {
            Log.store.error("Save projects failed: \(error.localizedDescription)")
        }
    }

    /// Delete a project's media directory along with the project.
    func deleteMedia(projectID: UUID) {
        let dir = FilePaths.projectsDirectory.appendingPathComponent(projectID.uuidString)
        try? FileManager.default.removeItem(at: dir)
    }
}
