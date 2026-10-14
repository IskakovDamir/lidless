import Foundation

/// What the app asks the daemon for. Rewritten every few seconds while a
/// closed-lid session runs; the file disappearing means "restore sleep now".
public struct ClosedLidLease: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var sessionID: String
    /// Unix time of the last refresh by the app.
    public var heartbeat: Double
    /// Unix time the session ends, nil for an unlimited session.
    public var sessionEnds: Double?
    /// False means unplugging the charger stops closed-lid protection.
    public var allowBattery: Bool
    /// Protection stops at or below this charge. The daemon never goes below its own floor.
    public var batteryCutoff: Int
    /// How long the Mac may keep running while closed. 0 means for the whole session.
    public var closedLimitMinutes: Int

    public init(sessionID: String, heartbeat: Double, sessionEnds: Double?, allowBattery: Bool,
                batteryCutoff: Int, closedLimitMinutes: Int) {
        self.version = Self.currentVersion
        self.sessionID = sessionID
        self.heartbeat = heartbeat
        self.sessionEnds = sessionEnds
        self.allowBattery = allowBattery
        self.batteryCutoff = batteryCutoff
        self.closedLimitMinutes = closedLimitMinutes
    }
}

public enum StopReason: String, Codable, Equatable, Sendable {
    case contactLost
    case sessionEnded
    case thermal
    case powerUnknown
    case chargerRequired
    case lowBattery
    case closedLimitReached
    case invalidLease
    case sleepSettingFailed

    public var message: String {
        switch self {
        case .contactLost: "Lost contact with the app. Normal sleep is back."
        case .sessionEnded: "The session ended."
        case .thermal: "Your Mac got too hot. Normal sleep is back."
        case .powerUnknown: "Power status is unavailable. Normal sleep is back."
        case .chargerRequired: "Charger disconnected. Normal sleep is back."
        case .lowBattery: "Battery reached the cutoff. Normal sleep is back."
        case .closedLimitReached: "Closed-lid time limit reached. The Mac went to sleep."
        case .invalidLease: "The app sent an invalid request."
        case .sleepSettingFailed: "macOS refused to change the sleep setting."
        }
    }

    /// When protection stops for one of these while the lid is closed, the Mac is put to sleep
    /// right away instead of waiting for the next lid event.
    public var sleepsClosedMac: Bool {
        switch self {
        case .closedLimitReached, .lowBattery, .thermal, .chargerRequired, .contactLost, .powerUnknown,
             .sessionEnded: true
        case .invalidLease, .sleepSettingFailed: false
        }
    }
}

public struct DaemonStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// No lease. Sleep settings are normal.
        case idle
        /// Sleep is disabled for the current lease.
        case holding
        /// The current lease was stopped by a safety rule. It stays stopped until a new session.
        case stopped
    }

    public var daemonVersion: String
    public var updatedAt: Double
    public var state: State
    public var sessionID: String?
    public var reason: StopReason?
    public var lidClosed: Bool?
    public var closedSince: Double?
    public var lastError: String?

    public init(daemonVersion: String, updatedAt: Double, state: State, sessionID: String?,
                reason: StopReason?, lidClosed: Bool?, closedSince: Double?, lastError: String?) {
        self.daemonVersion = daemonVersion
        self.updatedAt = updatedAt
        self.state = state
        self.sessionID = sessionID
        self.reason = reason
        self.lidClosed = lidClosed
        self.closedSince = closedSince
        self.lastError = lastError
    }

    /// Same content, ignoring the timestamp. Used to skip redundant writes.
    public func sameContent(as other: DaemonStatus) -> Bool {
        var a = self, b = other
        a.updatedAt = 0
        b.updatedAt = 0
        return a == b
    }
}

/// Written before the system setting changes, removed after it is restored.
public struct SleepJournal: Codable, Equatable, Sendable {
    public var previousSleepDisabled: Bool
    public var sessionID: String
    public var appliedAt: Double

    public init(previousSleepDisabled: Bool, sessionID: String, appliedAt: Double) {
        self.previousSleepDisabled = previousSleepDisabled
        self.sessionID = sessionID
        self.appliedAt = appliedAt
    }
}

public enum LidlessVersion {
    public static let string = "0.1.0"
}
