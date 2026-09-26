import AppKit
import CoreText

/// The board Clawd keeps beside it while Claude Code sessions work: a row for
/// each, "project · title", that Clawd writes up when the session starts and
/// rubs out when it's done, a red ! on one that needs you. It stands on the
/// ground next to Clawd's spot, toward the middle of the screen, only while
/// there's something on it: a chalkboard, a whiteboard, or a cork board with
/// a pinned note for each session.
///
/// Clawd does the writing (the Pet's chores); the board draws itself in its
/// own window just behind Clawd's, laid out in Clawd's grid units so its rows
/// sit where Clawd's claw reaches, and its words in Fusion Pixel's 12-pixel
/// font at a whole number of screen pixels to a font pixel, so they stay crisp.
@MainActor
final class Board {
    enum Style: String, CaseIterable {
        case chalk, white, cork

        var title: String {
            switch self {
            case .chalk: "Chalkboard"
            case .white: "Whiteboard"
            case .cork: "Cork Board"
            }
        }

        /// What Clawd writes and rubs out with, for the stand-in colours of its
        /// board clips: the stick and its tip, the duster's back and felt, and
        /// the chalk dust (none but the chalk's).
        @MainActor var tools: [NSColor] {
            switch self {
            case .chalk: [Board.cream, Board.cream, Board.wood, Board.grayDark, Board.cream]
            case .white: [Board.salmon, Board.salmonDark, Board.inkLight, Board.gray, .clear]
            case .cork: [Board.blue, Board.ink, Board.inkLight, Board.gray, .clear]
            }
        }
    }

    /// A session as the board shows it.
    struct Entry: Equatable {
        var id: String
        var project: String
        var title: String
        var needsYou: Bool
    }

    /// Something for Clawd to do at the board: write a session up or rub it out.
    struct Chore: Equatable {
        enum Kind { case write, erase }
        var kind: Kind
        var session: String
        var style: Style
        /// The clip Clawd plays for it, turned to the board.
        var clip: String
        /// About how long its loop should go round for.
        var seconds: Double
    }

    /// The most rows it holds; more sessions wait their turn, counted on a
    /// tab on its top that shows them all when clicked.
    static let capacity = 3
    /// A session only goes up once it's been at work this long: a question
    /// answered in a moment doesn't send Clawd over.
    static let settle = 4.0
    /// The most waiting sessions it shows opened up.
    static let mostShown = 10

    /// Which board, or nil for none.
    var style: Style? {
        didSet {
            guard style != oldValue else { return }
            if let style { Renderer.tools = style.tools } else { clear() }
            dirty = true
        }
    }

    private struct Row {
        var entry: Entry
        /// Where it is, 0 the bottom row, moving to `target`: rows slide up
        /// to make room at the bottom and drop into a gap.
        var slot: Double
        var target: Int
        /// How much of it is written, and rubbed out.
        var reveal = 1.0
        var erase = 0.0
        /// On the cork board, whether its note is up.
        var shown = true
    }

    private var rows: [Row] = []
    /// Sessions to write up when there's room, oldest first, and when each got going.
    private var waiting: [Entry] = []
    private var waitingSince: [String: Double] = [:]
    /// Showing every session waiting its turn, in dots over the rows, till
    /// the tab's clicked again.
    private(set) var expanded = false
    /// Sessions on the board that are done, to rub out.
    private var done: Set<String> = []
    /// The chore Clawd is on.
    private(set) var busy: Chore?
    /// How many rows the board has room for, growing and shrinking to them.
    private var room = 0.0
    /// Coming up (toward 1) or going (toward 0); drawn in dots on the way.
    private var presence = 0.0
    private var dirty = true

    private let panel: NSPanel
    private let view: BoardView
    private var unit: CGFloat = 3
    private var scale: CGFloat = 2
    /// The widest the board has been since it went up: it moves over to make
    /// room, never back, so Clawd's desk stays put while it's up.
    private var widest: CGFloat = 0
    /// Where Clawd's body's left edge stands at home, and the screen it's on.
    private var home: (bodyLeft: CGFloat, screen: NSRect)?

    init() {
        panel = BoardPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        view = BoardView(frame: panel.contentLayoutRect)
        panel.contentView = view
        view.board = self
        Renderer.tools = Style.chalk.tools
    }

    /// The window the board draws in.
    var window: NSWindow { panel }

    // MARK: Sessions

