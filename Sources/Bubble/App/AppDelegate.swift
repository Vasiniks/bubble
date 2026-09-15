import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy would register a second overlay window and fight over the hotkey.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        // Accessory: no Dock icon, no menu bar of its own.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeMainMenu()

        MetricsMonitor.shared.start()
        OverlayWindowController.shared.show()
        GlobalHotkeyManager.shared.register {
            OverlayWindowController.shared.toggleExpanded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyManager.shared.unregister()
    }

    /// Never shown for an accessory app, but still routes ⌘W / ⌘Q while Preferences is focused.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem(title: "Quit Bubble", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        return mainMenu
    }
}
