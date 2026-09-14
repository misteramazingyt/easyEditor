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

    /// Read the library, salvaging whatever is readable.
    ///
    /// The whole file used to be decoded in one go, which meant a single
    /// project the current build could not read — one field added since it was
    /// saved, one clip with something unexpected in it — returned an empty
    /// array and looked exactly like having no projects at all. Now a failure
    /// is retried project by project, so a bad one costs itself and nothing
    /// else, and it says in the log which one it was.
    func loadProjects() -> [VideoProject] {
        guard let data = try? Data(contentsOf: FilePaths.projectsStoreURL) else { return [] }
        if let projects = try? decoder.decode([VideoProject].self, from: data) {
            return projects
        }
        Log.store.error("Whole-library decode failed; salvaging project by project")
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            Log.store.error("Projects file is not an array; leaving it alone")
            return []
        }
        var salvaged: [VideoProject] = []
        for (index, item) in raw.enumerated() {
            guard let itemData = try? JSONSerialization.data(withJSONObject: item) else { continue }
            do {
                salvaged.append(try decoder.decode(VideoProject.self, from: itemData))
            } catch {
                let name = (item as? [String: Any])?["name"] as? String ?? "#\(index)"
                Log.store.error("Could not read project \(name): \(error.localizedDescription)")
            }
        }
        Log.store.info("Salvaged \(salvaged.count) of \(raw.count) projects")
        return salvaged
    }

    func saveProjects(_ projects: [VideoProject]) {
        do {
            let data = try encoder.encode(projects)
            // Keep the last good copy. Writing is atomic, so this is not about
            // a torn file — it is about being able to go back if a build ever
            // writes something a later one chokes on.
            backUpExistingStore()
            try data.write(to: FilePaths.projectsStoreURL, options: .atomic)
        } catch {
            Log.store.error("Save projects failed: \(error.localizedDescription)")
        }
    }

    private func backUpExistingStore() {
        let url = FilePaths.projectsStoreURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent("projects.backup.json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    /// Delete a project's media directory along with the project.
    func deleteMedia(projectID: UUID) {
        let dir = FilePaths.projectsDirectory.appendingPathComponent(projectID.uuidString)
        try? FileManager.default.removeItem(at: dir)
    }
}
