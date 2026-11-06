import Cocoa
import CoreImage
import Security

// MARK: - Settings

struct CameraSettings {
    var host: String
    var username: String
    var password: String
    var highQuality: Bool
    var rtspPort: Int
    var httpPort: Int

    static func load() -> CameraSettings {
        let d = UserDefaults.standard
        return CameraSettings(
            host: d.string(forKey: "host") ?? "",
            username: d.string(forKey: "username") ?? "",
            password: Keychain.read() ?? "",
            highQuality: d.object(forKey: "highQuality") as? Bool ?? true,
            rtspPort: d.object(forKey: "rtspPort") as? Int ?? 554,
            httpPort: d.object(forKey: "httpPort") as? Int ?? 80)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(host, forKey: "host")
        d.set(username, forKey: "username")
        d.set(highQuality, forKey: "highQuality")
        Keychain.write(password)
    }

    /// yi-hack-v5: ch0_0 is the 1080p stream, ch0_1 the 360p one.
    var streamPath: String { highQuality ? "ch0_0.h264" : "ch0_1.h264" }
}

enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.yicamera.viewer",
    ]

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Video view

final class VideoView: NSView {
    private let videoLayer = CALayer()
    var onMouseActivity: () -> Void = {}
    var onArrowKey: (String) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
    }

    func show(_ image: CVPixelBuffer) {
        if let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() {
            videoLayer.contents = surface
        }
    }

    func clear() { videoLayer.contents = nil }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onArrowKey("left")
        case 124: onArrowKey("right")
        case 125: onArrowKey("down")
        case 126: onArrowKey("up")
        default: super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { onMouseActivity() }
    override func mouseEntered(with event: NSEvent) { onMouseActivity() }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.toggleFullScreen(nil) }
        onMouseActivity()
    }
}

// MARK: - Window controller

