import Foundation

/// What Claude is up to across its sessions: nothing, thinking (before it
/// acts, or pausing a good while between steps), working (writing, or a tool
/// running), or stopped mid-turn until you answer it.
enum ClaudeState: Equatable {
    case idle, thinking, working, waiting
}

/// What kind of work Claude is at, from its last few tool calls: looking
/// things up (searching and reading), changing code, or anything else.
enum WorkMode: Equatable {
    case typing, searching, editing
}

/// Watches Claude Code's session transcripts (`~/.claude/projects/*/*.jsonl`,
/// written by the CLI and the desktop app alike) and reports whether any
/// session is mid-turn or waiting on you, and what the recent ones are about.
final class ClaudeWatcher {
    /// A session still going or touched in the last few minutes, as Clawd tells it.
    struct Session: Equatable {
        var project: String
        var state: ClaudeState
        var mode = WorkMode.typing
        /// Its `git commit`s and `git push`es that went through, by tool call.
        var shipped: [String] = []
        /// Mid-turn, whatever it's doing.
        var isWorking: Bool { state != .idle }
        /// What the person last asked, cut short.
        var prompt: String?
        /// What Claude last said, cut short.
        var reply: String?
        var updated: Date
    }

    /// What a transcript's newest turn entry says, read again only when the
    /// file changes; what it means for Claude's state depends on the time.
    struct Tail {
        enum Last {
            /// The turn is over: the model stopped for good (`end_turn` and
            /// the like), the person interrupted, or a slash command ran.
            case finished
            /// The person asked something; nothing of the answer is written yet.
            case asked
            /// A tool's result came back then.
            case result(at: Date?)
            /// The model wrote part of its answer: a thought or some text.
            case wrote
            /// The model called these tools then, and has no result yet.
            case calling(Set<String>, at: Date?)
        }

        var last: Last
        var project: String
        /// What the person last asked, and what Claude last said, cut short.
        var prompt: String?
        var reply: String?
        /// The tools this turn has called, newest first, the last few.
        var tools: [String] = []
        var shipped: [String] = []
    }

    /// Called on the main actor whenever what Claude is up to changes.
    var onChange: (@MainActor (ClaudeState, WorkMode) -> Void)?
    /// Called on the main actor when a `git commit` or `git push` of Claude's
    /// goes through.
    var onShip: (@MainActor () -> Void)?
    /// The recent sessions, newest first; read on the main actor.
    @MainActor private(set) var sessions: [Session] = []