    /// A session got going: it goes up on the board (or back up, if it was
    /// about to be rubbed out).
    func started(_ entry: Entry) {
        guard style != nil else { return }
        done.remove(entry.id)
        if let i = rows.firstIndex(where: { $0.entry.id == entry.id }) {
            if rows[i].entry != entry { rows[i].entry = entry; dirty = true }
        } else if let i = waiting.firstIndex(where: { $0.id == entry.id }) {
            if waiting[i] != entry { waiting[i] = entry; dirty = true }
        } else {
            wait(entry)
        }
    }

    private func wait(_ entry: Entry) {
        waiting.append(entry)
        waitingSince[entry.id] = ProcessInfo.processInfo.systemUptime
        dirty = true
    }

    /// The sessions waiting that have been at work long enough to go up.
    private var ready: [Entry] {
        let now = ProcessInfo.processInfo.systemUptime
        return waiting.filter { now - (waitingSince[$0.id] ?? now) >= Self.settle }
    }

    /// A session is done: rubbed out, or never written up.
    func finished(_ id: String) {
        waiting.removeAll { $0.id == id }
        waitingSince[id] = nil
        if rows.contains(where: { $0.entry.id == id }) { done.insert(id) }
        dirty = true
    }

    /// The sessions as they are now: `active` those at work (or waiting on
    /// you), `known` every one still about. Keeps titles and !s up to date,
    /// puts up sessions that got going unseen, and rubs out ones gone.
    func sync(active: [Entry], known: Set<String>) {
        guard style != nil else { return }
        let byID = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for i in rows.indices {
            let id = rows[i].entry.id
            if let now = byID[id] {
                if rows[i].entry != now { rows[i].entry = now; dirty = true }
                done.remove(id)
            } else if !known.contains(id) {
                done.insert(id)
            }
        }
        let before = waiting
        waiting = waiting.compactMap { byID[$0.id] ?? (known.contains($0.id) ? $0 : nil) }
        if waiting != before { dirty = true }
        for entry in active where !rows.contains(where: { $0.entry.id == entry.id }) && !waiting.contains(where: { $0.id == entry.id }) {
            wait(entry)
        }
        waitingSince = waitingSince.filter { id, _ in waiting.contains { $0.id == id } }
    }

    /// Everything off the board at once.
    func clear() {
        rows.removeAll()
        waiting.removeAll()
        waitingSince.removeAll()
        done.removeAll()
        expanded = false
        dirty = true
    }

    // MARK: Chores

    /// Whether there's something for Clawd to do at the board.
    var hasChores: Bool {
        guard style != nil, busy == nil, home != nil else { return false }
        return rows.contains { done.contains($0.entry.id) } || (rows.count < Self.capacity && !ready.isEmpty)
    }

    /// The next thing for Clawd to do at the board, now its own: rubbing a
    /// done session out comes first, to make room; then writing the next one
    /// up, one that needs you before the rest.
    func nextChore() -> Chore? {
        guard hasChores, let style else { return nil }
        if let row = rows.filter({ done.contains($0.entry.id) }).min(by: { $0.target < $1.target }) {
            let slot = min(row.target, Self.capacity - 1) + 1
            let chore = Chore(kind: .erase, session: row.entry.id, style: style,
                              clip: style == .cork ? "board-unpin-\(slot)" : "board-erase-\(slot)", seconds: 1.3)
            busy = chore
            return chore
        }
        let candidates = ready
        guard let entry = candidates.first(where: \.needsYou) ?? candidates.first else { return nil }
        waiting.removeAll { $0.id == entry.id }
        waitingSince[entry.id] = nil
        for i in rows.indices { rows[i].target += 1 }
        rows.append(Row(entry: entry, slot: 0, target: 0, reveal: 0, shown: style != .cork))
        let letters = Double(entry.project.count + entry.title.count)
        let chore = Chore(kind: .write, session: entry.id, style: style, clip: style == .cork ? "board-pin" : "board-write",
                          seconds: 0.8 + 0.07 * letters)
        busy = chore
        dirty = true
        return chore
    }

    /// How far the chore has got: `progress` through its clip's loop, and
    /// whether the clip has got to where it touches the board (a note
    /// pinned up or pulled down).
    func progress(_ chore: Chore, _ progress: Double, touched: Bool) {
        guard chore == busy, let i = rows.firstIndex(where: { $0.entry.id == chore.session }) else { return }
        switch (chore.kind, chore.style) {
        case (.write, .cork):
            rows[i].shown = touched
            rows[i].reveal = touched ? progress : 0
        case (.write, _):
            rows[i].reveal = progress
        case (.erase, .cork):
            rows[i].shown = !touched
        case (.erase, _):
            rows[i].erase = progress
        }
        dirty = true
    }

