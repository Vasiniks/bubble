import Foundation

// Values here are already quantized to display precision, so equality checks can
// suppress SwiftUI invalidations when a sample would not change what's on screen.

struct CPULoad: Equatable {
    var total: Int
    var user: Int
    var system: Int
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

struct MemoryUsage: Equatable {
    var usedBytes: UInt64
    var totalBytes: UInt64

    var fraction: Double {
        totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0
    }
}

struct NetworkRate: Equatable {
    var upBytesPerSecond: Double
    var downBytesPerSecond: Double
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

    static func network(_ rate: NetworkRate?) -> String {
        guard let rate else { return unavailable }
        return "↑ \(speed(rate.upBytesPerSecond))  ↓ \(speed(rate.downBytesPerSecond))"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
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
