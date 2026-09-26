import AppKit
import QuartzCore

/// Talking with Clawd: a field that pops up over its head, a speech bubble
/// that follows it, and the Brain answering what you type, the heartbeat
/// notes the Mind sends, and news of Claude Code's sessions to pass on.
@MainActor
final class ChatController {
    private enum Phase {
        case quiet
        case waiting(since: Double)
        case speaking
        case lingering(until: Double)
    }

    private enum Turn { case chat, heartbeat, event }

    let brain = Brain()
    /// A fact Clawd asked to keep, from a <remember> tag in a reply.
    var onRemember: ((String) -> Void)?
    /// Whether Clawd said something in answer to a heartbeat, or kept quiet.
    var onHeartbeatAnswered: ((Bool) -> Void)?

    private let pet: Pet
    private let input = ChatInputPanel()
    private let speech = SpeechPanel()
    private var phase = Phase.quiet
    /// Which kind of message the Brain is answering, if any.
    private var turn: Turn?
    /// The reply so far, tags and all.
    private var raw = ""
    /// A message typed while a heartbeat or an event was out, sent once it's answered.
    private var queued: String?
    /// What an event says if Clawd can't put it its own way in time, and
    /// whether that's been said already (the reply came too late).
    private var eventFallback: String?
    private var eventSaid = false
    /// How long Clawd gets to put news its own way.
    private static let eventTimeout = 10.0

    init(pet: Pet) {
        self.pet = pet
        brain.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        input.onSubmit = { [weak self] text in self?.submit(text) }
        input.onClose = { [weak self] in self?.inputClosed() }
    }

    /// Waiting on an answer to something you said.
    var isBusy: Bool { turn == .chat || queued != nil }

    /// The window the speech bubble shows in.
    var bubbleWindow: NSWindow { speech }

    /// A heartbeat waits while you're typing, reading a bubble, or talking with Clawd.
    var canTakeHeartbeat: Bool {
        guard turn == nil, queued == nil, !input.isVisible, case .quiet = phase else { return false }
        return true
    }

    func openInput() {
        guard !isBusy else { return }
        if case .lingering = phase { dismissBubble() }
        pet.chatMood = .listening
        ChatLog.start(from: Brain.transcript(of: brain.sessionID))
        input.show(over: pet.headTop(), within: pet.visibleFrame, history: ChatLog.recent())
    }

    func heartbeat(_ note: String) {
        turn = .heartbeat
        raw = ""
        brain.send(note)
    }

