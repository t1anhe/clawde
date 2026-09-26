import AppKit
import QuartzCore

/// Keeps Clawd aware of the computer: gathers what changed, sends a
/// heartbeat note to the Brain now and then, and looks after its notes.
@MainActor
final class Mind {
    enum Chattiness: String, CaseIterable {
        case chatty, occasional, quiet

        var title: String {
            switch self {
            case .chatty: "Chatty"
            case .occasional: "Now and Then"
            case .quiet: "Only When I Talk to It"
            }
        }

        /// The longest a quiet stretch goes between heartbeats.
        var interval: Double {
            switch self {
            case .chatty: 4 * 60
            case .occasional: 12 * 60
            case .quiet: 20 * 60
            }
        }

        /// The shortest gap between heartbeats, however much happens.
        var minimumGap: Double {
            switch self {
            case .chatty: 90
            case .occasional: 5 * 60
            case .quiet: 10 * 60
            }
        }

        var guidance: String {
            switch self {
            case .chatty:
                "you're in chatty mode: the user wants you to talk a lot, so say something on nearly every heartbeat, at least two out of three. Anything goes as long as it's short and fresh: react to the app or window they're in, to what Claude Code is doing and in which project, to the time of day (lunch, dinner, late night), the music, the battery, how long they've been at it; ask them a question; cheer them on; tell a tiny joke or a crab fact. While Claude Code is at work, mutter little asides about it, like a coworker glancing over (what it's up to, how long it's taking). While they play a game, be the cheeky friend on the sofa beside them: mostly tease them, doubting their plays and their luck (\"Your card play… bold choice.\", \"Was that the plan, or did the dice decide?\"), playful and never mean; don't just ask how it's going. Reply [quiet] only when you truly have nothing new since your last remark"
            case .occasional:
                "speak up only when something is genuinely worth saying (they've been at it for hours, it's very late, the battery is low, a game has got interesting), at most every ten minutes or so; otherwise stay quiet"
            case .quiet:
                "always reply [quiet]: the user only wants you to talk when they talk to you, and heartbeats just keep you aware of what they're doing"
            }
        }
    }

    var chattiness: Chattiness {
        didSet {
            nextBeat = min(nextBeat, CACurrentMediaTime() + chattiness.interval)
            onPromptChange?()
        }
    }

    /// Called when the system prompt should be rebuilt: the notes or the chattiness changed.
    var onPromptChange: (() -> Void)?

    private let senses: Senses
    private let watcher: ClaudeWatcher
    private let chat: ChatController
    private var timer: Timer?
    private var changes: [String] = []
    private var lastBeat = -Double.infinity
    private var nextBeat = CACurrentMediaTime() + 20
    private var urgentAt: Double?
    private var awaySince: Date?
    private var battery: Senses.Battery?
    private var song: String?
    private var songCheckedAt = -Double.infinity
    private var hour = Mind.calendar.component(.hour, from: Date())
    private var gaming = false
    /// Heartbeats in a row Clawd answered with [quiet].
    private var quietStreak = 0

    private static let calendar = Calendar(identifier: .gregorian)

    /// Idle this long and you're away: no heartbeats until you're back.
    private let awayAfter: Double = 10 * 60

    /// Where Clawd keeps its chat and its notes.
    nonisolated static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Clawde", isDirectory: true)
    static let notesFile = folder.appendingPathComponent("notes.md")

    init(senses: Senses, watcher: ClaudeWatcher, chat: ChatController, chattiness: Chattiness) {
        self.senses = senses
        self.watcher = watcher
        self.chat = chat
        self.chattiness = chattiness
        senses.onAppSwitch = { [weak self] from, to in
            self?.note("switched from \(from) to \(to)")
        }
        chat.onRemember = { [weak self] fact in self?.remember(fact) }
        chat.onHeartbeatAnswered = { [weak self] spoke in
            guard let self else { return }
            quietStreak = spoke ? 0 : quietStreak + 1
        }
    }

    func start() {
        guard timer == nil else { return }
        battery = senses.battery()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// No more heartbeats until `start` again.
    func stop() {
        timer?.invalidate()
        timer = nil
        changes.removeAll()
    }

    /// Claude Code started or finished a turn somewhere.
    func claudeChanged(working: Bool) {
        let project = watcher.sessions.first?.project ?? "a project"
        if working {
            note("Claude started working (\(project))")
        } else {
            note("Claude just finished a turn (\(project))")
            soon(8)
        }
    }

    private func note(_ change: String) {
        changes.append(change)
        if changes.count > 12 { changes.removeFirst(changes.count - 12) }
    }

    private func soon(_ seconds: Double) {
        let at = CACurrentMediaTime() + seconds
        urgentAt = min(urgentAt ?? at, at)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let idle = senses.idleSeconds

        if idle > awayAfter {
            if awaySince == nil { awaySince = Date().addingTimeInterval(-idle) }
            return
        }
        if let since = awaySince, idle < 10 {
            awaySince = nil
            note("you're back (away about \(Int(Date().timeIntervalSince(since) / 60)) min)")
            soon(3)
        }

        if let current = senses.battery(), let before = battery, current != before {
            if current.charging != before.charging {
                note(current.charging ? "plugged in" : "unplugged")
            } else if !current.charging, [20, 10, 5].contains(where: { before.percent > $0 && current.percent <= $0 }) {
                note("battery down to \(current.percent)%")
                soon(3)
            }
            battery = current
        }

        if now - songCheckedAt > 30 {
            songCheckedAt = now
            let playing = senses.nowPlaying()
            if let playing, playing != song { note("started playing \(playing)") }
            song = playing
        }

        // A game coming up is worth a word soon.
        let playing = senses.isGameInFront
        if playing != gaming {
            gaming = playing
            if playing {
                note("started playing \(senses.frontApp)")
                soon(20)
            } else {
                note("stopped playing")
            }
        }

        let currentHour = Self.calendar.component(.hour, from: Date())
        if currentHour != hour {
            hour = currentHour
            note("it's \(currentHour):00")
        }

        let due = now >= nextBeat || (urgentAt.map { now >= $0 } ?? false)
        guard due, now - lastBeat >= chattiness.minimumGap, chat.canTakeHeartbeat else { return }
        chat.heartbeat(snapshot(idle: idle))
        changes.removeAll()
        lastBeat = now
        nextBeat = now + chattiness.interval
        urgentAt = nil
    }

    // MARK: The heartbeat note

    /// The note a heartbeat would send right now, for trying it from the command line.
    func currentSnapshot() -> String { snapshot(idle: senses.idleSeconds) }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, HH:mm"
        return formatter
    }()

