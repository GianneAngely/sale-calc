import Cocoa
import WebKit

// Borderless window: only the gadget is visible
final class GadgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Clicking the gadget body (not a button or the screen) drags the window
final class GadgetView: WKWebView {
    var dragOK = false
    override func mouseDown(with event: NSEvent) {
        if dragOK { window?.performDrag(with: event) } else { super.mouseDown(with: event) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate {
    let size = NSSize(width: 336, height: 639) // gadget size in points, +56 leaves room for its shadow
    let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Gadget"
    var window: GadgetWindow!
    var web: GadgetView!
    var activity: NSObjectProtocol?
    var timers: [String: DispatchSourceTimer] = [:]
    var sounds: [String: NSSound] = [:]

    func applicationDidFinishLaunching(_ note: Notification) {
        // App Nap would delay the native alarm timers, so keep it off while the app runs
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Alarms")
        buildMenu()

        let config = WKWebViewConfiguration()
        for handler in ["drag", "alarm", "save"] { config.userContentController.add(self, name: handler) }
        config.mediaTypesRequiringUserActionForPlayback = []
        #if SNAPSHOT
        debugConfig(config)
        #endif
        web = GadgetView(frame: .zero, configuration: config)
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        #if SNAPSHOT
        web.navigationDelegate = self
        #endif

        window = GadgetWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.title = name
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("Main")
        window.setContentSize(size)

        let page = Bundle.main.url(forResource: "index", withExtension: "html")!
        web.loadHTMLString((try? String(contentsOf: page, encoding: .utf8)) ?? "", baseURL: URL(string: "https://\(Bundle.main.bundleIdentifier ?? "gadget").local/"))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildMenu() {
        let app = NSMenu()
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Close Window", action: #selector(closeWindow), keyEquivalent: "w").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit") // copy and paste in text fields
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = NSMenu()
        for menu in [app, edit] {
            let item = NSMenuItem()
            item.submenu = menu
            NSApp.mainMenu?.addItem(item)
        }
    }

    // Closing only hides the window so alarms keep running; click the Dock icon to bring it back
    @objc func closeWindow() { window.orderOut(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // The page asks for the camera (macOS still shows its own permission prompt once)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "drag": web.dragOK = message.body as? Bool ?? false
        case "save": save(message.body as? [String: Any] ?? [:])
        case "log": print(message.body)
        default: alarm(message.body as? [String: Any] ?? [:])
        }
    }

    // Writes a data URL from the page into ~/Pictures/<app name>/
    func save(_ m: [String: Any]) {
        guard let file = m["name"] as? String, let data = m["data"] as? String, let comma = data.firstIndex(of: ","),
              let bytes = Data(base64Encoded: String(data[data.index(after: comma)...])) else { return }
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? bytes.write(to: dir.appendingPathComponent((file as NSString).lastPathComponent))
        print("saved \(file)")
    }

    // One wall-clock alarm per kind: stays on time while the window is hidden or after the Mac sleeps
    func alarm(_ m: [String: Any]) {
        guard let kind = m["kind"] as? String else { return }
        if m["stop"] as? Bool == true { sounds[kind]?.stop() }
        timers[kind]?.cancel()
        timers[kind] = nil
        let t = (m["endAt"] as? Double ?? 0) / 1000, loop = m["loop"] as? Bool ?? false
        let wait = t - Date().timeIntervalSince1970
        print("alarm \(kind) \(t > 0 ? String(format: "%.1fs", wait) : "off")")
        guard t > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + max(0, wait), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.ring(kind, loop: loop) }
        timer.resume()
        timers[kind] = timer
    }

    func ring(_ kind: String, loop: Bool) {
        timers[kind]?.cancel()
        timers[kind] = nil
        print("ring \(kind)")
        if let url = Bundle.main.url(forResource: kind, withExtension: "wav"), let sound = NSSound(contentsOf: url, byReference: true) {
            sounds[kind]?.stop()
            sound.loops = loop
            sound.play()
            sounds[kind] = sound
            if loop { DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak sound] in sound?.stop() } }
        }
        _ = NSApp.requestUserAttention(.informationalRequest)
    }
}

#if SNAPSHOT
// Debug build (./build.sh --snapshot): logs JS errors, runs JS from APP_JS, hides the window with APP_HIDE,
// and saves a webview snapshot to APP_SNAPSHOT. Handy for testing without Screen Recording permission.
extension AppDelegate: WKNavigationDelegate {
    func debugConfig(_ config: WKWebViewConfiguration) {
        setvbuf(stdout, nil, _IOLBF, 0)
        config.userContentController.add(self, name: "log")
        config.userContentController.addUserScript(WKUserScript(source: """
            addEventListener('error', e => webkit.messageHandlers.log.postMessage('JS error: ' + e.message));
            const ce = console.error;
            console.error = (...a) => { webkit.messageHandlers.log.postMessage('console.error: ' + a.join(' ')); ce(...a); };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let env = ProcessInfo.processInfo.environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if let js = env["APP_JS"] { webView.evaluateJavaScript(js) { r, e in print("js:", r ?? "nil", e.map { "\($0)" } ?? "") } }
            if env["APP_HIDE"] != nil { self.window.orderOut(nil) }
            guard let out = env["APP_SNAPSHOT"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["APP_WAIT"] ?? "") ?? 1)) {
                webView.takeSnapshot(with: nil) { image, _ in
                    guard let tiff = image?.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return print("snapshot failed") }
                    try? png.write(to: URL(fileURLWithPath: out))
                    print("snapshot saved")
                }
            }
        }
    }
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
