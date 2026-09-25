import Foundation

/// Claude Code hooks that tell Clawde exactly what each session is doing: a
/// line of JSON is appended to Clawde's events file whenever a session
/// starts a turn, asks you something, needs your permission, notifies you,
/// or stops. They go into Claude Code's user settings only with your say-so
/// (the file is backed up first), run in the background so they never slow
/// Claude down, and come out again from the menu.
enum Hooks {
    /// Where the hooks write, one object a line: {"at": seconds, "hook": Claude Code's hook input}.
    static let eventsFile = Mind.folder.appendingPathComponent("events.jsonl")
    /// Claude Code's user settings (CLAWDE_CLAUDE_SETTINGS points elsewhere, for trying things out).
    static let settingsFile = ProcessInfo.processInfo.environment["CLAWDE_CLAUDE_SETTINGS"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")

    /// Whether Claude Code looks installed: it keeps its settings and
    /// transcripts in ~/.claude.
    static var claudeCodeFound: Bool {
        FileManager.default.fileExists(atPath: settingsFile.deletingLastPathComponent().path)
    }

    /// The events hooked, with the tools a tool hook is limited to.
    private static let events: [(name: String, matcher: String?)] = [
        ("UserPromptSubmit", nil), ("PreToolUse", "AskUserQuestion|ExitPlanMode"), ("PermissionRequest", nil),
        ("Notification", nil), ("Stop", nil), ("StopFailure", nil), ("SessionEnd", nil),
    ]

    /// What every hook runs: quick, one line per event, and never failing the hook.
    static let command = #"f="$HOME/Library/Application Support/Clawde/events.jsonl"; mkdir -p "${f%/*}" && { printf '{"at":%s,"hook":' "$(date +%s)"; tr -d '\n'; printf '}\n'; } >> "$f"; exit 0"#

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? {
            "Claude Code's settings file (~/.claude/settings.json) isn't valid JSON, so Clawde left it alone."
        }
    }

    /// Whether every one of Clawde's hooks is in the settings.
    static var isInstalled: Bool {
        guard let settings = try? readSettings(), let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in (hooks[event.name] as? [[String: Any]] ?? []).contains(where: isOurs) }
    }

    /// Adds Clawde's hooks, after backing the settings up; any of Clawde's
    /// already there are replaced, everyone else's are left as they are.
    static func install() throws {
        var settings = try readSettings()
        try backUp()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = (hooks[event.name] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "async": true]]]
            if let matcher = event.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[event.name] = groups
        }
        settings["hooks"] = hooks
        try write(settings)
    }

    /// Takes Clawde's hooks out again, leaving everyone else's.
    static func uninstall() throws {
        var settings = try readSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (name, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !isOurs($0) }
            hooks[name] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try write(settings)
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            ($0["command"] as? String)?.contains("Clawde/events.jsonl") == true
        }
    }

    private static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsFile) else { return [:] }
        guard let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.unreadable
        }
        return settings
    }

    private static func write(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: settingsFile, options: .atomic)
    }

    /// A copy of the settings as they were, next to them, stamped with the time.
    private static func backUp() throws {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let copy = settingsFile.deletingLastPathComponent()
            .appendingPathComponent("settings.json.before-clawde-\(stamp.replacingOccurrences(of: ":", with: ""))")
        guard !FileManager.default.fileExists(atPath: copy.path) else { return }
        try FileManager.default.copyItem(at: settingsFile, to: copy)
    }
}
