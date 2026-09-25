import AppKit

enum Palette {
    // The Code tab's Clawd colours, from its Lottie file.
    static let body = NSColor(srgbRed: 0xD8 / 255.0, green: 0x76 / 255.0, blue: 0x56 / 255.0, alpha: 1)
    /// The far side, once Clawd turns.
    static let shade = NSColor(srgbRed: 0xBE / 255.0, green: 0x68 / 255.0, blue: 0x4D / 255.0, alpha: 1)
    static let eye = NSColor.black
    static let lid = NSColor(srgbRed: 0x8B / 255.0, green: 0x8B / 255.0, blue: 0x8B / 255.0, alpha: 1)
    static let keys = lid
    /// The Fable 5 film's salmon and lit cream, for Clawd's own flourishes.
    static let salmon = NSColor(srgbRed: 0xDC / 255.0, green: 0x62 / 255.0, blue: 0x63 / 255.0, alpha: 1)
    static let cream = NSColor(srgbRed: 0xFC / 255.0, green: 0xED / 255.0, blue: 0xCA / 255.0, alpha: 1)
    static let bubble = NSColor(white: 1, alpha: 0.96)
    static let bubbleEdge = NSColor(white: 0, alpha: 0.14)
    static let bubbleText = NSColor(srgbRed: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x13 / 255.0, alpha: 1)
    static let iconBackground = NSColor(srgbRed: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x24 / 255.0, alpha: 1)
}

/// What Clawd's body is doing, frame by frame.
enum Action: Equatable {
    case stand
    /// The Fable 5 walk: four poses, 0 and 1 riding half a unit high with the
    /// legs splayed, 2 and 3 back down with them gathered.
    case walk(Int)
    /// A frame of one of the bundled clips (Animations): the laptop or one
    /// of Clawd's other actions.
    case clip(String, Int)
    /// Hanging in the air while carried, the pairs of legs kicking in turn.
    case dangle(Int)
    /// Stretched tall, on the way up a hop.
    case leap
    /// Legs drawn up, coming down from a hop.
    case tuck
    /// Squashed for a moment as it lands.
    case land
    /// Settled on its belly with the legs folded, for sleeping.
    case sit
}

struct Pose {
    var action = Action.stand
    var armsUp = false
    var eyesClosed = false
    /// The eyes squeezed happy, ^ ^, as when it's poked.
    var happy = false
    /// Where the eyes look, in units from straight ahead (x right, y up), at
    /// most half a unit each way: Clawd keeps them on the pointer.
    var gaze = CGPoint.zero
    /// Which way Clawd is turned, 1 right or -1 left; 0 faces you. Walking is
    /// drawn turned, and coding faces the laptop this way.
    var facing: CGFloat = 0
}

/// Everything the pet's window draws besides where it is.
struct Scene {
    var pose = Pose()
    /// Seconds since the heart appeared.
    var heartAge: Double?
    /// A running clock while asleep, for the floating z's.
    var zzzPhase: Double?
    var bubble: String?
    var bubbleAlpha: CGFloat = 1
}

/// Clawd as the desktop app and the Fable 5 animation draw it: a body 8 units
/// wide and 6 tall, 1-unit eyes in its second row, a 2-by-2 claw on each side
/// and four legs 2 units long, on a half-unit grid.
///
/// Poses are laid out facing right in body coordinates (x from the body's
/// left edge, y up from the ground) and mirrored to face left. The canvas is
/// the 12 units from claw to claw standing; a laptop reaches past it into
/// the window's side padding.
enum Renderer {
    static let columns: CGFloat = 12
    /// Standing height plus the half unit the body rises mid-stride.
    static let rows: CGFloat = 8.5
    /// Room above Clawd for the heart, the z's, the speech bubble and the
    /// props its actions hold up or throw, which reach 8 units over its rows.
    static func headroom(unit u: CGFloat) -> CGFloat { max(58, 8 * u) }

    /// Room beside Clawd for the laptop and for a bubble wider than it.
    static func padX(unit u: CGFloat) -> CGFloat { max(30, 7.5 * u) }

    static func windowSize(unit u: CGFloat) -> NSSize {
        NSSize(width: columns * u + 2 * padX(unit: u), height: rows * u + headroom(unit: u))
    }

    /// Clawd's own box in window coordinates (y up), claw to claw and head to feet.
    static func spriteRect(unit u: CGFloat) -> NSRect {
        NSRect(x: padX(unit: u), y: 0, width: columns * u, height: rows * u)
    }

