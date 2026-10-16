import SwiftUI
import AppKit

@main
struct MenuMonitorApp: App {
    @StateObject private var monitor = SystemMonitor()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
        } label: {
            Image(nsImage: monitor.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
