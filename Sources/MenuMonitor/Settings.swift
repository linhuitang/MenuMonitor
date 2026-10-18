import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Keys & values

enum SettingsKey {
    static let appearance = "appearanceMode"
    static let refreshInterval = "refreshInterval"
    static let menuBarDisplay = "menuBarDisplay"
    static let temperatureUnit = "temperatureUnit"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            appearance: AppearanceMode.system.rawValue,
            refreshInterval: 2.0,
            menuBarDisplay: MenuBarDisplay.memory.rawValue,
            temperatureUnit: TemperatureUnit.celsius.rawValue,
        ])
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.appearance) ?? "") ?? .system
    }
}

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case memory, cpu, memoryAndCPU, iconOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .memory: return "内存占用"
        case .cpu: return "CPU 占用"
        case .memoryAndCPU: return "内存 + CPU"
        case .iconOnly: return "仅图标"
        }
    }
    static var current: MenuBarDisplay {
        MenuBarDisplay(rawValue: UserDefaults.standard.string(forKey: SettingsKey.menuBarDisplay) ?? "") ?? .memory
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var symbol: String { self == .celsius ? "°C" : "°F" }
    func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }
}

enum RefreshIntervalOption {
    static let values: [Double] = [1, 2, 5]
    static var current: Double {
        let v = UserDefaults.standard.double(forKey: SettingsKey.refreshInterval)
        return values.contains(v) ? v : 2
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static var statusText: String {
        switch status {
        case .enabled: return "已启用"
        case .requiresApproval: return "需在「系统设置 → 通用 → 登录项」中允许"
        // mainApp reports .notFound until it has been registered once.
        case .notRegistered, .notFound: return "未启用"
        @unknown default: return "未知状态"
        }
    }

    /// Returns an error message on failure.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if status == .enabled || status == .requiresApproval { try SMAppService.mainApp.unregister() }
            }
            return nil
        } catch {
            NSLog("[MenuMonitor] login item %@ failed: %@", enabled ? "register" : "unregister", String(describing: error))
            return error.localizedDescription
        }
    }
}

// MARK: - View

struct SettingsView: View {
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(SettingsKey.refreshInterval) private var refreshInterval = 2.0
    @AppStorage(SettingsKey.menuBarDisplay) private var menuBarDisplay = MenuBarDisplay.memory.rawValue
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius.rawValue

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginStatus = LoginItem.statusText
    @State private var loginError: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "版本 \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("通用") {
                Toggle("开机自动启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        loginError = LoginItem.set(newValue)
                        refreshLoginState()
                    }
                ))
                LabeledContent("状态") {
                    Text(loginError.map { "设置失败：\($0)" } ?? loginStatus)
                        .foregroundStyle(loginError == nil ? Color.secondary : Color.red)
                        .font(.system(size: 12))
                }

                Picker("刷新间隔", selection: $refreshInterval) {
                    ForEach(RefreshIntervalOption.values, id: \.self) { v in
                        Text("\(Int(v)) 秒").tag(v)
                    }
                }
            }

            Section("显示") {
                Picker("外观", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Picker("菜单栏显示", selection: $menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { d in
                        Text(d.title).tag(d.rawValue)
                    }
                }

                Picker("温度单位", selection: $temperatureUnit) {
                    Text("摄氏度 °C").tag(TemperatureUnit.celsius.rawValue)
                    Text("华氏度 °F").tag(TemperatureUnit.fahrenheit.rawValue)
                }
                .pickerStyle(.segmented)
            }

            Section("关于") {
                LabeledContent("MenuMonitor") {
                    Text(version).foregroundStyle(.secondary)
                }
                LabeledContent("源代码") {
                    Link("github.com/linhuitang/MenuMonitor",
                         destination: URL(string: "https://github.com/linhuitang/MenuMonitor")!)
                        .foregroundStyle(MenuMonitorTheme.linkBlue)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refreshLoginState)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginState()
        }
    }

    private func refreshLoginState() {
        launchAtLogin = LoginItem.isEnabled
        loginStatus = LoginItem.statusText
    }
}

// MARK: - Window

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private(set) var window: NSWindow?

    func show() {
        PanelController.shared.close(reason: "openSettings")
        let window = self.window ?? makeWindow()
        self.window = window
        applyAppearance()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func applyAppearance() {
        guard let window else { return }
        switch AppearanceMode.current {
        case .system: window.appearance = nil
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "MenuMonitor 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("MenuMonitorSettings")
        return window
    }
}
