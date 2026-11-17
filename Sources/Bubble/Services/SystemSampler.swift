import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Reads raw system metrics using Mach, IOKit, the SMC and sysctl. Not thread-safe: it is only
/// ever used from MetricsMonitor's serial queue, which is what makes the conformance sound.
final class SystemSampler: @unchecked Sendable {
    /// Everything the graphs need is read every sample: each read takes microseconds, and
    /// while the notch is closed no view is drawing them, so the graphs are already full when
    /// it opens.
    struct Reading {
        var cpu: CPULoad?
        var gpu: Int?
        var gpuMemory: UInt64?
        var memory: MemoryUsage?
        var power: Double?
        var network: NetworkRate?
        var diskActivity: DiskActivity?
        var temperatureSampled = false
        var temperature: CoreTemperature?
        /// Per-core load, only read while open (it's drawn only then).
        var cores: [UInt8] = []
    }

    /// Temperature changes slowly; while closed it is read at most this often.
    private static let temperatureInterval: UInt64 = 5_000_000_000

    // mach_host_self() adds a port reference on every call, so take it once.
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let totalMemory: UInt64
    private let temperature = TemperatureSensor()

    private var lastCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var lastCoreTicks: [UInt32] = []
    private var lastNetwork: (up: UInt64, down: UInt64, time: UInt64)?
    private var lastDiskIO: (read: UInt64, write: UInt64, busy: UInt64, time: UInt64)?
    private var lastTemperatureTime: UInt64 = 0
    private var gpuService: io_registry_entry_t = 0
    private var diskDrivers: [io_registry_entry_t] = []
    private var diskDriversAge = 0
    private var batteryService: io_registry_entry_t = 0
    private var interfaceBuffer: [UInt8] = []
    private var isCountedInterface: [UInt16: Bool] = [:]

    init() {
        var size = vm_size_t(0)
        host_page_size(host, &size)
        pageSize = UInt64(size > 0 ? size : 4096)

        var memory: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memory, &length, nil, 0)
        totalMemory = memory