    /// The chore's over, or dropped halfway (Clawd picked up): either way
    /// its row is written, or gone and the rows above it drop down.
    func finish(_ chore: Chore) {
        guard chore == busy else { return }
        busy = nil
        if let i = rows.firstIndex(where: { $0.entry.id == chore.session }) {
            switch chore.kind {
            case .write:
                rows[i].reveal = 1
                rows[i].shown = true
            case .erase:
                let gone = rows.remove(at: i)
                done.remove(gone.entry.id)
                for j in rows.indices where rows[j].target > gone.target { rows[j].target -= 1 }
            }
        }
        dirty = true
    }

    /// A click on the board, in its view: on the tab, the sessions waiting
    /// are shown, or folded away again.
    func clicked(at point: NSPoint) {
        guard let tab = tabRect(), tab.contains(point) else { return }
        toggleExpanded()
    }

    /// Shows every session waiting, or folds them away again.
    func toggleExpanded() {
        guard expanded || (!waiting.isEmpty && rows.count >= Self.capacity) else { return }
        expanded.toggle()
        dirty = true
    }

    // MARK: Place

    /// Where Clawd lives, every frame: the board stands beside it.
    func follow(homeBodyLeft: CGFloat, screen: NSRect, unit: CGFloat, scale: CGFloat, below window: Int) {
        if unit != self.unit || scale != self.scale { dirty = true }
        self.unit = unit
        self.scale = scale
        home = (homeBodyLeft, screen)
        tick(below: window)
    }

    /// Whether the board is up, or on its way.
    var isUp: Bool { presence > 0 || !rows.isEmpty }

    /// Which way Clawd turns to face the board while it's up: right, always,
    /// so it writes from the start of each row.
    var side: CGFloat? { isUp ? 1 : nil }

    /// Where Clawd's body's left edge stands to work at the board as it is
    /// now: in front of its near end, 7 units short of it. Clawd heads for it
    /// afresh every frame, so it finds the board wherever the board has got to.
    func workSpot() -> CGFloat? {
        boardFrame().map { $0.near - 7 * unit }
    }

    /// Where Clawd's body's left edge sits at its laptop while the board is
    /// up: 14 units short of the board, the laptop between them. That's home,
    /// unless there's no room for the board to its right; then Clawd moves its
    /// desk over to the left of the board.
    var deskSpot: CGFloat? {
        guard isUp, let frame = boardFrame() else { return nil }
        return frame.near - 14 * unit
    }

    /// The board's near edge (its frame's left, next to Clawd) and its
    /// window's frame on screen: 14 units to the right of Clawd's home, or as
    /// much further left as it takes to stay on the screen.
    private func boardFrame() -> (near: CGFloat, window: NSRect)? {
        guard let home else { return nil }
        let u = unit
        let size = layoutSize()
        let width = size.width * u, height = size.height * u
        let screen = home.screen
        var near = min(home.bodyLeft + 14 * u, screen.maxX - max(width, widest) + Self.margin * u)
        near = max(near, screen.minX + 14 * u)
        return (near, NSRect(x: (near - Self.margin * u).rounded(), y: screen.minY, width: width, height: height))
    }

    // MARK: Frame

