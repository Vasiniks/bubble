import SwiftUI

private enum Palette {
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let track = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.07)
    static let warm = Color(red: 1.0, green: 0.74, blue: 0.38)
    static let hot = Color(red: 1.0, green: 0.46, blue: 0.40)

    static func load(_ percent: Int?) -> Color {
        guard let percent else { return primary }
        return percent >= 90 ? hot : percent >= 75 ? warm : primary
    }

    static func temperature(_ celsius: Int?) -> Color {
        guard let celsius else { return secondary }
        return celsius >= 90 ? hot : celsius >= 78 ? warm : secondary
    }
}

/// Root view. Each metric is read by its own small subview, so with Observation a new
/// sample only re-renders the pieces whose values actually changed. Metric changes are
/// deliberately not animated: a tween would render dozens of frames for every sample.
struct BubbleView: View {
    let state: OverlayState
    let monitor: MetricsMonitor
    let prefs: Preferences

    var body: some View {
        let geometry = state.geometry
        let expanded = state.isExpanded
        let size = geometry.size(expanded: expanded, compactStatus: prefs.showsCompactStatus)
        let shape = BubbleShape(
            flare: BubbleGeometry.flare,
            bottomRadius: expanded ? 22 : min(14, (size.height - BubbleGeometry.flare) / 2)
        )

        ZStack(alignment: .top) {
            shape.fill(Color.black)

            // Fixed-width content so nothing reflows while the shape animates; the clip reveals it.
            VStack(spacing: 0) {
                topRow(geometry)
                if expanded {
                    DetailGrid(monitor: monitor)
                        .padding(.horizontal, BubbleGeometry.flare + 18)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.1)),
                            removal: .opacity.animation(.easeIn(duration: 0.08))
                        ))
                }
            }
            .frame(width: geometry.expandedSize.width, alignment: .top)
            .opacity(state.isPressed ? 0.55 : 1)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Temperature · CPU  [camera]  GPU · battery. Identical in both modes, so the rings
    /// stay put while the shape grows around them.
    private func topRow(_ geometry: BubbleGeometry) -> some View {
        let wing = geometry.wing(compactStatus: prefs.showsCompactStatus)
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                if prefs.showTemperature {
                    TemperatureCompact(monitor: monitor)
                }
                Spacer(minLength: 0)
                RingLabel(text: "CPU")
                CPURing(monitor: monitor, diameter: geometry.ringDiameter)
            }
            .padding(.leading, 14)
            .padding(.trailing, 9)
            .frame(width: wing)

            Color.clear.frame(width: geometry.centerWidth)

            HStack(spacing: 6) {
                GPURing(monitor: monitor, diameter: geometry.ringDiameter)
                RingLabel(text: "GPU")
                Spacer(minLength: 0)
                if prefs.showBatteryTime {
                    BatteryCompact(monitor: monitor)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 14)
            .frame(width: wing)
        }
        .font(.system(size: 10, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(Palette.secondary)
        .frame(height: geometry.topHeight)
    }
}

/// Flush with the top screen edge, flared into it at the top corners, rounded at the bottom.
struct BubbleShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = max(0, min(bottomRadius, rect.height - flare, (rect.width - 2 * flare) / 2))
        let left = rect.minX + flare
        let right = rect.maxX - flare
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left, y: rect.minY + flare), radius: flare)
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: left + radius, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY - radius), radius: radius)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: flare)
        path.closeSubpath()
        return path
    }
}

// MARK: - Rings

private struct RingLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Palette.tertiary)
            .fixedSize()
    }
}

private struct CPURing: View {
    let monitor: MetricsMonitor
    let diameter: CGFloat

    var body: some View {
        LoadRing(percent: monitor.cpu?.total, diameter: diameter)
    }
}

private struct GPURing: View {
    let monitor: MetricsMonitor
    let diameter: CGFloat

    var body: some View {
        LoadRing(percent: monitor.gpu, diameter: diameter)
    }
}

private struct LoadRing: View {
    let percent: Int?
    let diameter: CGFloat

    private var lineWidth: CGFloat { diameter >= 22 ? 2.25 : 2 }

