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
            Text(monitor.menuBarLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}