    private func tick(below window: Int) {
        let dt = 1.0 / 60
        // Rows slide to where they're going, the board grows and shrinks to fit.
        for i in rows.indices where rows[i].slot != Double(rows[i].target) {
            let to = Double(rows[i].target)
            let step = (rows[i].slot > to ? 7.0 : 5.0) * dt
            rows[i].slot = abs(to - rows[i].slot) <= step ? to : rows[i].slot + (to > rows[i].slot ? step : -step)
            dirty = true
        }
        if expanded, waiting.isEmpty { expanded = false; dirty = true }
        let wantRoom = Double((rows.map(\.target).max() ?? -1) + 1 + (expanded ? min(waiting.count, Self.mostShown) : 0))
        if room != wantRoom {
            let step = 5.0 * dt
            room = abs(wantRoom - room) <= step ? wantRoom : room + (wantRoom > room ? step : -step)
            dirty = true
        }
        let up = style != nil && !rows.isEmpty
        let wantPresence = up ? 1.0 : 0.0
        if presence != wantPresence {
            let step = dt / 0.3
            presence = abs(wantPresence - presence) <= step ? wantPresence : presence + (up ? step : -step)
            dirty = true
        }
        if presence == 0 {
            if panel.isVisible { panel.orderOut(nil) }
            widest = 0
            if !up { room = 0 }
            return
        }
        widest = max(widest, layoutSize().width * unit)
        guard let frame = boardFrame() else { return }
        if panel.frame != frame.window {
            panel.setFrame(frame.window, display: false)
            view.frame = NSRect(origin: .zero, size: frame.window.size)
            dirty = true
        }
        // Just behind Clawd, and clicked through but for its tab.
        if !panel.isVisible { panel.order(.below, relativeTo: window) }
        let overTab = tabRect().map { $0.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY).contains(NSEvent.mouseLocation) } ?? false
        if panel.ignoresMouseEvents == overTab { panel.ignoresMouseEvents = !overTab }
        if dirty {
            dirty = false
            view.needsDisplay = true
        }
    }

    // MARK: Layout

    // All in Clawd's grid units, the window's bottom left at the origin.
    /// Room left and right of the frame for the ledge sticking out, and over
    /// it for the tab.
    private static let margin: CGFloat = 0.5
    private static let headroom: CGFloat = 4
    /// Where the writing surface starts, up from the ground.
    private static let surface: CGFloat = 2.5
    private static let pad: CGFloat = 1
    /// A row's height, the gap between rows, and a cork note's height and the gap between notes.
    private static let line: CGFloat = 3
    private static let gap: CGFloat = 0.75
    private static let noteHeight: CGFloat = 4
    private static let noteGap: CGFloat = 0.5
    private static let narrowest: CGFloat = 14

    private func frameWidth(_ style: Style) -> CGFloat { style == .white ? 0.5 : 1 }

    /// Points to a font pixel: a whole number of screen pixels, as near a
    /// quarter unit as it comes, without running much over.
    private var textPixel: CGFloat {
        let pixels = max(1, (unit / 4 * scale + 0.25).rounded(.down))
        return pixels / scale
    }

    /// A row's words as they're laid out, in units.
    private func textWidth(_ entry: Entry) -> CGFloat {
        CGFloat(Self.words(entry).width) * textPixel / unit
    }

    private func innerSize(_ style: Style) -> NSSize {
        var widths = rows.map { textWidth($0.entry) }
        if expanded { widths += waiting.prefix(Self.mostShown).map(textWidth) }
        let widest = widths.max() ?? 0
        let snap = { (v: CGFloat) in (v * 2).rounded(.up) / 2 }
        if style == .cork {
            let note = snap(widest + 1)
            return NSSize(width: max(Self.narrowest, note + 2 * Self.pad),
                          height: CGFloat(room) * (Self.noteHeight + Self.noteGap) - Self.noteGap + 2 * Self.pad)
        }
        return NSSize(width: max(Self.narrowest, snap(widest + 2 * Self.pad)),
                      height: max(0, CGFloat(room) * (Self.line + Self.gap) - Self.gap + 2 * Self.pad))
    }

    /// The whole window's size, in units.
    private func layoutSize() -> NSSize {
        let style = self.style ?? .chalk
        let inner = innerSize(style)
        let frame = frameWidth(style)
        return NSSize(width: inner.width + 2 * frame + 2 * Self.margin,
                      height: Self.surface + inner.height + frame + Self.headroom)
    }

    // MARK: Words

    /// A row's words as one picture in font pixels: room for the ! (drawn
    /// only if the session needs you), the project, a dot, the title.
    struct Words {
        var width: Int
        /// Lit pixels, x right and y down from the top of the line, and what each is.
        var pixels: [(x: Int, y: Int, part: Part)]
        enum Part { case bang, project, title }
    }

    private static var wordsCache: [String: Words] = [:]
    /// The room the ! hangs in, and the dot between project and title.
    private static let bangRoom = 6, dotRoom = 3, dotSize = 2
    /// The longest a project name and a whole row may be, in font pixels.
    private static let longestProject = 56, longestRow = 132

    static func words(_ entry: Entry) -> Words {
        let key = "\(entry.needsYou)\u{1}\(entry.project)\u{1}\(entry.title)"
        if let cached = wordsCache[key] { return cached }
        var pixels: [(x: Int, y: Int, part: Words.Part)] = []
        if entry.needsYou {
            pixels += BoardFont.line("!").lit.map { ($0.x, $0.y, .bang) }
        }
        var x = bangRoom
        let project = BoardFont.fit(entry.project, width: longestProject)
        let projectLine = BoardFont.line(project)
        pixels += projectLine.lit.map { ($0.x + x, $0.y, .project) }
        x += projectLine.width
        let title = entry.title.isEmpty || entry.title == entry.project ? "" : entry.title
        if !title.isEmpty {
            let middle = BoardFont.xMiddle
            for dx in 0..<dotSize {
                for dy in 0..<dotSize {
                    pixels.append((x + dotRoom + dx, middle - dotSize / 2 + dy, .project))
                }
            }
            x += 2 * dotRoom + dotSize
            let titleLine = BoardFont.line(BoardFont.fit(title, width: max(24, longestRow - x)))
            pixels += titleLine.lit.map { ($0.x + x, $0.y, .title) }
            x += titleLine.width
        }
        let words = Words(width: x, pixels: pixels)
        if wordsCache.count > 200 { wordsCache.removeAll() }
        wordsCache[key] = words
        return words
    }

    // MARK: Drawing

    /// Colours: the woods of Claude FM, the film's cream and salmon, and the
    /// boards' own.
    static let wood = hex(0x905418), woodDark = hex(0x5C300A), woodLight = hex(0xB4843A)
    static let slate = hex(0x2F4A3E), slateDark = hex(0x243A30), chalkDim = hex(0xB9B3A0)
    static let cream = hex(0xFCEDCA), salmon = hex(0xDC6263), salmonDark = hex(0xB24C4E)
    static let white = hex(0xF3F0E8), whiteShade = hex(0xDEDAD0)
    static let gray = hex(0x8B8B8B), grayDark = hex(0x666666), grayLight = hex(0xABABAB)
    static let ink = hex(0x303030), inkLight = hex(0x555555), blue = hex(0x463F89)
    static let cork = hex(0xC19A62), corkDark = hex(0xA57C45), paperEdge = hex(0xE3CFA6)
    static let amber = hex(0xE3A445), amberDark = hex(0xB87E2C)

    private static func hex(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// Where the board's parts are, in units, the window's bottom left at the origin.
    private struct Geometry {
        var x0, frame, legs: CGFloat
        var inner, outer: NSSize
        /// The writing surface's bottom left, and its top.
        var sx, sy, top: CGFloat
    }

    private func geometry(_ style: Style) -> Geometry {
        let frame = frameWidth(style)
        let inner = innerSize(style)
        let x0 = Self.margin
        return Geometry(x0: x0, frame: frame, legs: Self.surface - frame, inner: inner,
                        outer: NSSize(width: inner.width + 2 * frame, height: inner.height + 2 * frame),
                        sx: x0 + frame, sy: Self.surface, top: Self.surface + inner.height)
    }

    /// The tab over the board's top right, if it's showing: how many more
    /// sessions are waiting, with a red ! if one of them needs you; or, with
    /// them all shown, a dash to fold them away. Its box in units, and its
    /// pixels (x right and y down in font pixels, and whether each is the !).
    private func tabBox(_ g: Geometry) -> (rect: NSRect, pixels: [(x: Int, y: Int, red: Bool)])? {
        var pixels: [(x: Int, y: Int, red: Bool)] = []
        var width = 0
        if expanded {
            for x in 0..<7 {
                for y in 6...7 { pixels.append((x, y, false)) }
            }
            width = 7
        } else {
            guard !waiting.isEmpty, rows.count >= Self.capacity else { return nil }
            let label = BoardFont.line("+\(waiting.count)")
            pixels = label.lit.map { ($0.x, $0.y, false) }
            width = label.width
            if waiting.contains(where: \.needsYou) {
                let bang = BoardFont.line("!")
                pixels += bang.lit.map { ($0.x + width + 3, $0.y, true) }
                width += 3 + bang.width
            }
        }
        let snap = { (v: CGFloat) in (v * 2).rounded(.up) / 2 }
        let w = snap(CGFloat(width) * textPixel / unit + 1), h = snap(12 * textPixel / unit + 1)
        return (NSRect(x: g.x0 + g.outer.width - 1.5 - w, y: g.legs + g.outer.height, width: w, height: h), pixels)
    }

    /// Where a click opens or folds the tab, in the view's points: the tab
    /// and a little round it.
    private func tabRect() -> NSRect? {
        guard let style, presence == 1, let box = tabBox(geometry(style)) else { return nil }
        let r = box.rect.insetBy(dx: -0.5, dy: -0.5)
        return NSRect(x: r.minX * unit, y: r.minY * unit, width: r.width * unit, height: r.height * unit)
    }

    /// Draws the board into its view (y up, the window's bottom left at the origin).
    func draw() {
        guard let style, let cg = NSGraphicsContext.current?.cgContext else { return }
        let painter = Painter(cg: cg, unit: unit, dots: presence < 1 ? (presence < 0.5 ? 2 : 1) : 0)
        let g = geometry(style)
        let (x0, legs, inner, outer, sx, sy, top) = (g.x0, g.legs, g.inner, g.outer, g.sx, g.sy, g.top)
        let holding = busy.map(\.kind)

        switch style {
        case .chalk, .cork:
            painter.fill(x0 + 1.5, 0, 1, legs, Self.woodDark)
            painter.fill(x0 + outer.width - 2.5, 0, 1, legs, Self.woodDark)
            painter.fill(x0, legs, outer.width, outer.height, Self.wood)
            painter.fill(x0, legs + outer.height - 0.5, outer.width, 0.5, Self.woodLight)
            painter.fill(x0, legs, outer.width, 0.5, Self.woodDark)
        case .white:
            for lx in [x0 + 1, x0 + outer.width - 1.5] {
                painter.fill(lx, 0.5, 0.5, legs - 0.5, Self.grayDark)
                painter.fill(lx - 0.5, 0, 1.5, 0.5, Self.ink)
            }
            painter.fill(x0 + 1, 0.5, outer.width - 2, 0.5, Self.grayDark)
            painter.fill(x0, legs, outer.width, outer.height, Self.gray)
            painter.fill(x0, legs + outer.height - 0.5, outer.width, 0.5, Self.grayLight)
        }

        switch style {
        case .chalk:
            painter.fill(sx, sy, inner.width, inner.height, Self.slate)
            painter.fill(sx, top - 0.5, inner.width, 0.5, Self.slateDark)
            painter.fill(sx, sy, 0.5, inner.height - 0.5, Self.slateDark)
            // The ledge, and on it the chalk and the duster, unless Clawd has them.
            painter.fill(x0 - 0.5, legs + 0.5, outer.width + 1, 0.5, Self.woodLight)
            painter.fill(x0 - 0.5, legs, outer.width + 1, 0.5, Self.woodDark)
            if holding != .write { painter.fill(sx + inner.width - 7, legs + 1, 1, 0.5, Self.cream) }
            if holding != .erase {
                painter.fill(sx + inner.width - 4, legs + 1, 2, 0.5, Self.grayDark)
                painter.fill(sx + inner.width - 4, legs + 1.5, 2, 0.5, Self.wood)
            }
        case .white:
            painter.fill(sx, sy, inner.width, inner.height, Self.white)
            if inner.height > 4 {
                for k in 0..<5 {
                    painter.dot(sx + inner.width - 3 - CGFloat(k) * 0.5, top - 1 - CGFloat(k) * 0.5, Self.whiteShade)
                    painter.dot(sx + inner.width - 2 - CGFloat(k) * 0.5, top - 1 - CGFloat(k) * 0.5, Self.whiteShade)
                }
            }
            painter.fill(x0 - 0.5, legs, outer.width + 1, 0.5, Self.grayDark)
            if holding != .write {
                painter.fill(sx + inner.width - 8, legs + 0.5, 1.5, 0.5, Self.salmon)
                painter.fill(sx + inner.width - 6.5, legs + 0.5, 0.5, 0.5, Self.salmonDark)
            }
            if holding != .erase {
                painter.fill(sx + inner.width - 4, legs + 0.5, 2, 0.5, Self.gray)
                painter.fill(sx + inner.width - 4, legs + 1, 2, 0.5, Self.inkLight)
            }
        case .cork:
            painter.fill(sx, sy, inner.width, inner.height, Self.cork)
            for i in 0..<Int(inner.width * 2) {
                for j in 0..<Int(inner.height * 2) where (i * 7 + j * 3) % 5 == 0 && (i + 2 * j) % 3 == 0 {
                    painter.dot(sx + CGFloat(i) * 0.5, sy + CGFloat(j) * 0.5, Self.corkDark)
                }
            }
        }

        let tp = textPixel
        /// A row's place: its words' left and middle height, at `slot` rows up.
        func place(_ slot: CGFloat) -> (x: CGFloat, middle: CGFloat, bottom: CGFloat) {
            if style == .cork {
                let bottom = sy + Self.pad + slot * (Self.noteHeight + Self.noteGap)
                return (sx + Self.pad + 0.5, bottom + Self.noteHeight / 2, bottom)
            }
            let bottom = sy + Self.pad + slot * (Self.line + Self.gap)
            return (sx + Self.pad, bottom + Self.line / 2, bottom)
        }
        for row in rows {
            let words = Self.words(row.entry)
            let at = place(CGFloat(row.slot))
            if style == .cork {
                guard row.shown else { continue }
                let noteX = sx + Self.pad
                let noteW = ((CGFloat(words.width) * tp / unit + 1) * 2).rounded(.up) / 2
                painter.fill(noteX, at.bottom, noteW, Self.noteHeight, Self.cream)
                painter.fill(noteX, at.bottom, noteW, 0.5, Self.paperEdge)
                let pinX = ((noteX + noteW / 2 - 0.5) * 2).rounded() / 2
                let needs = row.entry.needsYou
                painter.fill(pinX, at.bottom + Self.noteHeight - 0.5, 1, 1, needs ? Self.salmon : Self.amber)
                painter.fill(pinX, at.bottom + Self.noteHeight - 0.5, 1, 0.5, needs ? Self.salmonDark : Self.amberDark)
            }
            drawWords(words, row: row, x: at.x, middle: at.middle, style: style, painter: painter)
        }
        // Opened up: every session still waiting its turn over the rows, in
        // dots, not yet written.
        if expanded {
            for (k, entry) in waiting.prefix(Self.mostShown).enumerated() {
                let at = place(CGFloat(rows.count + k))
                drawWaiting(Self.words(entry), x: at.x, middle: at.middle, style: style, painter: painter)
            }
        }

        if let tab = tabBox(g) {
            painter.fill(tab.rect.minX, tab.rect.minY, tab.rect.width, tab.rect.height, style == .white ? Self.gray : Self.wood)
            let label = style == .white ? Self.ink : Self.cream
            for red in [false, true] {
                painter.text(tab.pixels.filter { $0.red == red }.map { ($0.x, $0.y) }, x: tab.rect.minX + 0.5,
                             top: tab.rect.maxY - 0.5, pixel: tp, color: red ? Self.salmon : label)
            }
        }
    }

    /// A session waiting its turn, shown with the board opened up: its words
    /// in dots, every other pixel, as the film draws what's dim; its ! whole.
    private func drawWaiting(_ words: Words, x: CGFloat, middle: CGFloat, style: Style, painter: Painter) {
        let tp = textPixel
        let top = middle + 6 * tp / unit
        let dim = style == .chalk ? Self.chalkDim : Self.grayDark
        painter.text(words.pixels.filter { $0.part != .bang && ($0.x + $0.y) % 2 == 0 }.map { ($0.x, $0.y) },
                     x: x, top: top, pixel: tp, color: dim)
        painter.text(words.pixels.filter { $0.part == .bang }.map { ($0.x, $0.y) }, x: x, top: top, pixel: tp, color: Self.salmon)
    }

    /// A row's words, their line's left at `x` and centred on `middle`,
    /// written up to the row's `reveal` and rubbed out up to its `erase`, the
    /// rubbing edge crumbling.
    private func drawWords(_ words: Words, row: Row, x: CGFloat, middle: CGFloat, style: Style, painter: Painter) {
        let tp = textPixel
        let top = middle + 6 * tp / unit
        let written = row.reveal >= 1 ? Int.max : Self.bangRoom + Int(Double(words.width - Self.bangRoom) * row.reveal)
        let gone = row.erase > 0 ? Int(Double(words.width) * row.erase) : -1
        let dim = style == .chalk ? Self.chalkDim : Self.grayDark
        let bright = style == .chalk ? Self.cream : Self.ink
        let needsRed = row.entry.needsYou && style != .cork
        var lit: [NSColor: [(Int, Int)]] = [:]
        for pixel in words.pixels {
            if pixel.part == .bang, row.reveal < 1 { continue }
            if pixel.x >= written { continue }
            if pixel.x < gone { continue }
            if gone >= 0, pixel.x < gone + 6, (pixel.x + pixel.y) % 2 == 0 { continue }
            let color: NSColor
            switch pixel.part {
            case .bang: color = Self.salmon
            case .project: color = dim
            case .title: color = needsRed ? Self.salmon : bright
            }
            lit[color, default: []].append((pixel.x, pixel.y))
        }
        for (color, pixels) in lit {
            painter.text(pixels, x: x, top: top, pixel: tp, color: color)
        }
    }

    /// Fills in Clawd's grid units, every edge on a whole screen pixel as
    /// Clawd's own blocks are; or, while the board comes and goes, as the
    /// film's dots (every other one at first).
    private struct Painter {
        let cg: CGContext
        let unit: CGFloat
        /// 0 solid, 1 every half-unit cell a dot, 2 every other one.
        let dots: Int

        func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
            guard w > 0, h > 0 else { return }
            cg.setFillColor(color.cgColor)
            if dots == 0 {
                cg.fill(aligned(CGRect(x: x * unit, y: y * unit, width: w * unit, height: h * unit)))
                return
            }
            let columns = Int((w * 2).rounded()), rows = Int((h * 2).rounded())
            for i in 0..<columns {
                for j in 0..<rows {
                    let cx = x + CGFloat(i) * 0.5, cy = y + CGFloat(j) * 0.5
                    if dots == 2, (Int((cx * 2).rounded()) + Int((cy * 2).rounded())) % 2 == 1 { continue }
                    cg.fill(aligned(CGRect(x: (cx + 0.125) * unit, y: (cy + 0.125) * unit, width: 0.25 * unit, height: 0.25 * unit)))
                }
            }
        }

        /// A quarter-unit dot in the middle of the half-unit cell at (x, y).
        func dot(_ x: CGFloat, _ y: CGFloat, _ color: NSColor) {
            guard dots != 2 else { return }
            cg.setFillColor(color.cgColor)
            cg.fill(aligned(CGRect(x: (x + 0.125) * unit, y: (y + 0.125) * unit, width: 0.25 * unit, height: 0.25 * unit)))
        }

        /// Font pixels, x right and y down from the top left at (`x`, `top`)
        /// in units, each `pixel` points square from a whole screen pixel.
        func text(_ pixels: [(Int, Int)], x: CGFloat, top: CGFloat, pixel: CGFloat, color: NSColor) {
            guard !pixels.isEmpty else { return }
            cg.setFillColor(color.cgColor)
            let origin = aligned(CGRect(x: x * unit, y: top * unit, width: 0, height: 0)).origin
            var rects: [CGRect] = []
            rects.reserveCapacity(pixels.count)
            for (px, py) in pixels {
                if dots == 2, (px + py) % 2 == 1 { continue }
                rects.append(CGRect(x: origin.x + CGFloat(px) * pixel, y: origin.y - CGFloat(py + 1) * pixel,
                                    width: pixel, height: pixel))
            }
            cg.fill(rects)
        }

        private func aligned(_ rect: CGRect) -> CGRect {
            let device = cg.convertToDeviceSpace(rect)
            let minX = device.minX.rounded(), minY = device.minY.rounded()
            return cg.convertToUserSpace(CGRect(x: minX, y: minY, width: device.maxX.rounded() - minX,
                                                height: device.maxY.rounded() - minY))
        }
    }
}

