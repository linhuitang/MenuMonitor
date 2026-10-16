import SwiftUI
import AppKit

@main
struct MenuMonitorApp: App {
    @StateObject private var monitor = SystemMonitor()

    init() {
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
            // Also print metrics for verification
            print("preview=\(path) size=\(image.size.width)x\(image.size.height) template=\(image.isTemplate)")
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
        } label: {
            Image(nsImage: monitor.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private static func writePNG(image: NSImage, to path: String) {
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
}
