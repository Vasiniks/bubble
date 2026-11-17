import SwiftUI

enum Palette {
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let track = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.07)
    static let fill = Color.white.opacity(0.08)
    static let warm = Color(red: 1.0, green: 0.74, blue: 0.38)
    static let hot = Color(red: 1.0, green: 0.46, blue: 0.40)
    static let good = Color(red: 0.45, green: 0.86, blue: 0.56)

    static func load(_ percent: Int?) -> Color {
        guard let percent else { return primary }
        return percent >= 90 ? hot : percent >= 75 ? warm : primary
    }

    static func temperature(_ celsius: Int?) -> Color {
        guard let celsius else { return secondary }
        return celsius >= 90 ? hot : celsius >= 78 ? warm : secondary
    }

    static func pressure(_ pressure: MemoryPressure?) -> Color {
        switch pressure {
        case .critical: return hot
        case .warning: return warm
        default: return tertiary
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Palette.hairline).frame(height: 0.5)
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Palette.tertiary)
            .fixedSize()
    }
}

struct MiniBar: View {
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

// MARK: - Meters (the graph style of Glance)

/// An sRGB colour that can be mixed, so a meter's shades are derived from one hue.
struct RGB {
    let red: Double
    let green: Double
    let blue: Double

    init(_ hex: UInt32) {
        red = Double(hex >> 16 & 0xFF) / 255
        green = Double(hex >> 8 & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    func mix(_ other: RGB, _ amount: Double) -> RGB {
        RGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount, blue: blue + (other.blue - blue) * amount)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

/// One meter's colours: the line, the dark well behind it, and its readout text.
struct Hue {
    let fill: RGB
    let track: RGB
    let text: RGB

    init(_ fill: UInt32, _ track: UInt32, _ text: UInt32) {
        self.fill = RGB(fill)
        self.track = RGB(track)
        self.text = RGB(text)
    }

    static let cpu = Hue(0x2BC4AF, 0x18232A, 0x7EEAD9)
    static let memory = Hue(0x55ABF7, 0x1A2129, 0x93CAFF)
    static let gpu = Hue(0x9C81F7, 0x201F28, 0xBFB1FF)
    static let gpuMemory = Hue(0x6D5CBF, 0x201F28, 0xA199E6)
    static let diskBusy = Hue(0x65C55B, 0x1B231B, 0x98E090)
    static let diskRead = Hue(0xB9DF9B, 0x1B231B, 0xB9DF9B)
    static let diskWrite = Hue(0x36884D, 0x1B231B, 0x66BA7F)
    static let download = Hue(0xEC5775, 0x281D20, 0xF78C9C)
    static let upload = Hue(0xA93F75, 0x281D20, 0xDB7AA7)
    static let power = Hue(0xE9A93A, 0x2A2419, 0xFFD166)
    static let batteryLow = Hue(0xF0604F, 0x2A1C1A, 0xFF9A8F)

    /// CPU core tiles, idle to busy.
    static func core(_ percent: UInt8) -> Color {
        let stops: [(Double, RGB)] = [(0, RGB(0x1E2A2F)), (50, RGB(0x1F9486)), (100, RGB(0x6EF2DE))]
        let value = Double(percent)
        let upper = stops.firstIndex { $0.0 >= value } ?? stops.count - 1
        guard upper > 0 else { return stops[0].1.color }
        let (lowValue, lowColor) = stops[upper - 1]
        let (highValue, highColor) = stops[upper]
        return lowColor.mix(highColor, (value - lowValue) / (highValue - lowValue)).color
    }
}

/// Draws a band of history in a dark well, newest sample at the right edge, 2 pt per sample.
/// Tall bands are a filled graph with a bright top line; thin ones are a heat strip whose
/// brightness is the value. Rates are scaled to their recent peak (never below a floor).
enum Meter {
    static let step: CGFloat = 2
    private static let radius: CGFloat = 2

    static func full(_ history: History, floor: Float?) -> Float {
        guard let floor else { return 100 }
        return max(floor, history.peak)
    }

    static func draw(_ context: GraphicsContext, in rect: CGRect, _ history: History, hue: Hue, floor: Float? = nil) {
        let well = Path(roundedRect: rect, cornerRadius: radius)
        context.fill(well, with: .color(hue.track.color))
        let values = history.values
        guard !values.isEmpty, rect.width > 2, rect.height > 0 else { return }
        let full = Self.full(history, floor: floor)
        let count = min(values.count, Int(rect.width / step) + 1)
        func fraction(_ age: Int) -> CGFloat {
            CGFloat(min(1, max(0, values[values.count - 1 - age] / full)))
        }

        var clipped = context
        clipped.clip(to: well)

        if rect.height < 8 {
            // 16 shades; equal neighbours merge into one rectangle.
            let levels = (0 ..< count).map { Int((fraction($0) * 16).rounded()) }
            var start = 0
            while start < count {
                var end = start + 1
                while end < count, levels[end] == levels[start] { end += 1 }
                if levels[start] > 0 {
                    let right = rect.maxX - CGFloat(start) * step
                    let left = max(rect.minX, rect.maxX - CGFloat(end) * step)
                    let shade = hue.track.mix(hue.fill, 0.25 + 0.75 * Double(levels[start]) / 16)
                    clipped.fill(Path(CGRect(x: left, y: rect.minY, width: right - left, height: rect.height)), with: .color(shade.color))
                }
                start = end
            }
            return
        }

        var line = Path()
        var x = rect.maxX
        for age in 0 ..< count {
            x = max(rect.minX, rect.maxX - CGFloat(age) * step)
            let point = CGPoint(x: x, y: rect.maxY - fraction(age) * rect.height)
            if age == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        var area = line
        area.addLine(to: CGPoint(x: x, y: rect.maxY))
        area.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        area.closeSubpath()
        clipped.fill(area, with: .color(hue.track.mix(hue.fill, 0.42).color))
        clipped.stroke(line, with: .color(hue.fill.color), lineWidth: 1)
    }

    /// A plain bar: length is the value, a little brighter when fuller.
    static func bar(_ context: GraphicsContext, in rect: CGRect, fraction: CGFloat, hue: Hue) {
        context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(hue.track.color))
        let fraction = min(1, max(0, fraction))
        guard fraction > 0 else { return }
        let filled = CGRect(x: rect.minX, y: rect.minY, width: max(radius * 2, rect.width * fraction), height: rect.height)
        let shade = hue.track.mix(hue.fill, 0.7 + 0.3 * Double(fraction))
        context.fill(Path(roundedRect: filled, cornerRadius: radius), with: .color(shade.color))
    }

    /// Splits a band into a main graph and thinner bands below it, in Glance's proportions
    /// (e.g. 10:4:4 or 14:6), separated by small gaps.
    static func bands(_ rect: CGRect, _ weights: [CGFloat]) -> [CGRect] {
        let gap: CGFloat = 2
        let total = weights.reduce(0, +)
        let usable = rect.height - gap * CGFloat(weights.count - 1)
        var y = rect.minY
        return weights.map { weight in
            let height = (usable * weight / total).rounded()
            defer { y += height + gap }
            return CGRect(x: rect.minX, y: y, width: rect.width, height: height)
        }
    }
}

/// A thin draggable bar: volume and track position.
struct ScrubBar: View {
    let fraction: Double
    var height: CGFloat = 3
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void = { _ in }

    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let shown = CGFloat(min(1, max(0, dragFraction ?? fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(Palette.primary).frame(width: max(height, proxy.size.width * shown))
            }
            .frame(height: dragFraction == nil ? height : height + 2)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let next = Double(min(1, max(0, value.location.x / max(1, proxy.size.width))))
                        dragFraction = next
                        onChange(next)
                    }
                    .onEnded { value in
                        let next = Double(min(1, max(0, value.location.x / max(1, proxy.size.width))))
                        dragFraction = nil
                        onCommit(next)
                    }
            )
        }
        .frame(height: 14)
    }
}

/// Icon button with a soft hover highlight.
struct GlyphButton: View {
    let symbol: String
    var size: CGFloat = 12
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hovering ? Palette.primary : Palette.secondary)
                .frame(width: size + 16, height: size + 12)
                .background(Circle().fill(hovering ? Palette.fill : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