final class ViewerController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let video = VideoView()
    private let stream = CameraStream()
    private var settings = CameraSettings.load()
    private var lastFrame: CVPixelBuffer?
    private var isLive = false

    private let bar = NSVisualEffectView()
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let quality = NSSegmentedControl(labels: ["HD", "SD"], trackingMode: .selectOne, target: nil, action: nil)
    private var hideTimer: Timer?
    private var flashTimer: Timer?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Yi Camera"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.minSize = NSSize(width: 480, height: 300)
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.setFrameAutosaveName("ViewerWindow")
        window.level = UserDefaults.standard.bool(forKey: "keepOnTop") ? .floating : .normal
        buildUI()

        stream.onFrame = { [weak self] image in
            self?.lastFrame = image
            self?.video.show(image)
        }
        stream.onStatus = { [weak self] in self?.update(status: $0) }
        video.onMouseActivity = { [weak self] in self?.revealBar() }
        video.onArrowKey = { [weak self] in self?.pan($0) }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.connect()
        }
    }

    private func buildUI() {
        let content = window.contentView!
        video.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(video)

        messageLabel.alignment = .center
        messageLabel.textColor = NSColor(white: 1, alpha: 0.75)
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(messageLabel)

        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12
        bar.layer?.masksToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        quality.target = self
        quality.action = #selector(qualityChanged)
        quality.selectedSegment = settings.highQuality ? 0 : 1
        quality.toolTip = "HD (1080p) or SD (360p, uses less Wi-Fi)"
        quality.controlSize = .small

        let stack = NSStackView(views: [
            statusDot, statusLabel, spacer(),
            iconButton("arrow.left", "Pan left (←)", #selector(panLeft), continuous: true),
            iconButton("arrow.up", "Tilt up (↑)", #selector(panUp), continuous: true),
            iconButton("arrow.down", "Tilt down (↓)", #selector(panDown), continuous: true),
            iconButton("arrow.right", "Pan right (→)", #selector(panRight), continuous: true),
            divider(), quality,
            iconButton("camera", "Save snapshot to Pictures (⌘S)", #selector(snapshot)),
            iconButton("gearshape", "Camera settings (⌘,)", #selector(showSettings)),
        ])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            video.topAnchor.constraint(equalTo: content.topAnchor),
            video.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            messageLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -60),

            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            bar.heightAnchor.constraint(equalToConstant: 40),
            bar.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -28),
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector, continuous: Bool = false) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        b.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        if continuous {
            b.isContinuous = true
            b.setPeriodicDelay(0.35, interval: 0.35)
        }
        return b
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.widthAnchor.constraint(greaterThanOrEqualToConstant: 12).isActive = true
        return v
    }

    private func divider() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    // MARK: Connection

    func start() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(video)
        if settings.host.isEmpty {
            update(status: .failed("No camera set up yet."))
            showSettings()
        } else {
            connect()
        }
    }

    @objc func connect() {
        guard !settings.host.isEmpty else { return }
        isLive = false
        stream.start(host: settings.host, port: settings.rtspPort, path: settings.streamPath,
                     username: settings.username, password: settings.password)
    }

    private func update(status: CameraStream.Status) {
        switch status {
        case .connecting:
            setStatus(isLive ? "Reconnecting…" : "Connecting to \(settings.host)…", .systemYellow)
            if lastFrame == nil { showMessage("Connecting to camera at \(settings.host)…") }
            isLive = false
        case .live:
            isLive = true
            setStatus("Live · \(settings.highQuality ? "1080p" : "360p")", .systemGreen)
            showMessage(nil)
            scheduleHide()
        case .failed(let text):
            isLive = false
            setStatus(text, .systemRed)
            lastFrame = nil
            video.clear()
            showMessage(settings.host.isEmpty ? "Click the gear button to enter your camera's IP address." : "\(text)\nRetrying…")
            revealBar()
        }
    }

    private func setStatus(_ text: String, _ color: NSColor) {
        flashTimer?.invalidate()
        statusLabel.stringValue = text
        statusLabel.toolTip = text
        statusDot.layer?.backgroundColor = color.cgColor
    }

    private func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = text == nil
    }

    // MARK: Overlay auto-hide

    private func revealBar() {
        NSCursor.setHiddenUntilMouseMoves(false)
        if bar.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; bar.animator().alphaValue = 1 }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self, self.isLive else { return }
            let mouse = self.bar.convert(self.window.mouseLocationOutsideOfEventStream, from: nil)
            if self.bar.bounds.contains(mouse) { self.scheduleHide(); return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self.bar.animator().alphaValue = 0 }
        }
    }

    // MARK: Actions

    @objc private func qualityChanged() {
        settings.highQuality = quality.selectedSegment == 0
        settings.save()
        lastFrame = nil
        connect()
    }

    @objc func toggleQuality() {
        quality.selectedSegment = quality.selectedSegment == 0 ? 1 : 0
        qualityChanged()
    }

    @objc private func panLeft() { pan("left") }
    @objc private func panRight() { pan("right") }
    @objc private func panUp() { pan("up") }
    @objc private func panDown() { pan("down") }

    private func pan(_ direction: String) {
        guard !settings.host.isEmpty,
              let url = URL(string: "http://\(settings.host):\(settings.httpPort)/cgi-bin/ptz.sh?dir=\(direction)&time=0.3")
        else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        if !settings.username.isEmpty {
            let token = Data("\(settings.username):\(settings.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error != nil || code != 200 else { return }
            DispatchQueue.main.async {
                self?.flash(code == 401 ? "Pan/tilt: wrong username or password" : "Pan/tilt didn't respond")
            }
        }.resume()
        revealBar()
    }

    @objc func snapshot() {
        guard let frame = lastFrame else { NSSound.beep(); return }
        let image = CIImage(cvPixelBuffer: frame)
        let context = CIContext()
        guard let cg = context.createCGImage(image, from: image.extent),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Yi Camera")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = folder.appendingPathComponent("Snapshot \(f.string(from: Date())).png")
        do {
            try png.write(to: file)
            flash("Saved to Pictures › Yi Camera")
        } catch {
            flash("Couldn't save snapshot")
        }
    }

    private func flash(_ text: String) {
        let previous = (statusLabel.stringValue, statusDot.layer?.backgroundColor)
        statusLabel.stringValue = text
        revealBar()
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.statusLabel.stringValue = previous.0
            self?.statusDot.layer?.backgroundColor = previous.1
        }
    }

    @objc func toggleKeepOnTop(_ sender: NSMenuItem) {
        let on = window.level != .floating
        window.level = on ? .floating : .normal
        UserDefaults.standard.set(on, forKey: "keepOnTop")
    }

    var keepsOnTop: Bool { window.level == .floating }

    @objc func showSettings() {
        if window.attachedSheet != nil { return }
        let host = NSTextField(string: settings.host)
        host.placeholderString = "e.g. 192.168.86.45"
        let user = NSTextField(string: settings.username)
        user.placeholderString = "optional"
        let pass = NSSecureTextField(string: settings.password)
        pass.placeholderString = "optional"
        for f in [host, user, pass] { f.widthAnchor.constraint(equalToConstant: 230).isActive = true }

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Camera IP address:"), host],
            [NSTextField(labelWithString: "Username:"), user],
            [NSTextField(labelWithString: "Password:"), pass],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: 82)

        let alert = NSAlert()
        alert.messageText = "Camera Settings"
        alert.informativeText = "Find the IP address in the Yi app under Camera Settings › Network Info, or on your router. Leave the username and password blank unless you set them on the camera's yi-hack web page."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = host
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var h = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["rtsp://", "http://", "https://"] where h.lowercased().hasPrefix(prefix) { h = String(h.dropFirst(prefix.count)) }
            h = h.components(separatedBy: "/")[0]
            self.settings.host = h
            self.settings.username = user.stringValue.trimmingCharacters(in: .whitespaces)
            self.settings.password = pass.stringValue
            self.settings.save()
            self.lastFrame = nil
            if h.isEmpty {
                self.stream.stop()
                self.update(status: .failed("No camera set up yet."))
            } else {
                self.connect()
            }
        }
    }

    func windowWillClose(_ notification: Notification) { stream.stop() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var viewer: ViewerController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewer = ViewerController()
        NSApp.mainMenu = buildMenu()
        viewer.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleKeepOnTop(_:)) { item.state = viewer.keepsOnTop ? .on : .off }
        return true
    }

    @objc func showSettings() { viewer.showSettings() }
    @objc func reconnect() { viewer.connect() }
    @objc func snapshot() { viewer.snapshot() }
    @objc func toggleQuality() { viewer.toggleQuality() }
    @objc func toggleKeepOnTop(_ sender: NSMenuItem) { viewer.toggleKeepOnTop(sender) }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let holder = NSMenuItem()
            holder.submenu = m
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        add("Yi Camera", [
            item("About Yi Camera", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(showSettings), ","),
            .separator(),
            item("Hide Yi Camera", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Yi Camera", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("Camera", [
            item("Save Snapshot", #selector(snapshot), "s"),
            item("Reconnect", #selector(reconnect), "r"),
            item("Switch HD / SD", #selector(toggleQuality), "d"),
        ])
        add("View", [
            item("Keep on Top", #selector(toggleKeepOnTop(_:)), "t"),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
