import Foundation
import LidlessCore

/// Talks to the root daemon through two files: the app writes a lease, the daemon writes a status.
@MainActor
final class ClosedLidClient: ObservableObject {
    enum Helper: Equatable {
        case notInstalled
        /// Installed but its status file is stale: the daemon is not running.
        case notRunning
        case running
    }

    @Published private(set) var helper: Helper = .notInstalled
    @Published private(set) var status: DaemonStatus?
    /// The bundled daemon differs from the installed one.
    @Published private(set) var updateAvailable = false
    @Published private(set) var installing = false
    @Published var installError: String?

    private var hasLease = false

    func refresh() {
        let installed = FileManager.default.fileExists(atPath: LidlessPaths.daemonPlist)
        status = try? JSONFile.read(DaemonStatus.self, at: LidlessPaths.statusFile, owner: 0)
        if !installed {
            helper = .notInstalled
        } else if let status, Date().timeIntervalSince1970 - status.updatedAt < LidlessTiming.statusStaleAfter {
            helper = .running
        } else {
            helper = .notRunning
        }
    }

    func checkForUpdate() {
        guard helper != .notInstalled, let bundled = HelperInstaller.bundledDaemonPath else {
            updateAvailable = false
            return
        }
        let fm = FileManager.default
        updateAvailable = fm.contents(atPath: bundled) != fm.contents(atPath: LidlessPaths.daemonBinary)
    }

    func writeLease(_ lease: ClosedLidLease) {
        do {
            try JSONFile.write(lease, to: LidlessPaths.leaseFile, mode: 0o600)
            hasLease = true
        } catch {
            hasLease = false
        }
    }

    func clearLease() {
        // Always try: a lease may survive from a previous run of the app.
        JSONFile.remove(LidlessPaths.leaseFile)
        hasLease = false
    }

    func install() {
        guard !installing else { return }
        installing = true
        installError = nil
        Task {
            let error = await HelperInstaller.run(.install)
            installing = false
            installError = error
            // launchd needs a moment before the daemon writes its first status.
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                refresh()
                if helper == .running { break }
            }
            checkForUpdate()
        }
    }

    func uninstall() {
        guard !installing else { return }
        installing = true
        installError = nil
        clearLease()
        Task {
            let error = await HelperInstaller.run(.uninstall)
            installing = false
            installError = error
            refresh()
            updateAvailable = false
        }
    }
}

enum HelperInstaller {
    enum Action { case install, uninstall }

    static var bundledDaemonPath: String? {
        let path = Bundle.main.bundlePath + "/Contents/Helpers/lidlessd"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Runs the bundled shell script as root through the standard macOS admin password prompt.
    /// Returns an error message, or nil on success.
    static func run(_ action: Action) async -> String? {
        let scriptName = action == .install ? "install-helper" : "uninstall-helper"
        guard let script = Bundle.main.path(forResource: scriptName, ofType: "sh") else {
            return "The \(scriptName).sh script is missing from the app bundle."
        }
        var command = "/bin/bash " + shellQuote(script)
        if action == .install {
            guard let daemon = bundledDaemonPath else {
                return "The lidlessd helper is missing from the app bundle."
            }
            command += " " + shellQuote(daemon) + " " + String(getuid())
        }
        let prompt = action == .install
            ? "Lidless wants to install its helper so your Mac can stay awake with the lid closed."
            : "Lidless wants to remove its closed-lid helper."
        let source = "do shell script \(appleScriptQuote(command)) with prompt \(appleScriptQuote(prompt)) with administrator privileges"

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runOsascript(source))
            }
        }
    }

    private static func runOsascript(_ source: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        let errors = Pipe()
        task.standardError = errors
        task.standardOutput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return "Could not start the installer: \(error.localizedDescription)"
        }
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        guard task.terminationStatus != 0 else { return nil }
        if text.contains("-128") { return "Cancelled." }
        return "Setup failed: " + text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
