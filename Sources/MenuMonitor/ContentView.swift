import SwiftUI
import Charts
import AppKit

enum MenuMonitorTheme {
    /// Metric OK / healthy accent (#42D483)
    static let metricGreen = Color(red: 66/255, green: 212/255, blue: 131/255)
}

struct ContentView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @State private var selectedTab = 2 // 硬件

    private let panelRadius: CGFloat = 24
    private let panelBg = Color(red: 239/255, green: 241/255, blue: 244/255) // #EFF1F4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metricsCard
            systemCard
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .frame(width: 320)
        .background(panelBg, in: RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: Self.headerAppIcon())
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(monitor.junkText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let msg = monitor.cleanStatusMessage, !msg.isEmpty {
                        Text(msg)
                            .font(.system(size: 11))
                            .foregroundStyle(MenuMonitorTheme.metricGreen)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    monitor.cleanCaches()
                } label: {
                    Text(monitor.isCleaning ? "清理中…" : "快速清理")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white))
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .disabled(monitor.isCleaning)
            }

            if monitor.isCleaning || monitor.cleanProgress > 0 && monitor.cleanProgress < 1 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(white: 0.88))
                        Capsule()
                            .fill(MenuMonitorTheme.metricGreen)
                            .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, monitor.cleanProgress)))))
                    }
                }
                .frame(height: 4)
            }
        }
    }

    /// Prefer bundled 1024 PNG so the 44pt header icon stays sharp at @2x/@3x.
    private static func headerAppIcon() -> NSImage {
        let pointSize = NSSize(width: 44, height: 44)
        if let url = Bundle.main.url(forResource: "AppIcon-1024", withExtension: "png"),
           let src = NSImage(contentsOf: url) {
            return rasterized(src, toPoints: pointSize)
        }
        if let named = NSImage(named: "AppIcon") {
            return rasterized(named, toPoints: pointSize)
        }
        let fallback = NSApp.applicationIconImage ?? NSImage(size: pointSize)
        return rasterized(fallback, toPoints: pointSize)
    }

    private static func rasterized(_ source: NSImage, toPoints size: NSSize) -> NSImage {
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 2)
        let pxW = max(1, Int((size.width * scale).rounded()))
        let pxH = max(1, Int((size.height * scale).rounded()))

        // Pick the largest available bitmap rep from the source
        var cgImage: CGImage?
        if let reps = source.representations as? [NSImageRep] {
            let best = reps.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })
            if let bitmap = best as? NSBitmapImageRep {
                cgImage = bitmap.cgImage
            }
        }
        if cgImage == nil {
            var rect = NSRect(origin: .zero, size: source.size)
            cgImage = source.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let cg = cgImage else {
            let copy = source.copy() as? NSImage ?? NSImage(size: size)
            copy.size = size
            return copy
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return source
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))
        guard let outCG = ctx.makeImage() else { return source }
        let out = NSImage(cgImage: outCG, size: size)
        out.isTemplate = false
        return out
    }

    // MARK: Metrics Card

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                MetricColumn(
                    title: "内存占用",
                    valueText: String(format: "%.0f", monitor.memoryUsage),
                    unit: "%",
                    progress: monitor.memoryUsage / 100,
                    color: monitor.memoryUsage > 60 ? Color.orange : MenuMonitorTheme.metricGreen
                )
                MetricColumn(
                    title: "CPU 占用",
                    valueText: String(format: "%.0f", monitor.cpuUsage),
                    unit: "%",
                    progress: monitor.cpuUsage / 100,
                    color: cpuColor(monitor.cpuUsage)
                )
                MetricColumn(
                    title: "CPU 温度",
                    valueText: monitor.cpuTemp.map { String(format: "%.0f", $0) } ?? "--",
                    unit: monitor.cpuTemp != nil ? "°C" : "",
                    progress: tempProgress(monitor.cpuTemp),
                    color: tempColor(monitor.cpuTemp)
                )
            }

            HStack {
                Text("应用内存占用")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("释放") {
                    monitor.openActivityMonitor()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
            }

            // ~4 visible rows (28pt + 6pt spacing)
            let maxMem = max(monitor.topApps.first?.memoryBytes ?? 1, 1)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(monitor.topApps) { app in
                        AppMemoryRow(app: app, maxBytes: maxMem)
                    }
                }
            }
            .frame(height: 4 * 28 + 3 * 6)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 248/255, green: 249/255, blue: 250/255)) // #F8F9FA
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
    }

    // MARK: System Card

    private var systemCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("系统监控")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("", selection: $selectedTab) {
                    Text("磁盘 I/O").tag(0)
                    Text("网络").tag(1)
                    Text("硬件").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .labelsHidden()
            }

            Group {
                switch selectedTab {
                case 0:
                    diskIOTab
                case 1:
                    networkTab
                default:
                    hardwareTab
                }
            }
            .frame(minHeight: 72)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 248/255, green: 249/255, blue: 250/255)) // #F8F9FA
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
    }

    private var hardwareTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("可用 \(SystemMonitor.formatDiskGB(monitor.diskFree)) / 共 \(SystemMonitor.formatDiskGB(monitor.diskTotal))")
                    .font(.system(size: 11, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                Button("硬件详情") {
                    monitor.openSystemInformation()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
                .fixedSize()
            }

            GeometryReader { geo in
                let usedFrac: CGFloat = {
                    guard monitor.diskTotal > 0 else { return 0 }
                    return CGFloat(monitor.diskTotal - monitor.diskFree) / CGFloat(monitor.diskTotal)
                }()
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.90))
                    Capsule()
                        .fill(Color.orange)
                        .frame(width: max(4, geo.size.width * usedFrac))
                }
            }
            .frame(height: 8)

            HStack(spacing: 14) {
                LegendDot(color: .orange, label: "已用")
                LegendDot(color: Color(white: 0.75), label: "可用")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var networkTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("↑ \(SystemMonitor.formatSpeed(monitor.uploadSpeed))")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                Spacer()
                Text("↓ \(SystemMonitor.formatSpeed(monitor.downloadSpeed))")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
            }
            .foregroundStyle(.secondary)

            Chart(monitor.networkHistory) { sample in
                LineMark(
                    x: .value("t", sample.id),
                    y: .value("speed", sample.value)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 48)
        }
    }

    private var diskIOTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("读 \(SystemMonitor.formatSpeed(monitor.diskReadSpeed))")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                Spacer()
                Text("写 \(SystemMonitor.formatSpeed(monitor.diskWriteSpeed))")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
            }
            .foregroundStyle(.secondary)

            Chart(monitor.diskIOHistory) { sample in
                LineMark(
                    x: .value("t", sample.id),
                    y: .value("speed", sample.value)
                )
                .foregroundStyle(Color.orange)
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 48)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("退出") {
                NSApp.terminate(nil)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
    }

    private func cpuColor(_ v: Double) -> Color {
        if v > 85 { return .red }
        if v > 60 { return .orange }
        return MenuMonitorTheme.metricGreen
    }

    private func tempColor(_ t: Double?) -> Color {
        guard let t else { return .secondary }
        if t > 85 { return .red }
        if t > 70 { return .orange }
        return MenuMonitorTheme.metricGreen
    }

    private func tempProgress(_ t: Double?) -> Double {
        guard let t else { return 0 }
        return min(1, max(0, t / 100))
    }
}

