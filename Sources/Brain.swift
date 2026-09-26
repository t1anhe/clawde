import Foundation

/// Clawd's voice: one long-lived `claude -p` process speaking stream-json, so
/// replies skip startup, resuming the same saved session each launch so the
/// conversation carries on across days (Claude Code compacts it as it grows).
///
/// It runs on the person's own Claude Code login with no tools, so it can only
/// talk; its transcripts live under Clawd's own project, which the watcher skips.
final class Brain {
    enum Event {
        case text(String)
        case done
        case failed(String)
    }

    /// Called on the main thread, in order.
    var onEvent: ((Event) -> Void)?
    var model = "claude-haiku-4-5"
    /// The persona, in place of Claude Code's own system prompt; read at each launch.
    var systemPrompt = "You are Clawd, a small orange pixel crab living on the user's desktop."
    /// The one conversation Clawd keeps, resumed at each launch.
    var sessionID = UUID().uuidString.lowercased()

    /// A quiet process is let go after this long; the next message starts it
    /// again, on the same conversation.
    static let idleSeconds: TimeInterval = 15 * 60
    static let replyTimeout: TimeInterval = 120

    private let queue = DispatchQueue(label: "clawd.brain")
    private var process: Process?
    private var stdin: FileHandle?
    /// Its output and errors, read as they come.
    private var reading: [FileHandle] = []
    private var pending = Data()
    private var stderrTail = ""
    private var idleKill: DispatchWorkItem?
    private var timeout: DispatchWorkItem?

    /// Sends one message; the reply arrives as `.text` pieces and then `.done`.
    func send(_ text: String) {
        queue.async { [self] in
            do {
                if process == nil { try launch() }
                let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
                var line = try JSONSerialization.data(withJSONObject: message)
                line.append(0x0A)
                try stdin?.write(contentsOf: line)
                armTimers()
            } catch {
                emit(.failed(Self.describe(error)))
                stop()
            }
        }
    }

    /// Lets the process go; the next message relaunches it on the same
    /// conversation, with the current model and system prompt.
    func restart() {
        queue.async { [self] in stop() }
    }

    /// Stops the process before the app exits.
    func shutdown() {
        queue.sync { stop() }
    }

    // MARK: Process

    private func launch() throws {
        guard let claude = Self.findClaude() else {
            throw BrainError.message("Can't find the claude command. Install Claude Code, then come find me.")
        }
        let folder = Mind.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--include-partial-messages", "--verbose",
            "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
            "--model", model, "--system-prompt", systemPrompt,
            // No hooks for Clawd's own turns: Clawde's would take them for a
            // session of yours at work, and yours aren't meant for it.
            "--settings", #"{"disableAllHooks":true}"#,
        ]
        arguments += Self.transcriptExists(sessionID) ? ["--resume", sessionID] : ["--session-id", sessionID]
        // Haiku 4.5 takes no effort setting; the others answer faster at low.
        if !model.contains("haiku") { arguments += ["--effort", "low"] }

        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment

        let output = Pipe(), input = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            self?.queue.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(400))
            }
        }
        process.terminationHandler = { [weak self] ended in
            self?.queue.async {
                guard let self, self.process === ended else { return }
                let detail = self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                self.emit(.failed(detail.isEmpty ? "My brain just cut out (exit code \(ended.terminationStatus))." : detail))
                self.stop()
            }
        }
        try process.run()
        self.process = process
        stdin = input.fileHandleForWriting
        reading = [output.fileHandleForReading, errors.fileHandleForReading]
        pending = Data()
        stderrTail = ""
    }

    private func stop() {
        idleKill?.cancel()
        timeout?.cancel()
        guard let process else { return }
        self.process = nil
        try? stdin?.close()
        stdin = nil
        // Whatever it still had to say goes unheard: a reply cut off stays cut off.
        for handle in reading { handle.readabilityHandler = nil }
        reading = []
        if process.isRunning {
            process.terminate()
            // Claude Code writes the session's last bookkeeping as it exits.
            process.waitUntilExit()
        }
    }

    private func armTimers() {
        idleKill?.cancel()
        let kill = DispatchWorkItem { [weak self] in self?.stop() }
        idleKill = kill
        queue.asyncAfter(deadline: .now() + Self.idleSeconds, execute: kill)

        timeout?.cancel()
        let late = DispatchWorkItem { [weak self] in
            self?.emit(.failed("I thought too long. Taking a breather."))
            self?.stop()
        }
        timeout = late
        queue.asyncAfter(deadline: .now() + Self.replyTimeout, execute: late)
    }

    // MARK: Output

    private func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        switch event["type"] as? String {
        case "stream_event":
            guard let inner = event["event"] as? [String: Any], inner["type"] as? String == "content_block_delta",
                  let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return }
            emit(.text(text))
        case "result":
            timeout?.cancel()
            if event["is_error"] as? Bool == true {
                emit(.failed((event["result"] as? String).map { String($0.prefix(160)) } ?? "Something went wrong."))
            } else {
                emit(.done)
            }
        default:
            break
        }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    // MARK: Helpers

    private enum BrainError: Error { case message(String) }

    private static func describe(_ error: Error) -> String {
        if case BrainError.message(let text) = error { return text }
        return error.localizedDescription
    }

    /// Whether Claude Code has saved this session, so it can be resumed.
    /// Where a conversation's transcript is, if it has one yet.
    static func transcript(of id: String) -> URL? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        return folders.lazy.map { projects.appendingPathComponent("\($0)/\(id).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Throws away a conversation's transcript, for one that was only ever a try-out.
    static func forget(_ id: String) {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] {
            try? FileManager.default.removeItem(at: projects.appendingPathComponent("\(folder)/\(id).jsonl"))
        }
    }

    private static func transcriptExists(_ id: String) -> Bool {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        return folders.contains { FileManager.default.fileExists(atPath: projects.appendingPathComponent("\($0)/\(id).jsonl").path) }
    }

    /// Claude Code's usual install places; a GUI app doesn't get the shell's PATH.
    private static func findClaude() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