final class BoardView: NSView {
    weak var board: Board?

    override func draw(_ dirtyRect: NSRect) {
        board?.draw()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        board?.clicked(at: convert(event.locationInWindow, from: nil))
    }
}

/// The board's window: it never takes the keyboard, so a click on its tab
/// leaves focus with whatever you were typing in.
final class BoardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Fusion Pixel's 12-pixel proportional font (SIL Open Font License,
/// github.com/TakWolf/fusion-pixel-font), bundled: the board's words, CJK
/// and all, drawn a pixel at a time without smoothing.
@MainActor
enum BoardFont {
    struct Line {
        var width: Int
        /// Lit pixels, x right and y down from the top of the line's 12 rows.
        var lit: [(x: Int, y: Int)]
    }

    private static let font: CTFont = {
        if let url = Bundle.main.url(forResource: "fusion-pixel-12px-proportional", withExtension: "woff2"),
           let data = try? Data(contentsOf: url),
           let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) {
            return CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        }
        return CTFontCreateWithName("Menlo" as CFString, 11, nil)
    }()

    private static var cache: [String: Line] = [:]

    /// The row halfway down a lower-case x, for the dot between words.
    static let xMiddle: Int = {
        let rows = Set(line("x").lit.map(\.y))
        return ((rows.min() ?? 5) + (rows.max() ?? 10)) / 2
    }()

    static func line(_ text: String) -> Line {
        if let cached = cache[text] { return cached }
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let width = Int(CTLineGetTypographicBounds(ctLine, nil, nil, nil).rounded())
        // The font's line is 16 pixels, 3 of them under the baseline; its
        // glyphs keep to the 12 from the 4th row down.
        let height = 16
        var lit: [(x: Int, y: Int)] = []
        if width > 0, let context = CGContext(data: nil, width: width + 2, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            context.setShouldAntialias(false)
            context.setAllowsFontSmoothing(false)
            context.setShouldSubpixelPositionFonts(false)
            context.setShouldSubpixelQuantizeFonts(false)
            context.textPosition = CGPoint(x: 0, y: 3)
            CTLineDraw(ctLine, context)
            if let data = context.data?.assumingMemoryBound(to: UInt8.self) {
                for y in 3..<15 {
                    for x in 0..<(width + 2) where data[y * context.bytesPerRow + x] > 127 {
                        lit.append((x, y - 3))
                    }
                }
            }
        }
        let result = Line(width: width, lit: lit)
        if cache.count > 400 { cache.removeAll() }
        cache[text] = result
        return result
    }

    /// `text` cut short with an ellipsis to fit `width` pixels.
    static func fit(_ text: String, width: Int) -> String {
        guard line(text).width > width else { return text }
        var cut = text
        while !cut.isEmpty, line(cut + "…").width > width { cut.removeLast() }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}
