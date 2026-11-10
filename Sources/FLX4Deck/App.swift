import AppKit

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FLX4-4Deck.log")
    private static let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
    static var echo = false

    private static let q = DispatchQueue(label: "log", qos: .utility)
    static func write(_ s: String) {
        let stamp = Date()
        q.async { append(s, stamp) }
    }
    private static func append(_ s: String, _ stamp: Date) {
        let line = "\(df.string(from: stamp))  \(s)\n"
        if echo { FileHandle.standardOutput.write(line.data(using: .utf8)!) }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Remembers which rekordbox process the 4-deck layout was loaded into, so the app can be
/// quit and reopened mid-set without losing track of the session.
enum Session {
    static var file: URL { Layouts.stateDir.appendingPathComponent("session-pid") }
    static func begin(pid: pid_t) { try? "\(pid)".write(to: file, atomically: true, encoding: .utf8) }
    static func end() { try? FileManager.default.removeItem(at: file) }
    static var pid: pid_t? { (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0) } }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let rekordboxID = "com.pioneerdj.rekordboxdj"

    let bridge = MIDIBridge()
    let overlay = OverlayController()
    var statusItem: NSStatusItem!
    var lastActive = [0, 1]
    var note: String?           // transient message for the overlay
    var noteUntil = Date.distantPast

    var rekordbox: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.rekordboxID).first
    }
    var sessionLive: Bool {
        guard let rb = rekordbox, Layouts.is4DeckInstalled else { return false }
        return Session.pid == rb.processIdentifier || Session.pid == -1
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        bridge.log = { Log.write($0) }
        bridge.verbose = UserDefaults.standard.bool(forKey: "logMIDI") || ProcessInfo.processInfo.environment["FLX4_LOG_MIDI"] != nil
        do { try bridge.start() } catch {
            alert("MIDI could not start", error.localizedDescription); NSApp.terminate(nil); return
        }
        Log.write("app started")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu

        overlay.onSelectDeck = { [weak self] side, deck in self?.bridge.setDeck(side: side, deck: deck) }
        // The menu-bar icon can sit hidden under the notch or the pills; the banner opens the same menu.
        overlay.onBannerClick = { [weak self] in
            self?.statusItem.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        overlay.show(UserDefaults.standard.object(forKey: "overlayVisible") as? Bool ?? true)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }

        if let rb = rekordbox {
            if Layouts.is4DeckInstalled && Session.pid == rb.processIdentifier {
                Log.write("resuming 4-deck session with rekordbox pid \(rb.processIdentifier)")
            } else {
                show("rekordbox is open in 2-channel mode — quit it, then use Start 4-Deck Session", for: 12)
            }
        } else {
            if Layouts.is4DeckInstalled || Layouts.hardwareLeftRenamed {
                Log.write("cleaning up an unfinished session"); try? Layouts.restore2Channel()
            }
            startSession()
        }
    }

    // MARK: session

    @objc func startSession() {
        if rekordbox != nil {
            if sessionLive { show("4-deck session already running"); return }
            alert("Quit rekordbox first", "rekordbox detects controllers only at launch. Quit rekordbox, then choose Start 4-Deck Session again.")
            return
        }
        do { try Layouts.install4Deck() } catch {
            alert("Could not start 4-deck mode", error.localizedDescription); return
        }
        Session.begin(pid: -1)   // bound to the real pid once rekordbox launches
        Log.write("FLX4 renamed for the session, launching rekordbox")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.rekordboxID) else {
            alert("rekordbox not found", "Install rekordbox, then try again."); restore(); return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] app, error in
            DispatchQueue.main.async {
                if let app { Session.begin(pid: app.processIdentifier) }
                if let error { self?.alert("rekordbox failed to launch", error.localizedDescription); self?.restore() }
            }
        }
        show("Starting rekordbox in 4-deck mode…", for: 6)
    }

    @objc func restore() {
        do {
            try Layouts.restore2Channel(); Session.end()
            Log.write("FLX4 restored to normal (DDJ-FLX4)")
            show(rekordbox != nil ? "FLX4 back to normal — restart rekordbox for 2-channel mode" : "FLX4 back to normal", for: 6)
        } catch { alert("Could not restore the FLX4", error.localizedDescription) }
    }

    @objc func appLaunched(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.rekordboxID, Session.pid == -1 else { return }
        Session.begin(pid: app.processIdentifier)
    }

    @objc func appTerminated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.rekordboxID else { return }
        Log.write("rekordbox quit")
        restore()
        NSApp.terminate(nil)  // session over; the FLX4 is back to normal 2-channel use
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if sessionLive {
            let a = NSAlert()
            a.messageText = "rekordbox is still running in 4-deck mode"
            a.informativeText = "Quitting stops FLX4 control until rekordbox is restarted. The FLX4 goes back to normal 2-channel mode for the next rekordbox launch."
            a.addButton(withTitle: "Quit"); a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ n: Notification) {
        try? Layouts.restore2Channel(); Session.end()
        Log.write("app quit")
    }

    // MARK: UI refresh

    func tick() {
        let s = bridge.snapshot()
        for side in 0...1 where s.active[side] != lastActive[side] { overlay.flash(side) }
        lastActive = s.active
        var m = OverlayModel()
        m.active = s.active
        m.decks = s.decks
        m.pickup = s.pickup.map { $0.keys.sorted().compactMap { RouterCore.keyNames[$0] } }
        m.status = statusText()
        overlay.model = m
        overlay.updateHover()
        statusItem.button?.title = "\(s.active[0] + 1)|\(s.active[1] + 1)"
    }

    func statusText() -> String? {
        if Date() < noteUntil, let note { return note }
        if !bridge.hardwareConnected { return "DDJ-FLX4 not connected" }
        if rekordbox == nil { return "rekordbox not running" }
        if !sessionLive { return "rekordbox is in 2-channel mode — quit it, then click here: Start 4-Deck Session" }
        return nil
    }

    func show(_ s: String, for seconds: TimeInterval = 3) { note = s; noteUntil = Date().addingTimeInterval(seconds) }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = bridge.snapshot()
        for (side, name) in ["Left", "Right"].enumerated() {
            for deck in [side, side + 2] {
                let i = NSMenuItem(title: "\(name) side → Deck \(deck + 1)", action: #selector(pickDeck(_:)), keyEquivalent: "")
                i.tag = side * 10 + deck; i.target = self; i.state = s.active[side] == deck ? .on : .off
                menu.addItem(i)
            }
            menu.addItem(.separator())
        }
        let ov = NSMenuItem(title: "Show Overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        ov.target = self; ov.state = overlay.visible ? .on : .off; menu.addItem(ov)
        let pos = NSMenuItem(title: "Overlay Position", action: nil, keyEquivalent: ""); let pm = NSMenu()
        for (title, p) in [("Beside Notch", OverlayController.Placement.notch), ("Free (drag anywhere)", .free)] {
            let i = NSMenuItem(title: title, action: #selector(pickPlacement(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = p.rawValue; i.state = overlay.placement == p ? .on : .off; pm.addItem(i)
        }
        pos.submenu = pm; menu.addItem(pos)
        let sz = NSMenuItem(title: "Overlay Size", action: nil, keyEquivalent: ""); let sm = NSMenu()
        for (title, v) in OverlayController.sizes {
            let i = NSMenuItem(title: title, action: #selector(pickSize(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = v; i.state = abs(overlay.scale - v) < 0.01 ? .on : .off; sm.addItem(i)
        }
        sz.submenu = sm; menu.addItem(sz)
        menu.addItem(.separator())
        add(menu, sessionLive ? "4-Deck Session Running" : "Start 4-Deck Session (launch rekordbox)", sessionLive ? nil : #selector(startSession))
        add(menu, "Restore FLX4 to 2-Channel Mode", #selector(restore))
        let lm = NSMenuItem(title: "Log MIDI Messages", action: #selector(toggleMIDILog), keyEquivalent: "")
        lm.target = self; lm.state = bridge.verbose ? .on : .off; menu.addItem(lm)
        add(menu, "Open Log", #selector(openLog))
        add(menu, "Open rekordbox Mappings Folder", #selector(openMappings))
        menu.addItem(.separator())
        add(menu, "Help: SHIFT+CUE swaps a side · MASTER CUE swaps both", nil)
        menu.addItem(.separator())
        add(menu, "Quit FLX4 4Deck", #selector(NSApplication.terminate(_:)), target: NSApp)
    }

    private func add(_ m: NSMenu, _ title: String, _ sel: Selector?, target: AnyObject? = nil) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = target ?? self; i.isEnabled = sel != nil; m.addItem(i)
    }

    @objc func pickDeck(_ i: NSMenuItem) { bridge.setDeck(side: i.tag / 10, deck: i.tag % 10) }
    @objc func toggleOverlay() {
        overlay.show(!overlay.visible)
        UserDefaults.standard.set(overlay.visible, forKey: "overlayVisible")
    }
    @objc func pickPlacement(_ i: NSMenuItem) {
        overlay.placement = OverlayController.Placement(rawValue: i.representedObject as? String ?? "") ?? .notch
    }
    @objc func pickSize(_ i: NSMenuItem) {
        overlay.scale = i.representedObject as? CGFloat ?? 1
    }
    @objc func toggleMIDILog() {
        bridge.verbose.toggle()
        UserDefaults.standard.set(bridge.verbose, forKey: "logMIDI")
        Log.write("MIDI logging \(bridge.verbose ? "on" : "off")")
    }
    @objc func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc func openMappings() { NSWorkspace.shared.open(Layouts.rbDir) }

    func alert(_ title: String, _ text: String) {
        Log.write("ALERT \(title): \(text)")
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
}
