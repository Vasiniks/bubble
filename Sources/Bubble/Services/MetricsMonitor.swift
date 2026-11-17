import AppKit
import IOKit.ps
import Observation

/// Publishes display-ready metrics and their recent history. One low-priority timer drives
/// everything: every 2 s (the Refresh preference) while closed, every second while open.
/// Readings are microseconds each; closed, nothing draws them. Sampling stops while the
/// displays sleep, and battery state is pushed by macOS rather than polled.
@MainActor
@Observable
final class MetricsMonitor {
    static let shared = MetricsMonitor()

    private(set) var cpu: CPULoad?
    /// Per-core load while open, efficiency cores first (see `efficiencyCores`).
    private(set) var cores: [UInt8] = []
    private(set) var gpu: Int?
    private(set) var gpuMemory: UInt64?
    private(set) var temperature: CoreTemperature?
    private(set) var battery: BatteryStatus?
    private(set) var memory: MemoryUsage?
    private(set) var power: Double?
    private(set) var network: NetworkRate?
    private(set) var diskActivity: DiskActivity?
    private(set) var thermalState = ProcessInfo.ThermalState.nominal
    /// When the last sample landed. Other once-a-second views (the playback position) key off
    /// this so the whole notch redraws in one pass per second instead of several.
    private(set) var sampledAt = Date()

    /// Recent samples for the graphs, kept in every mode so they're full when the notch opens.
    private(set) var cpuHistory = History()
    private(set) var gpuHistory = History()
    private(set) var memoryHistory = History()
    /// GPU memory in use, as a share of physical memory (it's unified on Apple Silicon).
    private(set) var gpuMemoryHistory = History()
    private(set) var diskBusyHistory = History()
    private(set) var diskReadHistory = History()
    private(set) var diskWriteHistory = History()
    private(set) var downloadHistory = History()
    private(set) var uploadHistory = History()

    /// Efficiency-core count; the kernel lists them before the performance cores.
    let efficiencyCores = MetricsMonitor.sysctlInt("hw.perflevel1.logicalcpu")
    let physicalMemory = ProcessInfo.processInfo.physicalMemory

    @ObservationIgnored private let queue = DispatchQueue(label: "com.eason.bubble.metrics", qos: .utility)
    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var isSuspended = false

    private static let openInterval: TimeInterval = 1

    private init() {}

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSuspended(true) }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSuspended(false) }
        }

        // Battery state is event-driven: powerd notifies whenever charge or estimates change.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<MetricsMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refreshBattery() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        refreshBattery()
        restart(firstSampleAfter: 0.5)
    }

    /// Open: sample every second and read temperature every time. Sample right away so the
    /// numbers are fresh as the notch opens.
    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        restart(firstSampleAfter: open ? 0.05 : nil)
    }

    func restart(firstSampleAfter delay: TimeInterval? = nil) {
        timer?.cancel()
        timer = nil
        guard !isSuspended else { return }

        let open = isOpen
        let preferred = Preferences.shared.refreshInterval
        let interval = open ? min(Self.openInterval, preferred) : preferred
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway lets the kernel coalesce this wakeup with other work.
        timer.schedule(deadline: .now() + (delay ?? interval), repeating: interval, leeway: .milliseconds(Int(interval * 250)))
        timer.setEventHandler { [sampler] in
            let reading = sampler.read(open: open)
            DispatchQueue.main.async {
                MetricsMonitor.shared.apply(reading)
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if suspended {
            timer?.cancel()
            timer = nil
        } else {
            refreshBattery()
            restart(firstSampleAfter: 1)
        }
    }

    private func refreshBattery() {
        queue.async { [sampler] in
            let battery = sampler.battery()
            DispatchQueue.main.async {
                MetricsMonitor.shared.update(\.battery, battery)
            }
        }
    }

    private func apply(_ reading: SystemSampler.Reading) {
        sampledAt = Date()
        update(\.cpu, reading.cpu)
        update(\.cores, reading.cores)
        update(\.gpu, reading.gpu)
        update(\.gpuMemory, reading.gpuMemory)
        update(\.memory, reading.memory)
        update(\.power, reading.power)
        update(\.network, reading.network)
        update(\.diskActivity, reading.diskActivity)
        if reading.temperatureSampled {
            update(\.temperature, reading.temperature)
            update(\.thermalState, ProcessInfo.processInfo.thermalState)
        }

        if let cpu = reading.cpu { cpuHistory.append(Double(cpu.total)) }
        if let gpu = reading.gpu { gpuHistory.append(Double(gpu)) }
        if let bytes = reading.gpuMemory, physicalMemory > 0 {
            gpuMemoryHistory.append(Double(bytes) / Double(physicalMemory) * 100)
        }
        if let memory = reading.memory { memoryHistory.append(memory.fraction * 100) }
        if let disk = reading.diskActivity {
            diskBusyHistory.append(Double(disk.busyPercent))
            diskReadHistory.append(disk.readBytesPerSecond)
            diskWriteHistory.append(disk.writeBytesPerSecond)
        }
        if let network = reading.network {
            downloadHistory.append(network.downBytesPerSecond)
            uploadHistory.append(network.upBytesPerSecond)
        }
    }

    private static func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
    }

    /// Observation notifies on every assignment, so skip writes that wouldn't change the UI.
    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<MetricsMonitor, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}
