import Darwin
import IOKit
import IOKit.ps

/// Reads raw system metrics using Mach, IOKit and sysctl. Not thread-safe; confine to one queue.
final class SystemSampler {
    struct Reading {
        var cpu: CPULoad?
        var gpu: Int?
        var temperatureSampled = false
        var temperature: Int?
        var detailSampled = false
        var memory: MemoryUsage?
        var power: Double?
        var network: NetworkRate?
    }

    /// Temperature changes slowly; in compact mode it is read at most this often.
    private static let temperatureInterval: UInt64 = 5_000_000_000

    // mach_host_self() adds a port reference on every call, so take it once.
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let totalMemory: UInt64
    private let temperature = TemperatureSensor()

    private var lastCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var lastNetwork: (up: UInt64, down: UInt64, time: UInt64)?
    private var lastTemperatureTime: UInt64 = 0
    private var gpuService: io_registry_entry_t = 0
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
        if batteryService != 0 { IOObjectRelease(batteryService) }
        mach_port_deallocate(mach_task_self_, host)
    }

    func read(detailed: Bool) -> Reading {
        var reading = Reading(cpu: cpu(), gpu: gpu())

        let now = DispatchTime.now().uptimeNanoseconds
        if detailed || now - lastTemperatureTime >= Self.temperatureInterval {
            lastTemperatureTime = now
            reading.temperatureSampled = true
            reading.temperature = temperature.read().map { Int($0.rounded()) }
        }

        if detailed {
            reading.detailSampled = true
            reading.memory = memory()
            reading.power = power()
            reading.network = network()
        }
        return reading
    }

    /// Records a network baseline so the first detailed sample has a short, accurate delta.
    func primeNetwork() {
        _ = network()
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

    // MARK: GPU

    private func gpu() -> Int? {
        if gpuService == 0 {
            gpuService = Self.findGPUService()
        }
        guard gpuService != 0 else { return nil }

        // Read only PerformanceStatistics rather than the accelerator's full property table.
        guard let stats = IORegistryEntryCreateCFProperty(gpuService, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
            let utilization = stats["Device Utilization %"] as? Int
        else {
            IOObjectRelease(gpuService)
            gpuService = 0
            return nil
        }
        return min(100, max(0, utilization))
    }

    private static func findGPUService() -> io_registry_entry_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            if IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0) != nil {
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
        return MemoryUsage(usedBytes: (used + step / 2) / step * step, totalBytes: totalMemory)
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
        if batteryService == 0 {
            batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        guard batteryService != 0 else { return nil }

        // The gauge's telemetry reports whole-system draw in mW, on battery and on AC alike.
        if let telemetry = registryProperty(batteryService, "PowerTelemetryData") as? [String: Any] {
            for key in ["SystemLoad", "SystemPowerIn"] {
                if let milliwatts = telemetry[key] as? Int, milliwatts > 0 {
                    return (Double(milliwatts) / 100).rounded() / 10
                }
            }
        }
        if let millivolts = registryProperty(batteryService, "Voltage") as? Int,
           let milliamps = registryProperty(batteryService, "InstantAmperage") as? Int,
           millivolts * milliamps != 0 {
            return (Double(abs(millivolts * milliamps)) / 100_000).rounded() / 10
        }
        return nil
    }

    private func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
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
