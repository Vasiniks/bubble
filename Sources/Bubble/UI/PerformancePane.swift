import SwiftUI

/// Left half of Home, styled after Glance: one strip per device, each a graph in a dark
/// hue-tinted well beside a two-line readout.
///
///   CPU      one tile per core (performance above efficiency), plus load history when wide
///   RAM      memory in use
///   GPU      load, with GPU memory as a thin band
///   Disk     busy time, with read and write as thin bands
///   Network  download, with upload as a thin band
///   Battery  charge as a plain bar
///
/// The same rows serve both widths: popped up, the graphs are simply wider and reach further
/// back. Each row is its own view reading only what it draws.
struct PerformancePane: View {
    let monitor: MetricsMonitor

    var body: some View {
        VStack(spacing: 3) {
            CPURow(monitor: monitor)
            MemoryRow(monitor: monitor)
            GPURow(monitor: monitor)
            DiskRow(monitor: monitor)
            NetworkRow(monitor: monitor)
            BatteryRow(monitor: monitor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private enum Floors {
    static let disk: Float = 1_048_576 // 1 MB/s
    static let network: Float = 131_072 // 128 KB/s
}

private enum Ink {
    static let value = RGB(0xE8EDF4)
    static let detail = RGB(0x9AA4B2)
    static let cpuIcon = RGB(0xAEB7C4)
    static let memoryIcon = RGB(0x8EB6DC)
    static let gpuIcon = RGB(0xB1AADB)
    static let diskIcon = RGB(0x96BD96)
    static let networkIcon = RGB(0xD79FAF)
    static let batteryIcon = RGB(0xD9C08F)
}

private struct MeterRow<Readout: View>: View {
    let symbol: String
    let icon: RGB
    let draw: (GraphicsContext, CGRect) -> Void
    @ViewBuilder var readout: Readout

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(icon.color)
                .frame(width: 14)
            Canvas { context, size in
                draw(context, CGRect(origin: .zero, size: size))
            }
            .padding(.vertical, 3)
            VStack(alignment: .leading, spacing: 0) {
                readout
            }
            .lineLimit(1)
            .frame(width: 74, alignment: .leading)
        }
        .frame(height: 26)
    }
}

private func value(_ text: String, _ color: RGB) -> Text {
    Text(text)
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundColor(color.color)
}

private func detail(_ text: String, _ color: RGB = Ink.detail) -> Text {
    Text(text)
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundColor(color.color)
}

// MARK: - CPU

private struct CPURow: View {
    let monitor: MetricsMonitor

    var body: some View {
        let cores = monitor.cores
        let efficiency = monitor.efficiencyCores
        let history = monitor.cpuHistory
        let temperature = monitor.temperature?.average

        MeterRow(symbol: "cpu", icon: Ink.cpuIcon, draw: { context, rect in
            // Square tiles plus a load graph when there's room; otherwise the tiles fill the row.
            var tiles = CoreTiles(loads: cores, efficiencyCount: efficiency, height: rect.height)
            let graphX = rect.minX + tiles.width + 6
            if rect.maxX - graphX >= 60 {
                tiles.draw(context, at: rect.origin)
                Meter.draw(context, in: CGRect(x: graphX, y: rect.minY, width: rect.maxX - graphX, height: rect.height), history, hue: .cpu)
            } else {
                tiles.stretch(to: rect.width)
                tiles.draw(context, at: rect.origin)
            }
        }) {
            value(Format.percent(monitor.cpu?.total), Ink.value)
            averages(cores, efficiency) + detail(Format.temperature(temperature), temperatureInk(temperature))
        }
    }

    /// "P41 E22 " on hybrid chips.
    private func averages(_ cores: [UInt8], _ efficiency: Int) -> Text {
        guard efficiency > 0, cores.count > efficiency else { return detail("") }
        func mean(_ slice: ArraySlice<UInt8>) -> Int { Int((Double(slice.reduce(0) { $0 + Int($1) }) / Double(slice.count)).rounded()) }
        return detail("P\(mean(cores[efficiency...])) E\(mean(cores[..<efficiency])) ")
    }

    private func temperatureInk(_ celsius: Int?) -> RGB {
        guard let celsius else { return Ink.detail }
        return celsius >= 90 ? RGB(0xFF7566) : celsius >= 78 ? RGB(0xFFBD61) : Ink.detail
    }
}

/// One tile per logical core in a single row, brighter when busier: performance cores first,
/// then (after a slightly wider gap) efficiency cores.
private struct CoreTiles {
    let loads: [UInt8]
    let efficiencyCount: Int
    let height: CGFloat
    private var tileWidth: CGFloat = 9

    init(loads: [UInt8], efficiencyCount: Int, height: CGFloat) {
        self.loads = loads
        self.efficiencyCount = efficiencyCount
        self.height = height
    }

    private static let gap: CGFloat = 2
    private static let groupGap: CGFloat = 5
    private static let coreCount = ProcessInfo.processInfo.activeProcessorCount

    private var count: Int { loads.isEmpty ? Self.coreCount : loads.count }
    private var isHybrid: Bool { efficiencyCount > 0 && efficiencyCount < count }

    /// Core indices in drawing order; the kernel lists efficiency cores first.
    private var order: [Int] {
        isHybrid ? Array(efficiencyCount ..< count) + Array(0 ..< efficiencyCount) : Array(0 ..< count)
    }

    private var gaps: CGFloat {
        CGFloat(max(0, count - 1)) * Self.gap + (isHybrid ? Self.groupGap - Self.gap : 0)
    }

    var width: CGFloat {
        CGFloat(count) * tileWidth + gaps
    }

    /// Widens the tiles so the row spans `width`.
    mutating func stretch(to width: CGFloat) {
        guard count > 0 else { return }
        tileWidth = max(4, (width - gaps) / CGFloat(count))
    }

    func draw(_ context: GraphicsContext, at origin: CGPoint) {
        var x = origin.x
        let performanceCount = count - efficiencyCount
        for (position, core) in order.enumerated() {
            if isHybrid, position == performanceCount { x += Self.groupGap - Self.gap }
            let tile = CGRect(x: x, y: origin.y, width: tileWidth, height: height)
            let load = core < loads.count ? loads[core] : 0
            context.fill(Path(roundedRect: tile, cornerRadius: 2), with: .color(Hue.core(load)))
            x += tileWidth + Self.gap
        }
    }
}

// MARK: - Memory, GPU

private struct MemoryRow: View {
    let monitor: MetricsMonitor

    var body: some View {
        let memory = monitor.memory
        let history = monitor.memoryHistory
        let percent = memory.map { Int(($0.fraction * 100).rounded()) }
        let pressure = memory?.pressure ?? .normal

        MeterRow(symbol: "memorychip", icon: Ink.memoryIcon, draw: { context, rect in
            Meter.draw(context, in: rect, history, hue: .memory)
        }) {
            // High memory pressure tints the figure, since that's when swapping starts to hurt.
            value(Format.percent(percent), pressure == .critical ? RGB(0xFF7566) : pressure == .warning ? RGB(0xFFBD61) : Hue.memory.text)
            detail(memory.map { "\(Format.gigabytes($0.usedBytes).dropLast())/\(Int((Double($0.totalBytes) / Double(1 << 30)).rounded()))G" } ?? Format.unavailable,
                   Hue.memory.text.mix(RGB(0x000000), 0.2))
        }
    }
}

private struct GPURow: View {
    let monitor: MetricsMonitor

    var body: some View {
        let load = monitor.gpuHistory
        let memory = monitor.gpuMemoryHistory

        MeterRow(symbol: "cube", icon: Ink.gpuIcon, draw: { context, rect in
            let bands = Meter.bands(rect, [14, 6])
            Meter.draw(context, in: bands[0], load, hue: .gpu)
            Meter.draw(context, in: bands[1], memory, hue: .gpuMemory)
        }) {
            value(Format.percent(monitor.gpu), Hue.gpu.text)
            detail(Format.gigabytes(monitor.gpuMemory), Hue.gpuMemory.text)
        }
    }
}

// MARK: - Disk, network

private struct DiskRow: View {
    let monitor: MetricsMonitor

    var body: some View {
        let busy = monitor.diskBusyHistory
        let read = monitor.diskReadHistory
        let write = monitor.diskWriteHistory
        let activity = monitor.diskActivity

        MeterRow(symbol: "internaldrive", icon: Ink.diskIcon, draw: { context, rect in
            let bands = Meter.bands(rect, [10, 4, 4])
            Meter.draw(context, in: bands[0], busy, hue: .diskBusy)
            Meter.draw(context, in: bands[1], read, hue: .diskRead, floor: Floors.disk)
            Meter.draw(context, in: bands[2], write, hue: .diskWrite, floor: Floors.disk)
        }) {
            value(Format.percent(activity?.busyPercent), Hue.diskBusy.text)
            detail("R" + Format.rate(activity?.readBytesPerSecond), Hue.diskRead.text)
                + detail(" W" + Format.rate(activity?.writeBytesPerSecond), Hue.diskWrite.text)
        }
    }
}

private struct NetworkRow: View {
    let monitor: MetricsMonitor

    var body: some View {
        let download = monitor.downloadHistory
        let upload = monitor.uploadHistory
        let network = monitor.network

        MeterRow(symbol: "network", icon: Ink.networkIcon, draw: { context, rect in
            let bands = Meter.bands(rect, [14, 6])
            Meter.draw(context, in: bands[0], download, hue: .download, floor: Floors.network)
            Meter.draw(context, in: bands[1], upload, hue: .upload, floor: Floors.network)
        }) {
            value("↓" + Format.rate(network?.downBytesPerSecond), Hue.download.text)
            detail("↑" + Format.rate(network?.upBytesPerSecond), Hue.upload.text)
        }
    }
}

// MARK: - Battery

/// Charge as a plain bar (it moves too slowly to need a history), with watts and time left.
private struct BatteryRow: View {
    let monitor: MetricsMonitor

    var body: some View {
        let battery = monitor.battery
        let fraction = CGFloat(battery?.percent ?? 0) / 100
        let low = battery.map { $0.state == .battery && $0.percent <= 20 } ?? false

        MeterRow(symbol: symbol(battery), icon: Ink.batteryIcon, draw: { context, rect in
            Meter.bar(context, in: rect, fraction: fraction, hue: low ? .batteryLow : .power)
        }) {
            value(Format.batteryPercent(battery), chargeInk(battery))
            detail(details(battery))
        }
    }

    private func details(_ battery: BatteryStatus?) -> String {
        let watts = monitor.power.map { String(format: "%.1fW", $0) } ?? Format.unavailable
        guard let battery, battery.state != .onAC, let minutes = battery.minutesRemaining else { return watts }
        return "\(watts) \(Format.duration(minutes: minutes).replacingOccurrences(of: " ", with: ""))"
    }

    private func chargeInk(_ battery: BatteryStatus?) -> RGB {
        guard let battery, battery.state == .battery, battery.percent <= 20 else { return Hue.power.text }
        return Hue.batteryLow.text
    }

    private func symbol(_ battery: BatteryStatus?) -> String {
        guard let battery else { return "battery.100percent" }
        if battery.state == .charging { return "battery.100percent.bolt" }
        switch battery.percent {
        case 76...: return "battery.100percent"
        case 51...: return "battery.75percent"
        case 21...: return "battery.50percent"
        default: return "battery.25percent"
        }
    }
}