        _ = cpu() // Prime the tick counters so the first real sample is a valid delta.
    }

    deinit {
        if gpuService != 0 { IOObjectRelease(gpuService) }
        diskDrivers.forEach { IOObjectRelease($0) }
        if batteryService != 0 { IOObjectRelease(batteryService) }
        mach_port_deallocate(mach_task_self_, host)
    }

    /// `open`: the notch is open, so temperature is read every sample rather than every 5 s.
    func read(open: Bool) -> Reading {
        let graphics = gpu()
        var reading = Reading(
            cpu: cpu(),
            gpu: graphics?.utilization,
            gpuMemory: graphics?.memory,
            memory: memory(),
            power: power(),
            network: network(),
            diskActivity: diskActivity()
        )

        let now = DispatchTime.now().uptimeNanoseconds
        if open || now - lastTemperatureTime >= Self.temperatureInterval {
            lastTemperatureTime = now
            reading.temperatureSampled = true
            reading.temperature = temperature.read()
        }
        if open {
            reading.cores = coreLoads() ?? []
        } else {
            lastCoreTicks = []
        }
        return reading
    }

    // MARK: CPU

    private func cpu() -> CPULoad? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let ticks = (user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { lastCPUTicks = ticks }
        guard let last = lastCPUTicks else { return nil }

        // Tick counters are 32-bit and wrap; wrapping subtraction keeps deltas correct.
        let user = Double(ticks.user &- last.user) + Double(ticks.nice &- last.nice)
        let system = Double(ticks.system &- last.system)
        let total = user + system + Double(ticks.idle &- last.idle)
        guard total > 0 else { return nil }

        let userPercent = Int((user / total * 100).rounded())
        let systemPercent = Int((system / total * 100).rounded())
        return CPULoad(total: min(100, userPercent + systemPercent), user: userPercent, system: systemPercent)
    }

    /// Per-core load, in the kernel's core order (efficiency cores first on Apple Silicon).
    private func coreLoads() -> [UInt8]? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS, let info else {
            return nil
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        let ticks = (0 ..< Int(coreCount) * stride).map { UInt32(bitPattern: info[$0]) }
        defer { lastCoreTicks = ticks }
        guard lastCoreTicks.count == ticks.count else { return nil }

        return (0 ..< Int(coreCount)).map { core in
            let base = core * stride
            func delta(_ state: Int32) -> Double { Double(ticks[base + Int(state)] &- lastCoreTicks[base + Int(state)]) }
            let busy = delta(CPU_STATE_USER) + delta(CPU_STATE_SYSTEM) + delta(CPU_STATE_NICE)
            let total = busy + delta(CPU_STATE_IDLE)
            return total > 0 ? UInt8(min(100, (busy / total * 100).rounded())) : 0
        }
    }

    // MARK: GPU

    /// Utilization and the memory the GPU has in use (unified memory on Apple Silicon).
    private func gpu() -> (utilization: Int, memory: UInt64?)? {
        if gpuService == 0 {
            gpuService = Self.findGPUService()
        }
        guard gpuService != 0 else { return nil }

        // Read only PerformanceStatistics rather than the accelerator's full property table.
        guard let stats = Self.dictionary(gpuService, Key.performanceStatistics),
              let utilization = Self.number(stats, Key.deviceUtilization)
        else {
            IOObjectRelease(gpuService)
            gpuService = 0
            return nil
        }
        let memory = Self.number(stats, Key.gpuMemoryInUse).map { UInt64(max(0, $0)) }
        let step = UInt64(1 << 30) / 10
        return (Int(min(100, max(0, utilization))), memory.map { ($0 + step / 2) / step * step })
    }

    private static func findGPUService() -> io_registry_entry_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            if IORegistryEntryCreateCFProperty(service, Key.performanceStatistics, kCFAllocatorDefault, 0) != nil {
                return service
            }
            IOObjectRelease(service)
        }
        return 0
    }

    // MARK: Memory

    private func memory() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, totalMemory > 0 else { return nil }

        // Same definition as Activity Monitor's "Memory Used": app memory + wired + compressed.
        let appPages = UInt64(stats.internal_page_count) - UInt64(min(stats.purgeable_count, stats.internal_page_count))
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        let step = UInt64(1 << 30) / 10

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : 0

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
        let pressure: MemoryPressure = level >= 4 ? .critical : level >= 2 ? .warning : .normal

        return MemoryUsage(
            usedBytes: (used + step / 2) / step * step,
            totalBytes: totalMemory,
            swapUsedBytes: (swapUsed + step / 2) / step * step,
            pressure: pressure
        )
    }

    // MARK: Disk

    private func diskActivity() -> DiskActivity? {
        // The set of block storage drivers rarely changes; look it up once a minute, not every sample.
        if diskDrivers.isEmpty || diskDriversAge >= 60 {
            refreshDiskDrivers()
        }
        diskDriversAge += 1

        var read: Int64 = 0
        var written: Int64 = 0
        var busy: Int64 = 0 // nanoseconds spent on reads and writes, summed over requests
        for driver in diskDrivers {
            guard let stats = Self.dictionary(driver, Key.statistics) else {
                diskDriversAge = 60 // A driver went away; refresh next time.
                continue
            }
            read &+= Self.number(stats, Key.bytesRead) ?? 0
            written &+= Self.number(stats, Key.bytesWritten) ?? 0
            busy &+= Self.number(stats, Key.readTime) ?? 0
            busy &+= Self.number(stats, Key.writeTime) ?? 0
        }
        let (read64, written64, busy64) = (UInt64(max(0, read)), UInt64(max(0, written)), UInt64(max(0, busy)))
        return diskRates(read: read64, written: written64, busy: busy64)
    }

    private func refreshDiskDrivers() {
        diskDrivers.forEach { IOObjectRelease($0) }
        diskDrivers = []
        diskDriversAge = 0
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            diskDrivers.append(service)
        }
    }

    private func diskRates(read: UInt64, written: UInt64, busy: UInt64) -> DiskActivity? {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { lastDiskIO = (read, written, busy, now) }
        guard let last = lastDiskIO, now > last.time else { return nil }
        let elapsed = Double(now - last.time)
        let seconds = elapsed / 1_000_000_000
        let busyDelta = busy >= last.busy ? Double(busy - last.busy) : 0
        return DiskActivity(
            readBytesPerSecond: Self.quantizeSpeed(Double(read >= last.read ? read - last.read : 0) / seconds),
            writeBytesPerSecond: Self.quantizeSpeed(Double(written >= last.write ? written - last.write : 0) / seconds),
            busyPercent: Int(min(100, (busyDelta / elapsed * 100).rounded()))
        )
    }

    // MARK: Power & battery

    func battery() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let percent = description[kIOPSCurrentCapacityKey] as? Int
            else { continue }

            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let state: ChargeState = charging ? .charging : (onAC ? .onAC : .battery)

            var minutes: Int?
            switch state {
            case .battery: minutes = description[kIOPSTimeToEmptyKey] as? Int
            case .charging: minutes = description[kIOPSTimeToFullChargeKey] as? Int
            case .onAC: minutes = nil
            }
            // -1 means macOS is still calculating; 0 while charging means no estimate.
            if let value = minutes, value <= 0 { minutes = nil }

            return BatteryStatus(percent: percent, state: state, minutesRemaining: minutes)
        }
        return nil
    }

    private func power() -> Double? {
        guard openBatteryService() else { return nil }

        // The gauge's telemetry reports whole-system draw in mW, on battery and on AC alike.
        if let telemetry = Self.dictionary(batteryService, Key.powerTelemetry) {
            for key in [Key.systemLoad, Key.systemPowerIn] {
                if let milliwatts = Self.number(telemetry, key), milliwatts > 0 {
                    return (Double(milliwatts) / 100).rounded() / 10
                }
            }
        }
        if let millivolts = Self.number(batteryService, Key.voltage),
           let milliamps = Self.number(batteryService, Key.amperage),
           millivolts * milliamps != 0 {
            return (Double(abs(millivolts * milliamps)) / 100_000).rounded() / 10
        }
        return nil
    }

    private func openBatteryService() -> Bool {
        if batteryService == 0 {
            batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        return batteryService != 0
    }

    // MARK: CoreFoundation access

    /// Registry keys, created once. Values are read straight from the CFDictionary rather than
    /// bridged to a Swift Dictionary, which was the costliest part of a sample.
    private enum Key {
        static let performanceStatistics = "PerformanceStatistics" as CFString
        static let deviceUtilization = "Device Utilization %" as CFString
        static let gpuMemoryInUse = "In use system memory" as CFString
        static let statistics = "Statistics" as CFString
        static let bytesRead = "Bytes (Read)" as CFString
        static let bytesWritten = "Bytes (Write)" as CFString
        static let readTime = "Total Time (Read)" as CFString
        static let writeTime = "Total Time (Write)" as CFString
        static let powerTelemetry = "PowerTelemetryData" as CFString
        static let systemLoad = "SystemLoad" as CFString
        static let systemPowerIn = "SystemPowerIn" as CFString
        static let voltage = "Voltage" as CFString
        static let amperage = "InstantAmperage" as CFString
    }

    private static func dictionary(_ entry: io_registry_entry_t, _ key: CFString) -> CFDictionary? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(value) == CFDictionaryGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: CFDictionary.self)
    }

    private static func number(_ entry: io_registry_entry_t, _ key: CFString) -> Int64? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return number(value)
    }

    private static func number(_ dictionary: CFDictionary, _ key: CFString) -> Int64? {
        guard let raw = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        return number(Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue())
    }

    private static func number(_ value: CFTypeRef) -> Int64? {
        guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var result: Int64 = 0
        return CFNumberGetValue(unsafeBitCast(value, to: CFNumber.self), .sInt64Type, &result) ? result : nil
    }

    // MARK: Network

    private func network() -> NetworkRate? {
        // NET_RT_IFLIST2 returns 64-bit byte counters; getifaddrs' if_data wraps at 4 GB.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        if interfaceBuffer.count < length {
            interfaceBuffer = [UInt8](repeating: 0, count: length + 512)
        }
        guard sysctl(&mib, u_int(mib.count), &interfaceBuffer, &length, nil, 0) == 0 else { return nil }

        var up: UInt64 = 0
        var down: UInt64 = 0
        interfaceBuffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if countsInterface(message.ifm_index) {
                        up += message.ifm_data.ifi_obytes
                        down += message.ifm_data.ifi_ibytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }

        let now = DispatchTime.now().uptimeNanoseconds
        defer { lastNetwork = (up, down, now) }
        guard let last = lastNetwork, now > last.time else { return nil }

        let seconds = Double(now - last.time) / 1_000_000_000
        return NetworkRate(
            upBytesPerSecond: Self.quantizeSpeed(Double(up >= last.up ? up - last.up : 0) / seconds),
            downBytesPerSecond: Self.quantizeSpeed(Double(down >= last.down ? down - last.down : 0) / seconds)
        )
    }

    /// Physical Wi-Fi/Ethernet only, so VPN tunnels and AWDL don't double-count traffic.
    private func countsInterface(_ index: UInt16) -> Bool {
        if let cached = isCountedInterface[index] { return cached }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        let counted = if_indextoname(UInt32(index), &name) != nil && String(cString: name).hasPrefix("en")
        isCountedInterface[index] = counted
        return counted
    }

    private static func quantizeSpeed(_ bytesPerSecond: Double) -> Double {
        let step = bytesPerSecond >= 1_048_576 ? 104_857.6 : 1024
        return (bytesPerSecond / step).rounded() * step
    }
}