    /// Draws a scene into a flipped context of `windowSize(unit:)`.
    static func draw(_ scene: Scene, size: NSSize, unit u: CGFloat) {
        let origin = CGPoint(x: padX(unit: u), y: size.height - rows * u)
        let figure = figure(scene.pose)
        let headTop = origin.y + (rows - figure.top) * u

        drawClawd(scene.pose, at: origin, unit: u)
        if let age = scene.heartAge {
            drawHeart(age: age, at: origin, unit: u)
        }
        if let phase = scene.zzzPhase {
            drawZzz(phase: phase, top: figure.top, at: origin, unit: u)
        }
        if let text = scene.bubble {
            drawBubble(text, alpha: scene.bubbleAlpha, centerX: origin.x + 6 * u, headTop: headTop, width: size.width)
        }
    }

    // MARK: Figure

    /// Clawd's own colours by role; `custom` is a prop's, given by the block.
    enum Tone { case body, shade, eye, lid, keys, custom }

    struct Block {
        var x, y, w, h: CGFloat
        var tone: Tone
        var alpha: CGFloat = 1
        /// A `custom` block's colour.
        var color: NSColor?
    }

    /// A pose as blocks in body coordinates, and where the top of its head is.
    static func figure(_ pose: Pose) -> (blocks: [Block], top: CGFloat) {
        var blocks: [Block] = []
        func add(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ tone: Tone = .body, alpha: CGFloat = 1) {
            blocks.append(Block(x: x, y: y, w: w, h: h, tone: tone, alpha: alpha))
        }
        func eyes(_ xs: [CGFloat], y: CGFloat) {
            for x in xs {
                if pose.happy {
                    blocks += Self.happyEye(x: x, y: y)
                } else if pose.eyesClosed {
                    blocks.append(Self.closedEye(x: x, y: y))
                } else {
                    add(x, y, 1, 1, .eye)
                }
            }
        }

        /// Facing you: legs under the body at 0, 2, 5 and 7.
        func front(bottom: CGFloat, lifts: [CGFloat], height: CGFloat = 6) -> CGFloat {
            for (x, lift) in zip([0, 2, 5, 7] as [CGFloat], lifts) { add(x, lift, 1, bottom - lift) }
            add(0, bottom, 8, height)
            let armY = bottom + height - (pose.armsUp ? 3 : 4)
            add(-2, armY, 2, 2)
            add(8, armY, 2, 2)
            eyes([1 + pose.gaze.x, 6 + pose.gaze.x], y: bottom + height - 2 + pose.gaze.y)
            return bottom + height
        }

        /// Turned right: the back 1.5 units shaded, the claws foreshortened to
        /// 1.5, the near eye at 2.5 and the far one at the front edge, so the
        /// eyes can glance back but no further forward.
        func turned(bottom: CGFloat, top: CGFloat) {
            add(0, bottom, 8, top - bottom)
            add(0, bottom, 1.5, top - bottom, .shade)
            let armY = top - (pose.armsUp ? 3 : 4)
            add(-1.5, armY, 1.5, 2, .shade)
            add(8, armY, 1.5, 2)
            add(8, armY, 0.5, 2, .shade)
            let back = min(0, pose.gaze.x * (pose.facing < 0 ? -1 : 1))
            eyes([2.5 + back, 7 + back], y: top - 2 + pose.gaze.y)
        }

        /// Standing turned, all four feet down.
        func standTurned() -> CGFloat {
            for (x, tone) in [(0, Tone.shade), (2, .body), (5, .body), (7.5, .body)] as [(CGFloat, Tone)] {
                add(x, 0, 1, 2, tone)
            }
            turned(bottom: 2, top: 8)
            return 8
        }

        var top: CGFloat = 8
        switch pose.action {
        case .stand:
            top = pose.facing == 0 ? front(bottom: 2, lifts: [0, 0, 0, 0]) : standTurned()

        case .dangle(let frame):
            top = front(bottom: 2, lifts: frame % 2 == 0 ? [0, 0.5, 0, 0.5] : [0.5, 0, 0.5, 0])

        case .leap:
            top = front(bottom: 2, lifts: [0, 0, 0, 0], height: 6.5)

        case .tuck:
            top = front(bottom: 2, lifts: [0.5, 0.5, 0.5, 0.5])

        case .land:
            top = front(bottom: 1.5, lifts: [0, 0, 0, 0])

        case .sit:
            top = front(bottom: 0.5, lifts: [0, 0, 0, 0])

        case .walk(let frame):
            switch frame % 4 {
            case 0:
                add(-0.5, 1.5, 1.5, 1, .shade); add(-0.5, 0.5, 1, 1, .shade)
                add(1.5, 2, 1.5, 0.5); add(1.5, 0, 1, 2)
                add(5, 2, 1.5, 0.5); add(5.5, 1, 1, 1)
                add(7, 2, 1, 0.5); add(7, 1.5, 1.5, 0.5); add(7.5, 0, 1, 1.5)
                top = 8.5
                turned(bottom: 2.5, top: top)
            case 1:
                add(0, 2, 1, 0.5, .shade); add(-0.5, 1.5, 1.5, 0.5, .shade); add(-0.5, 0, 1, 1.5, .shade)
                add(1.5, 2, 1.5, 0.5); add(1.5, 0.5, 1, 1.5)
                add(5.5, 2, 1.5, 0.5); add(6, 0, 1, 2)
                add(7.5, 0.5, 1, 2)
                top = 8.5
                turned(bottom: 2.5, top: top)
            case 2:
                add(-0.5, 2, 2, 0.5, .shade); add(1.5, 2, 2, 0.5); add(5, 2, 3, 0.5)
                add(-0.5, 0.5, 1, 1.5, .shade); add(2, 0, 1, 2); add(5.5, 0, 1, 2); add(7, 0, 1, 2)
                turned(bottom: 2.5, top: top)
            default:
                add(0, 0, 1, 2, .shade); add(2, 0.5, 1, 1.5); add(5, 0, 1, 2); add(7.5, 0.5, 1, 1.5)
                add(8, 2, 0.5, 0.5)
                turned(bottom: 2, top: top)
            }

        case .clip(let name, let index):
            guard let frames = Animations.all[name]?.frames, frames.indices.contains(index) else { break }
            blocks = frames[index].blocks.map { block in
                guard pose.eyesClosed, block.tone == .eye, block.w == 1, block.h >= 1 else { return block }
                return Self.closedEye(x: block.x, y: block.y)
            }
            top = frames[index].top
        }
        return (blocks, top)
    }