    /// Passes on news of a Claude Code session in Clawd's own words: `note`
    /// goes to the Brain, and whatever it says shows over Clawd's head with a
    /// hop. Busy with something else, or slow to answer, Clawd says
    /// `fallback` instead.
    func event(_ note: String, fallback: String) {
        guard turn == nil, queued == nil, !input.isVisible else {
            tell(fallback)
            return
        }
        turn = .event
        raw = ""
        eventFallback = fallback
        eventSaid = false
        brain.send(note)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.eventTimeout) { [weak self] in
            guard let self, self.turn == .event, !self.eventSaid else { return }
            self.eventSaid = true
            self.tell(fallback)
        }
    }

    /// Something to tell you: a hop, and the line in the bubble.
    private func tell(_ line: String) {
        guard !line.isEmpty else { return }
        ChatLog.append(.clawd, line)
        pet.perk()
        say(line, linger: min(30, 8 + Double(line.count) * 0.06), holdsClawd: false)
    }

    /// Puts the field and the bubble away and lets the claude process go,
    /// keeping its saved conversation for next time.
    func disconnect() {
        input.close()
        turn = nil
        queued = nil
        dismissBubble()
        brain.restart()
    }

    /// A click on Clawd while its bubble shows puts the bubble away.
    func poked() {
        if case .lingering = phase { dismissBubble() }
    }

    /// Shows a line over Clawd's head for a while. In a chat Clawd stops to
    /// face you (`holdsClawd`); news and remarks it says in passing, carrying
    /// on with whatever it's doing, the bubble following it.
    func say(_ text: String, linger seconds: Double, holdsClawd: Bool = true) {
        raw = text
        speech.alphaValue = 1
        phase = .lingering(until: CACurrentMediaTime() + seconds)
        if holdsClawd { pet.chatMood = .listening }
    }

    /// Keeps the field and the bubble over Clawd's head; runs every frame.
    func tick() {
        let now = CACurrentMediaTime()
        if input.isVisible { input.place(over: pet.headTop(), within: pet.visibleFrame) }
        switch phase {
        case .quiet:
            return
        case .waiting(let since):
            let dots = String(repeating: "·", count: Int((now - since) * 3) % 3 + 1)
            speech.show(dots, over: pet.headTop(), within: pet.visibleFrame)
        case .speaking:
            speech.show(Self.visible(raw), over: pet.headTop(), within: pet.visibleFrame)
        case .lingering(let until):
            speech.show(Self.visible(raw), over: pet.headTop(), within: pet.visibleFrame)
            speech.alphaValue = CGFloat(min(1, max(0, (until - now) / 0.4)))
            if now >= until { dismissBubble() }
        }
    }

    private func submit(_ text: String) {
        ChatLog.append(.you, text)
        input.close()
        phase = .waiting(since: CACurrentMediaTime())
        pet.chatMood = .thinking
        speech.alphaValue = 1
        if turn == .heartbeat || turn == .event {
            queued = text
        } else {
            send(text)
        }
    }

    private func send(_ text: String) {
        turn = .chat
        raw = ""
        brain.send(text)
    }

    private func inputClosed() {
        if case .quiet = phase { pet.chatMood = .none }
    }

    private func handle(_ event: Brain.Event) {
        switch event {
        case .text(let piece):
            raw += piece
            if turn == .chat, !Self.visible(raw).isEmpty {
                phase = .speaking
                pet.chatMood = .talking
            }
        case .done:
            let finished = turn
            turn = nil
            for fact in Self.facts(in: raw) { onRemember?(fact) }
            if finished == .event {
                // News is told whatever else is going on: in Clawd's words,
                // or plainly if it came up empty or it's been told already.
                let shown = Self.visible(raw)
                if !eventSaid { tell(Self.isQuiet(shown) ? eventFallback ?? "" : shown) }
                eventFallback = nil
            }
            // You spoke while a heartbeat or news was out: its reply gives way to yours.
            if let text = queued {
                queued = nil
                send(text)
                return
            }
            guard finished != .event else { return }
            let shown = Self.visible(raw)
            // Long enough to read: a beat plus a little per character.
            let linger = min(30, 4 + Double(shown.count) * 0.12)
            if finished == .chat {
                ChatLog.append(.clawd, shown)
                say(shown.isEmpty ? "…" : shown, linger: linger)
            } else {
                let spoke = !Self.isQuiet(shown)
                onHeartbeatAnswered?(spoke)
                if spoke {
                    ChatLog.append(.clawd, shown)
                    // Speaking up unasked: a little hop first, so you notice.
                    pet.perk()
                    say(shown, linger: linger, holdsClawd: false)
                }
            }
        case .failed(let why):
            let finished = turn
            turn = nil
            if finished == .event {
                if !eventSaid { tell(eventFallback ?? "") }
                eventFallback = nil
            }
            if let text = queued {
                queued = nil
                send(text)
                return
            }
            // A heartbeat that fails passes unremarked.
            if finished == .chat { say("Oops… \(why)", linger: 8) }
        }
    }

    private func dismissBubble() {
        phase = .quiet
        speech.orderOut(nil)
        if !input.isVisible { pet.chatMood = .none }
    }

    // MARK: Reading replies

    private static let rememberTag = try! NSRegularExpression(
        pattern: "<remember>(.*?)</remember>", options: [.dotMatchesLineSeparators]
    )

    /// The facts a reply asked to keep.
    static func facts(in text: String) -> [String] {
        rememberTag.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
        }.filter { !$0.isEmpty }
    }

    /// What of a reply goes in the bubble: its <remember> tags taken out,
    /// including one still arriving.
    static func visible(_ text: String) -> String {
        var shown = rememberTag.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
        if let open = shown.range(of: "<remember") {
            shown = String(shown[..<open.lowerBound])
        } else if let cut = (1...8).reversed().first(where: { shown.hasSuffix(String("<remember".prefix($0))) }) {
            shown.removeLast(cut)
        }
        return shown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clawd chose not to say anything.
    static func isQuiet(_ shown: String) -> Bool {
        shown.isEmpty || shown.lowercased().hasPrefix("[quiet]")
    }
}

// MARK: - Input

