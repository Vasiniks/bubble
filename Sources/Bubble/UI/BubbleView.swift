import SwiftUI

/// Root view. The header row is identical in both states and pinned to the notch, so the
/// rings stay put while the shape springs open around them and reveals the tab bar and the
/// tab content. Each metric is read by its own small subview, so with Observation a new
/// sample only re-renders the pieces whose values actually changed.
struct BubbleView: View {
    let state: OverlayState
    let monitor: MetricsMonitor
    let prefs: Preferences

    var body: some View {
        let geometry = state.geometry
        let expanded = state.isExpanded
        let size = expanded ? geometry.openSize : geometry.closedSize(compactStatus: prefs.showsCompactStatus)
        let shape = NotchShape(
            topRadius: expanded ? BubbleGeometry.openRadii.top : BubbleGeometry.closedRadii.top,
            bottomRadius: expanded
                ? BubbleGeometry.openRadii.bottom
                : min(BubbleGeometry.closedRadii.bottom, (size.height - BubbleGeometry.closedRadii.top) / 2)
        )

        ZStack(alignment: .top) {
            shape.fill(Color.black)

            // Fixed-width content so nothing reflows while the shape animates; the clip reveals it.
            VStack(spacing: 0) {
                Header(state: state, monitor: monitor, prefs: prefs)
                if expanded {
                    TabContent(state: state, monitor: monitor)
                        .padding(.horizontal, BubbleGeometry.contentInset)
                        .padding(.top, BubbleGeometry.contentTop)
                        .padding(.bottom, BubbleGeometry.contentInset)
                        .frame(width: geometry.interiorWidth, height: BubbleGeometry.contentHeight, alignment: .top)
                        .transition(
                            .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.18))
                        )
                }
            }
            .frame(width: geometry.interiorWidth, alignment: .top)
            .opacity(state.isPressed ? 0.55 : 1)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .shadow(color: expanded ? .black.opacity(0.7) : .clear, radius: expanded ? 6 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// Flush with the top screen edge, flared into it at the top corners, rounded at the bottom.
/// Both radii animate, so the flare deepens as the notch opens.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let flare = max(0, min(topRadius, rect.width / 4, rect.height))
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

// MARK: - Header

/// Tabs · temperature · CPU  [camera]  GPU · battery · settings. The tab bar and settings
/// sit outside the collapsed shape, so they're simply revealed as it grows.
private struct Header: View {
    let state: OverlayState
    let monitor: MetricsMonitor
    let prefs: Preferences

    var body: some View {
        let geometry = state.geometry
        let wing = geometry.wing(compactStatus: prefs.showsCompactStatus)
        let extra = max(0, (geometry.interiorWidth - geometry.centerWidth - 2 * wing) / 2)

        HStack(spacing: 0) {
            // The tab bar and settings only exist while open, so the collapsed notch lays out
            // and redraws nothing it can't show.
            ZStack(alignment: .leading) {
                if state.isExpanded {
                    TabBar(state: state, prefs: prefs)
                        .padding(.leading, 6)
                        .transition(.opacity)
                }
            }
            .frame(width: extra, alignment: .leading)

            HStack(spacing: 6) {
                if prefs.showTemperature {
                    TemperatureCompact(monitor: monitor)
                }
                Spacer(minLength: 0)
                SectionLabel(text: "CPU")
                CPURing(monitor: monitor, diameter: geometry.ringDiameter)
            }
            .padding(.leading, 14)
            .padding(.trailing, 9)
            .frame(width: wing)

            Color.clear.frame(width: geometry.centerWidth)

            HStack(spacing: 6) {
                GPURing(monitor: monitor, diameter: geometry.ringDiameter)
                SectionLabel(text: "GPU")
                Spacer(minLength: 0)
                if prefs.showBatteryTime {
                    BatteryCompact(monitor: monitor)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 14)
            .frame(width: wing)

            ZStack(alignment: .trailing) {
                if state.isExpanded {
                    GlyphButton(symbol: "gearshape", size: 11, help: "Preferences") {
                        PreferencesWindowController.shared.show()
                    }
                    .padding(.trailing, 4)
                    .transition(.opacity)
                }
            }
            .frame(width: extra, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(Palette.secondary)
        .frame(height: geometry.topHeight)
    }
}

/// Home and, when enabled in Preferences, the terminal. Hidden when Home is the only tab.
private struct TabBar: View {
    let state: OverlayState
    let prefs: Preferences
    @Namespace private var namespace

    var body: some View {
        let tabs = prefs.terminalEnabled ? NotchTab.allCases : [.home]
        HStack(spacing: 2) {
            ForEach(tabs.count > 1 ? tabs : []) { tab in
                let selected = state.tab == tab
                Button {
                    OverlayWindowController.shared.select(tab)
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? Palette.primary : Palette.tertiary)
                        .frame(width: 30, height: 22)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.white.opacity(0.14))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
    }
}

private struct TabContent: View {
    let state: OverlayState
    let monitor: MetricsMonitor

    var body: some View {
        ZStack(alignment: .top) {
            switch state.tab {
            case .home:
                HomeView(state: state, monitor: monitor, media: .shared, outputs: .shared)
                    .transition(.opacity)
            case .terminal:
                TerminalTab(session: .shared)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Rings

// Plain SwiftUI views measured cheaper per update than drawing the wings in a Canvas
// (3.4 vs 4.6 ms/s at a 1 s refresh, and 6 MB less memory), so the header stays as views.

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
        let celsius = monitor.temperature?.average
        HStack(spacing: 5) {
            Text(Format.temperature(celsius))
            MiniBar(
                fraction: CGFloat(min(1, max(0, (Double(celsius ?? 0) - 30) / 70))),
                color: Palette.temperature(celsius),
                width: 14
            )
        }
        .fixedSize()
    }
}
