import Foundation

/// Identifiers and file locations shared by the app, the daemon and the install scripts.
/// The shell scripts in Resources/ repeat these paths; keep them in sync.
public enum LidlessPaths {
    public static let appBundleID = "dev.iskakov.lidless"
    public static let daemonLabel = "dev.iskakov.lidless.daemon"

    public static let supportDirectory = "/Library/Application Support/Lidless"
    /// Owned by the user (0700). The app writes its lease here.
    public static let clientDirectory = supportDirectory + "/client"
    public static let leaseFile = clientDirectory + "/lease.json"
    /// Written by the daemon (root, 0644). The app reads it.
    public static let statusFile = supportDirectory + "/status.json"
    /// Root only (0600). Holds the sleep setting to restore.
    public static let journalFile = supportDirectory + "/journal.json"

    public static let daemonBinary = "/Library/PrivilegedHelperTools/" + daemonLabel
    public static let daemonPlist = "/Library/LaunchDaemons/" + daemonLabel + ".plist"
}

public enum LidlessTiming {
    /// How often the app refreshes its lease while a closed-lid session runs.
    public static let heartbeatInterval: TimeInterval = 5
    /// A lease older than this means the app is gone or frozen.
    public static let leaseTimeout: TimeInterval = 30
    /// How often the daemon evaluates the lease.
    public static let daemonTick: TimeInterval = 2
    /// The app treats the daemon as dead when its status is older than this.
    public static let statusStaleAfter: TimeInterval = 15
}
