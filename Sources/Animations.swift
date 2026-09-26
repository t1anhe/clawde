import AppKit

/// Clawd's frame-by-frame animations, bundled by `tools/import_clawd.py`
/// from the Lottie files `tools/design_actions.py` draws, each frame blocks
/// already on Clawd's grid, facing right.
enum Animations {
    struct Frame {
        var blocks: [Renderer.Block]
        /// The top of Clawd's head, leaving out props.
        var top: CGFloat
    }

    struct Clip {
        var fps: Double
        var frames: [Frame]
        /// Frames that repeat while the clip plays on. Those before are its
        /// lead-in and those after its outro, each played once.
        var loop: ClosedRange<Int>?
        /// The frame it touches something the pet draws itself: a note
        /// pinned up on the board, or pulled down.
        var touch: Int?

        var seconds: Double { Double(frames.count) / fps }

        private var outro: Int { loop.map { frames.count - 1 - $0.upperBound } ?? 0 }

        /// How long a play of about `seconds` runs: the lead-in, whole times
        /// round the loop (at least once), then the outro. A clip without a
        /// loop plays once through.
        func length(about seconds: Double) -> Double {
            guard let loop else { return self.seconds }
            let ends = Double(loop.lowerBound + outro)
            let rounds = max(1, ((seconds * fps - ends) / Double(loop.count)).rounded())
            return (ends + rounds * Double(loop.count)) / fps
        }

        /// How many times round its loop a play `length` seconds long goes.
        func rounds(of length: Double) -> Int {
            guard let loop else { return 0 }
            return max(1, Int(((length * fps - Double(loop.lowerBound + outro)) / Double(loop.count)).rounded()))
        }

        /// How long a play that's been held going round its loop runs if let
        /// go of `t` seconds in: it finishes the time round it's on (or its
        /// first), then plays the outro; or, not `finishingRound`, goes
        /// straight into the outro.
        func length(releasedAt t: Double, finishingRound: Bool = true) -> Double {
            guard let loop else { return seconds }
            let n = max(0, Int(t * fps))
            guard finishingRound else { return Double(n + 1 + outro) / fps }
            let rounds = n < loop.lowerBound + loop.count ? 1 : (n - loop.lowerBound) / loop.count + 1
            return Double(loop.lowerBound + rounds * loop.count + outro) / fps
        }

        /// The frame `t` seconds into a play held going round its loop.
        func loopingIndex(at t: Double) -> Int {
            let n = max(0, Int(t * fps))
            guard let loop, n > loop.upperBound else { return min(n, frames.count - 1) }
            return loop.lowerBound + (n - loop.lowerBound) % loop.count
        }

        /// How far round its loop a play `length` seconds long has got `t`
        /// seconds in, from 0 as the loop starts to 1 as the outro does.
        func loopProgress(at t: Double, of length: Double) -> Double {
            guard let loop else { return min(1, max(0, t / max(length, 0.001))) }
            let start = Double(loop.lowerBound) / fps, end = length - Double(outro) / fps
            return min(1, max(0, (t - start) / max(end - start, 0.001)))
        }

        /// The frame `t` seconds into a play `length` seconds long.
        func index(at t: Double, of length: Double) -> Int {
            let n = max(0, Int(t * fps))
            guard let loop else { return min(n, frames.count - 1) }
            let outroStart = Int((length * fps).rounded()) - outro
            if n >= outroStart { return min(frames.count - 1, loop.upperBound + 1 + n - outroStart) }
            guard n > loop.upperBound else { return n }
            return loop.lowerBound + (n - loop.lowerBound) % loop.count
        }
    }

    static let all: [String: Clip] = load()

