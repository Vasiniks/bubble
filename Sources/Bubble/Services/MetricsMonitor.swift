import Foundation
import Combine
import Darwin
import IOKit
import IOKit.ps

/// Thread-safe native system metrics collector that runs on background queues.
private final class HardwareMetricsReader: @unchecked Sendable {
    private var previousCpuTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    private var previousNetBytes: (ibytes: UInt64, obytes: UInt64, time: Date)?
    private let totalRamBytes: UInt64
    private let pageSize: vm_size_t
    
    init() {
        var totalRam: UInt64 = 0
        var ramSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalRam, &ramSize, nil, 0)
        self.totalRamBytes = totalRam
        
        var pSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pSize)
        self.pageSize = pSize > 0 ? pSize : 4096
    }
    
    func collectSnapshot() -> SystemSnapshot {
        return SystemSnapshot(
            cpu: readCpuMetrics(),
            gpu: readGpuMetrics(),
            memory: readMemoryMetrics(),
            power: readPowerMetrics(),
            network: readNetworkMetrics(),
            timestamp: Date()
        )
    }
    
    // MARK: - CPU
    private func readCpuMetrics() -> CPUMetrics {
        var cpuLoad = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &cpuLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        
        guard kr == KERN_SUCCESS else {
            return CPUMetrics()
        }
        
        let u = cpuLoad.cpu_ticks.0
        let s = cpuLoad.cpu_ticks.1
        let i = cpuLoad.cpu_ticks.2
        let n = cpuLoad.cpu_ticks.3
        
        defer {
            previousCpuTicks = (u, s, i, n)
        }
        
        guard let prev = previousCpuTicks else {
            return CPUMetrics(coreCount: ProcessInfo.processInfo.processorCount)
        }
        
        let deltaUser = Double(u > prev.user ? u - prev.user : 0)
        let deltaSys  = Double(s > prev.sys ? s - prev.sys : 0)
        let deltaIdle = Double(i > prev.idle ? i - prev.idle : 0)
        let deltaNice = Double(n > prev.nice ? n - prev.nice : 0)
        
        let total = deltaUser + deltaSys + deltaIdle + deltaNice
        guard total > 0 else {
            return CPUMetrics(coreCount: ProcessInfo.processInfo.processorCount)
        }
        
        let userPct = (deltaUser / total) * 100.0
        let sysPct  = (deltaSys / total) * 100.0
        let idlePct = (deltaIdle / total) * 100.0
        let usagePct = max(0.0, min(100.0, userPct + sysPct))
        
        return CPUMetrics(
            usagePercent: usagePct,
            userPercent: userPct,
            systemPercent: sysPct,
            idlePercent: idlePct,
            coreCount: ProcessInfo.processInfo.processorCount
        )
    }
    
    // MARK: - GPU
    private func readGpuMetrics() -> GPUMetrics {
        var gpu = GPUMetrics()
        var iterator: io_iterator_t = 0
        let matchDict = IOServiceMatching("IOAccelerator")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)
        
        if result == kIOReturnSuccess {
            var regEntry = IOIteratorNext(iterator)
            while regEntry != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(regEntry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
                    if let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                        if let devUtil = perfStats["Device Utilization %"] as? Double {
                            gpu.utilizationPercent = max(gpu.utilizationPercent, devUtil)
                        } else if let devUtil = perfStats["Device Utilization %"] as? Int {
                            gpu.utilizationPercent = max(gpu.utilizationPercent, Double(devUtil))
                        }
                        
                        if let rendUtil = perfStats["Renderer Utilization %"] as? Double {
                            gpu.rendererUtilizationPercent = max(gpu.rendererUtilizationPercent, rendUtil)
                        } else if let rendUtil = perfStats["Renderer Utilization %"] as? Int {
                            gpu.rendererUtilizationPercent = max(gpu.rendererUtilizationPercent, Double(rendUtil))
                        }
                    }
                    if let name = dict["IOName"] as? String {
                        gpu.modelName = name
                    }
                }
                IOObjectRelease(regEntry)
                regEntry = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        return gpu
    }
    
    // MARK: - Memory
    private func readMemoryMetrics() -> MemoryMetrics {
        var mem = MemoryMetrics()
        mem.totalBytes = totalRamBytes
        
        var vmStat = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let active = UInt64(vmStat.active_count) * UInt64(pageSize)
            let wired = UInt64(vmStat.wire_count) * UInt64(pageSize)
            let compressed = UInt64(vmStat.compressor_page_count) * UInt64(pageSize)
            let free = UInt64(vmStat.free_count) * UInt64(pageSize)
            
            mem.usedBytes = active + wired + compressed
            mem.freeBytes = free
            
            if mem.usedPercent > 85.0 {
                mem.pressure = .critical
            } else if mem.usedPercent > 70.0 {
                mem.pressure = .warning
            } else {
                mem.pressure = .normal
            }
        }
        return mem
    }
    
    // MARK: - Power & Battery
    private func readPowerMetrics() -> PowerMetrics {
        var power = PowerMetrics()
        
        var iterator: io_iterator_t = 0
        let matchDict = IOServiceMatching("AppleSmartBattery")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)
        if result == kIOReturnSuccess {
            var regEntry = IOIteratorNext(iterator)
            while regEntry != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(regEntry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
                    if let v = dict["Voltage"] as? Int, let a = dict["Amperage"] as? Int {
                        let w = Double(abs(v * a)) / 1_000_000.0
                        power.watts = w
                    }
                    if let isCharging = dict["IsCharging"] as? Bool {
                        power.isCharging = isCharging
                    }
                }
                IOObjectRelease(regEntry)
                regEntry = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in sources {
                if let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] {
                    if let cap = desc[kIOPSCurrentCapacityKey as String] as? Int {
                        power.batteryPercent = cap
                    }
                    if let state = desc[kIOPSPowerSourceStateKey as String] as? String {
                        power.powerSourceState = state
                        power.isPluggedIn = (state == kIOPSACPowerValue as String)
                    }
                    if let charging = desc[kIOPSIsChargingKey as String] as? Bool {
                        power.isCharging = charging
                    }
                    
                    if power.isCharging {
                        if let timeToFull = desc[kIOPSTimeToFullChargeKey as String] as? Int, timeToFull > 0 {
                            power.timeRemainingMinutes = timeToFull
                        }
                    } else {
                        if let timeToEmpty = desc[kIOPSTimeToEmptyKey as String] as? Int, timeToEmpty > 0 {
                            power.timeRemainingMinutes = timeToEmpty
                        }
                    }
                }
            }
        }
        return power
    }
    
    // MARK: - Network
    private func readNetworkMetrics() -> NetworkMetrics {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return NetworkMetrics()
        }
        
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        
        while let cur = ptr {
            let family = cur.pointee.ifa_addr?.pointee.sa_family
            if family == UInt8(AF_LINK), let data = cur.pointee.ifa_data {
                let name = String(cString: cur.pointee.ifa_name)
                if !name.hasPrefix("lo") {
                    let ifData = data.assumingMemoryBound(to: if_data.self)
                    totalIn += UInt64(ifData.pointee.ifi_ibytes)
                    totalOut += UInt64(ifData.pointee.ifi_obytes)
                }
            }
            ptr = cur.pointee.ifa_next
        }
        freeifaddrs(firstAddr)
        
        let now = Date()
        defer {
            previousNetBytes = (totalIn, totalOut, now)
        }
        
        guard let prev = previousNetBytes else {
            return NetworkMetrics(totalInBytes: totalIn, totalOutBytes: totalOut)
        }
        
        let elapsed = now.timeIntervalSince(prev.time)
        guard elapsed > 0.05 else {
            return NetworkMetrics(totalInBytes: totalIn, totalOutBytes: totalOut)
        }
        
        let deltaIn = totalIn >= prev.ibytes ? Double(totalIn - prev.ibytes) : 0.0
        let deltaOut = totalOut >= prev.obytes ? Double(totalOut - prev.obytes) : 0.0
        
        return NetworkMetrics(
            bytesInPerSec: deltaIn / elapsed,
            bytesOutPerSec: deltaOut / elapsed,
            totalInBytes: totalIn,
            totalOutBytes: totalOut
        )
    }
}

@MainActor
public final class MetricsMonitor: ObservableObject {
    public static let shared = MetricsMonitor()
    
    @Published public private(set) var snapshot = SystemSnapshot()
    @Published public var updateInterval: TimeInterval = 1.0 {
        didSet {
            restartTimer()
        }
    }
    
    private var timer: AnyCancellable?
    private let reader = HardwareMetricsReader()
    private let queue = DispatchQueue(label: "com.bubble.metrics.monitor", qos: .utility)
    
    public init() {
        self.pollNow()
        self.restartTimer()
    }
    
    public func restartTimer() {
        timer?.cancel()
        timer = Timer.publish(every: updateInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.pollNow()
            }
    }
    
    public func pollNow() {
        let r = self.reader
        queue.async {
            let snap = r.collectSnapshot()
            Task { @MainActor in
                self.snapshot = snap
            }
        }
    }
}
