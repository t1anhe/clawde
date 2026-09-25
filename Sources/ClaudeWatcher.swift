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
    /// What a session is stopped for until you step in.
    enum Need: Equatable {
        /// Your permission to use a tool, e.g. "Bash: git push".
        case permission(String)
        /// An answer to its question.
        case question(String)
        /// Your go-ahead on its plan.
        case plan
    }

    /// A session still going or touched in the last few minutes, as Clawd tells it.
    struct Session: Equatable {
        /// Its transcript's name: Claude Code's session ID.
        var id: String
        var project: String
        /// What it's called: its title, or else what it was last asked, cut short.
        var title: String
        var state: ClaudeState
        /// What it's waiting on you for, while `state` is `.waiting`.
        var need: Need?
        /// Its last turn ended with you interrupting it.
        var interrupted = false
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
        /// The session's title, if it has one.
        var title: String?
        /// What the person last asked, and what Claude last said, cut short.
        var prompt: String?
        var reply: String?
        /// The tool calls whose results have come back.
        var results: Set<String> = []
        /// What a pending AskUserQuestion asks, or "" for a plan to approve.
        var asking: String?
        /// The last turn ended with the person interrupting it.
        var interrupted = false
        /// The tools this turn has called, newest first, the last few.
        var tools: [String] = []
        var shipped: [String] = []
    }

    /// Called on the main actor whenever what Claude is up to changes.
    var onChange: (@MainActor (ClaudeState, WorkMode) -> Void)?
    /// Called on the main actor when a `git commit` or `git push` of Claude's
    /// goes through.
    var onShip: (@MainActor () -> Void)?

    /// What happens to one session: it starts on something, it needs you,
    /// or it finishes, with the last thing it said (or it's interrupted).
    enum Event {
        case started(Session)
        case needsYou(Session)
        case finished(Session, said: String?)
    }

    /// Called on the main actor for each session that starts, needs you or finishes.
    var onEvent: (@MainActor (Event) -> Void)?
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
    /// What the hooks last said about each session, by session ID.
    private var notes: [String: Notes] = [:]
    /// How far into the hooks' events file has been read; nil before the first look.
    private var eventsRead: UInt64?
    /// Each session as last seen, to tell what changed.
    private var previous: [String: Session] = [:]
    /// Whether the sessions have been looked at yet: those already going at
    /// launch are told of as starting, but none as finishing.
    private var looked = false

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        let now = Date()
        readHookEvents()
        if checks % 30 == 0 { hooked = Hooks.isInstalled }
        checks += 1
        let sessions = Self.recentSessions(under: root, now: now, tails: &tails, notes: notes, hooked: hooked)
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
        let events = changes(to: sessions)
        let onChange = onChange, onShip = onShip, onEvent = onEvent, mode = self.mode
        Task { @MainActor [weak self] in
            self?.sessions = sessions
            if changed { onChange?(state, mode) }
            if shipped { onShip?() }
            for event in events { onEvent?(event) }
        }
    }

    /// Whether Clawde's hooks are in Claude Code's settings, looked at every
    /// half minute; and how many looks there have been.
    private var hooked = false
    private var checks = 0

    /// What's happened to each session since the last look.
    private func changes(to sessions: [Session]) -> [Event] {
        var events: [Event] = []
        let current = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for session in sessions {
            let before = previous[session.id]
            if session.state != .idle, (before?.state ?? .idle) == .idle { events.append(.started(session)) }
            if let need = session.need, need != before?.need { events.append(.needsYou(session)) }
        }
        var kept: [String: Session] = [:]
        if looked {
            for (id, before) in previous where before.state != .idle && (current[id]?.state ?? .idle) == .idle {
                // For a session the hooks have heard from, a turn is over when
                // they say it stopped or ended, or it's gone quiet for good; the
                // transcript alone can look finished for a moment mid-turn.
                let stopped = current[id]?.interrupted == true || notes[id].map { noted in
                    noted.stopped.map { $0.at >= (noted.turnAt ?? .distantPast) } ?? false
                } ?? false
                if hooked, notes[id] != nil, !stopped, current[id] != nil {
                    kept[id] = before
                    continue
                }
                let session = current[id] ?? before
                let said = session.interrupted ? nil : notes[id]?.stopped?.said ?? session.reply
                events.append(.finished(session, said: said))
            }
        }
        previous = current.merging(kept) { _, before in before }
        looked = true
        return events
    }

    // MARK: Hooks

    /// What the hooks said lately about one session: when its last turn
    /// began and how it ended, and what it needs of you, for which tool call.
    struct Notes {
        var turnAt: Date?
        var stopped: (at: Date, said: String?)?
        var need: (need: Need, at: Date, call: String?)?
        /// Where it runs, what it was last asked, and when a hook last said anything:
        /// enough to know a session whose transcript isn't written yet.
        var cwd: String?
        var prompt: String?
        var lastAt: Date?
    }

    /// Reads what the hooks have written since the last look; the first
    /// look starts near the end.
    private func readHookEvents() {
        guard let handle = try? FileHandle(forUpdating: Hooks.eventsFile) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        var start = eventsRead ?? (size > Self.tailBytes ? size - Self.tailBytes : 0)
        if start > size { start = 0 }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return }
        eventsRead = size
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let hook = entry["hook"] as? [String: Any], let id = hook["session_id"] as? String
            else { continue }
            let seconds = (entry["at"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            Self.note(hook, at: Date(timeIntervalSince1970: seconds), in: &notes[id, default: Notes()])
        }
        // Grown big, it starts afresh: everything in it has been read.
        if size > 4 << 20 {
            try? handle.truncate(atOffset: 0)
            eventsRead = 0
        }
    }

    /// Takes note of one hook's input.
    static func note(_ hook: [String: Any], at: Date, in notes: inout Notes) {
        let call = hook["tool_use_id"] as? String
        notes.lastAt = at
        if let cwd = hook["cwd"] as? String { notes.cwd = cwd }
        switch hook["hook_event_name"] as? String {
        case "UserPromptSubmit":
            notes.turnAt = at
            notes.need = nil
            notes.stopped = nil
            if let prompt = hook["prompt"] as? String, !prompt.isEmpty { notes.prompt = clip(prompt, 120) }
        case "PreToolUse":
            if hook["tool_name"] as? String == "ExitPlanMode" {
                notes.need = (.plan, at, call)
            } else if hook["tool_name"] as? String == "AskUserQuestion" {
                notes.need = (.question(question(in: hook["tool_input"]) ?? ""), at, call)
            }
        case "PermissionRequest":
            // Asking you and showing you a plan go through permissions too.
            switch hook["tool_name"] as? String {
            case "AskUserQuestion": notes.need = (.question(question(in: hook["tool_input"]) ?? ""), at, call)
            case "ExitPlanMode": notes.need = (.plan, at, call)
            default: notes.need = (.permission(summary(of: hook["tool_name"] as? String, input: hook["tool_input"])), at, call)
            }
        case "Notification":
            let message = clip(hook["message"] as? String ?? "", 80)
            switch hook["notification_type"] as? String {
            case "permission_prompt":
                if notes.need == nil { notes.need = (.permission(message), at, nil) }
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                notes.need = (.question(message), at, nil)
            default:
                break
            }
        case "Stop", "StopFailure":
            notes.need = nil
            notes.stopped = (at, (hook["last_assistant_message"] as? String).map { clip($0, 200) })
        case "SessionEnd":
            notes.need = nil
            notes.stopped = (at, nil)
        default:
            break
        }
    }

    /// Whether what a session needed has been seen to: its tool call came
    /// back, or a turn began or ended since, or the transcript's turn is over.
    static func resolved(_ need: (need: Need, at: Date, call: String?), notes: Notes, tail: Tail) -> Bool {
        if let call = need.call, tail.results.contains(call) { return true }
        if let turnAt = notes.turnAt, turnAt > need.at { return true }
        if let stopped = notes.stopped, stopped.at >= need.at { return true }
        if case .finished = tail.last { return true }
        return false
    }

    /// A tool call in a few words: the tool, and the command, file or page it's for.
    static func summary(of tool: String?, input: Any?) -> String {
        let input = input as? [String: Any] ?? [:]
        let name = tool.map { $0.hasPrefix("mcp__") ? $0.split(separator: "_").last.map(String.init) ?? $0 : $0 } ?? "a tool"
        if let command = input["command"] as? String {
            return "\(name): \(clip(command.split(separator: "\n").first.map(String.init) ?? command, 60))"
        }
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String {
            return "\(name): \((path as NSString).lastPathComponent)"
        }
        if let url = input["url"] as? String { return "\(name): \(clip(url, 60))" }
        return name
    }

    /// The first question an AskUserQuestion call asks.
    static func question(in input: Any?) -> String? {
        let questions = (input as? [String: Any])?["questions"] as? [[String: Any]]
        return (questions?.first?["question"] as? String).map { clip($0, 120) }
    }

    /// The kind of work last told to `onChange`.
    private var reportedMode = WorkMode.typing

    /// The sessions still going or lately touched, newest first, leaving out
    /// Clawd's own conversation. `tails` keeps each transcript's reading
    /// until the file changes.
    static func recentSessions(under root: URL, now: Date = Date(), tails: inout [String: (modified: Date, tail: Tail)],
                               notes: [String: Notes] = [:], hooked: Bool = false) -> [Session] {
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
                } else if let kept = tails[path] {
                    // Mid-write or unreadable just now: what it said last still goes.
                    tail = kept.tail
                } else {
                    continue
                }
                let id = file.deletingPathExtension().lastPathComponent
                // A session the hooks tell of asks for permissions through them;
                // only for others is a permission guessed from a quiet tool call.
                var state = state(of: tail.last, now: now, guessing: !(hooked && notes[id] != nil))
                // What it's stopped for: as the hooks tell it, or as its transcript shows.
                var need: Need?
                if let noted = notes[id]?.need, !resolved(noted, notes: notes[id]!, tail: tail) {
                    need = noted.need
                } else if let asking = tail.asking {
                    need = asking.isEmpty ? .plan : .question(asking)
                } else if state == .waiting {
                    need = .permission("")
                }
                if need != nil { state = .waiting }
                guard now.timeIntervalSince(modified) < lifetime(of: tail.last, in: state) else { continue }
                let title = tail.title ?? tail.prompt.map { clip($0, 30) } ?? tail.project
                found.append(Session(id: id, project: tail.project, title: title, state: state, need: need,
                                     interrupted: tail.interrupted, mode: mode(of: tail.tools), shipped: tail.shipped,
                                     prompt: tail.prompt, reply: tail.reply, updated: modified))
            }
        }
        tails = tails.filter { seen.contains($0.key) }
        // A session mid-turn that the hooks know of but whose transcript isn't
        // written yet: a new one writes nothing while it waits on your say-so.
        let known = Set(found.map(\.id))
        for (id, noted) in notes where !known.contains(id) {
            guard let turnAt = noted.turnAt, (noted.stopped?.at ?? .distantPast) < turnAt,
                  let lastAt = noted.lastAt, now.timeIntervalSince(lastAt) < runningStaleAfter
            else { continue }
            let project = noted.cwd.map { ($0 as NSString).lastPathComponent } ?? "Claude Code"
            found.append(Session(id: id, project: project, title: noted.prompt.map { clip($0, 30) } ?? project,
                                 state: noted.need == nil ? .working : .waiting, need: noted.need?.need,
                                 prompt: noted.prompt, updated: lastAt))
        }
        return found.sorted { $0.updated > $1.updated }
    }

    /// What a session's newest entry means now. Claude is thinking from the
    /// moment it's asked until something of its answer is written, and
    /// again when a tool's result has sat `thinkingAfter` with no next step;
    /// working once it has thought (a thinking block is written) or is
    /// writing or running a tool; and waiting on the person while the tool
    /// it's stopped at asks them something, or is a quick one that's had no
    /// result for a while (it needs allowing).
    static func state(of last: Tail.Last, now: Date, guessing: Bool = true) -> ClaudeState {
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
            if !tools.isDisjoint(with: askingTools) || (guessing && quick && now.timeIntervalSince(at ?? now) > permissionAfter) {
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
        // A tool's result can be one line longer than the usual tail (an
        // image, a big file): then more is read, up to 32 MB.
        for window in [tailBytes, 4 << 20, 32 << 20] as [UInt64] {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { return nil }
            try? handle.seek(toOffset: size > window ? size - window : 0)
            guard let data = try? handle.readToEnd() else { return nil }
            if let tail = read(data, of: file) { return tail }
            if size <= window { return nil }
        }
        return nil
    }

    /// Reads a transcript's tail from its last `data`, newest entry first.
    private static func read(_ data: Data, of file: URL) -> Tail? {
        var last: Tail.Last?
        var wasInterrupted = false
        var title: String?
        var results = Set<String>()
        var asking: String?
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
            case "custom-title":
                if title == nil, let named = entry["customTitle"] as? String, !named.isEmpty { title = clip(named, 40) }
                continue
            case "assistant":
                if last == nil {
                    let reason = message?["stop_reason"] as? String
                    let tools = Self.toolNames(in: message?["content"])
                    if !(reason == nil || reason == "tool_use" || reason == "pause_turn") {
                        last = .finished
                    } else {
                        last = tools.isEmpty ? .wrote : .calling(tools, at: Self.date(of: entry))
                        if tools.contains("ExitPlanMode") { asking = "" }
                        for call in (message?["content"] as? [[String: Any]] ?? []) where call["name"] as? String == "AskUserQuestion" {
                            asking = Self.question(in: call["input"]) ?? ""
                        }
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
                for block in message?["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    results.insert(id)
                    if block["is_error"] as? Bool != true { succeeded.insert(id) }
                }
                if last == nil {
                    if interrupted || text.hasPrefix("<command-") || text.hasPrefix("<local-command") {
                        last = .finished
                        wasInterrupted = interrupted
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
            if last != nil, prompt != nil, reply != nil, project != nil, title != nil { break }
        }
        guard let last else { return nil }
        return Tail(
            last: last,
            project: project ?? file.deletingLastPathComponent().lastPathComponent,
            title: title,
            prompt: prompt.map { clip($0, 120) },
            reply: reply.map { clip($0, 160) },
            results: results,
            asking: asking,
            interrupted: wasInterrupted,
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

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
