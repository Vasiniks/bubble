import Carbon.HIToolbox

/// ⌃⌥⌘ hotkeys via Carbon's RegisterEventHotKey — the only global hotkey API that needs no
/// Accessibility permission. Carbon delivers hot key events on the main thread, and only
/// once per physical press (no key repeat), so each press is exactly one action.
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private static let signature = OSType(0x4255_424C) // 'BUBL'

    private var hotKeys: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]

    private init() {}

    /// Registers ⌃⌥⌘ + `keyCode` (a kVK_ constant).
    func register(keyCode: Int, _ action: @escaping () -> Void) {
        installHandler()
        let id = UInt32(actions.count + 1)
        actions[id] = action

        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(cmdKey | optionKey | controlKey),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if status == noErr, let hotKey {
            hotKeys.append(hotKey)
        } else {
            NSLog("Bubble: could not register hotkey %d (%d)", keyCode, status)
        }
    }

    func unregisterAll() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
        actions = [:]
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { manager.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }
}
