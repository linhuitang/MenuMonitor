import AppKit
import Foundation

/// Owns the live status-bar NSPanel reference so any caller can dismiss the *actual* panel.
final class PanelController {
    static let shared = PanelController()

    private(set) weak var panel: NSPanel?
    private(set) var isShown: Bool = false

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private weak var statusButton: NSStatusBarButton?

    private init() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.close(reason: "appResignActive")
        }
    }

    func attach(panel: NSPanel, statusButton: NSStatusBarButton?) {
        self.panel = panel
        self.statusButton = statusButton
        NSLog("[MenuMonitor] PanelController.attach windowNumber=%d", panel.windowNumber)
    }

    func open(afterRelayout relayout: () -> Void) {
        assert(Thread.isMainThread)
        guard let panel else {
            NSLog("[MenuMonitor] PanelController.open: panel=nil")
            return
        }
        relayout()

        if let button = statusButton {
            button.window?.layoutIfNeeded()
            let buttonRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
                ?? NSRect(x: 100, y: 100, width: 30, height: 22)
            let size = panel.frame.size
            var x = buttonRect.midX - size.width / 2
            let y = buttonRect.minY - size.height - 6
            if let screen = button.window?.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        isShown = true
        installDismissalMonitors()
        NSLog("[MenuMonitor] PanelController.open isVisible=%d", panel.isVisible)
    }

    /// orderOut the real panel and clear shown state.
    func close(reason: String = "") {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.close(reason: reason)
            }
            return
        }
        guard let panel else {
            NSLog("[MenuMonitor] PanelController.close(%@): panel=nil isShown=%d", reason, isShown)
            isShown = false
            removeDismissalMonitors()
            return
        }
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        isShown = false
        removeDismissalMonitors()
        NSLog(
            "[MenuMonitor] PanelController.close(%@): wasVisible=%d nowVisible=%d windowNumber=%d",
            reason, wasVisible, panel.isVisible, panel.windowNumber
        )
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private func installDismissalMonitors() {
        removeDismissalMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if panel.frame.contains(NSEvent.mouseLocation) { return }
            self.close(reason: "clickOutsideGlobal")
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            let loc = NSEvent.mouseLocation
            if panel.frame.contains(loc) {
                return event
            }
            if let button = self.statusButton, let bw = button.window {
                let btnScreen = bw.convertToScreen(button.convert(button.bounds, to: nil))
                if btnScreen.contains(loc) {
                    return event
                }
            }
            self.close(reason: "clickOutsideLocal")
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
}
