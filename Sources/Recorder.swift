import AppKit

/// For looking at Clawd without a screen recording: with CLAWD_RECORD set to
/// a folder, twelve times a second the windows Clawd and the board draw in
/// are drawn together as they sit on screen, the strip along the bottom of
/// the screen they're on, into numbered PNGs there.
@MainActor
final class Recorder {
    private let folder: URL
    private let windows: () -> [NSWindow]
    private var timer: Timer?
    private var count = 0
    private static let scale: CGFloat = 2

    /// `windows` back to front.
    init(folder: String, windows: @escaping () -> [NSWindow]) {
        self.folder = URL(fileURLWithPath: folder, isDirectory: true)
        self.windows = windows
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func capture() {
        let all = windows()
        guard let screen = all.last?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let strip = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: 160)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(strip.width * Self.scale), pixelsHigh: Int(strip.height * Self.scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = strip.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 31 / 255, green: 30 / 255, blue: 29 / 255, alpha: 1).setFill()
        NSRect(origin: .zero, size: strip.size).fill()
        for window in all where window.isVisible {
            guard let view = window.contentView, let snap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: snap)
            let frame = window.frame.offsetBy(dx: -strip.minX, dy: -strip.minY)
            snap.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        count += 1
        let name = String(format: "frame-%05d.png", count)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
    }
}
