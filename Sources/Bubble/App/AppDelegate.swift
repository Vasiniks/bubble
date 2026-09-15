import AppKit
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as lightweight accessory (no dock icon clutter, stays as floating overlay)
        NSApp.setActivationPolicy(.accessory)
        
        // Setup Overlay Window
        OverlayWindowController.shared.show()
        
        // Setup Global Hotkey (⌘ ⌥ ⌃ B)
        GlobalHotkeyManager.shared.onHotKeyTriggered = { [weak self] in
            self?.toggleBubble()
        }
        GlobalHotkeyManager.shared.register()
        
        // Setup Menu Bar Extra (as convenient fallback & control point)
        setupStatusItem()
        
        // Re-center when screen configuration changes
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                OverlayWindowController.shared.repositionPanel(animated: true)
            }
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Bubble")
            button.image?.isTemplate = true
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Bubble (⌘⌥⌃B)", action: #selector(toggleBubble), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Center at Camera/Notch", action: #selector(recenterBubble), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Bubble", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    
    @objc private func toggleBubble() {
        OverlayWindowController.shared.toggle()
    }
    
    @objc private func recenterBubble() {
        OverlayWindowController.shared.repositionPanel(animated: true)
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyManager.shared.unregister()
    }
}
