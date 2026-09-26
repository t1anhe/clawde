import AppKit
import QuartzCore

/// A borderless panel that never takes the keyboard, so clicking Clawd leaves
/// focus with whatever app you were typing in.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PetView: NSView {
    weak var pet: Pet?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let pet else { return }
        Renderer.draw(pet.scene(), size: bounds.size, unit: pet.unit)
    }

    override func mouseDown(with event: NSEvent) { pet?.mouseDown(clicks: event.clickCount) }
    override func mouseDragged(with event: NSEvent) { pet?.mouseDragged() }
    override func mouseUp(with event: NSEvent) { pet?.mouseUp() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = pet?.makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Clawd: where it is, what it is doing, and how it answers the pointer,
/// Claude and what you're up to. Moves its own window, 60 times a second.
@MainActor
final class Pet {
    enum Behavior {
        case idle(until: Double)
        case walk(to: CGFloat)
        /// At the laptop since then: the setup plays, then the typing loop.
        case work(since: Double)
        /// Putting the laptop away since then, cheering after unless quiet.
        case pack(since: Double, cheers: Bool)
        /// Playing one of the bundled clips until then.
        case perform(String, since: Double, until: Double)
        /// Walking over to the board for a chore, or home again (no chore).
        case errand(Board.Chore?)
        /// At the board, playing the chore's clip until then.
        case chore(Board.Chore, since: Double, until: Double)
        /// Just done at the board, staying on a moment in case there's more.
        case linger(until: Double)
        /// Going round a clip's loop since then for as long as its reason
        /// lasts: the headphones while music plays, thinking while Claude
        /// waits on you. Let go, it finishes the time round and its outro.
        case hold(String, since: Double)
        case sleep
    }

    /// What Clawd would rather be doing, the most pressing first: along with
    /// Claude working (typing, investigating or building), thinking while
    /// Claude thinks, calling you while it waits on you; then gaming while
    /// you play, grooving while music plays, reading while you read or code,
    /// lounging with a laptop while you browse; or its own thing.
    enum Want { case work, investigate, build, think, call, game, music, read, browse, free }

    /// What Clawd wants when it's only keeping you company, and the clips it
    /// holds for that.
    private static let company: Set<Want> = [.game, .music, .read, .browse, .free]
    private static let companyClips: Set<String> = ["gaming", "headphones", "reading", "browsing"]

    /// What a chat has Clawd doing: listening while you type or it speaks,
    /// thinking while it waits for its reply, talking while the reply streams.
    enum ChatMood { case none, listening, thinking, talking }

    /// Points per grid unit: Clawd is 12 units claw to claw.
    private(set) var unit: CGFloat
    /// What Claude is up to, as far as Clawd follows it, and at what kind of work.
    private(set) var claude = ClaudeState.idle
    private var workMode = WorkMode.typing
    var makeMenu: (() -> NSMenu)?
    /// The board Clawd writes Claude Code's sessions up on.
    weak var board: Board?
    /// Every frame, after Clawd has moved.
    var onTick: (() -> Void)?
    var onPoke: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// A chat holds Clawd in place and sets its pose.
    var chatMood = ChatMood.none {
        didSet { if chatMood != .none { wake() } }
    }

    private let panel: PetPanel
    private let view: PetView
    private var timer: Timer?

    private var clock = 0.0
    private var lastTick = CACurrentMediaTime()
    /// The window's bottom-left in screen coordinates: Clawd's feet.
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var vx: CGFloat = 0
    private var vy: CGFloat = 0
    private var isAirborne = false
    private var facing: CGFloat = 1
    private var behavior = Behavior.idle(until: 1)

    private var isPressed = false
    private var isCarried = false
    private var grab = CGPoint.zero
    private var dragSamples: [(t: Double, p: CGPoint)] = []

    private var nextBlink = 2.0
    private var blinkUntil = 0.0
    /// Where the eyes look: at the pointer, a quarter unit at a time.
    private var gaze = CGPoint.zero
    /// Where Clawd paces about when it has nothing to do: the spot it last
    /// landed on. And which way it last paced.
    private var home: CGFloat = 0
    private var lastPace: CGFloat = 1
    private var cheerUntil = 0.0
    /// Squashed for a moment after landing.
    private var landedUntil = 0.0
    private var heartAt: Double?
    private var bubble: (text: String, from: Double, until: Double)?
    /// When Claude's current turn began, and whether it's got to work yet.
    private var turnSince = 0.0
    private var turnWorked = false
    private var ignoresNextUp = false
    /// When the button was found let go while Clawd was still carried.
    private var lettingGoSince: Double?
    /// Thrown hard enough to land dizzy.
    private var dizzyOnLanding = false
    /// The top of Clawd's head in the pose last drawn, in units.
    private var headUnits: CGFloat = 8
    /// With CLAWD_DEBUG set, what Clawd is doing goes to stderr as it changes.
    private static let debug = ProcessInfo.processInfo.environment["CLAWD_DEBUG"] != nil
    private var logged = ""

    // What you're up to, as the app's senses tell it every second.
    /// Seconds since you last touched the keyboard or mouse anywhere.
    private var userIdle = 0.0
    private var musicPlaying = false
    private var reading = false
    private var browsing = false
    private var gaming = false
    /// When Clawd may next yawn late at night, or go skateboarding at the
    /// weekend; and where a ride on the board is headed.
    private var nextYawn = 60.0
    private var nextSkate = 120.0
    private var skateTo: CGFloat?
    /// Claude has thought and is about to act: an idea first, then the laptop.
    private var ideaFirst = false
    /// Put to sleep from the menu: you coming back doesn't wake it.
    private var sleptOnPurpose = false
    /// Whether it's blown bubbles yet this time you've sat still.
    private var blewBubbles = false
    /// When you last sat down after a proper break, and when Clawd may next
    /// tell you to take one.
    private var busySince: Double?
    private var nextRestHint = 0.0

    /// Late at night Clawd yawns every ten minutes, and at the weekend it
    /// goes skateboarding every twenty, while you're about and it's free.
    private let yawnEvery = 600.0
    private let skateEvery = 1200.0
    /// How far from home a ride goes, in units, and how fast.
    private let skateRange: CGFloat = 18
    private let skateSpeed: CGFloat = 12
    /// Seconds without touching the computer before you're sitting still
    /// (Clawd blows bubbles), away (it naps), or long gone (it welcomes you back).
    private let stillAfter = 90.0
    private let awayAfter = 300.0
    private let welcomeAfter = 600.0
    /// At the computer this long without a break of `awayAfter`, and Clawd
    /// reels: time for a stretch. It says so again every half hour after.
    private let restAfter = 2 * 3600.0
    private let restAgain = 1800.0
    private let gravity: CGFloat = 2200
    /// The Fable 5 walk runs at 12 poses a second; pacing about, a good deal slower.
    private let walkFPS = 7.0
    /// Units a second, a unit a pose as in the Fable 5 walk, so the feet keep
    /// pace with the ground at any size.
    private let walkSpeed: CGFloat = 7
    /// How far from home Clawd paces, in units each way, and how far one pace goes.
    private let paceRange: CGFloat = 10
    private let paceLength: ClosedRange<CGFloat> = 3...7

    var isAsleep: Bool {
        if case .sleep = behavior { return true }
        return false
    }

    init(unit: CGFloat) {
        self.unit = unit
        let size = Renderer.windowSize(unit: unit)
        panel = PetPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        view = PetView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = view
        view.pet = self

        let frame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        // CLAWD_START_X (0 to 1 across the screen) starts it somewhere else, for trying things out.
        let across = ProcessInfo.processInfo.environment["CLAWD_START_X"].flatMap(Double.init) ?? 0.5
        x = frame.minX + frame.width * CGFloat(across) - size.width / 2
        y = frame.minY
        home = x
    }

    /// Starts Clawd's clock; `showing` puts it on screen.
    func start(showing: Bool = true) {
        if showing { panel.orderFrontRegardless() }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Commands

    /// Resizes Clawd in place: its feet keep their spot on the ground.
    func setUnit(_ unit: CGFloat) {
        let size = Renderer.windowSize(unit: unit)
        let grown = (size.width - panel.frame.width) / 2
        x -= grown
        home -= grown
        self.unit = unit
        panel.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
    }

    /// A small hop, to catch your eye; not in the middle of writing on the board.
    func perk() {
        wake()
        if case .chore = behavior { return }
        if !isCarried, !isAirborne { vy = 300 }
    }

    func toggleSleep() {
        if isAsleep {
            wake()
        } else {
            behavior = .sleep
            sleptOnPurpose = true
        }
    }

    /// What Claude is up to, when Clawd follows it. Thinking (or waiting on
    /// you) brings the thinking bubble; from thinking to doing, an idea
    /// strikes and the laptop comes out; and a turn done after some work
    /// gets a cheer, unless `quietly`.
    func setClaude(_ state: ClaudeState, mode: WorkMode = .typing, quietly: Bool = false) {
        workMode = mode
        guard state != claude else { return }
        let before = claude
        claude = state
        if before == .idle {
            turnSince = clock
            turnWorked = false
        }
        switch state {
        case .working:
            if before == .idle || before == .thinking { ideaFirst = true }
            if !turnWorked, !quietly { say("On it!", for: 1.2) }
            turnWorked = true
            wake()
        case .thinking, .waiting:
            wake()
        case .idle:
            ideaFirst = false
            let cheers = !quietly && turnWorked && clock - turnSince > 3
            if case .work = behavior, !isAirborne {
                behavior = .pack(since: clock, cheers: cheers)
            } else if cheers {
                cheer()
            }
        }
    }

    /// One of Claude's commits or pushes went through: off it goes in the post.
    func shipped() {
        guard !isCarried, !isAirborne, board?.busy == nil else { return }
        perform("mailbox")
    }

    /// What you're up to, every second: how long since you last touched the
    /// keyboard or mouse, whether music is playing, whether you're reading
    /// (or coding), whether you're playing a game. Back from a long time
    /// away Clawd welcomes you, sitting still it blows bubbles, after two
    /// hours without a break it reels and tells you to stretch; late at
    /// night it yawns, at the weekend it goes skateboarding.
    func sense(idle: Double, music: Bool, reading: Bool, gaming: Bool, browsing: Bool = false) {
        let before = userIdle
        userIdle = idle
        musicPlaying = music
        self.reading = reading
        self.browsing = browsing
        self.gaming = gaming
        if idle >= awayAfter { busySince = nil }
        guard !isCarried, !isAirborne else { return }
        if idle < 2 {
            blewBubbles = false
            if busySince == nil { busySince = clock }
            if before >= awayAfter, isAsleep, !sleptOnPurpose {
                behavior = .idle(until: clock + 1)
                if before >= welcomeAfter, Self.company.contains(want) {
                    perform("love")
                    say("Welcome back~", for: 3)
                }
            }
        } else if idle >= stillAfter, idle < awayAfter, !blewBubbles, want == .free, isFree {
            // Sitting still: once, as soon as Clawd's free for it.
            blewBubbles = true
            perform("bubbles")
        }
        // The rest are for when Clawd's only keeping you company.
        let easy = Self.company.contains(want) && (isFree || isHolding(Self.companyClips))
        guard easy, idle < 60 else { return }
        if let busySince, clock - busySince >= restAfter, clock >= nextRestHint {
            nextRestHint = clock + restAgain
            perform("dizzy", seconds: 2.5)
            say("Time to stretch~", for: 4)
            return
        }
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        if (1..<5).contains(hour), clock >= nextYawn {
            nextYawn = clock + yawnEvery
            perform("yawn")
        } else if calendar.isDateInWeekend(now), clock >= nextSkate {
            nextSkate = clock + skateEvery
            perform("skateboard")
        }
    }

    /// What Clawd would rather be doing now.
    private var want: Want {
        switch claude {
        case .working:
            switch workMode {
            case .typing: return .work
            case .searching: return .investigate
            case .editing: return .build
            }
        case .thinking: return .think
        case .waiting: return .call
        case .idle:
            // Reading and playing go with you being there; the music plays on
            // without you.
            let here = userIdle < awayAfter
            if gaming && here { return .game }
            if musicPlaying { return .music }
            return reading && here ? .read : browsing && here ? .browse : .free
        }
    }

    /// Standing about or pacing, free to take something up.
    private var isFree: Bool {
        switch behavior {
        case .idle, .walk: return true
        default: return false
        }
    }

    private func isHolding(_ names: Set<String>) -> Bool {
        if case .hold(let held, _) = behavior { return names.contains(held) }
        return false
    }

    /// Claude finished: a hop and a word.
    private func cheer() {
        say("All done!", for: 4)
        if let party = ["confetti", "sunglasses", "love"].filter({ Animations.all[$0] != nil }).randomElement() {
            perform(party)
        } else {
            cheerUntil = clock + 1.2
            if !isCarried { vy = 420 }
        }
    }

    /// Plays one of the bundled clips: once through, or a looping one for
    /// about `seconds` (six unless given). Claude starting work cuts it short.
    func perform(_ name: String, seconds: Double? = nil) {
        guard let clip = Animations.all[name], !isCarried else { return }
        wake()
        skateTo = nil
        behavior = .perform(name, since: clock, until: clock + clip.length(about: seconds ?? 6))
    }

    // MARK: Pointer

    func mouseDown(clicks: Int) {
        if clicks >= 2 {
            ignoresNextUp = true
            onDoubleClick?()
            return
        }
        isPressed = true
        let mouse = NSEvent.mouseLocation
        grab = CGPoint(x: mouse.x - x, y: mouse.y - y)
        dragSamples = [(clock, mouse)]
    }

    func mouseDragged() {
        // The second click of a double-click wobbling isn't a pick-up.
        guard !ignoresNextUp else { return }
        let mouse = NSEvent.mouseLocation
        if !isCarried, hypot(mouse.x - x - grab.x, mouse.y - y - grab.y) < 3 { return }
        isCarried = true
        x = mouse.x - grab.x
        y = mouse.y - grab.y
        dragSamples.append((clock, mouse))
        if dragSamples.count > 8 { dragSamples.removeFirst() }
        wake()
    }

    func mouseUp() {
        isPressed = false
        if ignoresNextUp {
            ignoresNextUp = false
            return
        }
        if isCarried {
            isCarried = false
            // Thrown: the pointer's speed over its last tenth of a second.
            let recent = dragSamples.filter { clock - $0.t < 0.1 }
            if let first = recent.first, let last = recent.last, last.t - first.t > 0.001 {
                let dt = CGFloat(last.t - first.t)
                vx = max(-1600, min(1600, (last.p.x - first.p.x) / dt))
                vy = max(-1600, min(1600, (last.p.y - first.p.y) / dt))
            } else {
                vx = 0
                vy = 0
            }
            behavior = .idle(until: clock + 1.5)
            dizzyOnLanding = hypot(vx, vy) > 900
        } else {
            poke()
        }
    }

    private func poke() {
        onPoke?()
        if isAsleep { say("Hm…?", for: 1.8) }
        wake()
        vy = 380
        heartAt = clock
        cheerUntil = clock + 0.9
    }

    private func wake() {
        sleptOnPurpose = false
        if isAsleep { behavior = .idle(until: clock + 2) }
    }

    /// A word from Clawd in its speech bubble, as a caption.
    func caption(_ text: String, for seconds: Double = 3.5) {
        say(text, for: seconds)
    }

    private func say(_ text: String, for seconds: Double) {
        // A chat's own bubble has the floor.
        guard chatMood == .none else { return }
        bubble = (text, clock, clock + seconds)
    }

    /// The top middle of Clawd's head, in screen coordinates.
    func headTop() -> NSPoint {
        let pad = Renderer.padX(unit: unit)
        return NSPoint(x: panel.frame.minX + pad + 6 * unit, y: panel.frame.minY + headUnits * unit)
    }

    var visibleFrame: NSRect { currentScreen().visibleFrame }

    /// The window Clawd draws in.
    var window: NSWindow { panel }

    // MARK: Frame

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        clock += dt

        let size = panel.frame.size
        let visible = currentScreen().visibleFrame
        // The claws may touch the screen's edges; the padding may run past them.
        let minX = visible.minX - Renderer.padX(unit: unit)
        let maxX = visible.maxX - size.width + Renderer.padX(unit: unit)
        let ground = visible.minY
        walkable = minX...max(minX, maxX)

        // Carried with the button let go a while and no mouse-up (it went to
        // another window): it's dropped.
        if isCarried, NSEvent.pressedMouseButtons & 1 == 0 {
            let since = lettingGoSince ?? clock
            lettingGoSince = since
            if clock - since > 0.25 {
                isCarried = false
                isPressed = false
                lettingGoSince = nil
                vx = 0
                vy = 0
                behavior = .idle(until: clock + 1)
            }
        } else {
            lettingGoSince = nil
        }
        if isCarried {
            isAirborne = true
        } else if y > ground + 0.5 || vy > 0 {
            isAirborne = true
            vy -= gravity * CGFloat(dt)
            x += vx * CGFloat(dt)
            y += vy * CGFloat(dt)
            if x < minX || x > maxX { vx = -vx * 0.5 }
            if y <= ground {
                y = ground
                vx = 0
                vy = 0
                landedUntil = clock + 0.15
            }
        } else {
            // Landing from a good throw: seeing stars.
            if isAirborne, dizzyOnLanding {
                dizzyOnLanding = false
                perform("dizzy", seconds: 2.5)
            }
            // Wherever it's put down, it stays about.
            if isAirborne { home = x }
            isAirborne = false
            y = ground
            act(dt, minX: minX, maxX: maxX)
        }
        x = min(max(x, minX), maxX)
        y = min(y, visible.maxY - size.height)

        if clock > nextBlink {
            blinkUntil = clock + 0.13
            nextBlink = clock + .random(in: 2.5...6)
        }

        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        if let board {
            // Picked up or set to something else halfway: the chore gets done anyway.
            if let busy = board.busy, !isDoing(busy) { board.finish(busy) }
            board.follow(homeBodyLeft: home + Renderer.padX(unit: unit) + 2 * unit, screen: visible, unit: unit,
                         scale: panel.backingScaleFactor, below: panel.windowNumber)
        }
        if Self.debug { log() }
        followPointer()
        updateClickThrough()
        view.needsDisplay = true
        onTick?()
    }

    private func act(_ dt: Double, minX: CGFloat, maxX: CGFloat) {
        // Clawd holds still while chatting, so the bubble has somewhere to point.
        if chatMood != .none, case .walk = behavior { behavior = .idle(until: clock + 2) }
        if chatMood != .none, case .idle = behavior { return }
        let want = self.want
        let chores = board?.hasChores ?? false
        switch behavior {
        case .work:
            if want != .work || chores { behavior = .pack(since: clock, cheers: false) }
        case .hold(let name, let since):
            // Let go once its reason has passed or something matters more:
            // the music finishes its beat, a thought just stops.
            if want != Self.reason(for: name) || chores, let clip = Animations.all[name] {
                let length = clip.length(releasedAt: clock - since, finishingRound: name == "headphones")
                behavior = .perform(name, since: since, until: since + length)
            }
        case .perform(let name, let since, let until):
            if clock >= until {
                behavior = .idle(until: clock + .random(in: 1...3))
                skateTo = nil
            } else if name == "skateboard" {
                ride(since: since, until: until, dt, minX: minX, maxX: maxX)
            }
        case .pack(let since, let cheers):
            if clock - since > WorkAnimation.outroSeconds {
                behavior = .idle(until: clock + 2)
                if cheers { cheer() }
            }
        case .walk(let target):
            if want != .free || chores {
                behavior = .idle(until: clock)
            } else if step(toward: target, speed: walkSpeed * unit, dt) {
                behavior = .idle(until: clock + .random(in: 2...6))
            }
        case .errand(let chore):
            // Headed for where the board is now, looked up every frame, or for home;
            // never somewhere Clawd can't get to, or it would walk on for ever.
            var target = desk
            if let chore {
                guard let spot = board?.workSpot() else {
                    board?.finish(chore)
                    behavior = .idle(until: clock)
                    break
                }
                target = spot - Renderer.padX(unit: unit) - 2 * unit
            }
            target = min(max(target, minX), maxX)
            if step(toward: target, speed: walkSpeed * unit, dt) {
                x = target
                if let chore { startChore(chore) } else { behavior = .idle(until: clock) }
            }
        case .chore(let chore, let since, let until):
            guard let clip = Animations.all[chore.clip], clock < until else {
                board?.finish(chore)
                // The next one, or a moment's wait for one before going back.
                if let next = board?.nextChore() { go(to: next) } else { behavior = .linger(until: clock + 1.5) }
                break
            }
            let t = clock - since
            board?.progress(chore, clip.loopProgress(at: t, of: until - since),
                            touched: clip.touch.map { clip.index(at: t, of: until - since) >= $0 } ?? false)
        case .linger(let until):
            if let chore = board?.nextChore() {
                go(to: chore)
            } else if clock > until {
                behavior = .errand(nil)
            }
        case .idle(let until):
            if let chore = board?.nextChore() {
                go(to: chore)
            } else if want != .free {
                take(want)
            } else if abs(reachable(desk) - x) > paceRange * unit {
                // Its desk moved beside the board, or back home once the board's gone.
                behavior = .errand(nil)
            } else if clock > until {
                if userIdle >= awayAfter {
                    // Nobody about: a nap till somebody is.
                    behavior = .sleep
                } else if Double.random(in: 0...1) < 0.65, let target = pace(minX: minX, maxX: maxX) {
                    behavior = .walk(to: target)
                } else {
                    behavior = .idle(until: clock + .random(in: 2...5))
                }
            }
        case .sleep:
            // Claude needing it wakes it; what you're up to doesn't.
            if chores {
                behavior = .idle(until: clock)
            } else if !Self.company.contains(want) {
                take(want)
            }
        }
    }

    /// Where Clawd works at its laptop (its window's x): beside the board
    /// while the board's up, else home.
    private var desk: CGFloat {
        guard let left = board?.deskSpot else { return home }
        return left - Renderer.padX(unit: unit) - 2 * unit
    }

    /// `x`, or the nearest place to it Clawd can walk to.
    private func reachable(_ x: CGFloat) -> CGFloat {
        min(max(x, walkable.lowerBound), walkable.upperBound)
    }

    /// Where Clawd's window can go along the ground, as of the last frame.
    private var walkable: ClosedRange<CGFloat> = -.greatestFiniteMagnitude ... .greatestFiniteMagnitude

    /// Off to the board for a chore (straight into it if already there).
    private func go(to chore: Board.Chore) {
        skateTo = nil
        behavior = .errand(chore)
    }

    /// Turned to the board, the chore's clip playing for about as long as it wants.
    private func startChore(_ chore: Board.Chore) {
        guard let clip = Animations.all[chore.clip] else {
            board?.finish(chore)
            behavior = .idle(until: clock)
            return
        }
        facing = board?.side ?? facing
        behavior = .chore(chore, since: clock, until: clock + clip.length(about: chore.seconds))
    }

    /// Whether Clawd is on its way to `chore` or doing it.
    private func isDoing(_ chore: Board.Chore) -> Bool {
        switch behavior {
        case .errand(let on): return on == chore
        case .chore(let on, _, _): return on == chore
        default: return false
        }
    }

    /// Rolls along on the skateboard while its clip goes round its loop,
    /// off toward the roomier side of home.
    private func ride(since: Double, until: Double, _ dt: Double, minX: CGFloat, maxX: CGFloat) {
        guard let clip = Animations.all["skateboard"], let loop = clip.loop,
              loop.contains(clip.index(at: clock - since, of: until - since))
        else { return }
        if skateTo == nil {
            let low = max(minX, home - skateRange * unit), high = min(maxX, home + skateRange * unit)
            skateTo = x - low > high - x ? low : high
        }
        if let skateTo, abs(skateTo - x) > 1 {
            facing = skateTo > x ? 1 : -1
            x += facing * min(abs(skateTo - x), skateSpeed * unit * CGFloat(dt))
        }
    }

    /// Takes up what Clawd wants to be doing; Claude setting to work after
    /// thinking gets an idea first.
    private func take(_ want: Want) {
        if [Want.work, .investigate, .build].contains(want), ideaFirst, let clip = Animations.all["idea"] {
            ideaFirst = false
            behavior = .perform("idea", since: clock, until: clock + clip.seconds)
            return
        }
        switch want {
        case .work:
            // At the desk: beside the board while it's up, facing it with the
            // laptop between them; else at home, facing the middle of the
            // screen, where the laptop has room.
            if abs(reachable(desk) - x) > 1 {
                behavior = .errand(nil)
                return
            }
            if let side = board?.side { facing = side } else { faceMiddle() }
            behavior = .work(since: clock)
        case .free:
            break
        default:
            let name = Self.clips.first { $0.value == want }?.key ?? ""
            // The TV goes up on the roomier side too.
            if want == .game || want == .browse { faceMiddle() }
            behavior = Animations.all[name] != nil ? .hold(name, since: clock) : .idle(until: clock + 1)
        }
    }

    private func faceMiddle() {
        facing = x + panel.frame.width / 2 < currentScreen().visibleFrame.midX ? 1 : -1
    }

    /// The clips held for as long as what Clawd wants lasts.
    private static let clips: [String: Want] = [
        "detective": .investigate, "hardhat": .build, "thinking": .think, "calling": .call,
        "gaming": .game, "headphones": .music, "reading": .read, "browsing": .browse,
    ]

    /// What keeps a held clip going.
    private static func reason(for clip: String) -> Want {
        clips[clip] ?? .free
    }

    private func log() {
        let doing: String
        switch behavior {
        case .idle: doing = "idle"
        case .walk: doing = "walk"
        case .work: doing = "work"
        case .pack(_, let cheers): doing = cheers ? "pack+cheer" : "pack"
        case .perform(let name, _, _): doing = "perform \(name)"
        case .errand(let chore): doing = chore.map { "to the board: \($0.clip)" } ?? "back from the board"
        case .chore(let chore, _, _): doing = "board: \(chore.clip)"
        case .linger: doing = "at the board"
        case .hold(let name, _): doing = "hold \(name)"
        case .sleep: doing = sleptOnPurpose ? "sleep (asked)" : "sleep"
        }
        let line = "\(doing)  [want \(want), claude \(claude), music \(musicPlaying)]"
        guard line != logged else { return }
        logged = line
        FileHandle.standardError.write(Data(String(format: "%7.2f  %@  idle %.0fs\n", clock, line, userIdle).utf8))
    }

    /// Where to pace to: a few steps back the way it didn't go last time, or
    /// on the same way when there's no room, never more than `paceRange`
    /// from home. Nil when there's no room either way.
    private func pace(minX: CGFloat, maxX: CGFloat) -> CGFloat? {
        let low = max(minX, home - paceRange * unit), high = min(maxX, home + paceRange * unit)
        let least = paceLength.lowerBound * unit
        var way = -lastPace
        if (way < 0 ? x - low : high - x) < least { way = -way }
        let room = way < 0 ? x - low : high - x
        guard room >= least else { return nil }
        lastPace = way
        return x + way * min(room, .random(in: paceLength) * unit)
    }

    /// Keeps the eyes on the pointer: as far off centre as half a unit, in
    /// quarter-unit steps. A step only changes once the pointer is well past
    /// the halfway mark, so the eyes don't flicker when it rests on one.
    private func followPointer() {
        let mouse = NSEvent.mouseLocation
        let eyes = CGPoint(x: panel.frame.minX + Renderer.padX(unit: unit) + 6 * unit,
                           y: panel.frame.minY + (headUnits - 1.5) * unit)
        let dx = mouse.x - eyes.x, dy = mouse.y - eyes.y
        // Near the head the eyes point right at it; beyond 12 units they're
        // as far over as they go.
        let reach = max(abs(dx), abs(dy), 12 * unit)
        gaze = CGPoint(x: Self.eyeStep(from: gaze.x, toward: 0.5 * dx / reach),
                       y: Self.eyeStep(from: gaze.y, toward: 0.5 * dy / reach))
    }

    private static func eyeStep(from current: CGFloat, toward target: CGFloat) -> CGFloat {
        abs(target - current) < 0.17 ? current : (target * 4).rounded() / 4
    }

    /// Moves toward `target`; true once there.
    private func step(toward target: CGFloat, speed: CGFloat, _ dt: Double) -> Bool {
        let distance = target - x
        if abs(distance) < 1 { return true }
        facing = distance > 0 ? 1 : -1
        x += facing * min(abs(distance), speed * CGFloat(dt))
        return false
    }

    /// Lets clicks through everywhere but Clawd itself.
    private func updateClickThrough() {
        let sprite = Renderer.spriteRect(unit: unit).offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        let ignores = !(isPressed || sprite.contains(NSEvent.mouseLocation))
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    private func currentScreen() -> NSScreen {
        let feet = NSPoint(x: x + panel.frame.width / 2, y: y + 1)
        return NSScreen.screens.first { $0.frame.contains(feet) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Drawing

    func scene() -> Scene {
        func frame(_ fps: Double, of count: Int) -> Int { Int(clock * fps) % count }

        var pose = Pose(gaze: gaze)
        if isCarried {
            pose.armsUp = true
            pose.action = .dangle(frame(9, of: 2))
        } else if isAirborne {
            // Stretched on the way up, legs tucked coming down.
            pose.armsUp = true
            pose.action = vy > 150 ? .leap : .tuck
        } else {
            switch behavior {
            case .work(let since):
                pose.facing = facing
                pose.action = WorkAnimation.working(at: clock - since)
            case .pack(let since, _):
                pose.facing = facing
                pose.action = WorkAnimation.packing(at: clock - since)
            case .perform(let name, let since, let until):
                if let clip = Animations.all[name] {
                    pose.action = .clip(name, clip.index(at: clock - since, of: until - since))
                }
                pose.facing = facing
            case .hold(let name, let since):
                if let clip = Animations.all[name] { pose.action = .clip(name, clip.loopingIndex(at: clock - since)) }
                pose.facing = facing
            case .chore(let chore, let since, let until):
                if let clip = Animations.all[chore.clip] {
                    pose.action = .clip(chore.clip, clip.index(at: clock - since, of: until - since))
                }
                pose.facing = facing
            case .linger:
                pose.facing = facing
            case .walk, .errand:
                pose.action = clock < landedUntil ? .land : .walk(frame(walkFPS, of: 4))
                pose.facing = clock < landedUntil ? 0 : facing
            case .sleep:
                pose.action = .sit
                pose.eyesClosed = true
            case .idle:
                if clock < landedUntil { pose.action = .land }
            }
        }
        if !isCarried, !isAirborne {
            switch chatMood {
            case .none:
                break
            case .listening:
                pose = Pose(gaze: gaze)
            case .thinking:
                pose = Pose(action: WorkAnimation.thinking)
            case .talking:
                // Claws waving along with the words.
                pose = Pose(armsUp: frame(4, of: 2) == 0)
            }
        }
        // A poke's hop: claws up and eyes squeezed happy.
        if clock < cheerUntil {
            pose.armsUp = true
            pose.happy = true
        }
        if clock < blinkUntil { pose.eyesClosed = true }
        headUnits = Renderer.figure(pose).top

        var scene = Scene(pose: pose)
        if let heartAt, clock - heartAt < 1.2 { scene.heartAge = clock - heartAt }
        if isAsleep { scene.zzzPhase = clock }
        if let bubble, clock < bubble.until {
            scene.bubble = bubble.text
            scene.bubbleAlpha = CGFloat(min(1, (bubble.until - clock) / 0.3, (clock - bubble.from) / 0.15))
        }
        return scene
    }
}
