import Foundation

/// Adds or removes Lidless hooks in ~/.claude/settings.json, leaving every other setting untouched.
enum ClaudeCodeIntegration {
    static let marker = "claude-hook.sh"

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var hookScript: String? {
        Bundle.main.path(forResource: "claude-hook", ofType: "sh")
    }

    /// Event name, hook argument, matcher.
    private static let events: [(String, String, String?)] = [
        ("UserPromptSubmit", "hold", nil),
        ("PostToolUse", "refresh", "*"),
        ("Stop", "release", nil),
        ("SessionEnd", "release", nil)
    ]

    enum Failure: LocalizedError {
        case unreadable, scriptMissing, writeFailed
        var errorDescription: String? {
            switch self {
            case .unreadable: "~/.claude/settings.json is not valid JSON, so it was left as is."
            case .scriptMissing: "claude-hook.sh is missing from the app bundle."
            case .writeFailed: "Could not write ~/.claude/settings.json."
            }
        }
    }

    static func isInstalled() -> Bool {
        guard let settings = try? load() else { return false }
        return containsMarker(settings["hooks"])
    }

    static func install() throws {
        guard let script = hookScript else { throw Failure.scriptMissing }
        var settings = try load()
        var hooks = strip(settings["hooks"] as? [String: Any] ?? [:])
        for (event, argument, matcher) in events {
            var group: [String: Any] = ["hooks": [[
                "type": "command",
                "command": "/bin/bash '\(script)' \(argument)",
                "timeout": 10
            ]]]
            if let matcher { group["matcher"] = matcher }
            var groups = hooks[event] as? [Any] ?? []
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try save(settings)
    }

    static func uninstall() throws {
        var settings = try load()
        guard let hooks = settings["hooks"] as? [String: Any] else { return }
        let cleaned = strip(hooks)
        if cleaned.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = cleaned }
        try save(settings)
    }

    // MARK: - Helpers

    private static func load() throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsURL.path) else { return [:] }
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable
        }
        return object
    }

    private static func save(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        let directory = settingsURL.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep one copy of the user's original file the first time we touch it.
        let backup = directory.appendingPathComponent("settings.json.lidless-backup")
        if fm.fileExists(atPath: settingsURL.path) && !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: settingsURL, to: backup)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: settings,
                                                     options: [.prettyPrinted, .withoutEscapingSlashes]),
              (try? data.write(to: settingsURL, options: .atomic)) != nil else {
            throw Failure.writeFailed
        }
    }

    /// Removes every Lidless hook, then drops groups and events left empty.
    private static func strip(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { result[event] = value; continue }
            var kept: [Any] = []
            for item in groups {
                guard var group = item as? [String: Any], let handlers = group["hooks"] as? [Any] else {
                    kept.append(item)
                    continue
                }
                let remaining = handlers.filter { !containsMarker($0) }
                if remaining.isEmpty { continue }
                group["hooks"] = remaining
                kept.append(group)
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func containsMarker(_ value: Any?) -> Bool {
        guard let value else { return false }
        switch value {
        case let text as String: return text.contains(marker)
        case let array as [Any]: return array.contains { containsMarker($0) }
        case let dictionary as [String: Any]: return dictionary.values.contains { containsMarker($0) }
        default: return false
        }
    }
}
