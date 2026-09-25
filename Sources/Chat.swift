import AppKit
import QuartzCore

/// Talking with Clawd: a field that pops up over its head, a speech bubble
/// that follows it, and the Brain answering both what you type and the
/// heartbeat notes the Mind sends.
@MainActor
final class ChatController {
    private enum Phase {
        case quiet
        case waiting(since: Double)
        case speaking
        case lingering(until: Double)
    }

    private enum Turn { case chat, heartbeat }

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
    /// A message typed while a heartbeat was out, sent once it's answered.
    private var queued: String?

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

    /// A heartbeat waits while you're typing, reading a bubble, or talking with Clawd.
    var canTakeHeartbeat: Bool {
        guard turn == nil, queued == nil, !input.isVisible, case .quiet = phase else { return false }
        return true
    }

    func openInput() {
        guard !isBusy else { return }
        if case .lingering = phase { dismissBubble() }
        pet.chatMood = .listening
        input.show(over: pet.headTop(), within: pet.visibleFrame)
    }

    func heartbeat(_ note: String) {
        turn = .heartbeat
        raw = ""
        brain.send(note)
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

    /// Shows a line over Clawd's head for a while.
    func say(_ text: String, linger seconds: Double) {
        raw = text
        speech.alphaValue = 1
        phase = .lingering(until: CACurrentMediaTime() + seconds)
        pet.chatMood = .listening
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
        input.close()
        phase = .waiting(since: CACurrentMediaTime())
        pet.chatMood = .thinking
        speech.alphaValue = 1
        if turn == .heartbeat {
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
            // You spoke while a heartbeat was out: its reply gives way to yours.
            if let text = queued {
                queued = nil
                send(text)
                return
            }
            let shown = Self.visible(raw)
            // Long enough to read: a beat plus a little per character.
            let linger = min(30, 4 + Double(shown.count) * 0.12)
            if finished == .chat {
                say(shown.isEmpty ? "…" : shown, linger: linger)
            } else {
                let spoke = !Self.isQuiet(shown)
                onHeartbeatAnswered?(spoke)
                if spoke {
                    // Speaking up unasked: a little hop first, so you notice.
                    pet.perk()
                    say(shown, linger: linger)
                }
            }
        case .failed(let why):
            let finished = turn
            turn = nil
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

/// A one-line field over Clawd's head. It takes the keyboard without
/// activating the app, so whatever you were in stays in front.
final class ChatInputPanel: NSPanel, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private static let size = NSSize(width: 300, height: 38)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        field.frame = NSRect(x: 14, y: 9, width: Self.size.width - 28, height: 20)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Say something to Clawd… (Return sends, Esc closes)"
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.target = self
        field.action = #selector(submit)

        background.addSubview(field)
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    func show(over head: NSPoint, within visible: NSRect) {
        place(over: head, within: visible)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    func place(over head: NSPoint, within visible: NSRect) {
        let x = min(max(head.x - Self.size.width / 2, visible.minX + 6), visible.maxX - Self.size.width - 6)
        setFrameOrigin(NSPoint(x: x.rounded(), y: (head.y + 10).rounded()))
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

final class SpeechView: NSView {
    var text = ""
    var tailX: CGFloat = 0

    private static let maxTextWidth: CGFloat = 240
    private static let padding = NSSize(width: 12, height: 8)
    private static let tail: CGFloat = 7

    private static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        return [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: Palette.bubbleText,
            .paragraphStyle: paragraph,
        ]
    }

    static func size(for text: String) -> NSSize {
        let bounds = NSAttributedString(string: text, attributes: attributes).boundingRect(
            with: NSSize(width: maxTextWidth, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // A point to spare, so drawing wraps exactly where measuring did.
        return NSSize(
            width: max(44, ceil(bounds.width) + 1 + 2 * padding.width),
            height: ceil(bounds.height) + 2 * padding.height + tail
        )
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: bounds.height - Self.tail - 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 11, yRadius: 11)
        let x = min(max(tailX, 14), bounds.width - 14)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: x - 6, y: box.maxY - 1))
        tail.line(to: NSPoint(x: x + 6, y: box.maxY - 1))
        tail.line(to: NSPoint(x: x, y: bounds.height - 0.5))
        tail.close()

        Palette.bubble.setFill()
        path.fill()
        Palette.bubbleEdge.setStroke()
        path.lineWidth = 1
        path.stroke()
        Palette.bubble.setFill()
        tail.fill()

        let textRect = NSRect(
            x: Self.padding.width, y: Self.padding.height,
            width: bounds.width - 2 * Self.padding.width, height: bounds.height - Self.tail - 2 * Self.padding.height
        )
        NSAttributedString(string: text, attributes: Self.attributes)
            .draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
