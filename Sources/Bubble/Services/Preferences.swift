import Foundation
import Observation
import ServiceManagement

enum DisplayChoice: String, CaseIterable, Identifiable {
    case automatic
    case primary

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: return "Built-in (camera)"
        case .primary: return "Primary display"
        }
    }
}

@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()
    static let didChange = Notification.Name("com.eason.bubble.preferencesDidChange")
    static let refreshOptions: [TimeInterval] = [1, 2, 5]

    private enum Key {
        static let refreshInterval = "refreshInterval"
        static let showBatteryTime = "showBatteryTime"
        static let showTemperature = "showTemperature"
        static let display = "display"
        static let openOnHover = "openOnHover"
        static let haptics = "haptics"
        static let terminalEnabled = "terminalEnabled"
    }

    var refreshInterval: TimeInterval {
        didSet { persist(refreshInterval, Key.refreshInterval) }
    }

    var showBatteryTime: Bool {
        didSet { persist(showBatteryTime, Key.showBatteryTime) }
    }

    var showTemperature: Bool {
        didSet { persist(showTemperature, Key.showTemperature) }
    }

    var display: DisplayChoice {
        didSet { persist(display.rawValue, Key.display) }
    }

    /// Hovering the notch for a moment opens it, as well as clicking.
    var openOnHover: Bool {
        didSet { persist(openOnHover, Key.openOnHover) }
    }

    /// A trackpad tick when the pointer reaches the notch or a swipe opens it.
    var haptics: Bool {
        didSet { persist(haptics, Key.haptics) }
    }

    /// The quick terminal tab. Off, no shell process ever runs.
    var terminalEnabled: Bool {
        didSet { persist(terminalEnabled, Key.terminalEnabled) }
    }

    private(set) var launchAtLogin: Bool

    var showsCompactStatus: Bool {
        showBatteryTime || showTemperature
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.refreshInterval: 2.0,
            Key.showBatteryTime: true,
            Key.showTemperature: true,
            Key.display: DisplayChoice.automatic.rawValue,
            Key.openOnHover: true,
            Key.haptics: true,
            Key.terminalEnabled: true,
        ])
        let interval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = Self.refreshOptions.contains(interval) ? interval : 2
        showBatteryTime = defaults.bool(forKey: Key.showBatteryTime)
        showTemperature = defaults.bool(forKey: Key.showTemperature)
        display = DisplayChoice(rawValue: defaults.string(forKey: Key.display) ?? "") ?? .automatic
        openOnHover = defaults.bool(forKey: Key.openOnHover)
        haptics = defaults.bool(forKey: Key.haptics)
        terminalEnabled = defaults.bool(forKey: Key.terminalEnabled)
        launchAtLogin = Self.loginItemEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        // Registration only works from a bundled app; on failure the toggle just reflects reality.
        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        launchAtLogin = Self.loginItemEnabled
    }

    private static var loginItemEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    private func persist(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