/// The chat over Clawd's head, a pixel-art dialog box: what you two have
/// said, scrollable, over a line to type in. It takes the keyboard without
/// activating the app, so whatever you were in stays in front.
final class ChatInputPanel: NSPanel, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let box = PixelBoxView()
    private let scroll = NSScrollView()
    private let history = ChatHistoryView()
    private static let width: CGFloat = 320
    private static let pad: CGFloat = 10
    private static let fieldHeight: CGFloat = 18
    /// The most of the history shown before it scrolls.
    private static let tallest: CGFloat = 220

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = BoardFont.nsFont
        field.textColor = PixelText.ink
        field.placeholderAttributedString = NSAttributedString(
            string: "Say something", attributes: [.font: BoardFont.nsFont, .foregroundColor: PixelText.faint])
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.target = self
        field.action = #selector(submit)

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = history

        box.addSubview(scroll)
        box.addSubview(field)
        contentView = box
    }

    override var canBecomeKey: Bool { true }

    /// Opens over Clawd's head with `entries` above the field, the newest in view.
    func show(over head: NSPoint, within visible: NSRect, history entries: [ChatLog.Entry]) {
        layOut(history: entries)
        place(over: head, within: visible)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    /// Sizes the box to `entries` (the history as tall as it needs, up to
    /// `tallest`) and scrolls to the newest.
    func layOut(history entries: [ChatLog.Entry]) {
        let inner = Self.width - 2 * Self.pad
        history.show(entries, width: inner - 8)
        let shown = min(history.frame.height, Self.tallest)
        let gap: CGFloat = shown > 0 ? 8 : 0
        let height = Self.pad + shown + gap + Self.fieldHeight + Self.pad + CGFloat(PixelBoxView.tail)
        setContentSize(NSSize(width: Self.width, height: height))
        box.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        scroll.frame = NSRect(x: Self.pad, y: Self.pad, width: inner, height: shown)
        field.frame = NSRect(x: Self.pad, y: Self.pad + shown + gap, width: inner, height: Self.fieldHeight)
        history.scroll(NSPoint(x: 0, y: max(0, history.frame.height - shown)))
    }

    func place(over head: NSPoint, within visible: NSRect) {
        let x = min(max(head.x - Self.width / 2, visible.minX + 6), visible.maxX - Self.width - 6).rounded()
        setFrameOrigin(NSPoint(x: x, y: (head.y + 4).rounded()))
        if box.tailX != head.x - x {
            box.tailX = head.x - x
            box.needsDisplay = true
        }
    }

    @objc private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        field.stringValue = ""
        onSubmit?(text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        close()
        return true
    }

    /// Clicking anywhere else puts the field away.
    override func resignKey() {
        super.resignKey()
        if isVisible { close() }
    }

    override func close() {
        guard isVisible else { return }
        orderOut(nil)
        onClose?()
    }
}

/// A pixel-art dialog box filling the view, its tail pointing down at `tailX`.
final class PixelBoxView: NSView {
    static let tail = 4
    var tailX: CGFloat = 0

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        PixelText.drawBox(bounds, tailX: tailX, tail: Self.tail, pixel: 1, in: cg)
    }
}

/// What you and Clawd have said, a speaker's name before each, in the pixel
/// font, wrapped to the chat's width; drawn only where it's scrolled into view.
final class ChatHistoryView: NSView {
    private var lines: [(y: CGFloat, text: String, label: String?, who: ChatLog.Who)] = []
    private static let clawd = NSColor(srgbRed: 0xD8 / 255.0, green: 0x76 / 255.0, blue: 0x56 / 255.0, alpha: 1)

    override var isFlipped: Bool { true }

    func show(_ entries: [ChatLog.Entry], width: CGFloat) {
        lines = []
        var y: CGFloat = 0
        for (n, entry) in entries.enumerated() {
            if n > 0 { y += 5 }
            let label = entry.who == .clawd ? "Clawd:" : "You:"
            for (k, line) in PixelText.wrap(label + " " + entry.text, width: Int(width)).enumerated() {
                lines.append((y, line, k == 0 ? label : nil, entry.who))
                y += CGFloat(PixelText.lineHeight)
            }
        }
        frame = NSRect(x: 0, y: 0, width: width, height: lines.isEmpty ? 0 : y - 2)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        for line in lines where line.y + CGFloat(PixelText.lineHeight) >= dirtyRect.minY && line.y <= dirtyRect.maxY {
            var text = line.text, x: CGFloat = 0
            if let label = line.label, text.hasPrefix(label) {
                PixelText.draw(label, at: CGPoint(x: 0, y: line.y), pixel: 1,
                               color: line.who == .clawd ? Self.clawd : PixelText.faint, in: cg)
                x = CGFloat(BoardFont.width(label + " "))
                text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
            }
            PixelText.draw(text, at: CGPoint(x: x, y: line.y), pixel: 1, color: PixelText.ink, in: cg)
        }
    }
}

// MARK: - History

/// What you and Clawd said in chat, and what Clawd told you on its own, kept
/// for the chat's history: a line of JSON each in chat.jsonl in Clawde's
/// folder, on your Mac only.
@MainActor
enum ChatLog {
    enum Who: String, Codable { case you, clawd }

