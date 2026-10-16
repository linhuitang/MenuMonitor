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
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var iconObs: NSKeyValueObservation?
    private var globalMonitor: Any?
    private var localMonitor: Any?
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
            Self.renderPanelPreview(monitor: monitor, to: path)
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
            m.cleanCaches(dryRun: true)
            let cleanDeadline = Date().addingTimeInterval(120)
            while m.isCleaning && Date() < cleanDeadline {
                let pct = Int((m.cleanProgress * 100).rounded())
                if pct != lastPct {
                    print("progress=\(pct)% status=\(m.cleanStatusMessage ?? "")")
                    lastPct = pct
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
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

        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = monitor.menuBarIcon
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel(_:))
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

        // Size to fitting size once content lays out
        DispatchQueue.main.async { [weak self] in
            self?.relayoutPanel()
        }
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

    @objc private func togglePanel(_ sender: Any?) {
        guard let panel else { return }
        if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let panel, let button = statusItem?.button else { return }
        relayoutPanel()

        // Position under status item, right-aligned to button
        button.window?.layoutIfNeeded()
        let buttonRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            ?? NSRect(x: 100, y: 100, width: 30, height: 22)
        let size = panel.frame.size
        var x = buttonRect.midX - size.width / 2
        let y = buttonRect.minY - size.height - 6

        // Keep on screen
        if let screen = button.window?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installDismissalMonitors()
    }

    private func closePanel() {
        panel?.orderOut(nil)
        removeDismissalMonitors()
    }

    private func installDismissalMonitors() {
        removeDismissalMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if panel.frame.contains(NSEvent.mouseLocation) { return }
            self.closePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            let loc = NSEvent.mouseLocation
            if panel.frame.contains(loc) {
                return event // clicks inside panel (buttons, etc.)
            }
            if let button = self.statusItem?.button,
               let bw = button.window {
                let btnScreen = bw.convertToScreen(button.convert(button.bounds, to: nil))
                if btnScreen.contains(loc) {
                    return event // status item toggles
                }
            }
            self.closePanel()
            return event
        }
    }

    private func removeDismissalMonitors() {
        if let g = globalMonitor {
            NSEvent.removeMonitor(g)
            globalMonitor = nil
        }
        if let l = localMonitor {
            NSEvent.removeMonitor(l)
            localMonitor = nil
        }
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

    @MainActor
    static func renderPanelPreview(monitor: SystemMonitor, to path: String) {
        let view = ContentView()
            .environmentObject(monitor)
            .frame(width: 320)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            fputs("ImageRenderer failed\n", stderr)
            exit(1)
        }
        writePNG(image: image, to: path)
        print("panel-preview=\(path) size=\(image.size.width)x\(image.size.height)")
    }
}
