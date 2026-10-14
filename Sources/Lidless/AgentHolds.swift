import Foundation

/// One empty file per working Claude Code session, written by Resources/claude-hook.sh.
/// Files are the whole protocol: no URL scheme or LaunchServices round trip in the hook path.
enum AgentHolds {
    /// A session that has not touched its file for this long is considered gone.
    static let lifetime: TimeInterval = 2 * 3600

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lidless/agents", isDirectory: true)
    }

    /// Live holds. Removes files older than `lifetime`.
    static func current(now: Date = Date()) -> Set<String> {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var live = Set<String>()
        for name in names where !name.hasPrefix(".") {
            let path = directory.appendingPathComponent(name).path
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(modified) > lifetime {
                try? fm.removeItem(atPath: path)
            } else {
                live.insert(name)
            }
        }
        return live
    }

    static func add(_ id: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(id)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id))
    }

    static func removeAll() {
        for id in current(now: Date()) { remove(id) }
    }
}
