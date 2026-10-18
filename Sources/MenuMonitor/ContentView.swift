import SwiftUI
import Charts
import AppKit

enum MenuMonitorTheme {
    /// Metric OK / healthy accent (#42D483). Same in both appearances; it stays legible on the dark card.
    static let metricGreen = Color(red: 66/255, green: 212/255, blue: 131/255)
    /// Link / action text (#539AFF)
    static let linkBlue = Color(red: 83/255, green: 154/255, blue: 255/255)

    /// Surfaces and controls. Light values match the original panel; dark values are the night-mode pair.
    struct Palette {
        let scheme: ColorScheme

        var isDark: Bool { scheme == .dark }

        var panelBackground: Color {
            isDark
                ? Color(red: 36/255, green: 37/255, blue: 42/255) // #24252A
                : Color(red: 239/255, green: 241/255, blue: 244/255) // #EFF1F4
        }

        var cardBackground: Color {
            isDark
                ? Color(red: 50/255, green: 51/255, blue: 58/255) // #32333A
                : Color(red: 248/255, green: 249/255, blue: 250/255) // #F8F9FA
        }

        var cardShadow: Color {
            Color.black.opacity(isDark ? 0.40 : 0.06)
        }

        /// Primary label / tab / button text. Light is #4D4D4D.
        var label: Color {
            isDark
                ? Color(red: 230/255, green: 230/255, blue: 232/255) // #E6E6E8
                : Color(red: 77/255, green: 77/255, blue: 77/255) // #4D4D4D
        }

        var buttonFill: Color {
            isDark
                ? Color(red: 69/255, green: 71/255, blue: 79/255) // #45474F
                : Color.white
        }

        var meterTrack: Color {
            isDark ? Color.white.opacity(0.12) : Color(white: 0.92)
        }

        var cleanTrack: Color {
            isDark ? Color.white.opacity(0.12) : Color(white: 0.88)
        }

        var diskTrack: Color {
            isDark ? Color.white.opacity(0.14) : Color(white: 0.90)
        }

        var diskFree: Color {
            isDark ? Color.white.opacity(0.32) : Color(white: 0.75)
        }

        var segmentTrack: Color {
            isDark
                ? Color(red: 30/255, green: 31/255, blue: 36/255) // #1E1F24
                : Color(red: 232/255, green: 234/255, blue: 238/255) // #E8EAEE
        }

        var segmentPill: Color {
            isDark
                ? Color(red: 74/255, green: 76/255, blue: 85/255) // #4A4C55
                : Color.white
        }

        var segmentDivider: Color {
            isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)
        }

        var segmentShadow: Color {
            Color.black.opacity(isDark ? 0.35 : 0.10)
        }

        var usageBar: Color {
            isDark ? Color.white.opacity(0.18) : Color(white: 0.94)
        }

        var usageBarHover: Color {
            isDark ? Color.white.opacity(0.26) : Color(white: 0.86)
        }

        var rowHover: Color {
            isDark ? Color.white.opacity(0.08) : Color(white: 0.90)
        }
    }
}

/// Follows the system appearance (System Settings → Appearance), including automatic day/night.
final class ThemeStore: ObservableObject {
    @Published private(set) var scheme: ColorScheme
    var onChange: ((ColorScheme) -> Void)?
    private var token: NSObjectProtocol?

    init() {
        scheme = Self.resolved
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The defaults key is sometimes committed on the next turn.
            DispatchQueue.main.async {
                self?.refresh()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.refresh()
            }
        }
    }

    /// Pinned scheme for previews and snapshots. Does not observe the system.
    init(fixed scheme: ColorScheme) {
        self.scheme = scheme
    }

    deinit {
        if let token {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    func refresh() {
        let next = Self.resolved
        guard next != scheme else { return }
        scheme = next
        onChange?(next)
    }

    /// User override from Settings (外观), else the system appearance.
    static var resolved: ColorScheme {
        switch AppearanceMode.current {
        case .light: return .light
        case .dark: return .dark
        case .system: return system
        }
    }

    static var system: ColorScheme {
        if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") {
            if style.caseInsensitiveCompare("Dark") == .orderedSame { return .dark }
            if style.caseInsensitiveCompare("Light") == .orderedSame { return .light }
        }
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
    }

    static func appearance(for scheme: ColorScheme) -> NSAppearance {
        let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
        return NSAppearance(named: name) ?? NSAppearance(named: .aqua)!
    }
}