    /// A shut eye as the Code tab's Clawd winks: a bar half a unit tall along
    /// the eye's lower half, half a unit wider toward the middle of the body.
    static func closedEye(x: CGFloat, y: CGFloat) -> Block {
        Block(x: x + 0.5 < 4 ? x : x - 0.5, y: y, w: 1.5, h: 0.5, tone: .eye)
    }

    /// A happy eye, ^, in Clawd's own pixels, as wide as the wink and
    /// leaning the same way toward the middle of the body.
    static func happyEye(x: CGFloat, y: CGFloat) -> [Block] {
        let left = x + 0.5 < 4 ? x : x - 0.5
        return [Block(x: left + 0.5, y: y + 0.5, w: 0.5, h: 0.5, tone: .eye),
                Block(x: left, y: y, w: 0.5, h: 0.5, tone: .eye),
                Block(x: left + 1, y: y, w: 0.5, h: 0.5, tone: .eye)]
    }

    /// Clawd with its canvas's top-left at `o`, in a flipped context.
    static func drawClawd(_ pose: Pose, at o: CGPoint, unit u: CGFloat) {
        let mirrored = pose.facing < 0
        for block in figure(pose).blocks {
            // The body's left edge sits 2 units into the canvas; facing left
            // mirrors about the body's middle.
            let x = mirrored ? 10 - block.x - block.w : block.x + 2
            (block.color ?? color(block.tone)).withAlphaComponent(block.alpha).setFill()
            pixelAligned(NSRect(x: o.x + x * u, y: o.y + (rows - block.y - block.h) * u, width: block.w * u, height: block.h * u)).fill()
        }
    }

    private static func color(_ tone: Tone) -> NSColor {
        switch tone {
        case .body: Palette.body
        case .shade: Palette.shade
        case .eye: Palette.eye
        case .lid: Palette.lid
        case .keys: Palette.keys
        case .custom: Palette.body
        }
    }

    /// The rect with its edges moved to the nearest device pixels, so Clawd's
    /// blocks stay crisp at any size the slider picks.
    private static func pixelAligned(_ rect: NSRect) -> NSRect {
        guard let cg = NSGraphicsContext.current?.cgContext else { return rect }
        let device = cg.convertToDeviceSpace(rect)
        let minX = device.minX.rounded(), minY = device.minY.rounded()
        let aligned = CGRect(x: minX, y: minY, width: device.maxX.rounded() - minX, height: device.maxY.rounded() - minY)
        return cg.convertToUserSpace(aligned)
    }

    // MARK: Overlays

