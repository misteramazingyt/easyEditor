import Foundation

enum TimeFormat {
    /// "00:04" style minutes:seconds.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Ruler labels: whole seconds as "4s", halves as "4.5s".
    static func ruler(_ seconds: Double) -> String {
        if seconds.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(seconds))s"
        }
        return String(format: "%.1fs", seconds)
    }

    /// "1.5x" speed label.
    static func speed(_ speed: Double) -> String {
        String(format: "%.2gx", speed)
    }
}
