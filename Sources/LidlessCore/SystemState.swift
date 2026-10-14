import Foundation
import IOKit
import IOKit.ps

public enum SystemState {
    /// Current power source, battery charge and thermal state.
    public static func power() -> PowerSnapshot {
        let thermal = ProcessInfo.processInfo.thermalState
        let thermalOK = thermal == .nominal || thermal == .fair
        let unknown = PowerSnapshot(source: .unknown, batteryPercent: nil, hasBattery: false, thermalOK: thermalOK)

        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return unknown }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?

        var percent: Int?
        var hasBattery = false
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
                guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                hasBattery = true
                if let current = description[kIOPSCurrentCapacityKey] as? Int,
                   let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                    let value = Int((Double(current) / Double(maximum) * 100).rounded(.down))
                    percent = min(percent ?? 100, max(0, min(100, value)))
                }
            }
        }

        let source: PowerSnapshot.Source
        switch providing ?? "" {
        case kIOPSACPowerValue: source = .adapter
        case kIOPSBatteryPowerValue: source = .battery
        default: source = hasBattery ? .unknown : .adapter
        }
        if source == .battery && percent == nil {
            return PowerSnapshot(source: .unknown, batteryPercent: nil, hasBattery: hasBattery, thermalOK: thermalOK)
        }
        return PowerSnapshot(source: source, batteryPercent: percent, hasBattery: hasBattery, thermalOK: thermalOK)
    }

    /// The effective kernel value of `pmset disablesleep`. nil when macOS does not report it.
    public static func sleepDisabled() -> Bool? {
        rootDomainBool("SleepDisabled")
    }

    /// True when the MacBook lid is closed. nil on Macs without a lid.
    public static func lidClosed() -> Bool? {
        rootDomainBool("AppleClamshellState")
    }

    private static func rootDomainBool(_ key: String) -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFEqual(value, kCFBooleanTrue)
    }
}