    var body: some View {
        let fraction = CGFloat(percent ?? 0) / 100
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(Palette.track, lineWidth: lineWidth)
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: fraction)
                .stroke(Palette.load(percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(fraction > 0 ? 1 : 0)
            Text(percent.map(String.init) ?? Format.unavailable)
                .font(.system(size: (diameter * 0.37).rounded(), weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.primary)
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Compact status

private struct BatteryCompact: View {
    let monitor: MetricsMonitor

    var body: some View {
        if let battery = monitor.battery {
            HStack(spacing: 4) {
                Image(systemName: symbol(for: battery))
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Palette.tertiary)
                Text(Format.batteryCompact(battery))
            }
            .fixedSize()
        }
    }

    private func symbol(for battery: BatteryStatus) -> String {
        switch battery.state {
        case .charging: return "bolt.fill"
        case .onAC: return "powerplug.fill"
        case .battery:
            switch battery.percent {
            case 76...: return "battery.100percent"
            case 51...: return "battery.75percent"
            case 21...: return "battery.50percent"
            default: return "battery.25percent"
            }
        }
    }
}

private struct TemperatureCompact: View {
    let monitor: MetricsMonitor

    var body: some View {
        HStack(spacing: 5) {
            Text(Format.temperature(monitor.temperature))
            TemperatureBar(celsius: monitor.temperature)
        }
        .fixedSize()
    }
}

private struct TemperatureBar: View {
    let celsius: Int?

    var body: some View {
        let fraction = CGFloat(min(1, max(0, (Double(celsius ?? 0) - 30) / 70)))
        MiniBar(fraction: fraction, color: Palette.temperature(celsius), width: 14)
    }
}

private struct MiniBar: View {
    let fraction: CGFloat
    let color: Color
    let width: CGFloat

    var body: some View {
        Capsule()
            .fill(Palette.track)
            .frame(width: width, height: 2.5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(color)
                    .frame(width: max(2.5, width * fraction), height: 2.5)
            }
    }
}

// MARK: - Expanded detail

/// Two short columns keep the expanded Bubble wide and shallow, like the collapsed one.
private struct DetailGrid: View {
    let monitor: MetricsMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 0) {
                CPUDetailRow(monitor: monitor)
                Hairline()
                GPUDetailRow(monitor: monitor)
                Hairline()
                MemoryDetailRow(monitor: monitor)
                Hairline()
                TemperatureDetailRow(monitor: monitor)
            }
            VStack(spacing: 0) {
                NetworkDetailRow(monitor: monitor)
                Hairline()
                PowerDetailRow(monitor: monitor)
                Hairline()
                BatteryDetailRow(monitor: monitor)
                Hairline()
                RemainingDetailRow(monitor: monitor)
            }
        }
        .padding(.top, 6)
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle().fill(Palette.hairline).frame(height: 0.5)
    }
}

private struct DetailRow<Accessory: View>: View {
    let label: String
    let value: String
    var note: String = ""
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.tertiary)
            Spacer(minLength: 6)
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
            }
            accessory
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.primary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 22)
    }
}

extension DetailRow where Accessory == EmptyView {
    init(label: String, value: String, note: String = "") {
        self.init(label: label, value: value, note: note) { EmptyView() }
    }
}

private struct CPUDetailRow: View {
    let monitor: MetricsMonitor

    var body: some View {
        let cpu = monitor.cpu
        DetailRow(
            label: "CPU",
            value: Format.percent(cpu?.total),
            note: cpu.map { "user \($0.user)%  ·  sys \($0.system)%" } ?? ""
        )
    }
}

private struct GPUDetailRow: View {
    let monitor: MetricsMonitor

    var body: some View {
        DetailRow(label: "GPU", value: Format.percent(monitor.gpu))
    }
}

private struct MemoryDetailRow: View {
    let monitor: MetricsMonitor

    var body: some View {
        DetailRow(label: "Memory", value: Format.memory(monitor.memory)) {
            if let memory = monitor.memory {
                MiniBar(fraction: memory.fraction, color: Palette.load(Int(memory.fraction * 100)), width: 28)
            }
        }
    }
}

private struct TemperatureDetailRow: View {
    let monitor: MetricsMonitor

    var body: some View {
        DetailRow(label: "Temperature", value: Format.temperature(monitor.temperature)) {
            TemperatureBar(celsius: monitor.temperature)
        }
    }
}

private struct NetworkDetailRow: View {
    let monitor: MetricsMonitor

    var body: some View {
        DetailRow(label: "Network", value: Format.network(monitor.network))
    }
}

private struct PowerDetailRow: View {
    let monitor: MetricsMonitor

    var body: some View {
        DetailRow(label: "Power", value: Format.watts(monitor.power))
    }
}

private struct BatteryDetailRow: View {
    let monitor: MetricsMonitor

    var body: some View {
        DetailRow(label: "Battery", value: Format.batteryPercent(monitor.battery), note: Format.chargeState(monitor.battery))
    }
}

private struct RemainingDetailRow: View {
    let monitor: MetricsMonitor

    var body: some View {
        let battery = monitor.battery
        DetailRow(label: "Remaining", value: Format.timeRemaining(battery), note: battery?.state == .charging ? "to full" : "")
    }
}
