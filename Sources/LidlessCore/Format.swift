import Foundation

public enum DurationFormat {
    /// "1:42:05" or "42:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Compact text for the menu bar: "1:42" (hours:minutes) or "42m".
    public static func compact(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return String(format: "%d:%02d", h, m) }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    /// "2 h 30 min", "45 min", "1 h".
    public static func words(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }
}
