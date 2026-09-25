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
        ])
        if defaults.string(forKey: "brainSession") == nil {
            defaults.set(UUID().uuidString.lowercased(), forKey: "brainSession")
        }

        pet = Pet(unit: CGFloat(defaults.double(forKey: "unit")))
        pet.makeMenu = { [unowned self] in self.buildMenu() }
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
        watcher.start()
        startSensing()
        if isConnected { mind.start() }
        // Started with --demo, the run-through begins at once.
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startDemo() }
        }
    }

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
        let steps: [(after: Double, caption: String?, act: () -> Void)] = [
            (0, "Here comes the demo~", {}),
            (3, "You're playing music", { [weak self] in self?.demo?.music = true }),
            (8, "Claude is thinking…", { [weak self] in self?.pet.setClaude(.thinking) }),
            (7, "Claude has a plan: to work", { [weak self] in self?.pet.setClaude(.working, mode: .typing) }),
            (9, "Claude is looking things up", { [weak self] in self?.pet.setClaude(.working, mode: .searching) }),
            (8, "Claude is rebuilding code", { [weak self] in self?.pet.setClaude(.working, mode: .editing) }),
            (8, "Claude committed its work", { [weak self] in self?.pet.shipped() }),
            (7, "Claude is waiting for you", { [weak self] in self?.pet.setClaude(.waiting) }),
            (7, "You answered", { [weak self] in self?.pet.setClaude(.working, mode: .typing) }),
            (5, "Claude is done", { [weak self] in self?.pet.setClaude(.idle) }),
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
        sense()
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