    struct Entry: Codable {
        var who: Who
        var text: String
        var at: Double
    }

    static let file = Mind.folder.appendingPathComponent("chat.jsonl")

    static func append(_ who: Who, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        write([Entry(who: who, text: text, at: Date().timeIntervalSince1970)])
    }

    /// The last `count` things said, oldest first.
    static func recent(_ count: Int = 300) -> [Entry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(count).compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0.utf8)) }
    }

    static func forget() {
        try? FileManager.default.removeItem(at: file)
    }

    /// The first time, the history starts with what you two said already in
    /// Clawd's conversation (`transcript`): your messages and its answers,
    /// not the notes Clawde sends it or what it says to those.
    static func start(from transcript: URL?) {
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        var entries: [Entry] = []
        if let transcript, let text = try? String(contentsOf: transcript, encoding: .utf8) {
            let dates = ISO8601DateFormatter()
            dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var answering = false, reply = "", replyAt = 0.0
            func finishReply() {
                let shown = ChatController.visible(reply)
                if answering, !ChatController.isQuiet(shown) { entries.append(Entry(who: .clawd, text: shown, at: replyAt)) }
                reply = ""
            }
            for line in text.split(separator: "\n") {
                guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let message = entry["message"] as? [String: Any]
                else { continue }
                let at = (entry["timestamp"] as? String).flatMap { dates.date(from: $0) }?.timeIntervalSince1970 ?? 0
                let words: String
                if let content = message["content"] as? String {
                    words = content
                } else if let blocks = message["content"] as? [[String: Any]] {
                    words = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                } else {
                    continue
                }
                switch entry["type"] as? String {
                case "user":
                    guard entry["isMeta"] as? Bool != true, entry["isCompactSummary"] as? Bool != true, !words.isEmpty else { continue }
                    finishReply()
                    answering = !(words.hasPrefix("[heartbeat]") || words.hasPrefix("[event]") || words.hasPrefix("<"))
                    if answering { entries.append(Entry(who: .you, text: words, at: at)) }
                case "assistant":
                    reply += words
                    replyAt = at
                default:
                    continue
                }
            }
            finishReply()
        }
        write(entries)
        if entries.isEmpty, !FileManager.default.fileExists(atPath: file.path) { try? Data().write(to: file) }
    }

    private static func write(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        var data = Data()
        for entry in entries {
            guard let line = try? JSONEncoder().encode(entry) else { continue }
            data += line + Data("\n".utf8)
        }
        try? FileManager.default.createDirectory(at: Mind.folder, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }
}

// MARK: - Speech bubble

/// Clawd's reply over its head, wrapped to a comfortable width, its tail
/// pointing down at Clawd even where the bubble is pushed in from a screen edge.
final class SpeechPanel: NSPanel {
    private let bubble = SpeechView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = bubble
    }

    override var canBecomeKey: Bool { false }

    func show(_ text: String, over head: NSPoint, within visible: NSRect) {
        let size = SpeechView.size(for: text)
        let x = min(max(head.x - size.width / 2, visible.minX + 4), visible.maxX - size.width - 4).rounded()
        let frame = NSRect(x: x, y: (head.y + 4).rounded(), width: size.width, height: size.height)
        if self.frame != frame { setFrame(frame, display: false) }
        bubble.frame = NSRect(origin: .zero, size: size)
        if bubble.text != text || bubble.tailX != head.x - x {
            bubble.text = text
            bubble.tailX = head.x - x
            bubble.needsDisplay = true
        }
        if !isVisible { orderFrontRegardless() }
    }
}

/// The speech bubble: a pixel-art dialog box, the words in the pixel font.
final class SpeechView: NSView {
    var text = ""
    var tailX: CGFloat = 0

    /// In font pixels, which are points.
    private static let maxTextWidth = 240
    private static let padding = (x: 9, y: 7)

    static func size(for text: String) -> NSSize {
        let lines = PixelText.wrap(text, width: maxTextWidth)
        let width = lines.map(BoardFont.width).max() ?? 0
        return NSSize(width: CGFloat(max(28, width + 2 * padding.x)),
                      height: CGFloat(lines.count * PixelText.lineHeight - 2 + 2 * padding.y + PixelBoxView.tail))
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        PixelText.drawBox(bounds, tailX: tailX, tail: PixelBoxView.tail, pixel: 1, in: cg)
        for (k, line) in PixelText.wrap(text, width: Self.maxTextWidth).enumerated() {
            PixelText.draw(line, at: CGPoint(x: Self.padding.x, y: Self.padding.y + k * PixelText.lineHeight), pixel: 1,
                           color: PixelText.ink, in: cg)
        }
    }
}
