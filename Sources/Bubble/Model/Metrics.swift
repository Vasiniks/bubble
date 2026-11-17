import Foundation

// Values here are already quantized to display precision, so equality checks can
// suppress SwiftUI invalidations when a sample would not change what's on screen.

struct CPULoad: Equatable {
    var total: Int
    var user: Int
    var system: Int
}

/// CPU core temperatures in whole °C.
struct CoreTemperature: Equatable {
    /// Average over every core that is currently reporting.
    var average: Int
    /// Hottest single core sensor.
    var hottest: Int
}

enum ChargeState: Equatable {
    case battery
    case charging
    case onAC
}

struct BatteryStatus: Equatable {
    var percent: Int
    var state: ChargeState
    /// Minutes to empty (on battery) or to full (charging). `nil` while macOS is still estimating.
    var minutesRemaining: Int?
}

enum MemoryPressure: Equatable {
    case normal
    case warning
    case critical
}

struct MemoryUsage: Equatable {
    var usedBytes: UInt64
    var totalBytes: UInt64
    var swapUsedBytes: UInt64 = 0
    var pressure: MemoryPressure = .normal

    var fraction: Double {
        totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0
    }
}

struct NetworkRate: Equatable {
    var upBytesPerSecond: Double
    var downBytesPerSecond: Double
}

struct DiskActivity: Equatable {
    var readBytesPerSecond: Double
    var writeBytesPerSecond: Double
    /// Share of the interval the disks were busy (summed read + write time), 0–100.
    var busyPercent: Int
}

/// Fixed-length rolling window of samples for graphs (percentages, bytes/s or watts).
/// Graphs draw 2 pt per sample, so a wider graph simply shows further back.
struct History: Equatable {
    static let capacity = 240
    private(set) var values: [Float] = []

    mutating func append(_ value: Double) {
        if values.count == Self.capacity { values.removeFirst() }
        values.append(Float(max(0, value)))
    }

    var peak: Float {
        values.max() ?? 0
    }
}

enum Format {
    static let unavailable = "—"

    static func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? unavailable
    }

    static func duration(minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return unavailable }
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    static func temperature(_ celsius: Int?) -> String {
        celsius.map { "\($0)°" } ?? unavailable
    }

    static func watts(_ watts: Double?) -> String {
        watts.map { String(format: "%.1f W", $0) } ?? unavailable
    }

    static func memory(_ usage: MemoryUsage?) -> String {
        guard let usage else { return unavailable }
        let gib = Double(1 << 30)
        return String(format: "%.1f / %.0f GB", Double(usage.usedBytes) / gib, Double(usage.totalBytes) / gib)
    }

    static func memoryUsed(_ usage: MemoryUsage?) -> String {
        guard let usage else { return unavailable }
        return String(format: "%.1f GB", Double(usage.usedBytes) / Double(1 << 30))
    }

    static func bytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / Double(1 << 30)
        if gib >= 100 { return String(format: "%.0f GB", gib) }
        if gib >= 1 { return String(format: "%.1f GB", gib) }
        return String(format: "%.0f MB", Double(bytes) / Double(1 << 20))
    }

    static func network(_ rate: NetworkRate?) -> String {
        guard let rate else { return unavailable }
        return "↑ \(speed(rate.upBytesPerSecond))  ↓ \(speed(rate.downBytesPerSecond))"
    }

    static func diskActivity(_ activity: DiskActivity?) -> String {
        guard let activity else { return unavailable }
        return "R \(speed(activity.readBytesPerSecond))  W \(speed(activity.writeBytesPerSecond))"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }

    static func speed(_ bytesPerSecond: Double?) -> String {
        bytesPerSecond.map { speed($0) } ?? unavailable
    }

    /// Glance-style short rate: 0, 512K, 4.2M, 38M, 1.1G (per second implied).
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond else { return unavailable }
        let kib = value / 1024
        if kib < 1 { return "0" }
        if kib < 1000 { return "\(Int(kib.rounded()))K" }
        let mib = kib / 1024
        if mib < 10 { return String(format: "%.1fM", mib) }
        if mib < 1000 { return "\(Int(mib.rounded()))M" }
        return String(format: "%.1fG", mib / 1024)
    }

    /// Short gigabytes: 0.4G, 13.4G.
    static func gigabytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return unavailable }
        return String(format: "%.1fG", Double(bytes) / Double(1 << 30))
    }

    static func playback(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func pressure(_ pressure: MemoryPressure?) -> String {
        switch pressure {
        case .normal: return "normal"
        case .warning: return "high"
        case .critical: return "critical"
        case nil: return ""
        }
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "warm"
        case .serious: return "throttling"
        case .critical: return "critical"
        @unknown default: return ""
        }
    }

    /// Compact battery text: time remaining first; percentage only when no estimate applies.
    static func batteryCompact(_ battery: BatteryStatus?) -> String {
        guard let battery else { return unavailable }
        switch battery.state {
        case .battery:
            return duration(minutes: battery.minutesRemaining)
        case .charging:
            return battery.minutesRemaining.map { duration(minutes: $0) } ?? "\(battery.percent)%"
        case .onAC:
            return "\(battery.percent)%"
        }
    }

    static func batteryPercent(_ battery: BatteryStatus?) -> String {
        battery.map { "\($0.percent)%" } ?? unavailable
    }

    static func timeRemaining(_ battery: BatteryStatus?) -> String {
        guard let battery, battery.state != .onAC else { return unavailable }
        return duration(minutes: battery.minutesRemaining)
    }

    static func chargeState(_ battery: BatteryStatus?) -> String {
        switch battery?.state {
        case .battery: return "on battery"
        case .charging: return "charging"
        case .onAC: return "on power"
        case nil: return ""
        }
    }
}
