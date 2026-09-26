import AppKit
import ApplicationServices
import IOKit.ps

/// What Clawd can tell about the computer: the app in front and its window,
/// how long since you last touched the keyboard or mouse, the battery and
/// the music.
@MainActor
final class Senses {
    struct Battery: Equatable {
        var percent: Int
        var charging: Bool
    }

    private(set) var frontApp: String
    /// The app in front's bundle identifier.
    private(set) var frontBundle: String
    private(set) var frontSince = Date()
    /// Called with the app left and the app now in front.
    var onAppSwitch: ((String, String) -> Void)?

    init() {
        frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let app = running?.localizedName ?? "", bundle = running?.bundleIdentifier ?? ""
            MainActor.assumeIsolated { self?.switched(to: app, bundle: bundle) }
        }
    }

    private func switched(to app: String, bundle: String) {
        frontBundle = bundle
        guard !app.isEmpty, app != frontApp else { return }
        let left = frontApp
        frontApp = app
        frontSince = Date()
        onAppSwitch?(left, app)
    }

    // MARK: Browsing

    /// Web browsers everyone knows, by bundle identifier.
    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
        "com.google.Chrome.dev", "com.google.Chrome.canary", "org.chromium.Chromium", "company.thebrowser.Browser",
        "company.thebrowser.dia", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.brave.Browser",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
        "com.kagi.kagimacOS", "com.duckduckgo.macos.browser", "ai.perplexity.comet", "org.torproject.torbrowser",
        "net.waterfox.waterfox", "io.gitlab.librewolf-community",
    ]
    /// Your default browser, looked up again once a minute.
    private var defaultBrowser: (id: String?, checked: Date) = (nil, .distantPast)

    /// Whether the app in front is a web browser: a well-known one, the one
    /// you've made your default, or one that calls itself a browser.
    var isBrowserInFront: Bool {
        let bundle = frontBundle
        guard !bundle.isEmpty, bundle != Bundle.main.bundleIdentifier else { return false }
        if Self.browsers.contains(bundle) || bundle.localizedCaseInsensitiveContains("browser") { return true }
        if Date().timeIntervalSince(defaultBrowser.checked) > 60, let web = URL(string: "https://example.com") {
            let app = NSWorkspace.shared.urlForApplication(toOpen: web)
            defaultBrowser = (app.flatMap { Bundle(url: $0)?.bundleIdentifier }, Date())
        }
        return bundle == defaultBrowser.id
    }

    /// Seconds since the last key press, click or mouse move anywhere.
    var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: Window title

    /// Reading other apps' window titles takes the Accessibility permission.
    static var canReadWindows: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security > Accessibility.
    static func askToReadWindows() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func windowTitle() -> String? {
        guard Self.canReadWindows, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              let text = title as? String, !text.isEmpty
        else { return nil }
        return text.count > 100 ? String(text.prefix(100)) + "…" : text
    }

    // MARK: Battery

    func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0
            else { continue }
            let onPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return Battery(percent: current * 100 / capacity, charging: onPower)
        }
        return nil
    }

    // MARK: Games

    /// Launchers file themselves under games too, but picking a world isn't
    /// playing: Minecraft's own, Prism's and the like all say "launcher".
    private static func isLauncher(_ bundle: String) -> Bool {
        bundle.localizedCaseInsensitiveContains("launcher")
    }
    /// The last app in front looked at, and whether it was a game.
    private var gameCheck: (pid: pid_t, launched: Date?, isGame: Bool)?

    /// Whether the app in front is a game, in a window or not: one filed
    /// under the games categories (what macOS goes by for Game Mode, which
    /// only comes on full screen), anything from the Steam library, or
    /// Minecraft running on Java. Each app is only looked into once.
    var isGameInFront: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if let gameCheck, gameCheck.pid == app.processIdentifier, gameCheck.launched == app.launchDate {
            return gameCheck.isGame
        }
        let isGame = Self.isGame(app)
        gameCheck = (app.processIdentifier, app.launchDate, isGame)
        return isGame
    }

    static func isGame(_ app: NSRunningApplication) -> Bool {
        if let bundle = app.bundleIdentifier, isLauncher(bundle) { return false }
        if let url = app.bundleURL {
            if url.path.contains("/steamapps/common/") { return true }
            let category = Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String ?? ""
            if category.hasPrefix("public.app-category."), category.hasSuffix("games") { return true }
        }
        guard app.executableURL?.lastPathComponent == "java" else { return false }
        return arguments(of: app.processIdentifier).contains { $0.localizedCaseInsensitiveContains("minecraft") }
    }

    /// The command line a process of yours was started with.
    static func arguments(of pid: pid_t) -> [String] {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        // The count, the executable's path, padding, then the arguments and
        // the environment, each ended by a NUL.
        let parts = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0)
        return parts.dropFirst().prefix(count).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Music

    private static let players = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]

    /// Whether one of the players is playing. Asking a player the first time
    /// brings up macOS's Automation prompt; one that isn't running is never
    /// asked, so it isn't launched.
    func isPlayingMusic() -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for (bundle, _) in Self.players where running.contains(bundle) {
            var error: NSDictionary?
            let script = NSAppleScript(source: "tell application id \"\(bundle)\" to return player state is playing")
            if script?.executeAndReturnError(&error).booleanValue == true { return true }
        }
        return false
    }

    /// "Spotify: Song — Artist" while one of the players is playing. Asking a
    /// player the first time brings up macOS's Automation prompt; a player
    /// that isn't running is never asked, so it isn't launched.
    func nowPlaying() -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for (bundle, name) in Self.players where running.contains(bundle) {
            let source = """
            tell application id "\(bundle)"
                if player state is playing then return (name of current track) & " — " & (artist of current track)
            end tell
            """
            var error: NSDictionary?
            if let song = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue, !song.isEmpty {
                return "\(name): \(song)"
            }
        }
        return nil
    }
}
