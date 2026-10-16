import Foundation
import AppKit
import Darwin
import IOKit
import IOKit.storage
import CoreText

struct AppMemoryInfo: Identifiable {
    let id: Int
    let name: String
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
    @Published var menuBarIcon: NSImage = SystemMonitor.makeMemBadge(percent: 0)

    private var timer: Timer?
    private var prevCPUTicks: (UInt64, UInt64)? = nil
    private var prevNetBytes: (UInt64, UInt64, Date)? = nil
    private var prevDiskBytes: (UInt64, UInt64, Date)? = nil

    var junkText: String {
        "待清理垃圾 \(Self.formatBytes(junkBytes))"
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
        topApps = Self.readTopApps(limit: 4)
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

    func cleanCaches() {
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
            Self.clearDirectoryContents(at: caches)
            let junk = Self.estimateJunkBytes()
            DispatchQueue.main.async {
                self?.junkBytes = junk
                self?.isCleaning = false
            }
        }
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

    private static func readCPUTemperature() -> Double? {
        // Best-effort private API via dlsym; crash-safe with nil returns
        typealias CreateFn = @convention(c) (CFAllocator?, CFDictionary?) -> UnsafeMutableRawPointer?
        typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer?, Int64) -> CFArray?
        typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer?, CFString?) -> CFTypeRef?
        typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer?, CFDictionary?) -> Void
        typealias GetValueFn = @convention(c) (UnsafeMutableRawPointer?, Int64, Int64) -> UnsafeMutableRawPointer?
        typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Double

        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        guard handle != nil else { return nil }
        defer { /* keep loaded */ }

        guard
            let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
            let setMatchingSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
            let copyServicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
            let copyPropSym = dlsym(handle, "IOHIDServiceClientCopyProperty"),
            let copyEventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
            let getFloatSym = dlsym(handle, "IOHIDEventGetFloatValue")
        else { return nil }

        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let setMatching = unsafeBitCast(setMatchingSym, to: SetMatchingFn.self)
        let copyServices = unsafeBitCast(copyServicesSym, to: CopyServicesFn.self)
        let copyProperty = unsafeBitCast(copyPropSym, to: CopyPropertyFn.self)
        let copyEvent = unsafeBitCast(copyEventSym, to: GetValueFn.self)
        let getFloat = unsafeBitCast(getFloatSym, to: GetFloatFn.self)

        guard let client = create(kCFAllocatorDefault, nil) else { return nil }

        let matching: [String: Any] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 5
        ]
        setMatching(client, matching as CFDictionary)

        guard let services = copyServices(client, 0) as? [UnsafeMutableRawPointer], !services.isEmpty else {
            return nil
        }

        // Prefer CPU / SOC related sensors
        var temps: [Double] = []
        for service in services {
            let nameRef = copyProperty(service, "Product" as CFString)
            let name = (nameRef as? String) ?? ""
            // Event type 15 = temperature (kIOHIDEventTypeTemperature)
            guard let event = copyEvent(service, 15, 0) else { continue }
            // Field = (15 << 16) for temperature value
            let value = getFloat(event, Int32(15 << 16))
            // Values often in Celsius already; sometimes Kelvin — normalize
            var celsius = value
            if celsius > 200 { celsius -= 273.15 }
            if celsius < 0 || celsius > 150 { continue }

            let lower = name.lowercased()
            if lower.contains("cpu") || lower.contains("soc") || lower.contains("die") || lower.contains("tdie") {
                temps.insert(celsius, at: 0)
            } else {
                temps.append(celsius)
            }
        }

        return temps.first
    }

    // MARK: - Top Apps Memory

    private static func readTopApps(limit: Int) -> [AppMemoryInfo] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier > 0
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
            results.append(AppMemoryInfo(id: Int(pid), name: name, memoryBytes: bytes, icon: app.icon))
        }

        return Array(results.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit))
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
        var total: UInt64 = 0
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        total += directorySize(at: caches)

        let trash = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
        total += directorySize(at: trash)
        return total
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

    private static func clearDirectoryContents(at url: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }

    static func makeMemBadge(percent: Double) -> NSImage {
        let percentText = String(format: "%.0f%%", percent)
        let memText = "MEM"

        let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        let memFont = NSFont.systemFont(ofSize: 7, weight: .medium)

        let percentAttr = NSAttributedString(string: percentText, attributes: [
            .font: percentFont,
            .foregroundColor: NSColor.black
        ])
        let memAttr = NSAttributedString(string: memText, attributes: [
            .font: memFont,
            .foregroundColor: NSColor.black,
            .kern: 0.6
        ])

        let percentLine = CTLineCreateWithAttributedString(percentAttr)
        let memLine = CTLineCreateWithAttributedString(memAttr)

        var percentAscent: CGFloat = 0, percentDescent: CGFloat = 0, percentLeading: CGFloat = 0
        let percentWidth = CGFloat(CTLineGetTypographicBounds(percentLine, &percentAscent, &percentDescent, &percentLeading))
        var memAscent: CGFloat = 0, memDescent: CGFloat = 0, memLeading: CGFloat = 0
        let memWidth = CGFloat(CTLineGetTypographicBounds(memLine, &memAscent, &memDescent, &memLeading))

        // Measure real ink relative to baseline by rasterizing each line alone @2x
        let pInk = Self.measureInk(line: percentLine, width: percentWidth, ascent: percentAscent, descent: percentDescent)
        let mInk = Self.measureInk(line: memLine, width: memWidth, ascent: memAscent, descent: memDescent)

        let gap: CGFloat = 1 // ~1pt between ink bottom of % and ink top of MEM
        let padX: CGFloat = 2

        let logicalW = ceil(max(percentWidth, memWidth) + padX * 2)
        let logicalH: CGFloat = 22
        let blockH = (pInk.maxY - pInk.minY) + gap + (mInk.maxY - mInk.minY)
        let blockTop = max(0, (logicalH - blockH) / 2)
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

        let percentInkTop = logicalH - blockTop
        let percentBaseline = percentInkTop - pInk.maxY
        let percentInkBottom = percentBaseline + pInk.minY
        let memInkTop = percentInkBottom - gap
        let memBaseline = memInkTop - mInk.maxY

        cg.textPosition = CGPoint(x: (logicalW - percentWidth) / 2, y: percentBaseline)
        CTLineDraw(percentLine, cg)
        cg.textPosition = CGPoint(x: (logicalW - memWidth) / 2, y: memBaseline)
        CTLineDraw(memLine, cg)

        if CommandLine.arguments.contains("--render-label-preview") {
            fputs(String(format: "metrics w=%.1f h=%.1f blockH=%.1f blockTop=%.1f pInk=%.2f..%.2f mInk=%.2f..%.2f pBase=%.2f mBase=%.2f gap=%.1f\n",
                         logicalW, logicalH, blockH, blockTop, pInk.minY, pInk.maxY, mInk.minY, mInk.maxY,
                         percentBaseline, memBaseline, gap), stderr)
        }

        guard let cgImage = cg.makeImage() else { return NSImage(size: size) }
        let image = NSImage(cgImage: cgImage, size: size)
        image.isTemplate = true
        return image
    }

    /// Ink minY/maxY relative to baseline (bottom-left), in points.
    private static func measureInk(line: CTLine, width: CGFloat, ascent: CGFloat, descent: CGFloat) -> (minY: CGFloat, maxY: CGFloat) {
        let scale: CGFloat = 2
        let pad: CGFloat = 2
        let w = max(1, ceil(width) + pad * 2)
        let h = max(1, ceil(ascent + descent) + pad * 2)
        let pxW = Int(w * scale)
        let pxH = Int(h * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cg = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = cg.data else {
            return (-descent, ascent)
        }

        cg.setShouldAntialias(true)
        cg.scaleBy(x: scale, y: scale)
        cg.textMatrix = .identity
        cg.clear(CGRect(x: 0, y: 0, width: w, height: h))
        cg.setFillColor(NSColor.black.cgColor)
        let baseline = pad + descent
        cg.textPosition = CGPoint(x: pad, y: baseline)
        CTLineDraw(line, cg)

        let bytesPerRow = cg.bytesPerRow
        let ptr = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * pxH)
        var minPy = pxH, maxPy = -1
        let thr = 20
        for y in 0..<pxH {
            var hit = false
            let row = y * bytesPerRow
            for x in 0..<pxW {
                if ptr[row + x * 4 + 3] > thr { hit = true; break }
            }
            if hit {
                if y < minPy { minPy = y }
                if y > maxPy { maxPy = y }
            }
        }
        guard maxPy >= minPy else { return (-descent, ascent) }

        // Context origin bottom-left; pixel y=0 is bottom
        let inkMinY = CGFloat(minPy) / scale - baseline
        let inkMaxY = CGFloat(maxPy + 1) / scale - baseline
        return (inkMinY, inkMaxY)
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

    static func formatSpeed(_ bytesPerSec: Double) -> String {
        formatBytes(UInt64(max(0, bytesPerSec))) + "/s"
    }
}
