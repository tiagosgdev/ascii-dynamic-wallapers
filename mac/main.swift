import Carbon.HIToolbox
import Cocoa
import WebKit

// Hosts a web scene behind the desktop icons, one window per display, and
// forwards the global cursor, desktop clicks and scrolling into the page.

private let agentLabel = "com.local.asciiwallpapers"
private let sceneKey = "scene"

private struct Scene: Decodable {
    let id: String       // file name in web/, without .html
    let title: String
    let stillJS: String?  // renders the lock screen frame as a PNG data URL; nil leaves
                          // the lock screen and saver alone while a scene is unfinished
}

/// The scene list is shared between platforms and lives in web/scenes.json.
private let scenes: [Scene] = {
    guard let url = Bundle.main.url(forResource: "scenes", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let list = try? JSONDecoder().decode([Scene].self, from: data), !list.isEmpty else {
        fatalError("scenes.json is missing or invalid")
    }
    return list
}()

/// This machine's CFG overrides per scene, from the optional
/// ~/.config/ascii-wallpapers/config.json. They reach the page as URL parameters.
private let sceneOverrides: [String: [URLQueryItem]] = {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ascii-wallpapers/config.json")
    guard let data = try? Data(contentsOf: url) else { return [:] }
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let all = root["overrides"] as? [String: [String: Any]] else {
        NSLog("ASCII Wallpapers: ignoring invalid %@", url.path)
        return [:]
    }
    return all.mapValues { values in
        values.keys.sorted().map { URLQueryItem(name: $0, value: "\(values[$0]!)") }
    }
}()

private let saverName = "ASCII Wallpapers.saver"

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

final class Wall: NSObject, WKNavigationDelegate {
    private(set) var screen: NSScreen
    let window: NSWindow
    let web: WKWebView
    private let onLoad: (Wall) -> Void

    init(screen: NSScreen, page: URL, onLoad: @escaping (Wall) -> Void) {
        self.screen = screen
        self.onLoad = onLoad
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)

        web = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: WKWebViewConfiguration())
        web.autoresizingMask = [.width, .height]
        super.init()
        web.navigationDelegate = self
        load(page)
        window.contentView = web
        window.orderFront(nil)
    }

    func load(_ page: URL) {
        // .path leaves out any override parameters on the page's URL.
        web.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: page.path).deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoad(self) }

    func call(_ js: String) { web.evaluateJavaScript(js, completionHandler: nil) }

    /// Cursor position as 0-1 fractions of this display, top-left origin.
    func normalized(_ p: NSPoint) -> (Double, Double) {
        let f = screen.frame
        return (Double((p.x - f.minX) / f.width), Double(1 - (p.y - f.minY) / f.height))
    }

    func close() { window.orderOut(nil); window.close() }

    /// Takes over the new NSScreen object if it is still the same display at the same
    /// size and scale, which means the running page can carry on untouched.
    func adopt(_ other: NSScreen) -> Bool {
        guard other.displayID == screen.displayID, other.frame == screen.frame,
              other.backingScaleFactor == screen.backingScaleFactor else { return false }
        screen = other
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var walls: [Wall] = []
    private var status: NSStatusItem!
    private var sceneItems: [NSMenuItem] = []
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var paused = false
    private var lastCursor = NSPoint(x: -1, y: -1)
    private var pointerTimer: Timer?
    private var hotKey: EventHotKeyRef?
    private var sceneIndex = 0
    private var pressedWall: Wall?

    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    private var currentPage: URL {
        guard let url = Bundle.main.url(forResource: scenes[sceneIndex].id, withExtension: "html") else {
            fatalError("\(scenes[sceneIndex].id).html missing from app bundle")
        }
        guard let items = sceneOverrides[scenes[sceneIndex].id], !items.isEmpty,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.queryItems = items
        return parts.url ?? url
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let saved = UserDefaults.standard.string(forKey: sceneKey) ?? "pond"
        sceneIndex = scenes.firstIndex { $0.id == saved } ?? 0

        syncWalls()
        buildMenu()
        registerHotKey()
        syncSaver()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Polling the cursor needs no permissions and also works over other apps.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tickPointer() }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.desktopClick() }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.desktopRelease() }
        NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self?.desktopScroll(e) }
    }

    // MARK: Walls and scenes

    /// Gives each display a wall, leaving alone any wall whose display hasn't changed.
    @objc private func syncWalls() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        var spare = walls
        walls = screens.map { screen in
            if let i = spare.firstIndex(where: { $0.adopt(screen) }) { return spare.remove(at: i) }
            return Wall(screen: screen, page: currentPage) { [weak self] wall in
                if self?.paused == true { wall.call("ascii.setPaused(true)") }
                self?.applyStill(to: wall)
            }
        }
        spare.forEach { $0.close() }
    }

    /// macOS posts this in bursts, dozens at a time around display sleep and wake, and
    /// usually nothing has really changed. So wait for it to go quiet, then compare.
    @objc private func screensChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(syncWalls), object: nil)
        perform(#selector(syncWalls), with: nil, afterDelay: 1)
    }

    private func wall(at p: NSPoint) -> Wall? {
        walls.first { NSMouseInRect(p, $0.screen.frame, false) }
    }

    private func setScene(_ index: Int) {
        guard index != sceneIndex else { return }
        sceneIndex = index
        UserDefaults.standard.set(scenes[index].id, forKey: sceneKey)
        updateSceneChecks()
        lastCursor = NSPoint(x: -1, y: -1)
        walls.forEach { $0.load(currentPage) }
        syncSaver()
    }

    // MARK: Lock screen and screen saver

    private var stillsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ASCII Wallpapers/Stills")
    }

    /// Makes the system wallpaper, which the lock screen shows, a still of the current scene.
    private func applyStill(to wall: Wall) {
        let scene = scenes[sceneIndex]
        guard let stillJS = scene.stillJS else { return }
        let fm = FileManager.default
        let modified = (try? fm.attributesOfItem(atPath: currentPage.path)[.modificationDate] as? Date) ?? .distantPast
        let px = wall.screen.frame.size, scale = wall.screen.backingScaleFactor
        // The page's date is in the name so a rebuilt scene gets a fresh image.
        let prefix = "\(scene.id)-\(Int(px.width * scale))x\(Int(px.height * scale))-"
        // Overrides change how the scene looks, so they get a fresh image too.
        let overrides = currentPage.query.map { q in "-\(q.utf8.reduce(5381 as UInt32) { $0 &* 33 &+ UInt32($1) })" } ?? ""
        let url = stillsDir.appendingPathComponent("\(prefix)\(Int(modified.timeIntervalSince1970))\(overrides).png")

        if fm.fileExists(atPath: url.path) {
            publishStill(url, on: wall.screen)
            return
        }
        wall.web.evaluateJavaScript(stillJS) { [weak self] result, _ in
            guard let self, let text = result as? String, let comma = text.firstIndex(of: ","),
                  let png = Data(base64Encoded: String(text[text.index(after: comma)...])) else { return }
            self.saverQueue.async {
                try? fm.createDirectory(at: self.stillsDir, withIntermediateDirectories: true)
                let old = (try? fm.contentsOfDirectory(at: self.stillsDir, includingPropertiesForKeys: nil)) ?? []
                old.filter { $0.lastPathComponent.hasPrefix(prefix) }.forEach { try? fm.removeItem(at: $0) }
                guard (try? png.write(to: url)) != nil else { return }
                DispatchQueue.main.async {
                    if scenes[self.sceneIndex].id == scene.id { self.publishStill(url, on: wall.screen) }
                }
            }
        }
    }

    /// The lock screen shows the system wallpaper, but setting that through the API
    /// also resets the chosen screen saver. So it is set only once, to a fixed file;
    /// after that just the file changes and the wallpaper service reloads it.
    private func publishStill(_ still: URL, on screen: NSScreen) {
        let scale = screen.backingScaleFactor
        let name = "LockScreen-\(Int(screen.frame.width * scale))x\(Int(screen.frame.height * scale)).png"
        let lock = stillsDir.deletingLastPathComponent().appendingPathComponent(name)
        saverQueue.async {
            guard let data = try? Data(contentsOf: still) else { return }
            let changed = (try? Data(contentsOf: lock)) != data
            if changed {
                guard (try? data.write(to: lock, options: .atomic)) != nil else { return }
            }
            DispatchQueue.main.async {
                let installedKey = "installed-\(name)"
                if !UserDefaults.standard.bool(forKey: installedKey) {
                    UserDefaults.standard.set(true, forKey: installedKey)
                    self.setSystemWallpaper(lock, on: screen)
                } else if changed {
                    self.reloadWallpaperService()
                }
            }
        }
    }

    /// The service restarts by itself and re-reads the wallpaper file when it does.
    private func reloadWallpaperService() {
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["WallpaperAgent"]
        restart.standardOutput = FileHandle.nullDevice
        restart.standardError = FileHandle.nullDevice
        try? restart.run()
    }

    private func setSystemWallpaper(_ url: URL, on screen: NSScreen) {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }

    private let saverQueue = DispatchQueue(label: "ascii.saver")

    /// Installs the screen saver if needed and points it at the current scene.
    private func syncSaver() {
        guard scenes[sceneIndex].stillJS != nil else { return }
        let sceneID = scenes[sceneIndex].id
        saverQueue.async {
            let fm = FileManager.default
            guard let source = Bundle.main.url(forResource: saverName, withExtension: nil) else { return }
            let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers")
            let dest = folder.appendingPathComponent(saverName)
            let version: (URL) -> String? = {
                (NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"]) as? String
            }
            if version(source) != version(dest) {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                guard (try? fm.copyItem(at: source, to: dest)) != nil else { return }
            }
            let sceneFile = dest.appendingPathComponent("Contents/Resources/scene.txt")
            guard (try? sceneID.write(to: sceneFile, atomically: true, encoding: .utf8)) != nil else { return }

            // Changing a file inside the bundle invalidates its signature, so re-seal it.
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", dest.path]
            sign.standardOutput = FileHandle.nullDevice
            sign.standardError = FileHandle.nullDevice
            try? sign.run()
            sign.waitUntilExit()
        }
    }

    fileprivate func nextScene() { setScene((sceneIndex + 1) % scenes.count) }

    @objc private func selectScene(_ item: NSMenuItem) { setScene(item.tag) }

    private func updateSceneChecks() {
        for (i, item) in sceneItems.enumerated() { item.state = i == sceneIndex ? .on : .off }
    }

    // MARK: Input

    private func tickPointer() {
        guard !paused else { return }
        let p = NSEvent.mouseLocation
        guard p != lastCursor, let w = wall(at: p) else { return }
        lastCursor = p
        let (x, y) = w.normalized(p)
        w.call("window.ascii&&ascii.pointer(\(x),\(y))")
    }

    /// True when the point is on bare desktop: not the menu bar, Dock or any window.
    private func isOverDesktop(_ p: NSPoint, on w: Wall) -> Bool {
        guard NSMouseInRect(p, w.screen.visibleFrame, false) else { return false }
        guard let primary = NSScreen.screens.first else { return false }
        let topLeft = CGPoint(x: p.x, y: primary.frame.maxY - p.y)
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return false }
        for info in list {
            // Dock (20) and menu bar (24) overlays span the screen, so only normal
            // and floating layers count as covering the desktop.
            guard let layer = info[kCGWindowLayer as String] as? Int, (0..<20).contains(layer),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict)
            else { continue }
            if rect.contains(topLeft) { return false }
        }
        return true
    }

    private func desktopClick() {
        guard !paused else { return }
        let p = NSEvent.mouseLocation
        guard let w = wall(at: p), isOverDesktop(p, on: w) else { return }
        let (x, y) = w.normalized(p)
        pressedWall = w
        w.call("window.ascii&&ascii.click(\(x),\(y))")
    }

    private func desktopRelease() {
        pressedWall?.call("window.ascii&&ascii.release&&ascii.release()")
        pressedWall = nil
    }

    private func desktopScroll(_ e: NSEvent) {
        guard !paused else { return }
        let p = NSEvent.mouseLocation
        guard let w = wall(at: p), isOverDesktop(p, on: w) else { return }
        let dy = e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 12)
        w.call("window.ascii&&ascii.scroll(\(dy))")
    }

    // MARK: Hotkey

    /// Control-Option-W cycles wallpapers. Carbon hotkeys need no extra permissions.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue().nextScene()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: 0x41534349, id: 1),
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    // MARK: Menu

    private func buildMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "@"
        status.button?.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)

        let menu = NSMenu()
        for (i, scene) in scenes.enumerated() {
            let item = NSMenuItem(title: scene.title, action: #selector(selectScene(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            menu.addItem(item)
            sceneItems.append(item)
        }
        updateSceneChecks()

        let next = NSMenuItem(title: "Next Wallpaper", action: #selector(nextFromMenu), keyEquivalent: "w")
        next.keyEquivalentModifierMask = [.control, .option]
        next.target = self
        menu.addItem(next)
        menu.addItem(.separator())

        pauseItem = NSMenuItem(title: "Pause Animation", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = FileManager.default.fileExists(atPath: agentURL.path) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ASCII Wallpapers", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = menu
    }

    @objc private func nextFromMenu() { nextScene() }

    @objc private func togglePause() {
        paused.toggle()
        pauseItem.title = paused ? "Resume Animation" : "Pause Animation"
        walls.forEach { $0.call("window.ascii&&ascii.setPaused(\(paused))") }
    }

    @objc private func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: agentURL.path) {
            try? fm.removeItem(at: agentURL)
            loginItem.state = .off
            return
        }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [Bundle.main.executablePath ?? ""],
            "RunAtLoad": true,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: agentURL)) != nil { loginItem.state = .on }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