    /// Everything Clawd can act out, with its menu names, grouped as the menu
    /// shows them: what goes with Claude, what goes with you, and what's
    /// just for fun.
    static let groups: [(title: String, actions: [(name: String, title: String)])] = [
        ("With Claude", [("laptop", "Typing"), ("thinking", "Thinking"), ("idea", "Idea"), ("detective", "Detective"),
                         ("hardhat", "Hard Hat"), ("calling", "Calling You"), ("mailbox", "Posting a Letter"),
                         ("confetti", "Confetti"), ("sunglasses", "Sunglasses")]),
        ("With You", [("gaming", "Gaming"), ("headphones", "Headphones"), ("reading", "Reading"), ("browsing", "Browsing"),
                      ("bubbles", "Bubbles"),
                      ("love", "Love"), ("dizzy", "Dizzy"), ("yawn", "Yawn"), ("skateboard", "Skateboard")]),
        ("Just for Fun", [("wizard", "Wizard"), ("guitar", "Guitar"), ("kite", "Kite"), ("sparkler", "Sparkler"),
                          ("sailboat", "Sailing")]),
    ].map { group in (group.0, group.1.filter { all[$0.0] != nil }) }.filter { !$0.1.isEmpty }

    private static func load() -> [String: Clip] {
        guard let url = Bundle.main.url(forResource: "clawd-animations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
        else { return [:] }
        return file.compactMapValues { entry in
            guard let rawFrames = entry["frames"] as? [[[Any]]], let fps = (entry["fps"] as? NSNumber)?.doubleValue
            else { return nil }
            let frames = rawFrames.map { rows in
                let blocks = rows.compactMap(block)
                let top = blocks.filter { [.body, .shade, .eye].contains($0.tone) }.map { $0.y + $0.h }.max() ?? 8
                return Frame(blocks: blocks, top: top)
            }
            let loop = (entry["loop"] as? [NSNumber]).flatMap { $0.count == 2 ? $0[0].intValue...$0[1].intValue : nil }
            return Clip(fps: fps, frames: frames, loop: loop, touch: (entry["touch"] as? NSNumber)?.intValue)
        }
    }

    /// Clawd's own colours map to its tones, so blinking and the palette still
    /// apply, and the board clips' stand-ins to the board's tools; anything
    /// else is drawn in its own colour.
    private static let tones: [String: Renderer.Tone] = [
        "#D87656": .body, "#BE684D": .shade, "#000000": .eye, "#8B8B8B": .keys,
        "#F100F1": .tool(0), "#F100F2": .tool(1), "#F100F3": .tool(2), "#F100F4": .tool(3), "#F100F5": .tool(4),
    ]

    private static func block(_ row: [Any]) -> Renderer.Block? {
        guard row.count == 5, let hex = row[4] as? String else { return nil }
        let n = row.prefix(4).compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } }
        guard n.count == 4 else { return nil }
        if let tone = tones[hex.uppercased()] {
            return Renderer.Block(x: n[0], y: n[1], w: n[2], h: n[3], tone: tone)
        }
        return Renderer.Block(x: n[0], y: n[1], w: n[2], h: n[3], tone: .custom, color: color(hex))
    }

    private static func color(_ hex: String) -> NSColor {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// Clawd at the laptop while Claude works, from the "laptop" clip: its
/// lead-in gets the laptop out, its loop types, its outro puts it away.
enum WorkAnimation {
    private static var clip: Animations.Clip? { Animations.all["laptop"] }

    static var outroSeconds: Double {
        guard let clip, let loop = clip.loop else { return 0 }
        return Double(clip.frames.count - 1 - loop.upperBound) / clip.fps
    }

    /// The frame `t` seconds after getting to work: the lead-in, then round the typing loop.
    static func working(at t: Double) -> Action {
        guard let clip else { return .stand }
        return .clip("laptop", clip.loopingIndex(at: t))
    }

    /// The frame `t` seconds into putting the laptop away.
    static func packing(at t: Double) -> Action {
        guard let clip, let loop = clip.loop else { return .stand }
        return .clip("laptop", min(clip.frames.count - 1, loop.upperBound + 1 + Int(t * clip.fps)))
    }

    /// Mulling a reply over in a chat: the thinking pose, without its bubble.
    static var thinking: Action {
        Animations.all["thinking"] != nil ? .clip("thinking", 2) : .stand
    }
}
