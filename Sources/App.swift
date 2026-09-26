import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// The size slider's range, in points per grid unit: Clawd is 12 units claw to claw.
    private static let units: ClosedRange<Double> = 2.5...10
    /// The Code tab draws its Clawd's 2750-wide Lottie canvas 80 points wide,
    /// 100 canvas units to a grid unit: about 2.9 points a unit.
    private static let codeTabUnit = 80.0 / 27.5
    /// The models Clawd can think with: the light ones, since it runs all day on
    /// the person's own subscription.
    private static let models: [(name: String, id: String)] = [
        ("Haiku 4.5", "claude-haiku-4-5"), ("Sonnet 5", "claude-sonnet-5"),
    ]

    private let defaults = UserDefaults.standard
    private let watcher = ClaudeWatcher()
    private var pet: Pet!
    /// Where Clawd writes up the Claude Code sessions at work.
    private let board = Board()
    private var chat: ChatController!
    private var mind: Mind!
    private let senses = Senses()
    private var statusItem: NSStatusItem!
    /// What the transcripts say, whether or not Clawd follows it.
    private var claudeState = ClaudeState.idle
    private var workMode = WorkMode.typing
    /// Apps that have Clawd read along with you: PDFs, books, and coding.
    private static let readingApps: Set<String> = ["com.apple.Preview", "com.apple.iBooksX", "com.microsoft.VSCode"]
    /// The senses' once-a-second look at what you're up to; the music
    /// players are asked every third, and two misses in a row mean it stopped
    /// rather than the next track loading.
    private var senseTimer: Timer?
    private var senseTicks = 0
    private var musicMisses = 2
    /// When a game was last in front: Clawd plays on through a quick look
    /// at something else.
    private var gameSeen = Date.distantPast
    /// A run-through of everything Clawd reacts to, its made-up senses
    /// standing in for the real ones and for Claude while it lasts.
    private var demo: (music: Bool, reading: Bool, gaming: Bool, idle: Double)?
    private var demoTimer: Timer?

    private var followsClaude: Bool {
        get { defaults.bool(forKey: "followClaude") }
        set { defaults.set(newValue, forKey: "followClaude") }
    }

    /// Whether Clawd talks through Claude: chatting when double-clicked and the
    /// Mind's heartbeats. Off, no claude process runs; the conversation and the
    /// notes stay on disk for when it's switched back on.
    private var isConnected: Bool {
        get { defaults.bool(forKey: "claudeConnected") }
        set { defaults.set(newValue, forKey: "claudeConnected") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            "unit": Self.codeTabUnit, "followClaude": true, "chatModel": "claude-haiku-4-5",
            "chattiness": Mind.Chattiness.chatty.rawValue, "claudeConnected": false,
            "boardStyle": Board.Style.chalk.rawValue,
        ])
        if defaults.string(forKey: "brainSession") == nil {
            defaults.set(UUID().uuidString.lowercased(), forKey: "brainSession")
        }

        pet = Pet(unit: CGFloat(defaults.double(forKey: "unit")))
        pet.makeMenu = { [unowned self] in self.buildMenu() }
        board.style = Board.Style(rawValue: defaults.string(forKey: "boardStyle") ?? "")
        pet.board = board
        chat = ChatController(pet: pet)
        chat.brain.model = defaults.string(forKey: "chatModel") ?? "claude-haiku-4-5"
        chat.brain.sessionID = defaults.string(forKey: "brainSession") ?? chat.brain.sessionID
        let chattiness = Mind.Chattiness(rawValue: defaults.string(forKey: "chattiness") ?? "") ?? .chatty
        mind = Mind(senses: senses, watcher: watcher, chat: chat, chattiness: chattiness)
        chat.brain.systemPrompt = mind.systemPrompt
        mind.onPromptChange = { [unowned self] in self.chat.brain.systemPrompt = self.mind.systemPrompt }
        pet.onTick = { [unowned self] in self.chat.tick() }
        pet.onPoke = { [unowned self] in self.chat.poked() }
        pet.onDoubleClick = { [unowned self] in
            if self.isConnected { self.chat.openInput() }
        }
        pet.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Renderer.menuBarImage()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        watcher.onChange = { [weak self] state, mode in
            guard let self else { return }
            self.claudeState = state
            self.workMode = mode
            if self.followsClaude, self.demo == nil { self.pet.setClaude(state, mode: mode) }
            self.mind.claudeChanged(working: state != .idle)
        }
        watcher.onShip = { [weak self] in
            guard let self, self.followsClaude, self.demo == nil else { return }
            self.pet.shipped()
        }
        watcher.onEvent = { [weak self] event in self?.claudeEvent(event) }
        watcher.start()
        startSensing()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.offerHooks() }
        if isConnected { mind.start() }
        // Started with --demo, the run-through begins at once.
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startDemo() }
        }
        // Started with --board-demo, made-up sessions come and go on the board.
        if CommandLine.arguments.contains("--board-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startBoardDemo() }
        }
        if let folder = ProcessInfo.processInfo.environment["CLAWD_RECORD"] {
            recorder = Recorder(folder: folder, windows: { [unowned self] in [self.board.window, self.pet.window] })
        }
    }

    /// With CLAWD_RECORD set to a folder, what Clawd and the board look like
    /// goes there a frame at a time.
    private var recorder: Recorder?

    /// Tells Clawd what you're up to, once a second.
    private func startSensing() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sense() }
        }
        RunLoop.main.add(timer, forMode: .common)
        senseTimer = timer
    }

    private func sense() {
        guard demo == nil else { return }
        if senseTicks % 3 == 0 {
            musicMisses = senses.isPlayingMusic() ? 0 : musicMisses + 1
        }
        senseTicks += 1
        if senses.isGameInFront { gameSeen = Date() }
        pet.sense(idle: senses.idleSeconds, music: musicMisses < 2, reading: Self.readingApps.contains(senses.frontBundle),
                  gaming: Date().timeIntervalSince(gameSeen) < 10)
        syncBoard()
    }

    /// The board kept to the sessions as they are.
    private func syncBoard() {
        guard followsClaude, demo == nil, !boardDemo else { return }
        let sessions = watcher.sessions
        board.sync(active: sessions.filter { $0.state != .idle }.map(Self.entry), known: Set(sessions.map(\.id)))
    }

    private static func entry(_ session: ClaudeWatcher.Session) -> Board.Entry {
        Board.Entry(id: session.id, project: session.project, title: session.title, needsYou: session.need != nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        chat.brain.shutdown()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let connect = item("Connect to Claude", #selector(toggleConnected))
        connect.state = isConnected ? .on : .off
        menu.addItem(connect)
        if isConnected { addChatItems(to: menu) }
        menu.addItem(.separator())
        if !Animations.groups.isEmpty {
            let acts = NSMenu()
            for (n, group) in Animations.groups.enumerated() {
                if n > 0 { acts.addItem(.separator()) }
                let heading = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                heading.isEnabled = false
                acts.addItem(heading)
                for action in group.actions {
                    let entry = item(action.title, #selector(performAction(_:)))
                    entry.representedObject = action.name
                    acts.addItem(entry)
                }
            }
            acts.addItem(.separator())
            let run = item(demo == nil ? "Run the Demo" : "Stop the Demo", #selector(toggleDemo))
            acts.addItem(run)
            let actItem = NSMenuItem(title: "Perform", action: nil, keyEquivalent: "")
            actItem.submenu = acts
            menu.addItem(actItem)
        }
        menu.addItem(item(pet.isAsleep ? "Wake Up" : "Take a Nap", #selector(toggleSleep)))

        let follow = item("Follow Claude", #selector(toggleFollow))
        follow.state = followsClaude ? .on : .off
        menu.addItem(follow)

        let boards = NSMenu()
        for style in Board.Style.allCases {
            let entry = item(style.title, #selector(pickBoard(_:)))
            entry.representedObject = style.rawValue
            entry.state = board.style == style ? .on : .off
            boards.addItem(entry)
        }
        boards.addItem(.separator())
        let noBoard = item("No Board", #selector(pickBoard(_:)))
        noBoard.representedObject = "off"
        noBoard.state = board.style == nil ? .on : .off
        boards.addItem(noBoard)
        let boardItem = NSMenuItem(title: "Bulletin Board", action: nil, keyEquivalent: "")
        boardItem.submenu = boards
        menu.addItem(boardItem)

        if Hooks.claudeCodeFound {
            let hooks = item("Use Claude Code Hooks", #selector(toggleHooks))
            hooks.state = Hooks.isInstalled ? .on : .off
            menu.addItem(hooks)
        }

        let login = item("Open at Login", #selector(toggleOpenAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        // A heading the menu lines up itself, and the slider under it.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Size"))
        menu.addItem(sizeSliderItem())

        menu.addItem(.separator())
        let status = NSMenuItem(title: Self.title(of: claudeState), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item("Quit Clawde", #selector(quit)))
        return menu
    }

    private static func title(of state: ClaudeState) -> String {
        switch state {
        case .idle: "Claude is idle"
        case .thinking: "Claude is thinking"
        case .working: "Claude is working"
        case .waiting: "Claude is waiting for you"
        }
    }

    /// Chatting, heartbeats and notes, shown while Clawd is connected to Claude.
    private func addChatItems(to menu: NSMenu) {
        let talk = item("Chat with Clawd…", #selector(openChat))
        talk.isEnabled = !chat.isBusy
        menu.addItem(talk)
        let chattinessMenu = NSMenu()
        for level in Mind.Chattiness.allCases {
            let entry = item(level.title, #selector(pickChattiness(_:)))
            entry.representedObject = level.rawValue
            entry.state = level == mind.chattiness ? .on : .off
            chattinessMenu.addItem(entry)
        }
        let chattinessItem = NSMenuItem(title: "Chattiness", action: nil, keyEquivalent: "")
        chattinessItem.submenu = chattinessMenu
        menu.addItem(chattinessItem)
        let modelMenu = NSMenu()
        for model in Self.models {
            let entry = item(model.name, #selector(pickModel(_:)))
            entry.representedObject = model.id
            entry.state = model.id == chat.brain.model ? .on : .off
            modelMenu.addItem(entry)
        }
        let modelItem = NSMenuItem(title: "Chat Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)
        menu.addItem(item("Things Clawd Remembers…", #selector(openNotes)))
        if !Senses.canReadWindows {
            menu.addItem(item("Let Clawd See Window Titles…", #selector(allowWindowTitles)))
        }
        menu.addItem(item("Make Clawd Forget Everything…", #selector(forgetEverything)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleConnected() {
        isConnected.toggle()
        if isConnected {
            mind.start()
        } else {
            mind.stop()
            chat.disconnect()
        }
    }

    @objc private func openChat() { chat.openInput() }
    @objc private func openNotes() { mind.openNotes() }
    @objc private func allowWindowTitles() { Senses.askToReadWindows() }

    /// A new model takes over the same conversation.
    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != chat.brain.model else { return }
        defaults.set(id, forKey: "chatModel")
        chat.brain.model = id
        chat.brain.restart()
    }

    @objc private func pickChattiness(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let level = Mind.Chattiness(rawValue: raw),
              level != mind.chattiness
        else { return }
        defaults.set(raw, forKey: "chattiness")
        mind.chattiness = level
        chat.brain.restart()
    }

    /// Starts Clawd's conversation over and throws away its notes, after asking.
    @objc private func forgetEverything() {
        let alert = NSAlert()
        alert.messageText = "Make Clawd forget everything?"
        alert.informativeText = "It forgets everything you two have talked about and every note it took, and gets to know you from scratch."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        mind.forgetNotes()
        let session = UUID().uuidString.lowercased()
        defaults.set(session, forKey: "brainSession")
        chat.brain.sessionID = session
        chat.brain.systemPrompt = mind.systemPrompt
        chat.brain.restart()
        chat.say("…Huh? Hi! I'm Clawd, nice to meet you! 🦀", linger: 5)
    }


    @objc private func performAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        pet.perform(name)
    }
    @objc private func toggleSleep() { pet.toggleSleep() }

    // MARK: Demo

    @objc private func toggleDemo() {
        if demo == nil { startDemo() } else { endDemo() }
    }

    /// Two minutes of everything Clawd reacts to, one after another, each
    /// captioned: music, Claude thinking, working, looking things up,
    /// changing code, committing, waiting on you and done; you reading,
    /// playing, sitting still, up late, at the weekend, at it too long, away
    /// and back.
    private func startDemo() {
        demo = (false, false, false, 0)
        pet.setClaude(.idle, quietly: true)
        board.clear()
        let session = { (needs: Bool) in Board.Entry(id: "demo", project: "clawde", title: "Demo", needsYou: needs) }
        let steps: [(after: Double, caption: String?, act: () -> Void)] = [
            (0, "Here comes the demo~", {}),
            (3, "You're playing music", { [weak self] in self?.demo?.music = true }),
            (8, "Claude is thinking…", { [weak self] in self?.pet.setClaude(.thinking); self?.board.started(session(false)) }),
            (7, "Claude has a plan: to work", { [weak self] in self?.pet.setClaude(.working, mode: .typing) }),
            (9, "Claude is looking things up", { [weak self] in self?.pet.setClaude(.working, mode: .searching) }),
            (8, "Claude is rebuilding code", { [weak self] in self?.pet.setClaude(.working, mode: .editing) }),
            (8, "Claude committed its work", { [weak self] in self?.pet.shipped() }),
            (7, "Claude is waiting for you", { [weak self] in self?.pet.setClaude(.waiting); self?.board.started(session(true)) }),
            (7, "You answered", { [weak self] in self?.pet.setClaude(.working, mode: .typing); self?.board.started(session(false)) }),
            (5, "Claude is done", { [weak self] in self?.pet.setClaude(.idle); self?.board.finished("demo") }),
            (8, "Music off, you're in VS Code", { [weak self] in self?.demo?.music = false; self?.demo?.reading = true }),
            (9, "You're playing a game", { [weak self] in self?.demo?.reading = false; self?.demo?.gaming = true }),
            (10, "You're sitting still", { [weak self] in self?.demo?.gaming = false; self?.demo?.idle = 95 }),
            (6, "It's late at night…", { [weak self] in self?.demo?.idle = 0; self?.pet.perform("yawn") }),
            (5, "It's the weekend", { [weak self] in self?.pet.perform("skateboard") }),
            (8, "Two hours without a break", { [weak self] in self?.pet.perform("dizzy", seconds: 2.5) }),
            (5, "You stepped away", { [weak self] in self?.demo?.idle = 400 }),
            (10, nil, { [weak self] in self?.demo?.idle = 720 }),
            (2, "You're back", { [weak self] in self?.demo?.idle = 0 }),
            (6, "That's the demo~", { [weak self] in self?.endDemo() }),
        ]
        var at = 0.0
        for step in steps {
            at += step.after
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self, self.demo != nil else { return }
                if let caption = step.caption { self.pet.caption(caption) }
                step.act()
            }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, var demo = self.demo else { return }
                if demo.idle > 0, demo.idle < 700 { demo.idle += 1 }
                self.demo = demo
                self.pet.sense(idle: demo.idle, music: demo.music, reading: demo.reading, gaming: demo.gaming)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
    }

    /// Back to the real senses and to what Claude's really up to.
    private func endDemo() {
        demo = nil
        demoTimer?.invalidate()
        demoTimer = nil
        pet.setClaude(followsClaude ? claudeState : .idle, mode: workMode, quietly: true)
        board.clear()
        sense()
    }

    /// Made-up sessions on the board, for trying it out (--board-demo): three
    /// get going and a fourth waits its turn, one needs you, then they finish.
    private var boardDemo = false

    private func startBoardDemo() {
        boardDemo = true
        board.clear()
        // --board-demo white (or cork) tries another board, this once.
        let arguments = CommandLine.arguments
        if let at = arguments.firstIndex(of: "--board-demo"), at + 1 < arguments.count,
           let style = Board.Style(rawValue: arguments[at + 1]) {
            board.style = style
        }
        let a = Board.Entry(id: "a", project: "my-app", title: "Login page", needsYou: false)
        let b = Board.Entry(id: "b", project: "website", title: "Dark mode", needsYou: false)
        let c = Board.Entry(id: "c", project: "api", title: "Rate limits", needsYou: false)
        let d = Board.Entry(id: "d", project: "docs", title: "Typos", needsYou: false)
        var needy = b
        needy.needsYou = true
        let steps: [(Double, () -> Void)] = [
            (0, { [weak self] in self?.pet.setClaude(.working); self?.board.started(a) }),
            (1, { [weak self] in self?.board.started(b) }),
            (1, { [weak self] in self?.board.started(c) }),
            (1, { [weak self] in self?.board.started(d) }),
            (14, { [weak self] in self?.board.started(needy) }),
            (4, { [weak self] in self?.board.finished("a") }),
            (12, { [weak self] in self?.board.started(b); self?.board.finished("c") }),
            (8, { [weak self] in self?.board.finished("b") }),
            (8, { [weak self] in self?.board.finished("d") }),
            (4, { [weak self] in self?.pet.setClaude(.idle, quietly: true) }),
            (8, { [weak self] in
                self?.boardDemo = false
                if ProcessInfo.processInfo.environment["CLAWD_RECORD"] != nil { NSApp.terminate(nil) }
            }),
        ]
        var at = 0.0
        for (after, act) in steps {
            at += after
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { act() }
        }
    }

    /// A slider that resizes Clawd live while the menu is open, as wide as the menu.
    private func sizeSliderItem() -> NSMenuItem {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        row.autoresizingMask = [.width]
        let slider = NSSlider(
            value: Double(pet.unit), minValue: Self.units.lowerBound, maxValue: Self.units.upperBound,
            target: self, action: #selector(slideSize(_:))
        )
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 20, y: 3, width: 184, height: 20)
        slider.autoresizingMask = [.width]
        row.addSubview(slider)

        let item = NSMenuItem()
        item.view = row
        return item
    }

    @objc private func slideSize(_ sender: NSSlider) {
        defaults.set(sender.doubleValue, forKey: "unit")
        pet.setUnit(CGFloat(sender.doubleValue))
    }

    @objc private func toggleFollow() {
        followsClaude.toggle()
        pet.setClaude(followsClaude ? claudeState : .idle, mode: workMode, quietly: true)
        if followsClaude { syncBoard() } else { board.clear() }
    }

    @objc private func pickBoard(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        defaults.set(raw, forKey: "boardStyle")
        board.style = Board.Style(rawValue: raw)
        syncBoard()
    }

    // MARK: Claude Code's sessions

    /// Tells you when a session needs you or has finished. A permission
    /// request is only told of once it's still waiting a few seconds on, as
    /// you've often seen to it by then; anything still waiting three minutes
    /// later is told of again.
    private func claudeEvent(_ event: ClaudeWatcher.Event) {
        guard followsClaude, demo == nil, !boardDemo else { return }
        switch event {
        case .started(let session):
            log("started: \(session.project) · \(session.title)")
            board.started(Self.entry(session))
        case .needsYou(let session):
            log("needs you: \(session.project) · \(session.title): \(session.need.map { "\($0)" } ?? "?")")
            board.started(Self.entry(session))
            var wait = 0.0
            if case .permission = session.need { wait = 8 }
            remind(session, after: wait)
            remind(session, after: wait + 180, again: true)
        case .finished(let session, let said):
            log("finished: \(session.project) · \(session.title)\(session.interrupted ? " (interrupted)" : said == nil ? "" : " (with its last words)")")
            if !session.interrupted { say("\(session.project) · \(session.title) is done!", linger: 6) }
            board.finished(session.id)
        }
    }

    /// A line in Clawd's chat bubble, and in the log with CLAWD_DEBUG set.
    private func say(_ line: String, linger: Double) {
        log("says: \(line)")
        chat.say(line, linger: linger)
    }

    private static let debug = ProcessInfo.processInfo.environment["CLAWD_DEBUG"] != nil

    private func log(_ text: String) {
        guard Self.debug else { return }
        let time = String(format: "%.1f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        FileHandle.standardError.write(Data("[claude \(time)] \(text)\n".utf8))
    }

    /// Says what a session needs, if it still needs it after `delay` seconds.
    private func remind(_ session: ClaudeWatcher.Session, after delay: Double, again: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.followsClaude, self.demo == nil,
                  let now = self.watcher.sessions.first(where: { $0.id == session.id }), let need = now.need,
                  need == session.need
            else { return }
            let name = "\(now.project) · \(now.title)"
            var line: String
            switch need {
            case .permission(let what): line = what.isEmpty ? "\(name) needs your OK." : "\(name) needs your OK: \(what)"
            case .question(let question): line = question.isEmpty ? "\(name) has a question for you." : "\(name) asks: \(question)"
            case .plan: line = "\(name) has a plan for you to look over."
            }
            if again { line = "Still waiting on you: " + line }
            self.say(line, linger: 8)
            self.pet.perk()
        }
    }

    /// Offers once, when Claude Code is about and the hooks aren't in, to add them.
    private func offerHooks() {
        guard Hooks.claudeCodeFound, !Hooks.isInstalled, !defaults.bool(forKey: "hooksOffered") else { return }
        defaults.set(true, forKey: "hooksOffered")
        let alert = NSAlert()
        alert.messageText = "Let Clawd keep an exact eye on Claude Code?"
        alert.informativeText = """
        Clawde can add a few hooks to Claude Code's settings (~/.claude/settings.json) so Clawd knows the moment \
        a session needs your permission, asks you something or finishes. The hooks only write a line to Clawde's \
        own folder; nothing leaves your Mac. Your settings are backed up first, and you can take the hooks out \
        from the menu at any time.
        """
        alert.addButton(withTitle: "Add Hooks")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { setHooks(on: true) }
    }

    @objc private func toggleHooks() { setHooks(on: !Hooks.isInstalled) }

    private func setHooks(on: Bool) {
        do {
            if on { try Hooks.install() } else { try Hooks.uninstall() }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate()
            alert.runModal()
        }
    }

    /// Adds Clawde to your login items, or takes it off. If macOS wants the
    /// change approved, its Login Items settings open.
    @objc private func toggleOpenAtLogin() {
        let app = SMAppService.mainApp
        do {
            if app.status == .enabled {
                try app.unregister()
            } else {
                try app.register()
            }
        } catch {
            NSSound.beep()
        }
        if app.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