    private static let heartTiny = ["#.#", "###", ".#."]
    private static let heartSmall = ["##.##", "#####", ".###.", "..#.."]
    private static let zSmall = ["###", ".#.", "###"]
    private static let zBig = ["####", "..#.", ".#..", "####"]

    /// A poke's heart in Clawd's own pixels, salmon like the film's letters:
    /// popping out small over its head, floating up half a unit at a time,
    /// and breaking up into dots.
    private static func drawHeart(age: Double, at o: CGPoint, unit u: CGFloat) {
        guard age < 1.2 else { return }
        let art = age < 0.1 ? heartTiny : heartSmall
        let left = 4.25 - CGFloat(art[0].count) / 4
        let bottom = 9 + CGFloat(Int(age / 0.2)) * 0.5
        Palette.salmon.setFill()
        drawArt(art, left: left, bottom: bottom, dots: age > 0.85, thin: age > 1.05, at: o, unit: u)
    }

    /// Sleep's Z's in Clawd's own pixels, cream: drifting up and out from
    /// the top of its head half a unit at a time, growing, breaking up.
    private static func drawZzz(phase: Double, top: CGFloat, at o: CGPoint, unit u: CGFloat) {
        Palette.cream.setFill()
        for i in 0..<3 {
            let p = (phase * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let step = CGFloat(Int(p * 8)) * 0.5
            drawArt(p < 0.45 ? zSmall : zBig, left: 8.5 + step, bottom: top + step, dots: p > 0.8, thin: p > 0.9,
                    at: o, unit: u)
        }
    }

    /// Character art in half-unit pixels at a spot in Clawd's grid (x from
    /// its body's left edge, y up from the ground), in the fill colour set;
    /// `dots` draws each pixel as the film's quarter-unit dot, `thin` leaves
    /// out every other one.
    private static func drawArt(_ art: [String], left: CGFloat, bottom: CGFloat, dots: Bool, thin: Bool,
                                at o: CGPoint, unit u: CGFloat) {
        for (r, line) in art.enumerated() {
            for (c, ch) in line.enumerated() where ch == "#" {
                if thin, (r + c) % 2 == 1 { continue }
                let x = left + CGFloat(c) * 0.5, y = bottom + CGFloat(art.count - 1 - r) * 0.5
                let (inset, size): (CGFloat, CGFloat) = dots ? (0.125, 0.25) : (0, 0.5)
                pixelAligned(NSRect(x: o.x + (x + inset + 2) * u, y: o.y + (rows - y - inset - size) * u,
                                    width: size * u, height: size * u)).fill()
            }
        }
    }

    private static func drawBubble(_ text: String, alpha: CGFloat, centerX: CGFloat, headTop: CGFloat, width: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Palette.bubbleText.withAlphaComponent(alpha),
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let w = ceil(textSize.width) + 16
        let h = ceil(textSize.height) + 8
        let bottom = headTop - 9
        let left = min(max(centerX - w / 2, 2), width - w - 2)
        let box = NSRect(x: left, y: bottom - h, width: w, height: h)

        let path = NSBezierPath(roundedRect: box, xRadius: h / 2, yRadius: h / 2)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: centerX - 5, y: bottom - 0.5))
        tail.line(to: NSPoint(x: centerX + 5, y: bottom - 0.5))
        tail.line(to: NSPoint(x: centerX, y: bottom + 6))
        tail.close()

        Palette.bubbleEdge.withAlphaComponent(0.14 * alpha).setStroke()
        path.lineWidth = 1
        path.stroke()
        Palette.bubble.withAlphaComponent(0.96 * alpha).setFill()
        path.fill()
        tail.fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attributes)
    }

    // MARK: Icons

    /// Clawd for the menu bar, a point and a half per unit.
    static func menuBarImage() -> NSImage {
        let u: CGFloat = 1.5
        let image = NSImage(size: NSSize(width: columns * u, height: rows * u), flipped: true) { _ in
            drawClawd(Pose(), at: .zero, unit: u)
            return true
        }
        image.accessibilityDescription = "Clawd"
        return image
    }

    /// The app icon at `side` points: Clawd on a dark rounded square.
    static func drawIcon(side: CGFloat) {
        let inset = side * 0.1
        let square = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
        Palette.iconBackground.setFill()
        NSBezierPath(roundedRect: square, xRadius: square.width * 0.225, yRadius: square.width * 0.225).fill()

        let u = square.width * 0.7 / columns
        let standing: CGFloat = 8
        drawClawd(Pose(), at: CGPoint(x: square.midX - columns * u / 2, y: square.midY - standing * u / 2 - (rows - standing) * u), unit: u)
    }
}
