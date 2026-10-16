import Foundation
import AppKit
import Darwin
import IOKit
import IOKit.storage
import CoreText

struct AppMemoryInfo: Identifiable {
    let id: Int // primary PID
    let name: String
    let bundleIdentifier: String?
    let pids: [Int]
    let memoryBytes: UInt64
    let icon: NSImage?
}

struct SpeedSample: Identifiable {
    let id: Date
    let value: Double
}

final class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var memoryUsage: Double = 0
    @Published var cpuTemp: Double? = nil
    @Published var junkBytes: UInt64 = 0
    @Published var topApps: [AppMemoryInfo] = []
    @Published var diskTotal: UInt64 = 0
    @Published var diskFree: UInt64 = 0
    @Published var uploadSpeed: Double = 0
    @Published var downloadSpeed: Double = 0
    @Published var diskReadSpeed: Double = 0
    @Published var diskWriteSpeed: Double = 0
    @Published var networkHistory: [SpeedSample] = []
    @Published var diskIOHistory: [SpeedSample] = []
    @Published var isCleaning = false
    @Published var cleanStatusMessage: String? = nil
    /// 0...1 while cleaning
    @Published var cleanProgress: Double = 0
    @Published var menuBarIcon: NSImage = SystemMonitor.makeMemBadge(percent: 0)

    private var timer: Timer?
    private var cleanDisplayTimer: Timer?
    private var cleanRawProgress: Double = 0
    private var cleanStartDate: Date?
    private var cleanWorkFinished = false
    private var cleanHoldUntil: Date?
    private var cleanDoneMessage: String?
    private var prevCPUTicks: (UInt64, UInt64)? = nil
    private var prevNetBytes: (UInt64, UInt64, Date)? = nil
    private var prevDiskBytes: (UInt64, UInt64, Date)? = nil

    var junkText: String {
        if junkBytes == 0 {
            return "没有要清理的垃圾"
        }
        return "待清理垃圾 \(Self.formatBytes(junkBytes))"
    }

    init() {
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    deinit {
        timer?.invalidate()
    }

    func refreshAll() {
        cpuUsage = Self.readCPUUsage(prev: &prevCPUTicks)
        memoryUsage = Self.readMemoryUsage()
        menuBarIcon = Self.makeMemBadge(percent: memoryUsage)
        cpuTemp = Self.readCPUTemperature()
        topApps = Self.readTopApps(limit: 10)
        let disk = Self.readDiskSpace()
        diskTotal = disk.total
        diskFree = disk.free
        updateNetwork()
        updateDiskIO()
        // junk size less frequently via async
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let junk = Self.estimateJunkBytes()
            DispatchQueue.main.async {
                self?.junkBytes = junk
            }
        }
    }

    func cleanCaches(dryRun: Bool = false) {
        guard !isCleaning else { return }
        isCleaning = true
        cleanProgress = 0
        cleanRawProgress = 0
        cleanWorkFinished = false
        cleanHoldUntil = nil
        cleanDoneMessage = nil
        cleanStatusMessage = "清理中 0%"
        cleanStartDate = Date()
        startCleanDisplayTimer()

        let publishedBefore = junkBytes
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let before = publishedBefore > 0 ? publishedBefore : Self.estimateJunkBytes()
            let result = Self.performSafeCleanup(dryRun: dryRun) { processed, total in
                let fraction = total > 0 ? Double(processed) / Double(total) : 1
                DispatchQueue.main.async {
                    self?.cleanRawProgress = min(1, fraction)
                }
            }
            let junk = dryRun ? before : Self.estimateJunkBytes()
            DispatchQueue.main.async {
                guard let self else { return }
                if !dryRun {
                    self.junkBytes = junk
                }
                let freed = max(result.freedBytes, before > junk ? before - junk : 0)
                if result.errorCount > 0 {
                    NSLog("[MenuMonitor] clean finished with %d errors (see earlier logs)", result.errorCount)
                }
                let prefix = dryRun ? "[dry-run] " : ""
                self.cleanDoneMessage = String(
                    format: "%@已清理 %@",
                    prefix,
                    Self.formatBytes(freed)
                )
                self.cleanRawProgress = 1
                self.cleanWorkFinished = true
                NSLog("[MenuMonitor] clean done dryRun=%@ freed=%@ junkNow=%@ removed=%d skipped=%d errors=%d",
                      dryRun ? "YES" : "NO",
                      Self.formatBytes(freed), Self.formatBytes(junk),
                      result.removedCount, result.skippedCount, result.errorCount)
            }
        }
    }

    private func startCleanDisplayTimer() {
        cleanDisplayTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickCleanDisplay()
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanDisplayTimer = timer
    }

    private func stopCleanDisplayTimer() {
        cleanDisplayTimer?.invalidate()
        cleanDisplayTimer = nil
    }

    /// Smoothly ease displayed progress; enforce ~1.8s to reach 100%, then hold done state ~2s.
    private func tickCleanDisplay() {
        let minDuration: TimeInterval = 1.8
        let holdDuration: TimeInterval = 2.0
        guard let start = cleanStartDate else { return }
        let elapsed = Date().timeIntervalSince(start)

        if let holdUntil = cleanHoldUntil {
            // Full bar + "已清理 …" visible
            cleanProgress = 1
            if Date() >= holdUntil {
                cleanStatusMessage = nil
                cleanProgress = 0
                cleanRawProgress = 0
                cleanHoldUntil = nil
                cleanDoneMessage = nil
                cleanWorkFinished = false
                cleanStartDate = nil
                isCleaning = false
                stopCleanDisplayTimer()
            }
            return
        }

        if cleanWorkFinished {
            // Ease toward 100%, but do not arrive until minDuration has elapsed.
            if elapsed >= minDuration {
                cleanProgress += (1.0 - cleanProgress) * 0.45
                if cleanProgress >= 0.995 {
                    cleanProgress = 1
                    cleanStatusMessage = cleanDoneMessage ?? "已清理"
                    isCleaning = false
                    cleanHoldUntil = Date().addingTimeInterval(holdDuration)
                } else {
                    cleanStatusMessage = "清理中 99%"
                }
            } else {
                let remaining = max(0.05, minDuration - elapsed)
                // Step so we land near 1.0 exactly at minDuration from current value.
                let step = (1.0 - cleanProgress) * min(1.0, (1.0 / 30.0) / remaining)
                cleanProgress = min(0.99, cleanProgress + step)
                let pct = Int((cleanProgress * 100).rounded())
                cleanStatusMessage = "清理中 \(pct)%"
            }
            return
        }

        // Still working: follow raw progress but never hit 100% yet; blend time so fast cleans animate.
        let timeFloor = min(0.92, elapsed / minDuration)
        let blended = min(0.97, max(cleanRawProgress * 0.85 + timeFloor * 0.15, min(cleanRawProgress, 0.97)))
        cleanProgress += (blended - cleanProgress) * 0.28
        let pct = Int((cleanProgress * 100).rounded())
        cleanStatusMessage = "清理中 \(pct)%"
    }


    private struct CleanupResult {
        var freedBytes: UInt64 = 0
        var removedCount: Int = 0
        var skippedCount: Int = 0
        var errorCount: Int = 0
        var totalItems: Int = 0
        var processedItems: Int = 0
    }

    /// Safe cleanup: ~/Library/Caches children + own temp dirs. `dryRun` only simulates progress/sizes.
    private static func performSafeCleanup(dryRun: Bool, progress: @escaping (_ processed: Int, _ total: Int) -> Void) -> CleanupResult {
        var result = CleanupResult()
        let fm = FileManager.default
        var roots: [URL] = []

        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        roots.append(caches)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        for name in ["MenuMonitor", "com.ankii.menumonitor"] {
            let url = tmp.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                roots.append(url)
            }
        }

        // Collect all top-level items first for determinate progress
        var allItems: [URL] = []
        for root in roots {
            if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) {
                allItems.append(contentsOf: items)
            }
        }
        result.totalItems = allItems.count
        progress(0, max(allItems.count, 1))

        let skipNames: Set<String> = ["CloudKit", ".DS_Store"]
        for (index, item) in allItems.enumerated() {
            let name = item.lastPathComponent
            if skipNames.contains(name) {
                result.skippedCount += 1
                result.processedItems = index + 1
                progress(index + 1, max(allItems.count, 1))
                continue
            }
            let size = directorySize(at: item)
            if dryRun {
                // Simulate work without deleting
                Thread.sleep(forTimeInterval: 0.02)
                result.removedCount += 1
                result.freedBytes += size
            } else {
                do {
                    try fm.removeItem(at: item)
                    result.removedCount += 1
                    result.freedBytes += size
                } catch {
                    result.skippedCount += 1
                    result.errorCount += 1
                    NSLog("[MenuMonitor] skip %@: %@", item.path, String(describing: error))
                }
            }
            result.processedItems = index + 1
            progress(index + 1, max(allItems.count, 1))
        }
        return result
    }


    func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    func openSystemInformation() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/System Information.app"))
    }

    // MARK: - CPU

    private static func readCPUUsage(prev: inout (UInt64, UInt64)?) -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else { return 0 }

        defer {
            let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var totalIdle: UInt64 = 0
        var totalNice: UInt64 = 0

        for i in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * i
            totalUser += UInt64(info[offset + Int(CPU_STATE_USER)])
            totalSystem += UInt64(info[offset + Int(CPU_STATE_SYSTEM)])
            totalIdle += UInt64(info[offset + Int(CPU_STATE_IDLE)])
            totalNice += UInt64(info[offset + Int(CPU_STATE_NICE)])
        }

        let totalBusy = totalUser + totalSystem + totalNice
        let total = totalBusy + totalIdle

        defer { prev = (totalBusy, total) }

        guard let previous = prev else { return 0 }
        let busyDelta = Double(totalBusy &- previous.0)
        let totalDelta = Double(total &- previous.1)
        guard totalDelta > 0 else { return 0 }
        return min(100, max(0, busyDelta / totalDelta * 100))
    }

    // MARK: - Memory

    private static func readMemoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let used = active + wired + compressed

        var totalMem: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalMem, &size, nil, 0)
        guard totalMem > 0 else { return 0 }
        return min(100, Double(used) / Double(totalMem) * 100)
    }

    // MARK: - Temperature (Apple Silicon via IOHID)

    private struct SMCKeyData_vers_t {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved0: UInt8 = 0
        var reserved1: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCKeyData_pLimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyData_keyInfo_t {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct SMCKeyData_t {
        var key: UInt32 = 0
        var vers = SMCKeyData_vers_t()
        var pLimitData = SMCKeyData_pLimitData_t()
        var keyInfo = SMCKeyData_keyInfo_t()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private static func readCPUTemperature() -> Double? {
        if let t = readTemperatureViaIOHID() { return t }
        if let t = readTemperatureViaSMC() { return t }
        return nil
    }

    /// Apple Silicon thermal sensors via private IOHIDEventSystemClient (no root).
    private static func readTemperatureViaIOHID() -> Double? {
        typealias Client = UnsafeMutableRawPointer
        typealias Service = UnsafeMutableRawPointer
        typealias Event = UnsafeMutableRawPointer
        typealias CreateFn = @convention(c) (CFAllocator?) -> Client?
        typealias SetMatchingFn = @convention(c) (Client?, CFDictionary?) -> Void
        typealias CopyServicesFn = @convention(c) (Client?) -> Unmanaged<CFArray>?
        typealias CopyPropertyFn = @convention(c) (Service?, CFString?) -> Unmanaged<CFTypeRef>?
        typealias CopyEventFn = @convention(c) (Service?, Int64, Int64) -> Event?
        typealias GetFloatFn = @convention(c) (Event?, Int32) -> Double

        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY) else {
            return nil
        }

        func load<T>(_ name: String) -> T? {
            guard let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }

        guard
            let create: CreateFn = load("IOHIDEventSystemClientCreate"),
            let setMatching: SetMatchingFn = load("IOHIDEventSystemClientSetMatching"),
            let copyServices: CopyServicesFn = load("IOHIDEventSystemClientCopyServices"),
            let copyProperty: CopyPropertyFn = load("IOHIDServiceClientCopyProperty"),
            let copyEvent: CopyEventFn = load("IOHIDServiceClientCopyEvent"),
            let getFloat: GetFloatFn = load("IOHIDEventGetFloatValue"),
            let client = create(kCFAllocatorDefault)
        else { return nil }

        let matching: [String: Any] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 5
        ]
        setMatching(client, matching as CFDictionary)

        guard let services = copyServices(client)?.takeRetainedValue() else { return nil }
        let count = CFArrayGetCount(services)
        guard count > 0 else { return nil }

        var preferred: [Double] = []
        var others: [Double] = []

        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = UnsafeMutableRawPointer(mutating: raw)

            var name = ""
            if let pref = copyProperty(service, "Product" as CFString)?.takeUnretainedValue(),
               CFGetTypeID(pref) == CFStringGetTypeID() {
                name = (pref as! String)
            }

            // kIOHIDEventTypeTemperature = 15
            guard let event = copyEvent(service, 15, 0) else { continue }
            var value = getFloat(event, Int32(15 << 16))
            if value > 200 { value -= 273.15 } // Kelvin → °C if needed
            guard value.isFinite, value >= 0, value <= 120 else { continue }

            let lower = name.lowercased()
            if lower.contains("tdie") || lower.contains("pacc") || lower.contains("eacc") {
                preferred.append(value)
            } else if lower.contains("soc") || lower.contains("die") || lower.contains("cpu") {
                others.insert(value, at: 0)
            } else if !lower.contains("battery") && !lower.contains("nand") && !lower.contains("gas") {
                others.append(value)
            }
        }

        let pool = preferred.isEmpty ? others : preferred
        guard !pool.isEmpty else { return nil }
        // Average preferred die/performance-cluster sensors
        return pool.reduce(0, +) / Double(pool.count)
    }

    /// Fallback: AppleSMC user-client read of common CPU/SoC temp keys (no sudo on many Macs).
    private static func readTemperatureViaSMC() -> Double? {
        let keys = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "TC0P", "Te05", "Te0F"]
        for key in keys {
            if let t = smcReadTemperature(key: key), t >= 0, t <= 120 {
                return t
            }
        }
        return nil
    }

    private static func smcReadTemperature(key: String) -> Double? {
        // Minimal SMC read via IOService "AppleSMC"
        let serviceName = "AppleSMC"
        guard let matching = IOServiceMatching(serviceName) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(conn) }

        // SMCKeyData / SMCVal structures (packed)
        // Using a simplified approach: many modern macOS builds restrict SMC;
        // return nil if the call fails.
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = Self.smcFourCharCode(key)
        input.data8 = 5 // KERNEL_INDEX_SMC = 5? Actually SELECTOR read = 2 for key info then 2?
        // Standard sequence: data8 = 9 (SMC_CMD_READ_KEYINFO) then READ_BYTES
        input.data8 = 9 // READ_KEYINFO
        var outSize = MemoryLayout<SMCKeyData_t>.stride
        let kr1 = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData_t>.stride, &output, &outSize)
        guard kr1 == KERN_SUCCESS else { return nil }

        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5 // READ_BYTES
        outSize = MemoryLayout<SMCKeyData_t>.stride
        let kr2 = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData_t>.stride, &output, &outSize)
        guard kr2 == KERN_SUCCESS else { return nil }

        // SP78 format: bytes[0] integer, bytes[1] fraction
        let b0 = Double(output.bytes.0)
        let b1 = Double(output.bytes.1)
        return b0 + b1 / 256.0
    }

    private static func smcFourCharCode(_ s: String) -> UInt32 {
        var result: UInt32 = 0
        for (i, ch) in s.utf8.enumerated() where i < 4 {
            result |= UInt32(ch) << (8 * (3 - i))
        }
        return result
    }

    // MARK: - Top Apps Memory

    private static let excludedBundleIds: Set<String> = [
        "com.apple.finder",
        "com.ankii.menumonitor"
    ]

    private static func readTopApps(limit: Int) -> [AppMemoryInfo] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfBundle = Bundle.main.bundleIdentifier

        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, app.processIdentifier > 0 else { return false }
            if app.processIdentifier == selfPID { return false }
            if app == NSRunningApplication.current { return false }
            if let bid = app.bundleIdentifier {
                if excludedBundleIds.contains(bid) { return false }
                if let selfBundle, bid == selfBundle { return false }
            }
            let name = app.localizedName ?? ""
            if name == "Finder" || name == "MenuMonitor" { return false }
            return true
        }

        var results: [AppMemoryInfo] = []
        for app in apps {
            let pid = app.processIdentifier
            var rusage = rusage_info_v2()
            let ret = withUnsafeMutablePointer(to: &rusage) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, Int32(RUSAGE_INFO_V2), rebound)
                }
            }
            guard ret == 0 else { continue }
            let bytes = rusage.ri_phys_footprint
            guard bytes > 0 else { continue }
            let name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "Unknown"
            results.append(AppMemoryInfo(
                id: Int(pid),
                name: name,
                bundleIdentifier: app.bundleIdentifier,
                pids: [Int(pid)],
                memoryBytes: bytes,
                icon: app.icon
            ))
        }

        return Array(results.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit))
    }

    func quitApp(_ info: AppMemoryInfo) {
        // Never quit ourselves or Finder
        if info.bundleIdentifier == "com.apple.finder" { return }
        if info.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        if info.name == "Finder" || info.name == "MenuMonitor" { return }
        if info.pids.contains(Int(ProcessInfo.processInfo.processIdentifier)) { return }

        guard let app = NSRunningApplication(processIdentifier: pid_t(info.id)) else {
            topApps = Self.readTopApps(limit: 10)
            return
        }
        app.terminate() // graceful only; no forceTerminate

        // Refresh after a short delay and again at ~3s; do not force-kill
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.topApps = Self.readTopApps(limit: 10)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.topApps = Self.readTopApps(limit: 10)
        }
    }


    // MARK: - Disk

    private static func readDiskSpace() -> (total: UInt64, free: UInt64) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) else {
            return (0, 0)
        }
        let total = UInt64(values.volumeTotalCapacity ?? 0)
        let free = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        return (total, free)
    }

    // MARK: - Network

    private func updateNetwork() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }

        var sent: UInt64 = 0
        var recv: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let name = String(cString: current.pointee.ifa_name)
            if name.hasPrefix("lo") {
                ptr = current.pointee.ifa_next
                continue
            }
            if let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let dataPtr = current.pointee.ifa_data {
                let data = dataPtr.assumingMemoryBound(to: if_data.self)
                sent += UInt64(data.pointee.ifi_obytes)
                recv += UInt64(data.pointee.ifi_ibytes)
            }
            ptr = current.pointee.ifa_next
        }

        let now = Date()
        if let prev = prevNetBytes {
            let dt = now.timeIntervalSince(prev.2)
            if dt > 0 {
                uploadSpeed = Double(sent &- prev.0) / dt
                downloadSpeed = Double(recv &- prev.1) / dt
                let sample = SpeedSample(id: now, value: uploadSpeed + downloadSpeed)
                networkHistory.append(sample)
                if networkHistory.count > 30 { networkHistory.removeFirst(networkHistory.count - 30) }
            }
        }
        prevNetBytes = (sent, recv, now)
    }

    // MARK: - Disk I/O

    private func updateDiskIO() {
        // Use sysctl kern.diskstats or IOKit — simplified via IOBlockStorageDriver is complex
        // Fall back: read from iostat via /dev is hard; use host_statistics for swap as weak proxy
        // Better: parse `IOServiceMatching("IOBlockStorageDriver")`
        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0

        let matching = IOServiceMatching("IOBlockStorageDriver")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let statistics = dict["Statistics"] as? [String: Any] else { continue }

            if let r = statistics["Bytes (Read)"] as? NSNumber { readBytes += r.uint64Value }
            if let w = statistics["Bytes (Write)"] as? NSNumber { writeBytes += w.uint64Value }
            // Alternative keys on newer macOS
            if let r = statistics["BytesRead"] as? NSNumber { readBytes += r.uint64Value }
            if let w = statistics["BytesWritten"] as? NSNumber { writeBytes += w.uint64Value }
        }

        let now = Date()
        if let prev = prevDiskBytes {
            let dt = now.timeIntervalSince(prev.2)
            if dt > 0 {
                diskReadSpeed = Double(readBytes &- prev.0) / dt
                diskWriteSpeed = Double(writeBytes &- prev.1) / dt
                let sample = SpeedSample(id: now, value: diskReadSpeed + diskWriteSpeed)
                diskIOHistory.append(sample)
                if diskIOHistory.count > 30 { diskIOHistory.removeFirst(diskIOHistory.count - 30) }
            }
        }
        prevDiskBytes = (readBytes, writeBytes, now)
    }

    // MARK: - Junk estimate

    private static func estimateJunkBytes() -> UInt64 {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        // Match what 快速清理 actually removes (not Trash)
        return directorySize(at: caches)
    }

    private static func directorySize(at url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var size: UInt64 = 0
        var count = 0
        for case let fileURL as URL in enumerator {
            count += 1
            if count > 5000 { break } // cap for performance
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true,
                  let fileSize = values.fileSize else { continue }
            size += UInt64(fileSize)
        }
        return size
    }


    static func makeMemBadge(percent: Double) -> NSImage {
        let percentText = String(format: "%.0f%%", percent)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let attrStr = NSAttributedString(string: percentText, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let padX: CGFloat = 2
        let logicalW = ceil(width + padX * 2)
        let logicalH: CGFloat = 22
        let size = NSSize(width: logicalW, height: logicalH)

        let scale: CGFloat = 2
        let pxW = Int(logicalW * scale)
        let pxH = Int(logicalH * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cg = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: size)
        }

        cg.setShouldAntialias(true)
        cg.setAllowsFontSmoothing(true)
        cg.setShouldSmoothFonts(true)
        cg.scaleBy(x: scale, y: scale)
        cg.textMatrix = .identity
        cg.clear(CGRect(x: 0, y: 0, width: logicalW, height: logicalH))
        cg.setFillColor(NSColor.black.cgColor)

        // Vertically center using typographic bounds
        let textH = ascent + descent
        let baseline = (logicalH - textH) / 2 + descent
        cg.textPosition = CGPoint(x: (logicalW - width) / 2, y: baseline)
        CTLineDraw(line, cg)

        guard let cgImage = cg.makeImage() else { return NSImage(size: size) }
        let image = NSImage(cgImage: cgImage, size: size)
        image.isTemplate = true
        return image
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        let b = Double(bytes)
        if b >= gb { return String(format: "%.2f GB", b / gb) }
        if b >= mb { return String(format: "%.1f MB", b / mb) }
        if b >= kb { return String(format: "%.0f KB", b / kb) }
        return "\(bytes) B"
    }

    /// Disk totals for the hardware row — always one decimal GB, shorter than formatBytes.
    static func formatDiskGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        return String(format: "%.1f GB", gb)
    }

    static func formatSpeed(_ bytesPerSec: Double) -> String {
        formatBytes(UInt64(max(0, bytesPerSec))) + "/s"
    }
}
