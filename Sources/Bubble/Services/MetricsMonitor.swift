import AppKit
import IOKit.ps
import Observation

/// Publishes display-ready metrics. One low-priority timer drives everything; compact mode
/// skips memory/power/network reads entirely, and sampling stops while the displays sleep.
@MainActor
@Observable
final class MetricsMonitor {
    static let shared = MetricsMonitor()

    private(set) var cpu: CPULoad?
    private(set) var gpu: Int?
    private(set) var temperature: Int?
    private(set) var battery: BatteryStatus?
    private(set) var memory: MemoryUsage?
    private(set) var power: Double?
    private(set) var network: NetworkRate?

    @ObservationIgnored private let queue = DispatchQueue(label: "com.eason.bubble.metrics", qos: .utility)
    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var isDetailed = false
    @ObservationIgnored private var isSuspended = false

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

    /// Expanded mode needs the extra metrics; sample almost immediately so they aren't stale.
    func setDetailed(_ detailed: Bool) {
        guard detailed != isDetailed else { return }
        isDetailed = detailed
        if detailed {
            queue.async { [sampler] in sampler.primeNetwork() }
        }
        restart(firstSampleAfter: detailed ? 0.35 : nil)
    }

    func restart(firstSampleAfter delay: TimeInterval? = nil) {
        timer?.cancel()
        timer = nil
        guard !isSuspended else { return }

        let interval = Preferences.shared.refreshInterval
        let detailed = isDetailed
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway lets the kernel coalesce this wakeup with other work.
        timer.schedule(deadline: .now() + (delay ?? interval), repeating: interval, leeway: .milliseconds(Int(interval * 250)))
        timer.setEventHandler { [sampler] in
            let reading = sampler.read(detailed: detailed)
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
        update(\.cpu, reading.cpu)
        update(\.gpu, reading.gpu)
        if reading.temperatureSampled {
            update(\.temperature, reading.temperature)
        }
        if reading.detailSampled {
            update(\.memory, reading.memory)
            update(\.power, reading.power)
            update(\.network, reading.network)
        }
    }

    /// Observation notifies on every assignment, so skip writes that wouldn't change the UI.
    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<MetricsMonitor, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}
