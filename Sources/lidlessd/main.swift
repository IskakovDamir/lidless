import Darwin
import Foundation
import LidlessCore

// Usage: lidlessd --uid <uid>
// Installed by Resources/install-helper.sh as a launchd daemon running as root.

guard geteuid() == 0 else {
    fputs("lidlessd must run as root (it is started by launchd).\n", stderr)
    exit(77)
}

var parsedUID: uid_t?
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--uid"), index + 1 < arguments.count,
   let value = UInt32(arguments[index + 1]), value != 0 {
    parsedUID = value
}
guard let clientUID = parsedUID else {
    fputs("Usage: lidlessd --uid <uid of the user running Lidless.app>\n", stderr)
    exit(64)
}

umask(0o022)
let daemon = Daemon(clientUID: clientUID)
daemon.start()
dispatchMain()
