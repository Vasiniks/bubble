import Foundation
import Carbon
import AppKit

public final class GlobalHotkeyManager {
    public static let shared = GlobalHotkeyManager()
    
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    public var onHotKeyTriggered: (@MainActor () -> Void)?
    
    private init() {}
    
    public func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData = userData else { return noErr }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                manager.onHotKeyTriggered?()
            }
            return noErr
        }
        
        let installErr = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
        
        if installErr != noErr {
            print("[Bubble] InstallEventHandler failed: \(installErr)")
        }
        
        // Register Command + Option + Control + B
        let hotKeyID = EventHotKeyID(signature: OSType(0x4255424C), id: 1) // 'BUBL'
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_B),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if status == noErr {
            print("[Bubble] Successfully registered global hotkey ⌘⌥⌃B")
        } else {
            print("[Bubble] Failed to register global hotkey: \(status)")
        }
    }
    
    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
    
    deinit {
        unregister()
    }
}
