import Foundation

public struct PowerSnapshot: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case adapter, battery, unknown }

    public var source: Source
    /// nil on Macs without a battery.
    public var batteryPercent: Int?
    public var hasBattery: Bool
    /// False when macOS reports serious or critical thermal pressure.
    public var thermalOK: Bool

    public init(source: Source, batteryPercent: Int?, hasBattery: Bool, thermalOK: Bool) {
        self.source = source
        self.batteryPercent = batteryPercent
        self.hasBattery = hasBattery
        self.thermalOK = thermalOK
    }
}

public enum ClosedLidVerdict: Equatable, Sendable {
    case hold
    case stop(StopReason)
}

/// Pure decision logic for the daemon. Everything that keeps a closed Mac awake goes through here.
public enum ClosedLidRules {
    /// Protection always stops at this charge, whatever the app asks for.
    public static let batteryFloor = 10
    public static let allowedCutoffs = Array(stride(from: 10, through: 80, by: 5))

    public static func validate(_ lease: ClosedLidLease) -> Bool {
        lease.version == ClosedLidLease.currentVersion
            && !lease.sessionID.isEmpty && lease.sessionID.count <= 64
            && (0...100).contains(lease.batteryCutoff)
            && (0...(24 * 60)).contains(lease.closedLimitMinutes)
            && lease.heartbeat.isFinite
            && (lease.sessionEnds?.isFinite ?? true)
    }

    /// - Parameter closedFor: seconds the lid has been closed continuously while protection held.
    public static func evaluate(lease: ClosedLidLease, now: Double, power: PowerSnapshot,
                                closedFor: TimeInterval) -> ClosedLidVerdict {
        guard validate(lease) else { return .stop(.invalidLease) }

        let age = now - lease.heartbeat
        if age > LidlessTiming.leaseTimeout || age < -60 { return .stop(.contactLost) }
        if let ends = lease.sessionEnds, now >= ends { return .stop(.sessionEnded) }
        if !power.thermalOK { return .stop(.thermal) }

        switch power.source {
        case .unknown:
            return .stop(.powerUnknown)
        case .battery:
            guard lease.allowBattery else { return .stop(.chargerRequired) }
            guard let percent = power.batteryPercent, (0...100).contains(percent) else { return .stop(.powerUnknown) }
            if percent <= max(lease.batteryCutoff, batteryFloor) { return .stop(.lowBattery) }
        case .adapter:
            break
        }

        if lease.closedLimitMinutes > 0, closedFor >= Double(lease.closedLimitMinutes) * 60 {
            return .stop(.closedLimitReached)
        }
        return .hold
    }
}

/// Rules for every session, lid open or closed. Enforced by the app.
public struct SessionPowerRules: Equatable, Sendable {
    public var requireCharger: Bool
    public var endOnLowBattery: Bool
    public var batteryCutoff: Int

    public init(requireCharger: Bool, endOnLowBattery: Bool, batteryCutoff: Int) {
        self.requireCharger = requireCharger
        self.endOnLowBattery = endOnLowBattery
        self.batteryCutoff = batteryCutoff
    }

    public enum Violation: Equatable, Sendable {
        case chargerRequired
        case lowBattery(Int)

        public var message: String {
            switch self {
            case .chargerRequired: "Charger disconnected, session ended."
            case .lowBattery(let cutoff): "Battery reached \(cutoff)%, session ended."
            }
        }
    }

    public func violation(for power: PowerSnapshot) -> Violation? {
        guard power.hasBattery, power.source == .battery else { return nil }
        if requireCharger { return .chargerRequired }
        if endOnLowBattery, let percent = power.batteryPercent, percent <= batteryCutoff {
            return .lowBattery(batteryCutoff)
        }
        return nil
    }

    /// The closed-lid lease derived from the same settings, so the user sets power rules once.
    public var leaseBatteryCutoff: Int {
        endOnLowBattery ? max(batteryCutoff, ClosedLidRules.batteryFloor) : ClosedLidRules.batteryFloor
    }
}
