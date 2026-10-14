import Foundation

enum SessionMode: String, CaseIterable, Identifiable {
    case timer, until, unlimited
    var id: String { rawValue }
    var title: String {
        switch self {
        case .timer: "Timer"
        case .until: "Until"
        case .unlimited: "Unlimited"
        }
    }
}

/// Small typed wrapper over UserDefaults.
enum Store {
    private static let defaults = UserDefaults.standard

    enum Key: String {
        case mode, timerMinutes, untilTime, closedLidEnabled, closedLimitMinutes
        case requireCharger, endOnLowBattery, batteryCutoff, keepDisplayOn, showTimeInMenuBar
    }

    static func bool(_ key: Key, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    static func int(_ key: Key, _ fallback: Int) -> Int {
        defaults.object(forKey: key.rawValue) as? Int ?? fallback
    }

    static func string(_ key: Key, _ fallback: String) -> String {
        defaults.string(forKey: key.rawValue) ?? fallback
    }

    static func date(_ key: Key, _ fallback: Date) -> Date {
        defaults.object(forKey: key.rawValue) as? Date ?? fallback
    }

    static func set(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}

enum Choices {
    static let timerPresets = [15, 30, 60, 120, 240, 480]
    /// 0 means "for the whole session".
    static let closedLimits = [30, 60, 120, 240, 480, 0]
    static let batteryCutoffs = Array(stride(from: 10, through: 80, by: 5))
}
