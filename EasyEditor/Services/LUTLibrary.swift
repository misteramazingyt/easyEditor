import Foundation
import CoreImage

/// One bundled 3D LUT.
struct LUTEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let family: String
    /// How many dots the pack's own name carried — 1 is the gentlest version
    /// of a look, 5 the strongest. 0 for LUTs that come in one strength.
    let strength: Int
    let size: Int
    let offset: Int
    let length: Int

    var displayName: String {
        strength > 0 ? "\(name) \(String(repeating: "•", count: strength))" : name
    }
}

/// The bundled LUTs, and the colour cubes Core Image needs to apply them.
///
/// The `.cube` files are packed into one blob at 8 bits a channel: 131 of them
/// come to under two megabytes that way, against eight as floats, and a 16³
/// grid has nowhere near enough resolution for the difference to show.
enum LUTLibrary {

    static let all: [LUTEntry] = load()

    static func entry(_ id: String) -> LUTEntry? {
        all.first { $0.id == id }
    }

    /// Families, in the order they should be offered.
    static var families: [String] {
        var seen: [String] = []
        for lut in all where !seen.contains(lut.family) { seen.append(lut.family) }
        return seen
    }

    static func luts(in family: String) -> [LUTEntry] {
        all.filter { $0.family == family }
    }

    // MARK: - Loading

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let id: String
            let name: String
            let family: String
            let strength: Int
            let size: Int
            let offset: Int
            let length: Int
        }
        let luts: [Entry]
    }

    private static let blob: Data? = {
        guard let url = Bundle.main.url(forResource: "luts", withExtension: "bin") else {
            Log.engine.error("LUT blob missing from the bundle")
            return nil
        }
        return try? Data(contentsOf: url)
    }()

    private static func load() -> [LUTEntry] {
        guard let url = Bundle.main.url(forResource: "lut-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            Log.engine.error("LUT manifest missing or unreadable")
            return []
        }
        return manifest.luts.map {
            LUTEntry(id: $0.id, name: $0.name, family: $0.family, strength: $0.strength,
                     size: $0.size, offset: $0.offset, length: $0.length)
        }
    }

    // MARK: - Cubes

    private static let cacheLock = NSLock()
    private static var cubes: [String: Data] = [:]

    /// The LUT as Core Image wants it: premultiplied RGBA floats, B-major.
    static func cube(_ id: String) -> (data: Data, dimension: Int)? {
        guard let entry = entry(id) else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cubes[id] { return (hit, entry.size) }
        guard let blob, entry.offset + entry.length <= blob.count else { return nil }

        let count = entry.size * entry.size * entry.size
        var floats = [Float](repeating: 0, count: count * 4)
        blob.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: entry.offset)
                .assumingMemoryBound(to: UInt8.self)
            for i in 0..<count {
                floats[i * 4 + 0] = Float(base[i * 3 + 0]) / 255
                floats[i * 4 + 1] = Float(base[i * 3 + 1]) / 255
                floats[i * 4 + 2] = Float(base[i * 3 + 2]) / 255
                floats[i * 4 + 3] = 1
            }
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        cubes[id] = data
        return (data, entry.size)
    }
}
