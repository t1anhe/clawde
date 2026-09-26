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
        /// Where Clawd's body's left edge stands for it, on screen, and which
        /// way it faces to be turned to the board.
        var spot: CGFloat
        var facing: CGFloat
        /// About how long its loop should go round for.
        var seconds: Double
    }

    /// The most rows it holds; more sessions wait their turn, counted on a
    /// tab on its top.
    static let capacity = 3

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
    /// Sessions to write up when there's room, oldest first.
    private var waiting: [Entry] = []
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
    /// Whether it stands to the right of Clawd's spot; fixed while it's up.
    private var onRight: Bool?
    /// Where Clawd's body's left edge stands at home, and the screen it's on.
    private var home: (bodyLeft: CGFloat, screen: NSRect)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
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
            waiting[i] = entry
        } else {
            waiting.append(entry)
            dirty = true
        }
    }

    /// A session is done: rubbed out, or never written up.
    func finished(_ id: String) {
        waiting.removeAll { $0.id == id }
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
        waiting = waiting.compactMap { byID[$0.id] ?? (known.contains($0.id) ? $0 : nil) }
        for entry in active where !rows.contains(where: { $0.entry.id == entry.id }) && !waiting.contains(where: { $0.id == entry.id }) {
            waiting.append(entry)
        }
    }

    /// Everything off the board at once.
    func clear() {
        rows.removeAll()
        waiting.removeAll()
        done.removeAll()
        dirty = true
    }

    // MARK: Chores

    /// Whether there's something for Clawd to do at the board.
    var hasChores: Bool {
        guard style != nil, busy == nil, home != nil else { return false }
        return rows.contains { done.contains($0.entry.id) } || (rows.count < Self.capacity && !waiting.isEmpty)
    }

    /// The next thing for Clawd to do at the board, now its own: rubbing a
    /// done session out comes first, to make room; then writing the next one up.
    func nextChore() -> Chore? {
        guard hasChores, let style, let spot = spot(), let facing = side ?? boardFrame().map({ $0.right ? 1 : -1 }) else {
            return nil
        }
        if let row = rows.filter({ done.contains($0.entry.id) }).min(by: { $0.target < $1.target }) {
            let slot = min(row.target, Self.capacity - 1) + 1
            let chore = Chore(kind: .erase, session: row.entry.id, style: style,
                              clip: style == .cork ? "board-unpin-\(slot)" : "board-erase-\(slot)",
                              spot: spot, facing: facing, seconds: 1.3)
            busy = chore
            return chore
        }
        let entry = waiting.removeFirst()
        for i in rows.indices { rows[i].target += 1 }
        rows.append(Row(entry: entry, slot: 0, target: 0, reveal: 0, shown: style != .cork))
        let letters = Double(entry.project.count + entry.title.count)
        let chore = Chore(kind: .write, session: entry.id, style: style, clip: style == .cork ? "board-pin" : "board-write",
                          spot: spot, facing: facing, seconds: 0.8 + 0.07 * letters)
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

    // MARK: Place

    /// Where Clawd lives, every frame: the board stands beside it.
    func follow(homeBodyLeft: CGFloat, screen: NSRect, unit: CGFloat, scale: CGFloat, below window: Int) {
        if unit != self.unit || scale != self.scale { dirty = true }
        self.unit = unit
        self.scale = scale
        home = (homeBodyLeft, screen)
        tick(below: window)
    }

    /// Which way Clawd turns to face the board while it's up: 1 right, -1 left.
    var side: CGFloat? {
        guard presence > 0 || !rows.isEmpty, let frame = boardFrame() else { return nil }
        return frame.right ? 1 : -1
    }

    /// Where Clawd's body's left edge stands to work at the board: in front
    /// of its near end, 7 units short of it when it stands to the right, and
    /// turned left to one on the left, its body's right edge 7 units past it.
    private func spot() -> CGFloat? {
        guard let frame = boardFrame() else { return nil }
        return frame.right ? frame.near - 7 * unit : frame.near - unit
    }

    /// The board's near edge (its frame's edge next to Clawd), whether it
    /// stands to the right of Clawd's spot, and its window's frame on screen.
    /// It stands to the right, where Clawd writes on from the start of its
    /// rows, unless it would run off the screen there.
    private func boardFrame() -> (near: CGFloat, right: Bool, window: NSRect)? {
        guard let home else { return nil }
        let u = unit
        let size = layoutSize()
        let width = size.width * u, height = size.height * u
        let screen = home.screen
        let right = onRight ?? (home.bodyLeft + 14 * u - Self.margin * u + width <= screen.maxX)
        if onRight == nil, presence > 0 || !rows.isEmpty { onRight = right }
        if right {
            // The frame's near edge 14 units from home: room for the laptop.
            var near = home.bodyLeft + 14 * u
            near = min(near, screen.maxX - width + Self.margin * u)
            return (near, true, NSRect(x: (near - Self.margin * u).rounded(), y: screen.minY, width: width, height: height))
        }
        var near = home.bodyLeft - 6 * u
        near = max(near, screen.minX + width - Self.margin * u)
        return (near, false, NSRect(x: (near + Self.margin * u - width).rounded(), y: screen.minY, width: width, height: height))
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
        let wantRoom = Double((rows.map(\.target).max() ?? -1) + 1)
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
            onRight = nil
            if !up { room = 0 }
            return
        }
        guard let frame = boardFrame() else { return }
        if panel.frame != frame.window {
            panel.setFrame(frame.window, display: false)
            view.frame = NSRect(origin: .zero, size: frame.window.size)
            dirty = true
        }
        // Just behind Clawd.
        if !panel.isVisible { panel.order(.below, relativeTo: window) }
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
        let widest = rows.map { textWidth($0.entry) }.max() ?? 0
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

    /// Draws the board into its view (y up, the window's bottom left at the origin).
    func draw() {
        guard let style, let cg = NSGraphicsContext.current?.cgContext else { return }
        let painter = Painter(cg: cg, unit: unit, dots: presence < 1 ? (presence < 0.5 ? 2 : 1) : 0)
        let frame = frameWidth(style)
        let inner = innerSize(style)
        let x0 = Self.margin
        let legs = Self.surface - frame
        let outer = NSSize(width: inner.width + 2 * frame, height: inner.height + 2 * frame)
        let sx = x0 + frame, sy = Self.surface
        let top = sy + inner.height
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
        for row in rows {
            let words = Self.words(row.entry)
            let slot = CGFloat(row.slot)
            if style == .cork {
                guard row.shown else { continue }
                let bottom = sy + Self.pad + slot * (Self.noteHeight + Self.noteGap)
                let noteX = sx + Self.pad
                let noteW = ((CGFloat(words.width) * tp / unit + 1) * 2).rounded(.up) / 2
                painter.fill(noteX, bottom, noteW, Self.noteHeight, Self.cream)
                painter.fill(noteX, bottom, noteW, 0.5, Self.paperEdge)
                let pinX = ((noteX + noteW / 2 - 0.5) * 2).rounded() / 2
                let needs = row.entry.needsYou
                painter.fill(pinX, bottom + Self.noteHeight - 0.5, 1, 1, needs ? Self.salmon : Self.amber)
                painter.fill(pinX, bottom + Self.noteHeight - 0.5, 1, 0.5, needs ? Self.salmonDark : Self.amberDark)
                drawWords(words, row: row, x: noteX + 0.5, middle: bottom + Self.noteHeight / 2, style: style, painter: painter)
            } else {
                let bottom = sy + Self.pad + slot * (Self.line + Self.gap)
                drawWords(words, row: row, x: sx + Self.pad, middle: bottom + Self.line / 2, style: style, painter: painter)
            }
        }

        // More sessions than rows: how many more, on a tab over the top.
        let more = waiting.count
        if more > 0, rows.count >= Self.capacity {
            let tag = BoardFont.line("+\(more)")
            let snap = { (v: CGFloat) in (v * 2).rounded(.up) / 2 }
            let tabW = snap(CGFloat(tag.width) * tp / unit + 1), tabH = snap(12 * tp / unit + 1)
            let tabX = x0 + outer.width - 1.5 - tabW
            painter.fill(tabX, legs + outer.height, tabW, tabH, style == .white ? Self.gray : Self.wood)
            painter.text(tag.lit.map { ($0.x, $0.y) }, x: tabX + 0.5, top: legs + outer.height + tabH - 0.5,
                         pixel: tp, color: style == .white ? Self.ink : Self.cream)
        }
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
