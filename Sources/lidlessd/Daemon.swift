import Darwin
import Foundation
import LidlessCore
import os

/// Root daemon. Turns `pmset disablesleep` on while a valid lease exists and every
/// safety rule passes, and puts the previous value back the moment anything fails.
/// All state lives on one serial queue.
final class Daemon {
    private let clientUID: uid_t
    private let queue = DispatchQueue(label: "dev.iskakov.lidless.daemon")
    private let log = Logger(subsystem: LidlessPaths.daemonLabel, category: "daemon")
    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []

    private var sessionID: String?
    private var stoppedReason: StopReason?
    private var closedSince: Double?
    private var lastError: String?
    private var lastStatus: DaemonStatus?

    init(clientUID: uid_t) {
        self.clientUID = clientUID
    }

    func start() {
        queue.sync {
            prepareDirectories()
            // A journal left from a crash or power loss means sleep may still be disabled.
            restore()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: LidlessTiming.daemonTick, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        for value in [SIGTERM, SIGINT, SIGHUP] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: queue)
            source.setEventHandler { [weak self] in
                self?.restore()
                self?.writeStatus(state: .idle, force: true)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
        log.info("lidlessd \(LidlessVersion.string, privacy: .public) started for uid \(self.clientUID)")
    }

    // MARK: - Tick

    private func tick() {
        let now = Date().timeIntervalSince1970
        let lease = readLease()

        if lease?.sessionID != sessionID {
            sessionID = lease?.sessionID
            stoppedReason = nil
            closedSince = nil
        }

        guard let lease else {
            let wasApplied = JSONFile.exists(LidlessPaths.journalFile)
            restore()
            writeStatus(state: .idle)
            // A session that ended on its own while the lid is shut: no lid event will follow, so sleep now.
            if wasApplied && !JSONFile.exists(LidlessPaths.journalFile) && SystemState.lidClosed() == true {
                log.notice("Session ended with the lid closed, sleeping")
                _ = runPmset(["sleepnow"])
            }
            return
        }

        if let reason = stoppedReason {
            // A safety stop is final for this session. A returning charger never re-arms it.
            restore()
            writeStatus(state: .stopped, reason: reason)
            return
        }

        let lid = SystemState.lidClosed()
        let applied = JSONFile.exists(LidlessPaths.journalFile)
        if lid == true && applied {
            if closedSince == nil { closedSince = now }
        } else if lid != true {
            closedSince = nil
        }

        let verdict = ClosedLidRules.evaluate(lease: lease, now: now, power: SystemState.power(),
                                              closedFor: closedSince.map { now - $0 } ?? 0)
        switch verdict {
        case .hold:
            if apply(sessionID: lease.sessionID) {
                writeStatus(state: .holding, lid: lid)
            } else {
                stop(.sleepSettingFailed, lid: lid)
            }
        case .stop(let reason):
            stop(reason, lid: lid)
        }
    }

    private func stop(_ reason: StopReason, lid: Bool?) {
        stoppedReason = reason
        let wasApplied = JSONFile.exists(LidlessPaths.journalFile)
        restore()
        log.notice("Protection stopped: \(reason.rawValue, privacy: .public)")
        writeStatus(state: .stopped, reason: reason, lid: lid, force: true)
        if wasApplied && lid == true && reason.sleepsClosedMac {
            // The lid is already shut, so macOS will not see a new lid event. Sleep now.
            _ = runPmset(["sleepnow"])
        }
    }

    // MARK: - Sleep setting

    /// Disables system sleep, journaling the previous value first. Returns false on failure.
    private func apply(sessionID: String) -> Bool {
        if JSONFile.exists(LidlessPaths.journalFile) {
            if SystemState.sleepDisabled() == true { return true }
            // Someone flipped it back. Put our value in place again; the journal already
            // holds the original setting.
            return setSleepDisabled(true)
        }
        guard let previous = SystemState.sleepDisabled() else {
            lastError = "macOS did not report the current sleep setting"
            return false
        }
        let journal = SleepJournal(previousSleepDisabled: previous, sessionID: sessionID,
                                   appliedAt: Date().timeIntervalSince1970)
        do {
            try JSONFile.write(journal, to: LidlessPaths.journalFile, mode: 0o600, sync: true)
        } catch {
            lastError = "could not write the recovery journal"
            return false
        }
        if setSleepDisabled(true) {
            log.info("Sleep disabled for session \(sessionID, privacy: .public)")
            return true
        }
        restore()
        return false
    }

    /// Puts back the value from the journal. Keeps the journal if that fails, so the next tick retries.
    private func restore() {
        guard JSONFile.exists(LidlessPaths.journalFile) else { return }
        let previous: Bool
        do {
            previous = try JSONFile.read(SleepJournal.self, at: LidlessPaths.journalFile, owner: 0)
                .previousSleepDisabled
        } catch {
            // An unreadable journal must not leave the Mac awake forever. Normal sleep is the safe default.
            previous = false
        }
        if setSleepDisabled(previous) {
            JSONFile.remove(LidlessPaths.journalFile)
            closedSince = nil
            log.info("Sleep setting restored to \(previous)")
        } else {
            lastError = "could not restore the sleep setting, retrying"
        }
    }

    private func setSleepDisabled(_ value: Bool) -> Bool {
        guard runPmset(["-a", "disablesleep", value ? "1" : "0"]) else { return false }
        // powerd hands the preference to the kernel asynchronously.
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            if SystemState.sleepDisabled() == value { return true }
            usleep(50_000)
        } while Date() < deadline
        lastError = "macOS did not confirm disablesleep=\(value ? 1 : 0)"
        return false
    }

    private func runPmset(_ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        do { try task.run() } catch {
            lastError = "could not run pmset"
            return false
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            task.terminate()
            lastError = "pmset timed out"
            return false
        }
        return task.terminationStatus == 0
    }

    // MARK: - Files

    private func prepareDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: LidlessPaths.clientDirectory, withIntermediateDirectories: true)
        chown(LidlessPaths.supportDirectory, 0, 0)
        chmod(LidlessPaths.supportDirectory, 0o755)
        chown(LidlessPaths.clientDirectory, clientUID, 20) // group staff
        chmod(LidlessPaths.clientDirectory, 0o700)
    }

    private func readLease() -> ClosedLidLease? {
        do {
            return try JSONFile.read(ClosedLidLease.self, at: LidlessPaths.leaseFile, owner: clientUID)
        } catch JSONFile.Failure.missing {
            return nil
        } catch {
            // Unsafe or corrupt lease: behave as if there is none.
            lastError = "ignored an invalid lease file"
            return nil
        }
    }

    private func writeStatus(state: DaemonStatus.State, reason: StopReason? = nil, lid: Bool? = nil,
                             force: Bool = false) {
        let now = Date().timeIntervalSince1970
        let status = DaemonStatus(daemonVersion: LidlessVersion.string, updatedAt: now, state: state,
                                  sessionID: sessionID, reason: reason, lidClosed: lid ?? SystemState.lidClosed(),
                                  closedSince: closedSince, lastError: lastError)
        // Write on change, and every few seconds as a liveness signal for the app.
        if !force, let last = lastStatus, last.sameContent(as: status), now - last.updatedAt < 5 { return }
        do {
            try JSONFile.write(status, to: LidlessPaths.statusFile, mode: 0o644)
            lastStatus = status
        } catch {
            log.error("Could not write status")
        }
    }
}