    /// How long a transcript can sit untouched and its session still count:
    /// one mid-turn that long was abandoned or crashed, but a question can
    /// wait on you for hours and a command can run for a good while.
    static let staleAfter: TimeInterval = 300
    static let waitingStaleAfter: TimeInterval = 3 * 3600
    static let runningStaleAfter: TimeInterval = 1800
    /// How much of a transcript's end is read to find its last entries.
    static let tailBytes: UInt64 = 256 * 1024
    /// Tools that stop the turn until you answer them.
    static let askingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
    /// Tools that can run a long while on their own, so waiting on one says
    /// nothing about waiting on you; MCP servers' tools count too.
    static let slowTools: Set<String> = ["Bash", "Agent", "Task", "Workflow", "TaskOutput", "BashOutput", "Monitor"]
    /// A quicker tool with no result after this long is waiting for you to allow it.
    static let permissionAfter: TimeInterval = 10
    /// Claude going this long after a tool's result without taking a next
    /// step is thinking; shorter pauses between steps are part of working.
    static let thinkingAfter: TimeInterval = 8
    /// Tools that look things up, and tools that change files.
    static let lookingTools: Set<String> = ["Read", "Grep", "Glob", "LS", "WebSearch", "WebFetch", "NotebookRead", "ToolSearch"]
    static let changingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    /// A kind of work has to last this long before Clawd changes what it's doing for it.
    static let modeSettles: TimeInterval = 3

    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)
    private let queue = DispatchQueue(label: "clawd.watcher", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var state = ClaudeState.idle
    private var mode = WorkMode.typing
    /// A different kind of work seen lately, and since when.
    private var nextMode: (mode: WorkMode, since: Date)?
    /// Each transcript's tail as of when it last changed, by path.
    private var tails: [String: (modified: Date, tail: Tail)] = [:]
    /// The commits and pushes already told of; nil until the first look,
    /// which only takes note of what's there.
    private var shipsSeen: Set<String>?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        let now = Date()
        let sessions = Self.recentSessions(under: root, now: now, tails: &tails)
        // A session waiting on you matters most, then one working, then one thinking.
        let states = Set(sessions.map(\.state))
        let state = [ClaudeState.waiting, .working, .thinking].first { states.contains($0) } ?? .idle
        // The kind of work of the latest session at it, once it's lasted.
        let seen = sessions.first { $0.state == .working }?.mode ?? .typing
        if seen == mode {
            nextMode = nil
        } else if nextMode?.mode != seen {
            nextMode = (seen, now)
        } else if let next = nextMode, now.timeIntervalSince(next.since) >= Self.modeSettles {
            mode = next.mode
            nextMode = nil
        }
        let changed = state != self.state || (state == .working && mode != reportedMode)
        self.state = state
        if changed { reportedMode = mode }
        let ships = Set(sessions.flatMap(\.shipped))
        let shipped = shipsSeen.map { !ships.subtracting($0).isEmpty } ?? false
        shipsSeen = (shipsSeen ?? []).union(ships)
        let onChange = onChange, onShip = onShip, mode = self.mode
        Task { @MainActor [weak self] in
            self?.sessions = sessions
            if changed { onChange?(state, mode) }
            if shipped { onShip?() }
        }
    }

    /// The kind of work last told to `onChange`.
    private var reportedMode = WorkMode.typing

    /// The sessions still going or lately touched, newest first, leaving out
    /// Clawd's own conversation. `tails` keeps each transcript's reading
    /// until the file changes.
    static func recentSessions(under root: URL, now: Date = Date(),
                               tails: inout [String: (modified: Date, tail: Tail)]) -> [Session] {
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var found: [Session] = []
        var seen = Set<String>()
        for project in projects where !project.lastPathComponent.hasSuffix("Application-Support-Clawde") {
            let files = (try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
            )) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(modified) < waitingStaleAfter
                else { continue }
                let path = file.path
                seen.insert(path)
                let tail: Tail
                if let kept = tails[path], kept.modified == modified {
                    tail = kept.tail
                } else if let read = read(file) {
                    tail = read
                    tails[path] = (modified, read)
                } else {
                    continue
                }
                let state = state(of: tail.last, now: now)
                guard now.timeIntervalSince(modified) < lifetime(of: tail.last, in: state) else { continue }
                found.append(Session(project: tail.project, state: state, mode: mode(of: tail.tools),
                                     shipped: tail.shipped, prompt: tail.prompt, reply: tail.reply, updated: modified))
            }
        }
        tails = tails.filter { seen.contains($0.key) }
        return found.sorted { $0.updated > $1.updated }
    }

    /// What a session's newest entry means now. Claude is thinking from the
    /// moment it's asked until something of its answer is written, and
    /// again when a tool's result has sat `thinkingAfter` with no next step;
    /// working once it has thought (a thinking block is written) or is
    /// writing or running a tool; and waiting on the person while the tool
    /// it's stopped at asks them something, or is a quick one that's had no
    /// result for a while (it needs allowing).
    static func state(of last: Tail.Last, now: Date) -> ClaudeState {
        switch last {
        case .finished:
            return .idle
        case .asked:
            return .thinking
        case .result(let at):
            return now.timeIntervalSince(at ?? now) >= thinkingAfter ? .thinking : .working
        case .wrote:
            return .working
        case .calling(let tools, let at):
            let quick = tools.isDisjoint(with: slowTools) && !tools.contains { $0.hasPrefix("mcp__") }
            if !tools.isDisjoint(with: askingTools) || (quick && now.timeIntervalSince(at ?? now) > permissionAfter) {
                return .waiting
            }
            return .working
        }
    }

    /// The kind of work the last four tool calls add up to: two changes to
    /// files make it editing, three look-ups searching.
    static func mode(of tools: [String]) -> WorkMode {
        let recent = tools.prefix(4)
        if recent.filter({ changingTools.contains($0) }).count >= 2 { return .editing }
        if recent.filter({ lookingTools.contains($0) }).count >= 3 { return .searching }
        return .typing
    }

    /// How long a session in `state` can go untouched and still count.
    private static func lifetime(of last: Tail.Last, in state: ClaudeState) -> TimeInterval {
        if state == .waiting { return waitingStaleAfter }
        if case .calling = last { return runningStaleAfter }
        return staleAfter
    }

    /// Reads a transcript's tail, newest entry first, for its newest turn
    /// entry, the project it's in and the last things said.
    static func read(_ file: URL) -> Tail? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        var last: Tail.Last?
        var prompt: String?
        var reply: String?
        var project: String?
        var tools: [String] = []
        var shipped: [String] = []
        /// Which tool calls' results came back fine, by call.
        var succeeded = Set<String>()
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            // The tail's first line is usually cut in half and fails to parse.
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let message = entry["message"] as? [String: Any]
            if project == nil, let cwd = entry["cwd"] as? String { project = (cwd as NSString).lastPathComponent }
            switch entry["type"] as? String {
            case "assistant":
                if last == nil {
                    let reason = message?["stop_reason"] as? String
                    let tools = Self.toolNames(in: message?["content"])
                    if !(reason == nil || reason == "tool_use" || reason == "pause_turn") {
                        last = .finished
                    } else {
                        last = tools.isEmpty ? .wrote : .calling(tools, at: Self.date(of: entry))
                    }
                }
                if reply == nil, let text = Self.text(of: message?["content"]), !text.isEmpty { reply = text }
                if prompt == nil {
                    // This turn's calls, newest first; a commit or push that went through.
                    for call in Self.toolCalls(in: message?["content"]).reversed() {
                        tools.append(call.name)
                        if call.ships, succeeded.contains(call.id) { shipped.append(call.id) }
                    }
                }
            case "user":
                if entry["isMeta"] as? Bool == true { continue }
                let text = Self.text(of: message?["content"]) ?? ""
                let interrupted = text.hasPrefix("[Request interrupted")
                let isResult = Self.isToolResult(message?["content"])
                for block in message?["content"] as? [[String: Any]] ?? []
                where block["type"] as? String == "tool_result" && block["is_error"] as? Bool != true {
                    if let id = block["tool_use_id"] as? String { succeeded.insert(id) }
                }
                if last == nil {
                    if interrupted || text.hasPrefix("<command-") || text.hasPrefix("<local-command") {
                        last = .finished
                    } else {
                        last = isResult ? .result(at: Self.date(of: entry)) : .asked
                    }
                }
                if prompt == nil, !text.isEmpty, !text.hasPrefix("<"), !interrupted, !isResult {
                    prompt = text
                }
            default:
                continue
            }
            if last != nil, prompt != nil, reply != nil, project != nil { break }
        }
        guard let last else { return nil }
        return Tail(
            last: last,
            project: project ?? file.deletingLastPathComponent().lastPathComponent,
            prompt: prompt.map { clip($0, 120) },
            reply: reply.map { clip($0, 160) },
            tools: Array(tools.prefix(6)),
            shipped: shipped
        )
    }

    /// The tool calls in a message: their names, ids, and whether each is a
    /// shell command committing or pushing with git.
    private static func toolCalls(in content: Any?) -> [(name: String, id: String, ships: Bool)] {
        (content as? [[String: Any]] ?? []).compactMap { block in
            guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
            let command = (block["input"] as? [String: Any])?["command"] as? String ?? ""
            return (name, block["id"] as? String ?? "", name == "Bash" && ships(command))
        }
    }

    /// Whether a shell command runs `git commit` or `git push` (perhaps with
    /// `-C dir`) as one of the commands on its first line: what follows the
    /// first line, like a heredoc's text, doesn't count.
    static func ships(_ command: String) -> Bool {
        let line = command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return line.components(separatedBy: CharacterSet(charactersIn: "&|;")).contains { part in
            var words = part.split(separator: " ")[...]
            guard words.first == "git" else { return false }
            words = words.dropFirst()
            if words.first == "-C" { words = words.dropFirst(2) }
            return words.first == "commit" || words.first == "push"
        }
    }

    /// The names of the tools a message calls.
    private static func toolNames(in content: Any?) -> Set<String> {
        Set((content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "tool_use" ? $0["name"] as? String : nil })
    }

    /// When an entry was written, if it says.
    private static func date(of entry: [String: Any]) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (entry["timestamp"] as? String).flatMap(format.date(from:))
    }

    private static func isToolResult(_ content: Any?) -> Bool {
        (content as? [[String: Any]])?.contains { $0["type"] as? String == "tool_result" } ?? false
    }

    /// The text blocks of a message's content, or its string.
    private static func text(of content: Any?) -> String? {
        if let text = content as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let texts = (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return texts.isEmpty ? nil : texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
