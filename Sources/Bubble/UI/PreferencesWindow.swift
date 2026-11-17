import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // Bubble is an accessory app, so it must activate itself for the window to take focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView(prefs: .shared)))
        window.styleMask = [.titled, .closable]
        window.title = "Bubble"
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

private struct PreferencesView: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { prefs.launchAtLogin },
                    set: { prefs.setLaunchAtLogin($0) }
                ))
                Picker("Refresh", selection: $prefs.refreshInterval) {
                    ForEach(Preferences.refreshOptions, id: \.self) { seconds in
                        Text(seconds == 1 ? "Every second" : "Every \(Int(seconds)) seconds").tag(seconds)
                    }
                }
            }

            Section("Notch") {
                Toggle("Open on hover", isOn: $prefs.openOnHover)
                Toggle("Haptic feedback", isOn: $prefs.haptics)
            }

            Section {
                Toggle("Quick terminal", isOn: $prefs.terminalEnabled)
            } footer: {
                Text("A terminal tab in the notch. Turning it off ends its shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Compact view") {
                Toggle("Battery time", isOn: $prefs.showBatteryTime)
                Toggle("CPU core temperature", isOn: $prefs.showTemperature)
            }

            Section {
                Picker("Display", selection: $prefs.display) {
                    ForEach(DisplayChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
            } footer: {
                Text("⌃⌥⌘B opens or closes Bubble.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Quit Bubble") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