struct MetricColumn: View {
    let title: String
    let valueText: String
    let unit: String
    let progress: Double
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ZStack(alignment: .bottom) {
                Capsule().fill(Color(white: 0.92))
                Capsule()
                    .fill(color)
                    .frame(height: max(4, 42 * CGFloat(min(1, max(0, progress)))))
            }
            .frame(width: 5, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(valueText)
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundStyle(color.opacity(0.85))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppMemoryRow: View {
    @EnvironmentObject var monitor: SystemMonitor
    let app: AppMemoryInfo
    let maxBytes: UInt64

    @State private var hovering = false
    @State private var showInfo = false

    var body: some View {
        GeometryReader { geo in
            let frac = maxBytes > 0 ? CGFloat(app.memoryBytes) / CGFloat(maxBytes) : 0
            ZStack(alignment: .leading) {
                // Full-row hover background
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color(white: 0.90) : Color.clear)

                // Proportional usage bar
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: hovering ? 0.86 : 0.94))
                    .frame(width: max(8, geo.size.width * frac))

                HStack(spacing: 8) {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                            .cornerRadius(4)
                    } else {
                        Image(systemName: "app.fill")
                            .frame(width: 18, height: 18)
                            .foregroundStyle(.secondary)
                    }
                    Text(app.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 4)

                    if hovering {
                        Button("关闭") {
                            monitor.quitApp(app)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .buttonStyle(.plain)

                        Button {
                            showInfo = true
                        } label: {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                            AppInfoPopover(app: app)
                                .environmentObject(monitor)
                        }
                    } else {
                        Text(SystemMonitor.formatBytes(app.memoryBytes))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct AppInfoPopover: View {
    @EnvironmentObject var monitor: SystemMonitor
    let app: AppMemoryInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .cornerRadius(6)
                }
                Text(app.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
            }

            infoRow("Bundle ID", app.bundleIdentifier ?? "—")
            infoRow("PID", app.pids.map(String.init).joined(separator: ", "))
            infoRow("内存", SystemMonitor.formatBytes(app.memoryBytes))

            Button("在活动监视器中查看") {
                monitor.openActivityMonitor()
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }
}
