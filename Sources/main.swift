import AppKit

/// Offscreen renders the build and a quick look at the poses use.
enum Tools {
    /// PNG data of `points` drawn at `pixelsPerPoint`, into a flipped context.
    static func png(points: NSSize, pixelsPerPoint: CGFloat = 1, _ draw: () -> Void) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(points.width * pixelsPerPoint),
            pixelsHigh: Int(points.height * pixelsPerPoint),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = points
        let bitmap = NSGraphicsContext(bitmapImageRep: rep)!
        let cg = bitmap.cgContext
        cg.translateBy(x: 0, y: points.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// The `.iconset` folder `iconutil` turns into AppIcon.icns.
    static func writeIconset(to path: String) throws {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for side in [16, 32, 128, 256, 512] {
            for density in [1, 2] {
                let name = density == 1 ? "icon_\(side)x\(side).png" : "icon_\(side)x\(side)@2x.png"
                let points = NSSize(width: side, height: side)
                let data = png(points: points, pixelsPerPoint: CGFloat(density)) { Renderer.drawIcon(side: CGFloat(side)) }
                try data.write(to: folder.appendingPathComponent(name))
            }
        }
    }

    /// Every pose and overlay side by side, to look at without running the app.
    static func writeSheet(to path: String, unit: CGFloat = 7) throws {
        let cell = Renderer.windowSize(unit: unit)
        let right: (Action) -> Scene = { Scene(pose: Pose(action: $0, facing: 1)) }
        var scenes: [(String, Scene)] = [
            ("idle", Scene()),
            ("blink", Scene(pose: Pose(eyesClosed: true))),
            ("glance", Scene(pose: Pose(gaze: CGPoint(x: -0.5, y: 0.5)))),
            ("asleep", Scene(pose: Pose(action: .sit, eyesClosed: true), zzzPhase: 0.6)),
            ("asleep later", Scene(pose: Pose(action: .sit, eyesClosed: true), zzzPhase: 1.7)),
            ("carried", Scene(pose: Pose(action: .dangle(0), armsUp: true))),
            ("poke: leap", Scene(pose: Pose(action: .leap, armsUp: true, happy: true), heartAge: 0.05)),
            ("poke: up", Scene(pose: Pose(action: .leap, armsUp: true, happy: true), heartAge: 0.3)),
            ("poke: down", Scene(pose: Pose(action: .tuck, armsUp: true, happy: true), heartAge: 0.6)),
            ("poke: land", Scene(pose: Pose(action: .land, armsUp: true, happy: true), heartAge: 0.9)),
            ("poke: after", Scene(pose: Pose(), heartAge: 1.1)),
        ]
        for i in 0..<4 { scenes.append(("walk \(i)", right(.walk(i)))) }
        scenes.append(("walk left", Scene(pose: Pose(action: .walk(0), facing: -1))))
        scenes.append(("done", Scene(pose: Pose(armsUp: true), bubble: "All done!")))
        let columns = 6
        let label: CGFloat = 16
        let size = NSSize(width: cell.width * CGFloat(columns), height: (cell.height + label) * CGFloat((scenes.count + columns - 1) / columns))
        let data = png(points: size, pixelsPerPoint: 2) {
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            for (i, (name, scene)) in scenes.enumerated() {
                let origin = NSPoint(x: CGFloat(i % columns) * cell.width, y: CGFloat(i / columns) * (cell.height + label))
                NSGraphicsContext.saveGraphicsState()
                let shift = NSAffineTransform()
                shift.translateX(by: origin.x, yBy: origin.y)
                shift.concat()
                Renderer.draw(scene, size: cell, unit: unit)
                (name as NSString).draw(
                    at: NSPoint(x: 6, y: cell.height + 1),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.darkGray]
                )
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}

extension Tools {
    /// One PNG per animation frame of the walk and every clip, for
    /// stitching into previews.
    static func writeFrames(to path: String, unit: CGFloat) throws {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = Renderer.windowSize(unit: unit)
        func write(_ name: String, _ pose: Pose) throws {
            let data = png(points: size, pixelsPerPoint: 2) { Renderer.draw(Scene(pose: pose), size: size, unit: unit) }
            try data.write(to: folder.appendingPathComponent(name + ".png"))
        }
        for i in 0..<4 { try write(String(format: "walk_%d", i), Pose(action: .walk(i), facing: 1)) }
        for (name, clip) in Animations.all {
            for index in clip.frames.indices {
                try write(String(format: "%@_%02d", name, index), Pose(action: .clip(name, index), facing: -1))
            }
        }
        try write("stand", Pose())
    }
}

let arguments = CommandLine.arguments
if arguments.count >= 2, arguments[1] == "--claude-state" {
    // What the watcher makes of the transcripts under a folder (Claude Code's
    // own by default) and the hooks' events file (Clawde's own by default):
    // each recent session, then all of them together.
    let root = arguments.count > 2 ? URL(fileURLWithPath: arguments[2], isDirectory: true)
        : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    let eventsFile = arguments.count > 3 ? URL(fileURLWithPath: arguments[3]) : Hooks.eventsFile
    var notes: [String: ClaudeWatcher.Notes] = [:]
    for line in (try? String(contentsOf: eventsFile, encoding: .utf8))?.split(separator: "\n") ?? [] {
        guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let hook = entry["hook"] as? [String: Any], let id = hook["session_id"] as? String
        else { continue }
        let at = Date(timeIntervalSince1970: (entry["at"] as? NSNumber)?.doubleValue ?? 0)
        ClaudeWatcher.note(hook, at: at, in: &notes[id, default: ClaudeWatcher.Notes()])
    }
    var tails: [String: (modified: Date, tail: ClaudeWatcher.Tail)] = [:]
    let sessions = ClaudeWatcher.recentSessions(under: root, tails: &tails, notes: notes,
                                                hooked: arguments.count > 3 || Hooks.isInstalled)
    for session in sessions {
        let mode = session.state == .working ? " (\(session.mode))" : ""
        let need = session.need.map { " needing \($0)" } ?? ""
        let ships = session.shipped.isEmpty ? "" : ", shipped \(session.shipped.joined(separator: " "))"
        print("\(session.project) · \(session.title) [\(session.id.prefix(8))]: \(session.state)\(mode)\(need)\(ships)")
    }
    let states = Set(sessions.map(\.state))
    print("=> \([ClaudeState.waiting, .working, .thinking].first { states.contains($0) } ?? .idle)")
    exit(0)
}
if arguments.count >= 2, arguments[1] == "--hooks" {
    // Adds Clawde's hooks to Claude Code's settings ("on"), takes them out
    // ("off"), or says whether they're in.
    do {
        if arguments.count > 2 { try arguments[2] == "off" ? Hooks.uninstall() : Hooks.install() }
        print("Claude Code hooks: \(Hooks.isInstalled ? "on" : "off") (\(Hooks.settingsFile.path))")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
if arguments.count == 2, arguments[1] == "--games" {
    // Which of the apps running now Clawd would take for a game in front.
    MainActor.assumeIsolated {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let id = app.bundleIdentifier ?? app.executableURL?.path ?? ""
            print("\(Senses.isGame(app) ? "game" : "    ")  \(app.localizedName ?? "?")  \(id)")
        }
    }
    exit(0)
}
if arguments.count == 2, arguments[1] == "--simulate" {
    // Runs an unseen Clawd through a made-up stretch of your day, its moves
    // on stderr (set CLAWD_DEBUG to see them): music, Claude thinking and
    // acting and asking you something, the job done, the music off, you
    // reading, playing, stepping away from the game and back, sitting still.
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let pet = Pet(unit: 3)
        pet.start(showing: false)
        var idle = 0.0, music = false
        var reading = false, gaming = false
        let script: [(Double, String, () -> Void)] = [
            (2, "music on", { music = true }),
            (10, "Claude asked: thinking", { pet.setClaude(.thinking) }),
            (16, "Claude acts: working", { pet.setClaude(.working) }),
            (24, "Claude looks things up", { pet.setClaude(.working, mode: .searching) }),
            (32, "Claude edits files", { pet.setClaude(.working, mode: .editing) }),
            (40, "Claude commits", { pet.shipped() }),
            (47, "a long pause: thinking", { pet.setClaude(.thinking) }),
            (52, "acts again: working", { pet.setClaude(.working) }),
            (60, "Claude asks you: waiting", { pet.setClaude(.waiting) }),
            (66, "you answered: working", { pet.setClaude(.working) }),
            (72, "Claude done", { pet.setClaude(.idle) }),
            (84, "music off, VS Code in front", { music = false; reading = true }),
            (92, "a game in front", { reading = false; gaming = true }),
            (102, "game left in front, you step away", { idle = 290 }),
            (116, "", { idle = 720 }),
            (120, "back after 12 min, still in the game", { idle = 0 }),
            (130, "game closed, sitting still", { gaming = false; idle = 95 }),
            (138, "end", { exit(0) }),
        ]
        // One beat a second plays the script and then the senses, so the
        // senses see every step even when the system runs the timer late.
        var second = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                second += 1
                for (at, what, act) in script where Int(at) == second {
                    if !what.isEmpty { FileHandle.standardError.write(Data("-- \(what)\n".utf8)) }
                    act()
                }
                if idle > 0, idle < 700 { idle += 1 }
                pet.sense(idle: idle, music: music, reading: reading, gaming: gaming)
            }
        }
        // Unseen, the app would be napped and its timers put off, the senses
        // missing some of the script's moments.
        let awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Simulating a day")
        withExtendedLifetime(awake) { NSApplication.shared.run() }
    }
}
if arguments.count >= 3, arguments[1] == "--ask" {
    // Asks Clawd one question from the command line and prints the reply as it streams.
    let brain = Brain()
    if arguments.count > 3 { brain.model = arguments[3] }
    brain.onEvent = { event in
        switch event {
        case .text(let piece):
            print(piece, terminator: "")
            fflush(stdout)
        case .done:
            print("\n[done]")
            brain.shutdown()
            exit(0)
        case .failed(let why):
            print("\n[failed] \(why)")
            exit(1)
        }
    }
    brain.send(arguments[2])
    RunLoop.main.run()
}
if arguments.count == 2, arguments[1] == "--heartbeat" {
    // Sends one heartbeat note about the computer as it is, on a throwaway
    // conversation, and prints the note and Clawd's raw reply.
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let watcher = ClaudeWatcher()
        watcher.start()
        let pet = Pet(unit: 4)
        let mind = Mind(senses: Senses(), watcher: watcher, chat: ChatController(pet: pet), chattiness: .chatty)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                let note = mind.currentSnapshot()
                print(note + "\n----")
                let brain = Brain()
                brain.systemPrompt = mind.systemPrompt
                var reply = ""
                brain.onEvent = { event in
                    switch event {
                    case .text(let piece): reply += piece
                    case .done, .failed:
                        print(reply)
                        brain.shutdown()
                        // Leave no trace of the throwaway conversation.
                        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
                        for folder in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] {
                            try? FileManager.default.removeItem(at: projects.appendingPathComponent("\(folder)/\(brain.sessionID).jsonl"))
                        }
                        exit(0)
                    }
                }
                brain.send(note)
            }
        }
    }
    RunLoop.main.run()
}
if arguments.count == 4, arguments[1] == "--bubble" {
    // Renders a speech bubble holding the given text, to check wrapping.
    let view = SpeechView(frame: NSRect(origin: .zero, size: SpeechView.size(for: arguments[3])))
    view.text = arguments[3]
    view.tailX = view.bounds.width / 2
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
    exit(0)
}
if arguments.count == 4, arguments[1] == "--frames" {
    try Tools.writeFrames(to: arguments[2], unit: CGFloat(Double(arguments[3]) ?? 6))
    exit(0)
}
if arguments.count == 3, arguments[1] == "--iconset" {
    try Tools.writeIconset(to: arguments[2])
    exit(0)
}
if arguments.count >= 3, arguments[1] == "--sheet" {
    try Tools.writeSheet(to: arguments[2], unit: arguments.count > 3 ? CGFloat(Double(arguments[3]) ?? 7) : 7)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
