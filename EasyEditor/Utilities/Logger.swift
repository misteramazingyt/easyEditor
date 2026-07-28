import Foundation
import os

/// Lightweight logging wrapper over os.Logger with stable subsystem/category.
enum Log {
    private static let subsystem = "com.easyeditor.app"

    static let store = Logger(subsystem: subsystem, category: "store")
    static let importer = Logger(subsystem: subsystem, category: "import")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let app = Logger(subsystem: subsystem, category: "app")
}