struct ContentView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var theme: ThemeStore
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnitRaw = TemperatureUnit.celsius.rawValue
    @AppStorage(SettingsKey.language) private var languageRaw = LanguageSetting.system.rawValue
    /// Resolved UI language; reading `languageRaw` re-renders the panel live on change.
    private var lang: AppLanguage { (LanguageSetting(rawValue: languageRaw) ?? .system).resolved }
    private var tempUnit: TemperatureUnit { TemperatureUnit(rawValue: temperatureUnitRaw) ?? .celsius }
    @State private var selectedTab: Int

    init(initialTab: Int = 2) {
        _selectedTab = State(initialValue: initialTab)
    }

    private let panelRadius: CGFloat = 24
    private var colors: MenuMonitorTheme.Palette { .init(scheme: theme.scheme) }

    /// Idle + junk below 1 MiB: grey out 快速清理 (cleaning / result UI unchanged).
    private var quickCleanGreyed: Bool {
        !monitor.isCleaning
            && monitor.cleanProgress == 0
            && (monitor.cleanStatusMessage == nil || monitor.cleanStatusMessage?.isEmpty == true)
            && !monitor.hasCleanableJunk
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metricsCard
            systemCard
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .frame(width: 320)
        .background(colors.panelBackground, in: RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .overlay {
            if colors.isDark {
                RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .environment(\.colorScheme, theme.scheme)
        .animation(.easeInOut(duration: 0.22), value: theme.scheme)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                // Layout frame == icon size (44) so HStack centers icon with text/button.
                // Diffuse lavender shadow via .background — overflows, does not affect layout.
                Image(nsImage: Self.headerAppIcon())
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .shadow(
                        color: Color(red: 154/255, green: 168/255, blue: 232/255).opacity(0.28),
                        radius: 6,
                        y: 3
                    )
                    .background(alignment: .center) {
                        Ellipse()
                            .fill(Color(red: 154/255, green: 168/255, blue: 232/255).opacity(0.35)) // #9AA8E8
                            .frame(width: 38, height: 14)
                            .blur(radius: 6)
                            .offset(y: 18)
                            .allowsHitTesting(false)
                    }

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
                    Text(monitor.isCleaning ? lang.tr("Cleaning…", "清理中…") : lang.tr("Quick Clean", "快速清理"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colors.label.opacity(quickCleanGreyed ? 0.45 : 1))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(colors.buttonFill.opacity(quickCleanGreyed ? (colors.isDark ? 0.55 : 0.7) : 1))
                        )
                        .shadow(color: .black.opacity(quickCleanGreyed ? 0 : (colors.isDark ? 0.28 : 0.08)), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .disabled(monitor.isCleaning || quickCleanGreyed)
                .allowsHitTesting(!quickCleanGreyed)
            }

            // Show bar through completion (progress == 1) until status is cleared.
            if monitor.isCleaning || monitor.cleanProgress > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(colors.cleanTrack)
                        Capsule()
                            .fill(MenuMonitorTheme.metricGreen)
                            .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, monitor.cleanProgress)))))
                    }
                }
                .frame(height: 4)
                .animation(.easeInOut(duration: 0.2), value: monitor.cleanProgress)
            }
        }
    }

    /// Prefer bundled cropped full-res PNG; SwiftUI .resizable().interpolation(.high) downscales it.
    private static func headerAppIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon-1024", withExtension: "png"),
           let src = NSImage(contentsOf: url) {
            // Native crop size (not Lanczos-forced 1024); SwiftUI scales for the header.
            return src
        }
        if let named = NSImage(named: "AppIcon") {
            return named
        }
        return NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 44, height: 44))
    }


    // MARK: Metrics Card

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                MetricColumn(
                    title: lang.tr("Memory", "内存占用"),
                    valueText: String(format: "%.0f", monitor.memoryUsage),
                    unit: "%",
                    progress: monitor.memoryUsage / 100,
                    color: monitor.memoryUsage > 60 ? Color.orange : MenuMonitorTheme.metricGreen
                )
                MetricColumn(
                    title: lang.tr("CPU", "CPU 占用"),
                    valueText: String(format: "%.0f", monitor.cpuUsage),
                    unit: "%",
                    progress: monitor.cpuUsage / 100,
                    color: cpuColor(monitor.cpuUsage)
                )
                MetricColumn(
                    title: lang.tr("CPU Temp", "CPU 温度"),
                    valueText: monitor.cpuTemp.map { String(format: "%.0f", tempUnit.convert($0)) } ?? "--",
                    unit: monitor.cpuTemp != nil ? tempUnit.symbol : "",
                    progress: tempProgress(monitor.cpuTemp),
                    color: tempColor(monitor.cpuTemp)
                )
            }

            HStack {
                Text(lang.tr("App Memory", "应用内存占用"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(lang.tr("Manage Processes", "管理进程")) {
                    monitor.openActivityMonitor()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MenuMonitorTheme.linkBlue)
                .buttonStyle(.plain)
                .lineLimit(1)
                .fixedSize()
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
        .monitorCard(colors)
    }

    // MARK: System Card

    private var systemCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(lang.tr("System", "系统监控"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                SegmentedTabs(
                    titles: [lang.tr("Disk I/O", "磁盘 I/O"), lang.tr("Network", "网络"), lang.tr("Hardware", "硬件")],
                    selection: $selectedTab
                )
                .frame(width: 190, height: 26)
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
        .monitorCard(colors)
    }

    private var hardwareTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(lang.tr("\(SystemMonitor.formatDiskGB(monitor.diskFree)) free of \(SystemMonitor.formatDiskGB(monitor.diskTotal))", "可用 \(SystemMonitor.formatDiskGB(monitor.diskFree)) / 共 \(SystemMonitor.formatDiskGB(monitor.diskTotal))"))
                    .font(.system(size: 11, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                Button(lang.tr("Hardware Info", "硬件详情")) {
                    monitor.openSystemInformation()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MenuMonitorTheme.linkBlue)
                .buttonStyle(.plain)
                .fixedSize()
            }

            GeometryReader { geo in
                let usedFrac: CGFloat = {
                    guard monitor.diskTotal > 0 else { return 0 }
                    return CGFloat(monitor.diskTotal - monitor.diskFree) / CGFloat(monitor.diskTotal)
                }()
                ZStack(alignment: .leading) {
                    Capsule().fill(colors.diskTrack)
                    Capsule()
                        .fill(Color.orange)
                        .frame(width: max(4, geo.size.width * usedFrac))
                }
            }
            .frame(height: 8)

            HStack(spacing: 14) {
                LegendDot(color: .orange, label: lang.tr("Used", "已用"))
                LegendDot(color: colors.diskFree, label: lang.tr("Free", "可用"))
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
            .chartPlotStyle { plot in
                plot.background(Color.clear)
            }
            .frame(height: 48)
        }
    }

    private var diskIOTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(lang.tr("Read \(SystemMonitor.formatSpeed(monitor.diskReadSpeed))", "读 \(SystemMonitor.formatSpeed(monitor.diskReadSpeed))"))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                Spacer()
                Text(lang.tr("Write \(SystemMonitor.formatSpeed(monitor.diskWriteSpeed))", "写 \(SystemMonitor.formatSpeed(monitor.diskWriteSpeed))"))
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
            .chartPlotStyle { plot in
                plot.background(Color.clear)
            }
            .frame(height: 48)
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

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let track = MenuMonitorTheme.Palette(scheme: colorScheme).meterTrack
        HStack(alignment: .center, spacing: 6) {
            ZStack(alignment: .bottom) {
                Capsule().fill(track)
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
    @AppStorage(SettingsKey.language) private var languageRaw = LanguageSetting.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = MenuMonitorTheme.Palette(scheme: colorScheme)
        GeometryReader { geo in
            let frac = maxBytes > 0 ? CGFloat(app.memoryBytes) / CGFloat(maxBytes) : 0
            ZStack(alignment: .leading) {
                // Full-row hover background
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? colors.rowHover : Color.clear)

                // Proportional usage bar
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? colors.usageBarHover : colors.usageBar)
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
                        Button(L("Quit", "关闭")) {
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
    @AppStorage(SettingsKey.language) private var languageRaw = LanguageSetting.system.rawValue
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
            infoRow(L("Memory", "内存"), SystemMonitor.formatBytes(app.memoryBytes))

            Button(L("Show in Activity Monitor", "在活动监视器中查看")) {
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

private extension View {
    func monitorCard(_ colors: MenuMonitorTheme.Palette) -> some View {
        background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colors.cardBackground)
                .shadow(color: colors.cardShadow, radius: 6, y: 2)
                .overlay {
                    if colors.isDark {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    }
                }
        )
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

/// Custom segmented control. Light: gray track, white pill, #4D4D4D labels. Dark: inset track, lifted pill.
private struct SegmentedTabs: View {
    let titles: [String]
    @Binding var selection: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = MenuMonitorTheme.Palette(scheme: colorScheme)
        GeometryReader { geo in
            let count = max(titles.count, 1)
            let segmentW = geo.size.width / CGFloat(count)
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(colors.segmentTrack)

                // Thin separators between segments (pill covers neighbors)
                ForEach(1..<count, id: \.self) { i in
                    Rectangle()
                        .fill(colors.segmentDivider)
                        .frame(width: 1, height: 14)
                        .position(x: CGFloat(i) * segmentW, y: geo.size.height / 2)
                }

                // Selected pill
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colors.segmentPill)
                    .shadow(color: colors.segmentShadow, radius: 2, y: 1)
                    .frame(width: max(0, segmentW - 4), height: max(0, geo.size.height - 4))
                    .offset(x: CGFloat(selection) * segmentW + 2)
                    .animation(.easeInOut(duration: 0.18), value: selection)

                // Labels + hit targets (full segment area clickable)
                HStack(spacing: 0) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                        Button {
                            selection = i
                        } label: {
                            Text(title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(colors.label)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                }
            }
        }
    }
}
