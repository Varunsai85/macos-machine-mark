import AppKit
import Carbon.HIToolbox
import WebKit

// Machine Mark for macOS: an "About this Mac" that draws the machine as a
// sigil of dots you can knead into a strip and back. It lives in the menu
// bar; ⌃⌥⌘A or the menu opens the window. The drawing is web/ (sigil.js and
// card.js) in a web view; this file is the window, the menu bar item, the
// hotkey and the bridge that hands the page what Collector reads.

// `MachineMark --dump` prints one reading and exits (for checking the facts).
if CommandLine.arguments.contains("--dump") {
    let app = NSApplication.shared
    _ = app
    let m = Collector.read(frontmost: nil, look: Palette.look())
    let d = try! JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(d)
    print()
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    var status: NSStatusItem!
    var pageReady = false
    var machineJSON: String?
    var reading = false
    var readAgain = false
    var liveTimer: Timer?
    var hotKey: EventHotKeyRef?
    // The app the user was in before opening (the Apps ring marks it).
    var cameFrom: URL?
    var appearanceWatch: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenus()
        buildStatusItem()
        buildWindow()
        registerHotKey()

        // Track the last app in front other than this one.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app != .current { self?.cameFrom = app.bundleURL }
        }
        cameFrom = NSWorkspace.shared.frontmostApplication?.bundleURL

        // Light/dark mode and the accent colour: new colours, and a new reading
        // (the Look ring shows them).
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in DispatchQueue.main.async { self?.themeChanged() } }
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.themeChanged() }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("AppleColorPreferencesChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.themeChanged() }
        }

        // Read once soon after launch, so the first opening has the facts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in if self?.machineJSON == nil { self?.read() } }
        // Launched from Spotlight, Finder or the Dock: open the window straight
        // away. `--background` starts it in the menu bar only.
        if !CommandLine.arguments.contains("--background") { open() }
    }

    // Opened again while running (Spotlight, Finder, `open -a`): show the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        open()
        return true
    }

    func applicationDidBecomeActive(_ n: Notification) {
        if !window.isVisible && !window.isMiniaturized { open() }
    }

    // ------------------------------------------------------------ window

    func buildWindow() {
        let size = NSSize(width: 1180, height: 720)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "About This Mac"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 560)
        window.delegate = self
        window.backgroundColor = Palette.background(dark: Palette.look().dark)
        window.setFrameAutosaveName("MachineMark")
        if !window.setFrameUsingName("MachineMark") { window.center() }

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "mark")
        web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.autoresizingMask = [.width, .height]
        content.addSubview(web)
        // The page fills the title bar; this strip keeps it draggable.
        let grip = DragStrip(frame: NSRect(x: 80, y: size.height - 28, width: size.width - 80, height: 28))
        grip.autoresizingMask = [.width, .minYMargin]
        content.addSubview(grip)
        window.contentView = content

        if let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        }
    }

    @objc func open() {
        if window.isVisible && NSApp.isActive { window.makeKeyAndOrderFront(nil); return }
        NSApp.setActivationPolicy(.regular)
        sendPalette()
        call("MachineMark.opened()")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        read()
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.readLive() }
    }

    @objc func toggle() { window.isVisible && NSApp.isActive ? window.performClose(nil) : open() }

    func windowWillClose(_ n: Notification) {
        liveTimer?.invalidate(); liveTimer = nil
        call("MachineMark.closed()")
        NSApp.setActivationPolicy(.accessory)
        // Hand focus back to the app the user came from, so the next launch
        // from Spotlight activates this one again (and opens the window).
        DispatchQueue.main.async { if !self.window.isVisible { NSApp.hide(nil) } }
    }

    func windowDidMiniaturize(_ n: Notification) { call("MachineMark.closed()") }
    func windowDidDeminiaturize(_ n: Notification) { call("MachineMark.resumed()") }

    // ------------------------------------------------------------ bridge

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            pageReady = true
            sendPalette()
            if let m = machineJSON { call("MachineMark.take(\(m))") }
            if window.isVisible { call("MachineMark.opened()") }
        case "close":
            window.performClose(nil)
        default: break
        }
    }

    func call(_ js: String) {
        guard pageReady else { return }
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    func json(_ o: Any) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func sendPalette() {
        window.backgroundColor = Palette.background(dark: Palette.look().dark)
        if let p = json(Palette.current()) { call("MachineMark.setPalette(\(p))") }
    }

    func themeChanged() {
        sendPalette()
        read()
    }

    // A reading asked for while one runs is queued, not dropped.
    func read() {
        if reading { readAgain = true; return }
        reading = true
        let from = cameFrom, look = Palette.look()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let s = self?.json(Collector.read(frontmost: from, look: look))
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                if let s { self.machineJSON = s; self.call("MachineMark.take(\(s))") }
                else if self.machineJSON == nil { self.call("MachineMark.error(\"Couldn't read this Mac.\")") }
                if self.readAgain { self.readAgain = false; self.read() }
            }
        }
    }

    func readLive() {
        guard window.isVisible, machineJSON != nil else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let s = self?.json(Collector.live()) else { return }
            DispatchQueue.main.async { self?.call("MachineMark.live(\(s))") }
        }
    }

    // ------------------------------------------------------------ menus

    func buildMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Machine Mark", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Machine Mark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        main.addItem(winItem)
        NSApp.mainMenu = main
    }

    func buildStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: "Machine Mark") {
            img.isTemplate = true
            status.button?.image = img
        } else {
            status.button?.title = "◎"
        }
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "About This Mac", action: #selector(open), keyEquivalent: "a")
        openItem.keyEquivalentModifierMask = [.control, .option, .command]
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Machine Mark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
    }

    // ⌃⌥⌘A, from anywhere (Carbon's hotkeys need no accessibility permission).
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x4D4D524B), id: 1)   // "MMRK"
        RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}

// A see-through strip along the top that moves the window when dragged.
final class DragStrip: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
