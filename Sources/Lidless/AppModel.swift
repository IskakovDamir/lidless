import AppKit
import Combine
import LidlessCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    struct Session: Equatable {
        let id: String
        let mode: SessionMode
        let started: Date
        var ends: Date?
        /// Set by the URL scheme to turn closed-lid mode on or off for this session only.
        var lidOverride: Bool?
        /// Started by Claude Code hooks; ends when the last agent lets go.
        var startedByAgents = false
    }

    // MARK: Session state

    @Published private(set) var session: Session?
    @Published private(set) var now = Date()
    @Published private(set) var power = SystemState.power()
    /// Why the last session ended, when it did not end by the user's hand.
    @Published var lastEndReason: String?
    @Published var errorMessage: String?
    /// Claude Code sessions currently holding the Mac awake (files in AgentHolds.directory).
    @Published private(set) var agentHolds: Set<String> = []
    @Published private(set) var claudeCodeHooksInstalled = ClaudeCodeIntegration.isInstalled()

    // MARK: Settings

    @Published var mode: SessionMode = SessionMode(rawValue: Store.string(.mode, "timer")) ?? .timer {
        didSet { Store.set(mode.rawValue, .mode) }
    }
    @Published var timerMinutes: Int = Store.int(.timerMinutes, 120) {
        didSet { Store.set(timerMinutes, .timerMinutes) }
    }
    @Published var untilTime: Date = Store.date(.untilTime, Date().addingTimeInterval(3 * 3600)) {
        didSet { Store.set(untilTime, .untilTime) }
    }
    @Published var closedLidEnabled: Bool = Store.bool(.closedLidEnabled, false) {
        didSet { Store.set(closedLidEnabled, .closedLidEnabled); syncLease() }
    }
    @Published var closedLimitMinutes: Int = Store.int(.closedLimitMinutes, 120) {
        didSet { Store.set(closedLimitMinutes, .closedLimitMinutes); syncLease() }
    }
    @Published var requireCharger: Bool = Store.bool(.requireCharger, true) {
        didSet { Store.set(requireCharger, .requireCharger); enforcePower(); syncLease() }
    }
    @Published var endOnLowBattery: Bool = Store.bool(.endOnLowBattery, true) {
        didSet { Store.set(endOnLowBattery, .endOnLowBattery); enforcePower(); syncLease() }
    }
    @Published var batteryCutoff: Int = Store.int(.batteryCutoff, 20) {
        didSet { Store.set(batteryCutoff, .batteryCutoff); enforcePower(); syncLease() }
    }
    @Published var keepDisplayOn: Bool = Store.bool(.keepDisplayOn, false) {
        didSet { Store.set(keepDisplayOn, .keepDisplayOn); reassert() }
    }
    @Published var showTimeInMenuBar: Bool = Store.bool(.showTimeInMenuBar, true) {
        didSet { Store.set(showTimeInMenuBar, .showTimeInMenuBar) }
    }
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled

    let closedLid: ClosedLidClient
    private let assertion = PowerAssertion()
    private var ticker: Timer?
    private var tickCount = 0
    private var observers: [NSObjectProtocol] = []
    private var lidSubscription: AnyCancellable?

    init() {
        closedLid = ClosedLidClient()
        // A lease left behind by a crash would be stale anyway; drop it.
        closedLid.clearLease()
        closedLid.refresh()
        closedLid.checkForUpdate()
        // Re-publish helper changes so views that only observe the model update too.
        lidSubscription = closedLid.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                self.closedLid.refresh()
                if let status = self.closedLid.status, status.sessionID == session.id,
                   status.state == .stopped, let reason = status.reason {
                    self.end(reason: reason.message)
                } else {
                    self.end(reason: "Your Mac went to sleep, session ended.")
                }
            }
        })
    }

    // MARK: Derived values

    var isActive: Bool { session != nil }

    var remaining: TimeInterval? {
        guard let ends = session?.ends else { return nil }
        return max(0, ends.timeIntervalSince(now))
    }

    var rules: SessionPowerRules {
        SessionPowerRules(requireCharger: requireCharger, endOnLowBattery: endOnLowBattery, batteryCutoff: batteryCutoff)
    }

    /// The end of a session started right now with the current settings.
    func plannedEnd(from start: Date = Date()) -> Date? {
        switch mode {
        case .timer:
            return start.addingTimeInterval(TimeInterval(max(1, timerMinutes)) * 60)
        case .until:
            return Self.nextOccurrence(of: untilTime, after: start)
        case .unlimited:
            return nil
        }
    }

    /// Today at the picked time, or tomorrow if that time has passed.
    static func nextOccurrence(of time: Date, after start: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        let candidate = calendar.nextDate(after: start, matching: parts, matchingPolicy: .nextTime) ?? start
        return candidate
    }

    enum LidState: Equatable {
        case off
        case needsHelper
        case helperStopped
        case waiting
        case ready
        case stopped(String)
        case idleArmed
    }

    /// Closed-lid mode for the running session, or the setting when idle.
    var closedLidActive: Bool {
        session?.lidOverride ?? closedLidEnabled
    }

    var lidState: LidState {
        guard closedLidActive, power.hasBattery else { return .off }
        switch closedLid.helper {
        case .notInstalled: return .needsHelper
        case .notRunning: return .helperStopped
        case .running: break
        }
        guard let session else { return .idleArmed }
        guard let status = closedLid.status, status.sessionID == session.id else { return .waiting }
        switch status.state {
        case .holding: return .ready
        case .stopped: return .stopped(status.reason?.message ?? "Closed-lid protection stopped.")
        case .idle: return .waiting
        }
    }

    // MARK: Actions

    func start() {
        startSession(mode: mode, ends: plannedEnd(from: Date()), lidOverride: nil)
    }

    private func startSession(mode: SessionMode, ends: Date?, lidOverride: Bool?, byAgents: Bool = false) {
        errorMessage = nil
        lastEndReason = nil
        power = SystemState.power()
        if let violation = rules.violation(for: power) {
            switch violation {
            case .chargerRequired:
                errorMessage = "Connect a charger, or turn off \u{201C}Require charger\u{201D}."
            case .lowBattery(let cutoff):
                errorMessage = "Battery is at or below \(cutoff)%. Connect a charger or lower the cutoff."
            }
            return
        }
        let started = Date()
        if let ends, ends <= started { return }
        do {
            try assertion.activate(keepDisplayOn: keepDisplayOn)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        session = Session(id: UUID().uuidString, mode: mode, started: started, ends: ends,
                          lidOverride: lidOverride, startedByAgents: byAgents)
        now = started
        syncLease()
    }

    func stop() {
        // A manual Stop wins over agents until their next prompt.
        AgentHolds.removeAll()
        agentHolds = []
        end(reason: nil)
    }

    func setClaudeCodeHooks(_ enabled: Bool) {
        do {
            if enabled { try ClaudeCodeIntegration.install() } else { try ClaudeCodeIntegration.uninstall() }
        } catch {
            errorMessage = error.localizedDescription
        }
        claudeCodeHooksInstalled = ClaudeCodeIntegration.isInstalled()
    }

    // MARK: Agent holds

    /// Called by lidless://hold. The Claude Code hook writes the file itself.
    func agentHold(id: String) {
        AgentHolds.add(id)
        syncAgents()
    }

    /// Called by lidless://release.
    func agentRelease(id: String) {
        AgentHolds.remove(id)
        syncAgents()
    }

    /// Starts a session when an agent begins working and ends it when the last one finishes.
    private func syncAgents() {
        let holds = AgentHolds.current()
        if holds != agentHolds { agentHolds = holds }
        if let session {
            if session.startedByAgents && holds.isEmpty {
                end(reason: "Claude Code finished, session ended.")
            }
        } else if !holds.isEmpty {
            startSession(mode: .unlimited, ends: nil, lidOverride: nil, byAgents: true)
        }
    }

    func extend(minutes: Int = 15) {
        guard var current = session, let ends = current.ends else { return }
        let limit = Date().addingTimeInterval(24 * 3600)
        current.ends = min(ends.addingTimeInterval(TimeInterval(minutes) * 60), limit)
        session = current
        syncLease()
    }

    func end(reason: String?) {
        assertion.release()
        closedLid.clearLease()
        session = nil
        lastEndReason = reason
        closedLid.refresh()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Could not change the login item: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func popoverWillShow() {
        power = SystemState.power()
        closedLid.refresh()
        closedLid.checkForUpdate()
        openAtLogin = SMAppService.mainApp.status == .enabled
        claudeCodeHooksInstalled = ClaudeCodeIntegration.isInstalled()
        now = Date()
    }

    func shutdown() {
        assertion.release()
        closedLid.clearLease()
    }

    // MARK: URL scheme

    /// lidless://start?minutes=90&lid=1, lidless://start (unlimited), lidless://stop, lidless://extend?minutes=15
    func handle(url: URL) {
        guard url.scheme == "lidless" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host ?? "" {
        case "start":
            let lid = value("lid").map { $0 == "1" || $0 == "true" }
            let minutes = value("minutes").flatMap { Int($0) }.map { min(max($0, 1), 24 * 60) }
            if session != nil { end(reason: nil) }
            startSession(mode: minutes == nil ? .unlimited : .timer,
                         ends: minutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) },
                         lidOverride: lid)
        case "hold":
            guard let id = value("id").flatMap(Self.sanitizedID) else { return }
            agentHold(id: id)
        case "release":
            guard let id = value("id").flatMap(Self.sanitizedID) else { return }
            agentRelease(id: id)
        case "stop":
            stop()
        case "extend":
            extend(minutes: value("minutes").flatMap { Int($0) } ?? 15)
        default:
            break
        }
    }

    private static func sanitizedID(_ raw: String) -> String? {
        let allowed = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return allowed.isEmpty ? nil : String(allowed.prefix(64))
    }

    // MARK: Ticking

    private func tick() {
        tickCount += 1
        now = Date()
        syncAgents()
        guard let session else {
            if tickCount % 10 == 0 {
                power = SystemState.power()
                closedLid.refresh()
            }
            return
        }
        if let ends = session.ends, now >= ends {
            end(reason: "Time is up, session ended.")
            return
        }
        if tickCount % Int(LidlessTiming.heartbeatInterval) == 0 {
            power = SystemState.power()
            enforcePower()
            syncLease()
        }
    }

    private func enforcePower() {
        guard session != nil, let violation = rules.violation(for: power) else { return }
        end(reason: violation.message)
    }

    private func reassert() {
        guard session != nil else { return }
        do {
            try assertion.activate(keepDisplayOn: keepDisplayOn)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes or removes the closed-lid lease to match the current session and settings.
    private func syncLease() {
        guard let session, closedLidActive, power.hasBattery, closedLid.helper != .notInstalled else {
            closedLid.clearLease()
            closedLid.refresh()
            return
        }
        let lease = ClosedLidLease(
            sessionID: session.id,
            heartbeat: Date().timeIntervalSince1970,
            sessionEnds: session.ends?.timeIntervalSince1970,
            allowBattery: !requireCharger,
            batteryCutoff: rules.leaseBatteryCutoff,
            closedLimitMinutes: closedLimitMinutes)
        closedLid.writeLease(lease)
        closedLid.refresh()
    }
}
