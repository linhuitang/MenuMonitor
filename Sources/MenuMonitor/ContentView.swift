import SwiftUI
import Charts
import AppKit

struct ContentView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @State private var selectedTab = 2 // 硬件
    @State private var showCleanConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metricsCard
            systemCard
            footer
        }
        .padding(14)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .alert("确认清理？", isPresented: $showCleanConfirm) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                monitor.cleanCaches()
            }
        } message: {
            Text("将清理用户缓存目录 ~/Library/Caches 中的内容，系统和其他位置不会改动。")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.45, green: 0.55, blue: 1.0),
                                Color(red: 0.55, green: 0.35, blue: 0.95)
                            ],
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: 28
                        )
                    )
                    .frame(width: 40, height: 40)
                    .shadow(color: Color.blue.opacity(0.45), radius: 8, y: 2)
                Image(systemName: "shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("守护你的电脑")
                    .font(.system(size: 15, weight: .semibold))
                Text(monitor.junkText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                showCleanConfirm = true
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
                    color: monitor.memoryUsage > 60 ? Color.orange : Color.green
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

            VStack(spacing: 6) {
                let maxMem = max(monitor.topApps.first?.memoryBytes ?? 1, 1)
                ForEach(monitor.topApps) { app in
                    AppMemoryRow(app: app, maxBytes: maxMem)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
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
                .fill(Color.white)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
    }

    private var hardwareTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("可用 \(SystemMonitor.formatBytes(monitor.diskFree)) / 共 \(SystemMonitor.formatBytes(monitor.diskTotal))")
                    .font(.system(size: 12))
                Spacer()
                Button("硬件详情") {
                    monitor.openSystemInformation()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
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
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Text("↓ \(SystemMonitor.formatSpeed(monitor.downloadSpeed))")
                    .font(.system(size: 11, design: .monospaced))
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
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Text("写 \(SystemMonitor.formatSpeed(monitor.diskWriteSpeed))")
                    .font(.system(size: 11, design: .monospaced))
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
        return .green
    }

    private func tempColor(_ t: Double?) -> Color {
        guard let t else { return .secondary }
        if t > 85 { return .red }
        if t > 70 { return .orange }
        return .green
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
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color(white: 0.92))
                    Capsule()
                        .fill(color)
                        .frame(height: max(4, geo.size.height * CGFloat(min(1, max(0, progress)))))
                }
            }
            .frame(width: 5, height: 42)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(valueText)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(color.opacity(0.85))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppMemoryRow: View {
    let app: AppMemoryInfo
    let maxBytes: UInt64

    var body: some View {
        GeometryReader { geo in
            let frac = maxBytes > 0 ? CGFloat(app.memoryBytes) / CGFloat(maxBytes) : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.94))
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
                    Spacer()
                    Text(SystemMonitor.formatBytes(app.memoryBytes))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .frame(height: 28)
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
