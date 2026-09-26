import AppKit

/// The board's pixel font set in lines and boxes, for Clawd's speech bubbles
/// and its chat: text wrapped to a width and drawn a font pixel at a time on
/// whole screen pixels, in cream boxes edged in ink with their corners
/// stepped in, as pixel-art dialog boxes are (and Claude FM's ink on paper).
enum PixelText {
    /// Font pixels from one line's top to the next's.
    static let lineHeight = 14
    static let paper = NSColor(srgbRed: 0xFC / 255.0, green: 0xED / 255.0, blue: 0xCA / 255.0, alpha: 1)
    static let ink = NSColor(srgbRed: 0x30 / 255.0, green: 0x30 / 255.0, blue: 0x30 / 255.0, alpha: 1)
    static let faint = NSColor(srgbRed: 0x8B / 255.0, green: 0x7F / 255.0, blue: 0x6A / 255.0, alpha: 1)

    /// `text` broken into lines at most `width` font pixels wide: at spaces,
    /// or between any two characters of Chinese, Japanese or Korean; a word
    /// too long for a line is broken where it has to be.
    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for (piece, spaced) in pieces(of: paragraph) {
                let candidate = line.isEmpty ? piece : line + (spaced ? " " : "") + piece
                if BoardFont.width(candidate) <= width {
                    line = candidate
                    continue
                }
                if !line.isEmpty { lines.append(line) }
                var rest = piece
                while BoardFont.width(rest) > width, rest.count > 1 {
                    var cut = rest.count - 1
                    while cut > 1, BoardFont.width(String(rest.prefix(cut))) > width { cut -= 1 }
                    lines.append(String(rest.prefix(cut)))
                    rest = String(rest.dropFirst(cut))
                }
                line = rest
            }
            lines.append(line)
        }
        return lines
    }

    /// A paragraph's words, and whether a space comes before each; every
    /// wide character (Chinese, Japanese, Korean) is a word of its own.
    private static func pieces(of paragraph: String) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        var word = "", spaced = false
        func flush() {
            guard !word.isEmpty else { return }
            out.append((word, spaced))
            word = ""
            spaced = false
        }
        for character in paragraph {
            if character == " " {
                flush()
                spaced = true
            } else if isWide(character) {
                flush()
                out.append((String(character), spaced))
                spaced = false
            } else {
                word.append(character)
            }
        }
        flush()
        return out
    }

    private static func isWide(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(value) || (0xAC00...0xD7AF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0xFF00...0xFFEF).contains(value)
    }

    /// A line of text with its top left at `origin` (in a flipped view),
    /// `pixel` points to a font pixel, from a whole screen pixel.
    static func draw(_ line: String, at origin: CGPoint, pixel: CGFloat, color: NSColor, in cg: CGContext) {
        let lit = BoardFont.line(line).lit
        guard !lit.isEmpty else { return }
        let o = aligned(origin, in: cg)
        cg.setFillColor(color.cgColor)
        cg.fill(lit.map { CGRect(x: o.x + CGFloat($0.x) * pixel, y: o.y + CGFloat($0.y) * pixel, width: pixel, height: pixel) })
    }

    /// A box filling `rect` (in a flipped view): paper inside, a pixel of ink
    /// round the edge with the corners stepped in, and, `tailX` given, a
    /// tail from its bottom edge pointing down there, `tail` pixels long.
    static func drawBox(_ rect: CGRect, tailX: CGFloat? = nil, tail: Int = 4, pixel p: CGFloat, alpha: CGFloat = 1,
                        in cg: CGContext) {
        let r = CGRect(origin: aligned(rect.origin, in: cg), size: rect.size)
        let paper = Self.paper.withAlphaComponent(alpha).cgColor, ink = Self.ink.withAlphaComponent(alpha).cgColor
        let bottom = r.maxY - CGFloat(tail) * p
        cg.setFillColor(paper)
        cg.fill(CGRect(x: r.minX + p, y: r.minY + p, width: r.width - 2 * p, height: bottom - r.minY - 2 * p))
        cg.setFillColor(ink)
        cg.fill([CGRect(x: r.minX + p, y: r.minY, width: r.width - 2 * p, height: p),
                 CGRect(x: r.minX + p, y: bottom - p, width: r.width - 2 * p, height: p),
                 CGRect(x: r.minX, y: r.minY + p, width: p, height: bottom - r.minY - 2 * p),
                 CGRect(x: r.maxX - p, y: r.minY + p, width: p, height: bottom - r.minY - 2 * p)])
        guard let tailX else { return }
        // The tail: rows narrowing to a point, paper edged in ink, opening
        // through the bottom edge.
        let cx = r.minX + ((min(max(tailX, r.minX + 6 * p), r.maxX - 6 * p) - r.minX) / p).rounded(.down) * p
        for row in 0..<tail {
            let y = bottom - p + CGFloat(row) * p
            let half = CGFloat(tail - 1 - row)
            cg.setFillColor(paper)
            if half > 0 { cg.fill(CGRect(x: cx - (half - 1) * p, y: y, width: (2 * half - 1) * p, height: p)) }
            cg.setFillColor(ink)
            if half > 0 {
                cg.fill([CGRect(x: cx - half * p, y: y, width: p, height: p), CGRect(x: cx + half * p, y: y, width: p, height: p)])
            } else {
                cg.fill(CGRect(x: cx, y: y, width: p, height: p))
            }
        }
    }

    /// `point` moved to the nearest whole screen pixel.
    static func aligned(_ point: CGPoint, in cg: CGContext) -> CGPoint {
        let device = cg.convertToDeviceSpace(point)
        return cg.convertToUserSpace(CGPoint(x: device.x.rounded(), y: device.y.rounded()))
    }
}
