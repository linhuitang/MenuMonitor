import SwiftUI
import AppKit

@main
struct MenuMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No MenuBarExtra — status item owned by AppDelegate.
        // Keep a Settings scene so SwiftUI App lifecycle stays alive without a Dock icon
        // (LSUIElement=true in Info.plist).
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = SystemMonitor()
    private let theme = ThemeStore()
    private var settingsObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var iconObs: NSKeyValueObservation?
    private var iconTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--render-label-preview"),
           args.count > idx + 1 {
            let path = args[idx + 1]
            let pct: Double
            if let pIdx = args.firstIndex(of: "--percent"), args.count > pIdx + 1,
               let v = Double(args[pIdx + 1]) {
                pct = v
            } else {
                pct = 73
            }
            let image = SystemMonitor.makeMemBadge(percent: pct)
            Self.writePNG(image: image, to: path)
            print("preview=\(path) size=\(image.size.width)x\(image.size.height) template=\(image.isTemplate)")
            NSApp.terminate(nil)
            return
        }

        if let idx = args.firstIndex(of: "--render-panel-preview"),
           args.count > idx + 1 {
            let path = args[idx + 1]
            let tab = Self.tab(from: args)
            Self.renderPanelPreview(monitor: monitor, to: path, scheme: Self.scheme(from: args), tab: tab)
            NSApp.terminate(nil)
            return
        }

        if args.contains("--clean-dry-run") {
            let m = SystemMonitor()
            let deadline = Date().addingTimeInterval(3)
            while m.junkBytes == 0 && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            print("junkBefore=\(m.junkBytes) (\(SystemMonitor.formatBytes(m.junkBytes)))")
            var lastPct = -1
            var lastStatus = ""
            let t0 = Date()
            m.cleanCaches(dryRun: true)
            // Wait for progress animation + done hold (status clears when fully done).
            let cleanDeadline = Date().addingTimeInterval(120)
            while Date() < cleanDeadline {
                let pct = Int((m.cleanProgress * 100).rounded())
                let status = m.cleanStatusMessage ?? ""
                if pct != lastPct || status != lastStatus {
                    let elapsed = Date().timeIntervalSince(t0)
                    print(String(format: "t=%.2fs progress=%d%% status=%@", elapsed, pct, status))
                    lastPct = pct
                    lastStatus = status
                }
                if !m.isCleaning && m.cleanProgress == 0 && m.cleanStatusMessage == nil && Date().timeIntervalSince(t0) > 0.5 {
                    break
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            print(String(format: "elapsed=%.2fs", Date().timeIntervalSince(t0)))
            print("junkAfter=\(m.junkBytes) (\(SystemMonitor.formatBytes(m.junkBytes)))")
            print("status=\(m.cleanStatusMessage ?? "nil")")
            print("dryRun=OK (no files deleted)")
            NSApp.terminate(nil)
            return
        }

        if args.contains("--print-temp") {
            let m = SystemMonitor()
            if let t = m.cpuTemp {
                print(String(format: "cpuTemp=%.1f", t))
            } else {
                print("cpuTemp=nil")
            }
            NSApp.terminate(nil)
            return
        }

        if let idx = args.firstIndex(of: "--snapshot-header"),
           args.count > idx + 1 {
            let path = args[idx + 1]
            Self.snapshotLiveHeader(monitor: monitor, to: path)
            NSApp.terminate(nil)
            return
        }

        if let idx = args.firstIndex(of: "--snapshot-panel"),
           args.count > idx + 1 {
            let path = args[idx + 1]
            Self.snapshotLivePanel(monitor: monitor, to: path)
            NSApp.terminate(nil)
            return
        }

        if args.contains("--print-status-menu") {
            for item in makeStatusMenu().items {
                print(item.isSeparatorItem ? "---" : "\(item.title) [\(item.keyEquivalent)]")
            }
            NSApp.terminate(nil)
            return
        }

        if args.contains("--test-login-item") {
            print("before=\(LoginItem.status.rawValue) \(LoginItem.statusText)")
            let e1 = LoginItem.set(true)
            print("afterRegister=\(LoginItem.status.rawValue) \(LoginItem.statusText) error=\(e1 ?? "nil")")
            let e2 = LoginItem.set(false)
            print("afterUnregister=\(LoginItem.status.rawValue) \(LoginItem.statusText) error=\(e2 ?? "nil")")
            NSApp.terminate(nil)
            return
        }

        if args.contains("--print-settings") {
            SettingsKey.registerDefaults()
            let d = UserDefaults.standard
            print("appearance=\(AppearanceMode.current.rawValue) refreshInterval=\(RefreshIntervalOption.current) menuBarDisplay=\(MenuBarDisplay.current.rawValue) temperatureUnit=\(d.string(forKey: SettingsKey.temperatureUnit) ?? "nil") loginItem=\(LoginItem.statusText)")
            NSApp.terminate(nil)
            return
        }

        if let idx = args.firstIndex(of: "--snapshot-settings"), args.count > idx + 1 {
            SettingsKey.registerDefaults()
            NSApp.setActivationPolicy(.accessory)
            let path = args[idx + 1]
            let controller = SettingsWindowController.shared
            controller.show()
            if let window = controller.window {
                if let i = args.firstIndex(of: "--appearance"), args.count > i + 1 {
                    window.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
                }
                let deadline = Date().addingTimeInterval(0.8)
                while Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                var saved = false
                if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                    CGWindowID(window.windowNumber),
                                                    [.boundsIgnoreFraming, .bestResolution]) {
                    Self.writePNG(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), to: path)
                    saved = true
                    print("settings-shot=\(path) via=CGWindow size=\(cg.width)x\(cg.height)")
                }
                if !saved, let view = window.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let img = NSImage(size: view.bounds.size)
                    img.addRepresentation(rep)
                    Self.writePNG(image: img, to: path)
                    print("settings-shot=\(path) via=bitmap")
                }
            }
            NSApp.terminate(nil)
            return
        }

        if args.contains("--test-panel-close") {
            // Build a real panel path identical to production, then close and verify.
            NSApp.setActivationPolicy(.accessory)
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.statusItem = item
            setupPanel()
            openPanel()
            let before = PanelController.shared.isVisible
            PanelController.shared.close(reason: "test-panel-close")
            let after = PanelController.shared.isVisible
            let panelVis = panel?.isVisible ?? false
            print("test-panel-close before=\(before) afterShared=\(after) afterPanel=\(panelVis)")
            NSLog("[MenuMonitor] test-panel-close before=%d afterShared=%d afterPanel=%d", before, after, panelVis)
            if after || panelVis {
                fputs("FAIL: panel still visible after close\n", stderr)
                exit(1)
            }
            print("test-panel-close OK")
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        SettingsKey.registerDefaults()
        monitor.applySettings()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applySettings()
        }

        theme.onChange = { [weak self] scheme in
            self?.applyPanelAppearance(scheme)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = monitor.menuBarIcon
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        // Keep status item image in sync with monitor refreshes
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem?.button else { return }
            button.image = self.monitor.menuBarIcon
        }
        RunLoop.main.add(iconTimer!, forMode: .common)

        setupPanel()
    }

    private func setupPanel() {
        let root = ContentView()
            .environmentObject(monitor)
            .environmentObject(theme)
        let hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true

        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = container.bounds
        container.addSubview(hostingView)
        panel.contentView = container

        self.panel = panel
        self.hosting = hostingView
        applyPanelAppearance(theme.scheme)
        PanelController.shared.attach(panel: panel, statusButton: statusItem?.button)

        // Size to fitting size once content lays out
        DispatchQueue.main.async { [weak self] in
            self?.relayoutPanel()
        }
    }

    /// Pin the panel to the system appearance so SwiftUI colorScheme and AppKit popovers stay in sync.
    private func applyPanelAppearance(_ scheme: ColorScheme) {
        let appearance = ThemeStore.appearance(for: scheme)
        panel?.appearance = appearance
        hosting?.appearance = appearance
    }

    private func relayoutPanel() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 10 || size.height < 10 {
            size = NSSize(width: 320, height: 520)
        }
        size.width = max(size.width, 320)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        if let container = panel.contentView {
            container.frame = NSRect(origin: .zero, size: size)
            hosting.frame = container.bounds
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePanel(sender)
            return
        }
        if event.type == .rightMouseUp {
            showStatusMenu()
            return
        }
        togglePanel(sender)
    }

    private func applySettings() {
        monitor.applySettings()
        if let button = statusItem?.button {
            button.image = monitor.menuBarIcon
        }
        theme.refresh()
        applyPanelAppearance(theme.scheme)
        SettingsWindowController.shared.applyAppearance()
    }

    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "退出 MenuMonitor",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openSettings(_ sender: Any?) {
        // Defer until the status menu has fully dismissed.
        DispatchQueue.main.async {
            SettingsWindowController.shared.show()
        }
    }

    private func showStatusMenu() {
        let menu = makeStatusMenu()
        // Temporarily attach menu so the status button can present it, then clear
        // so the next left-click still toggles the panel.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func togglePanel(_ sender: Any?) {
        if PanelController.shared.isVisible {
            PanelController.shared.close(reason: "statusItemToggle")
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let panel else { return }
        theme.refresh()
        applyPanelAppearance(theme.scheme)
        PanelController.shared.attach(panel: panel, statusButton: statusItem?.button)
        PanelController.shared.open(afterRelayout: { [weak self] in
            self?.relayoutPanel()
        })
    }

    static func writePNG(image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            fputs("failed to encode png\n", stderr)
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fputs("failed to write png: \(error)\n", stderr)
            exit(1)
        }
    }

    static func scheme(from args: [String]) -> ColorScheme {
        if let idx = args.firstIndex(of: "--appearance"), args.count > idx + 1 {
            let value = args[idx + 1].lowercased()
            if value == "dark" { return .dark }
            if value == "light" { return .light }
        }
        return ThemeStore.resolved
    }

    static func tab(from args: [String]) -> Int {
        if let idx = args.firstIndex(of: "--tab"), args.count > idx + 1, let value = Int(args[idx + 1]) {
            return min(2, max(0, value))
        }
        return 2
    }

    @MainActor
    static func renderPanelPreview(monitor: SystemMonitor, to path: String, scheme: ColorScheme, tab: Int = 2) {
        let theme = ThemeStore(fixed: scheme)
        let view = ContentView(initialTab: tab)
            .environmentObject(monitor)
            .environmentObject(theme)
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
            .frame(width: 320)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 320, height: nil)
        guard let image = renderer.nsImage else {
            fputs("ImageRenderer failed\n", stderr)
            exit(1)
        }
        writePNG(image: image, to: path)
        print("panel-preview=\(path) scheme=\(scheme == .dark ? "dark" : "light") size=\(image.size.width)x\(image.size.height)")
    }

    /// Capture the full live NSPanel (window-server pixels).
    @MainActor
    static func snapshotLivePanel(monitor: SystemMonitor, to path: String) {
        let scheme = scheme(from: CommandLine.arguments)
        let theme = ThemeStore(fixed: scheme)
        let root = ContentView(initialTab: tab(from: CommandLine.arguments))
            .environmentObject(monitor)
            .environmentObject(theme)
            .environment(\.colorScheme, scheme)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.appearance = ThemeStore.appearance(for: scheme)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.appearance = ThemeStore.appearance(for: scheme)
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container

        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 10 || size.height < 10 {
            size = NSSize(width: 320, height: 520)
        }
        size.width = max(size.width, 320)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        container.frame = NSRect(origin: .zero, size: size)
        hosting.frame = container.bounds

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        let deadline = Date().addingTimeInterval(0.45)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        var saved = false
        if panel.windowNumber > 0 {
            let opts = CGWindowListOption(arrayLiteral: .optionIncludingWindow)
            if let cgImg = CGWindowListCreateImage(
                .null,
                opts,
                CGWindowID(panel.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]
            ) {
                let out = NSImage(
                    cgImage: cgImg,
                    size: NSSize(width: CGFloat(cgImg.width) / 2, height: CGFloat(cgImg.height) / 2)
                )
                writePNG(image: out, to: path)
                saved = true
                print("panel-live=\(path) via=CGWindow size=\(cgImg.width)x\(cgImg.height)")
            }
        }
        if !saved {
            let bounds = hosting.bounds
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else {
                fputs("snapshot-panel: bitmap failed\n", stderr)
                exit(1)
            }
            hosting.cacheDisplay(in: bounds, to: rep)
            let img = NSImage(size: bounds.size)
            img.addRepresentation(rep)
            writePNG(image: img, to: path)
            print("panel-live=\(path) via=bitmap")
        }
        panel.orderOut(nil)
    }

    /// Open a real NSPanel with ContentView, capture the header band (live SwiftUI + PNG asset).
    @MainActor
    static func snapshotLiveHeader(monitor: SystemMonitor, to path: String) {
        let scheme = scheme(from: CommandLine.arguments)
        let theme = ThemeStore(fixed: scheme)
        let root = ContentView()
            .environmentObject(monitor)
            .environmentObject(theme)
            .environment(\.colorScheme, scheme)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.appearance = ThemeStore.appearance(for: scheme)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.appearance = ThemeStore.appearance(for: scheme)
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container

        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 10 || size.height < 10 {
            size = NSSize(width: 320, height: 520)
        }
        size.width = max(size.width, 320)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        container.frame = NSRect(origin: .zero, size: size)
        hosting.frame = container.bounds

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        let headerHeight: CGFloat = 88
        var saved = false

        if panel.windowNumber > 0 {
            let opts = CGWindowListOption(arrayLiteral: .optionIncludingWindow)
            if let cgImg = CGWindowListCreateImage(
                .null,
                opts,
                CGWindowID(panel.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]
            ) {
                let scaleX = CGFloat(cgImg.width) / max(size.width, 1)
                let scaleY = CGFloat(cgImg.height) / max(size.height, 1)
                let crop = CGRect(
                    x: 0,
                    y: 0,
                    width: size.width * scaleX,
                    height: headerHeight * scaleY
                )
                if let cropImg = cgImg.cropping(to: crop) {
                    let out = NSImage(
                        cgImage: cropImg,
                        size: NSSize(width: crop.width / scaleX, height: crop.height / scaleY)
                    )
                    writePNG(image: out, to: path)
                    saved = true
                    print("header-live=\(path) via=CGWindow size=\(Int(crop.width))x\(Int(crop.height))")
                }
            }
        }

        if !saved {
            let viewHeader = NSRect(x: 0, y: size.height - headerHeight, width: size.width, height: headerHeight)
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: viewHeader) else {
                fputs("snapshot-header: bitmap failed\n", stderr)
                exit(1)
            }
            hosting.cacheDisplay(in: viewHeader, to: rep)
            let img = NSImage(size: viewHeader.size)
            img.addRepresentation(rep)
            writePNG(image: img, to: path)
            print("header-live=\(path) via=bitmap size=\(Int(viewHeader.width))x\(Int(viewHeader.height))")
        }

        panel.orderOut(nil)
    }
}
