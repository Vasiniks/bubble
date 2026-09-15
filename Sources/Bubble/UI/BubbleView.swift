import SwiftUI

public struct BubbleView: View {
    @ObservedObject var monitor = MetricsMonitor.shared
    @Binding var isExpanded: Bool
    @State private var isHovering = false
    @State private var showingPreferences = false
    
    public init(isExpanded: Binding<Bool>) {
        self._isExpanded = isExpanded
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                expandedView
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                    ))
            } else {
                basicPillView
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isExpanded)
        .animation(.easeInOut(duration: 0.15), value: showingPreferences)
    }
    
    // MARK: - Basic Pill Mode (Minimalist Camera/Notch Adjacent)
    private var basicPillView: some View {
        HStack(spacing: 12) {
            // CPU
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(cpuColor(monitor.snapshot.cpu.usagePercent))
                Text(monitor.snapshot.cpu.formattedPercent)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
            }
            .help("CPU Total Usage")
            
            divider
            
            // GPU
            HStack(spacing: 5) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(red: 0.75, green: 0.52, blue: 0.99))
                Text(monitor.snapshot.gpu.formattedPercent)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
            }
            .help("GPU Utilization")
            
            divider
            
            // Battery / Power
            HStack(spacing: 5) {
                Image(systemName: batteryIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(batteryColor)
                Text(batteryText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
            }
            .help("Battery Time / Power Status")
            
            divider
            
            // Expand & Preferences Trigger
            HStack(spacing: 8) {
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isExpanded = true
                    }
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("Expand / Preferences")
                
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Toggle Expanded HUD")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(red: 0.04, green: 0.04, blue: 0.05))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.6), radius: 10, y: 3)
        )
        .contentShape(Capsule())
        .onHover { hover in
            isHovering = hover
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }
    }
    
    // MARK: - Expanded Mode (Detailed System HUD)
    private var expandedView: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("BUBBLE")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(1.2)
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                // Refresh rate badge
                Button(action: {
                    showingPreferences.toggle()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10))
                        Text("Settings")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(showingPreferences ? .white : .white.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(showingPreferences ? Color.white.opacity(0.2) : Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                
                // Collapse button
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isExpanded = false
                        showingPreferences = false
                    }
                }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.7))
                        .padding(5)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Collapse to Pill")
            }
            .padding(.bottom, 2)
            
            if showingPreferences {
                preferencesSection
            } else {
                metricsDashboard
            }
            
            // Footer
            HStack {
                Text("⌘⌥⌃B to toggle")
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.4))
                
                Spacer()
                
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Quit")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(Color.red.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.04, green: 0.04, blue: 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.8), radius: 20, y: 8)
        )
    }
    
    // MARK: - Metrics Dashboard
    private var metricsDashboard: some View {
        VStack(spacing: 10) {
            // CPU & GPU row
            HStack(spacing: 8) {
                // CPU Card
                metricCard(
                    title: "CPU",
                    icon: "cpu",
                    color: cpuColor(monitor.snapshot.cpu.usagePercent),
                    primary: monitor.snapshot.cpu.formattedPercent,
                    secondary: "\(monitor.snapshot.cpu.coreCount) Cores",
                    barValue: monitor.snapshot.cpu.usagePercent / 100.0
                )
                
                // GPU Card
                metricCard(
                    title: "GPU",
                    icon: "sparkles.tv",
                    color: Color(red: 0.75, green: 0.52, blue: 0.99),
                    primary: monitor.snapshot.gpu.formattedPercent,
                    secondary: monitor.snapshot.gpu.modelName,
                    barValue: monitor.snapshot.gpu.utilizationPercent / 100.0
                )
            }
            
            // Memory & Power row
            HStack(spacing: 8) {
                // Memory Card
                metricCard(
                    title: "RAM",
                    icon: "memorychip",
                    color: memoryColor,
                    primary: monitor.snapshot.memory.formattedPercent,
                    secondary: "\(monitor.snapshot.memory.formattedUsed) / \(monitor.snapshot.memory.formattedTotal)",
                    barValue: monitor.snapshot.memory.usedPercent / 100.0
                )
                
                // Power Card
                metricCard(
                    title: "POWER",
                    icon: monitor.snapshot.power.isCharging ? "bolt.fill" : "bolt",
                    color: Color(red: 0.98, green: 0.75, blue: 0.15),
                    primary: monitor.snapshot.power.formattedWatts,
                    secondary: monitor.snapshot.power.formattedTimeRemaining,
                    barValue: min(1.0, monitor.snapshot.power.watts / 60.0)
                )
            }
            
            // Network Card (Full width)
            networkRow
        }
    }
    
    // MARK: - Metric Card Component
    private func metricCard(title: String, icon: String, color: Color, primary: String, secondary: String, barValue: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.6))
                Spacer()
                Text(primary)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
            }
            
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 4)
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, geo.size.width * CGFloat(min(1.0, max(0.0, barValue)))), height: 4)
                }
            }
            .frame(height: 4)
            
            Text(secondary)
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(Color.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }
    
    // MARK: - Network Row Component
    private var networkRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.35, green: 0.85, blue: 0.55))
                VStack(alignment: .leading, spacing: 1) {
                    Text("DOWN")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.4))
                    Text(monitor.snapshot.network.formattedDown)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)
                }
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.38, green: 0.75, blue: 0.98))
                VStack(alignment: .trailing, spacing: 1) {
                    Text("UP")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.4))
                    Text(monitor.snapshot.network.formattedUp)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }
    
    // MARK: - Preferences Section
    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PREFERENCES")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(Color.white.opacity(0.5))
            
            HStack {
                Text("Refresh Interval")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Picker("", selection: $monitor.updateInterval) {
                    Text("0.5s (Fast)").tag(0.5)
                    Text("1.0s (Normal)").tag(1.0)
                    Text("2.0s (Eco)").tag(2.0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
            }
            
            HStack {
                Text("Global Hotkey")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Text("⌘ ⌥ ⌃ B")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            
            HStack {
                Text("Placement")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Text("Top Camera / Notch")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.6))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }
    
    // MARK: - Helpers
    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 11)
    }
    
    private func cpuColor(_ pct: Double) -> Color {
        if pct > 80 {
            return Color(red: 0.98, green: 0.35, blue: 0.35)
        } else if pct > 50 {
            return Color(red: 0.98, green: 0.75, blue: 0.20)
        } else {
            return Color(red: 0.32, green: 0.75, blue: 0.98)
        }
    }
    
    private var memoryColor: Color {
        switch monitor.snapshot.memory.pressure {
        case .normal:
            return Color(red: 0.38, green: 0.85, blue: 0.55)
        case .warning:
            return Color(red: 0.98, green: 0.75, blue: 0.20)
        case .critical:
            return Color(red: 0.98, green: 0.35, blue: 0.35)
        }
    }
    
    private var batteryIcon: String {
        let p = monitor.snapshot.power
        if p.isCharging {
            return "bolt.batteryblock.fill"
        }
        if p.batteryPercent > 80 {
            return "battery.100"
        } else if p.batteryPercent > 50 {
            return "battery.75"
        } else if p.batteryPercent > 25 {
            return "battery.50"
        } else {
            return "battery.25"
        }
    }
    
    private var batteryColor: Color {
        let p = monitor.snapshot.power
        if p.isCharging {
            return Color(red: 0.38, green: 0.85, blue: 0.55)
        }
        if p.batteryPercent < 20 {
            return Color(red: 0.98, green: 0.35, blue: 0.35)
        }
        return Color.white.opacity(0.85)
    }
    
    private var batteryText: String {
        let p = monitor.snapshot.power
        if p.isCharging {
            if let mins = p.timeRemainingMinutes, mins > 0 {
                let h = mins / 60
                let m = mins % 60
                return "\(h)h \(m)m"
            }
            return "\(p.batteryPercent)%"
        }
        if let mins = p.timeRemainingMinutes, mins > 0 {
            let h = mins / 60
            let m = mins % 60
            return "\(h)h \(m)m"
        }
        if p.isPluggedIn {
            return "AC"
        }
        return "\(p.batteryPercent)%"
    }
}