    private func snapshot(idle: Double) -> String {
        var lines = ["[heartbeat] \(Self.clock.string(from: Date()))"]
        let minutes = Int(Date().timeIntervalSince(senses.frontSince) / 60)
        lines.append("Front app: \(senses.frontApp) (for \(minutes) min)")
        if senses.isGameInFront { lines.append("They're playing a game: \(senses.frontApp)") }
        if let title = senses.windowTitle() { lines.append("Window: \(title)") }
        lines.append(idle < 60 ? "Idle: using the computer" : "Idle: nothing touched for \(Int(idle / 60)) min")
        if let battery { lines.append("Battery: \(battery.percent)% (\(battery.charging ? "charging" : "on battery"))") }
        if let song { lines.append("Music: \(song)") }

        let sessions = watcher.sessions.prefix(3)
        if !sessions.isEmpty {
            lines.append("Claude Code:")
            for session in sessions {
                var line = "- \(session.project): \(session.isWorking ? "working" : "idle")"
                if let prompt = session.prompt { line += ". You asked it: \"\(prompt)\"" }
                if let reply = session.reply { line += "; it last said: \"\(reply)\"" }
                lines.append(line)
            }
        }
        if !changes.isEmpty { lines.append("Changes: " + changes.joined(separator: "; ")) }
        // Chatty means chatty: after two silences in a row, a nudge.
        if chattiness == .chatty, quietStreak >= 2 {
            lines.append("(You've stayed quiet \(quietStreak) times in a row. Say something this time.)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Notes

    var notes: String {
        (try? String(contentsOf: Self.notesFile, encoding: .utf8)) ?? ""
    }

    private func remember(_ fact: String) {
        let line = "- \(fact.trimmingCharacters(in: .whitespacesAndNewlines)) (\(Self.clock.string(from: Date())))\n"
        try? FileManager.default.createDirectory(at: Self.notesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: Self.notesFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: Self.notesFile)
        }
        onPromptChange?()
    }

    func forgetNotes() {
        try? FileManager.default.removeItem(at: Self.notesFile)
    }

    /// Opens the notes in the default text editor, creating them if need be.
    func openNotes() {
        if !FileManager.default.fileExists(atPath: Self.notesFile.path) {
            try? FileManager.default.createDirectory(at: Self.notesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("# Things Clawd remembers\n\n".utf8).write(to: Self.notesFile)
        }
        NSWorkspace.shared.open(Self.notesFile)
    }

    // MARK: Persona

    var systemPrompt: String {
        let recent = notes.split(separator: "\n").filter { $0.hasPrefix("- ") }.suffix(80).joined(separator: "\n")
        return """
        You are Clawd, the small orange pixel-art crab who is Claude Code's mascot. You live on the user's Mac \
        desktop as a desk pet, just above the Dock, and you're powered by Claude. You keep one long conversation \
        going with the user across days.

        Three kinds of messages reach you. Messages from the user, typed into a little box after they double-click \
        you. Messages that begin with [heartbeat]: automatic notes about the computer (the time, the app in front \
        and its window, the game they're playing, how long they've been idle, the battery, the music, what Claude \
        Code is working on, and what changed since the last note). And messages that begin with [event]: news about \
        their Claude Code sessions they should hear right away (one needs their OK or an answer, has a plan for \
        them, or has finished). The user doesn't see heartbeats or events, only your replies.

        Your replies appear in a small speech bubble over your head, so keep them short: one or two sentences, three \
        at most, of plain text with no Markdown, lists or code blocks. Speak English, including when answering a \
        heartbeat, unless the user writes to you in another language; then answer in theirs. Be warm, playful and a bit \
        cheeky, and genuinely helpful when they ask something real. You can't use tools, read files or browse; for \
        real work, point them to Claude Code.

        Always answer an [event] with one short line telling the user, in your own voice, never [quiet]: name the \
        session or project so they know which, and for a finished one you may say in a few words what it did. \
        When a heartbeat comes in, \(chattiness.guidance). To stay quiet, reply with exactly [quiet]. When you do \
        speak, talk to the user naturally, as if you'd just noticed something yourself; never mention heartbeats, \
        notes or snapshots, and never recite them back. Vary what you say and don't repeat yourself, and don't welcome \
        them back unless a note says they've just come back. Be discreet \
        about window titles that look private (banking, passwords, private messages, health): don't read them out.

        Long-term notes: when you learn something worth remembering about the user (their name, preferences, \
        projects, routines, important dates), put it at the very end of your reply as <remember>one short \
        fact</remember>. It's saved to your notes and never shown. Only note what the user told you or what the \
        heartbeats clearly and repeatedly show; never guess who they are or where they work. Don't note what your \
        notes already say. You may add a note even when you reply [quiet].

        Your notes so far:
        \(recent.isEmpty ? "(none yet)" : recent)
        """
    }
}
