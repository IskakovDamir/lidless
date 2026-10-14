import Foundation
import IOKit.pwr_mgt

/// Holds IOKit power assertions for an open-lid session. Visible in `pmset -g assertions`.
final class PowerAssertion {
    private var ids: [IOPMAssertionID] = []
    private var activity: NSObjectProtocol?

    var isActive: Bool { !ids.isEmpty }

    func activate(keepDisplayOn: Bool) throws {
        var created: [IOPMAssertionID] = []
        do {
            created.append(try create(kIOPMAssertionTypePreventUserIdleSystemSleep, "Lidless session"))
            if keepDisplayOn {
                created.append(try create(kIOPMAssertionTypePreventUserIdleDisplaySleep, "Lidless display"))
            }
        } catch {
            created.forEach { IOPMAssertionRelease($0) }
            throw error
        }
        release()
        ids = created
        // Keep App Nap away from the heartbeat timer while a session runs.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Lidless session")
    }

    func release() {
        ids.forEach { IOPMAssertionRelease($0) }
        ids.removeAll()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func create(_ type: String, _ name: String) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 name as CFString, &id)
        guard result == kIOReturnSuccess else {
            throw NSError(domain: "Lidless", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: "macOS refused the keep-awake request (\(result))."
            ])
        }
        return id
    }
}
