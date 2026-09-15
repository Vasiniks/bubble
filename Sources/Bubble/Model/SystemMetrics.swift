import Foundation

public struct CPUMetrics: Sendable {
    public var usagePercent: Double = 0.0
    public var userPercent: Double = 0.0
    public var systemPercent: Double = 0.0
    public var idlePercent: Double = 100.0
    public var coreCount: Int = ProcessInfo.processInfo.processorCount
    
    public var formattedPercent: String {
        String(format: "%.0f%%", usagePercent)
    }
}

public struct GPUMetrics: Sendable {
    public var utilizationPercent: Double = 0.0
    public var rendererUtilizationPercent: Double = 0.0
    public var modelName: String = "Apple GPU"
    
    public var formattedPercent: String {
        String(format: "%.0f%%", utilizationPercent)
    }
}

public enum MemoryPressure: String, Sendable {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"
}

public struct MemoryMetrics: Sendable {
    public var usedBytes: UInt64 = 0
    public var totalBytes: UInt64 = 0
    public var freeBytes: UInt64 = 0
    public var pressure: MemoryPressure = .normal
    
    public var usedPercent: Double {
        guard totalBytes > 0 else { return 0.0 }
        return (Double(usedBytes) / Double(totalBytes)) * 100.0
    }
    
    public var formattedUsed: String {
        ByteCountFormatter.string(fromByteCount: Int64(usedBytes), countStyle: .memory)
    }
    
    public var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .memory)
    }
    
    public var formattedPercent: String {
        String(format: "%.0f%%", usedPercent)
    }
}

public struct PowerMetrics: Sendable {
    public var watts: Double = 0.0
    public var batteryPercent: Int = 100
    public var isCharging: Bool = false
    public var isPluggedIn: Bool = false
    public var timeRemainingMinutes: Int? = nil
    public var powerSourceState: String = "AC Power"
    
    public var formattedTimeRemaining: String {
        if isCharging {
            if let mins = timeRemainingMinutes, mins > 0 {
                let h = mins / 60
                let m = mins % 60
                return "\(h)h \(m)m to full"
            }
            return "Charging"
        }
        if let mins = timeRemainingMinutes, mins > 0 {
            let h = mins / 60
            let m = mins % 60
            return "\(h)h \(m)m"
        }
        if isPluggedIn {
            return "Plugged In"
        }
        return "\(batteryPercent)%"
    }
    
    public var formattedWatts: String {
        String(format: "%.1f W", watts)
    }
}

public struct NetworkMetrics: Sendable {
    public var bytesInPerSec: Double = 0.0
    public var bytesOutPerSec: Double = 0.0
    public var totalInBytes: UInt64 = 0
    public var totalOutBytes: UInt64 = 0
    
    public var formattedDown: String {
        Self.formatSpeed(bytesInPerSec)
    }
    
    public var formattedUp: String {
        Self.formatSpeed(bytesOutPerSec)
    }
    
    private static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSec / 1_048_576.0)
        } else if bytesPerSec >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024.0)
        } else {
            return String(format: "%.0f B/s", bytesPerSec)
        }
    }
}

public struct SystemSnapshot: Sendable {
    public var cpu = CPUMetrics()
    public var gpu = GPUMetrics()
    public var memory = MemoryMetrics()
    public var power = PowerMetrics()
    public var network = NetworkMetrics()
    public var timestamp = Date()
}
