import AudioToolbox
import CoreAudio
import Observation

/// Output devices, the current default output, and its volume, straight from CoreAudio.
/// Listeners are registered only while Home is on screen; CoreAudio pushes changes
/// (AirPods connecting, volume keys) so nothing is polled.
@MainActor
@Observable
final class AudioOutputs {
    static let shared = AudioOutputs()

    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
        let symbol: String
    }

    private(set) var devices: [Device] = []
    private(set) var currentID = AudioDeviceID(0)
    /// nil when the device has no software volume (e.g. some HDMI or digital outputs).
    private(set) var volume: Float?
    private(set) var isMuted = false

    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var stopWork: DispatchWorkItem?
    @ObservationIgnored private var systemListeners: [Listener] = []
    @ObservationIgnored private var deviceListeners: [Listener] = []

    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private static let gracePeriod: TimeInterval = 20
    private static let volumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    private init() {}

    func activate() {
        stopWork?.cancel()
        stopWork = nil
        guard !isActive else { return }
        isActive = true
        systemListeners = [
            listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) { $0.reloadDevices() },
            listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) { $0.reloadCurrent() },
        ]
        reloadDevices()
        reloadCurrent()
    }

    func deactivate() {
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gracePeriod, execute: work)
    }

    func select(_ device: Device) {
        var id = device.id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        currentID = device.id // The listener confirms and loads its volume.
    }

    func setVolume(_ value: Float) {
        var scalar = min(1, max(0, value))
        var address = Self.address(Self.volumeSelector, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(currentID, &address) else { return }
        AudioObjectSetPropertyData(currentID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar)
        volume = scalar
        if isMuted, scalar > 0 { setMuted(false) }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    private func setMuted(_ muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(currentID, &address) else { return }
        AudioObjectSetPropertyData(currentID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        isMuted = muted
    }

    private func stop() {
        guard isActive else { return }
        isActive = false
        (systemListeners + deviceListeners).forEach(remove)
        systemListeners = []
        deviceListeners = []
    }

    // MARK: Loading

    private func reloadDevices() {
        let ids: [AudioDeviceID] = Self.readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        let loaded = ids.compactMap(Self.outputDevice)
        // Built-in outputs first, then alphabetical.
        let sorted = loaded.sorted { lhs, rhs in
            let lhsBuiltIn = lhs.symbol == "laptopcomputer", rhsBuiltIn = rhs.symbol == "laptopcomputer"
            return lhsBuiltIn != rhsBuiltIn ? lhsBuiltIn : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        if devices != sorted { devices = sorted }
    }

    private func reloadCurrent() {
        let id: AudioDeviceID = Self.read(AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyDefaultOutputDevice)) ?? 0
        currentID = id
        deviceListeners.forEach(remove)
        deviceListeners = []
        guard id != 0 else { return }
        deviceListeners = [
            listen(id, Self.volumeSelector, scope: kAudioDevicePropertyScopeOutput) { $0.reloadVolume() },
            listen(id, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) { $0.reloadVolume() },
        ]
        reloadVolume()
    }

    private func reloadVolume() {
        let volumeAddress = Self.address(Self.volumeSelector, scope: kAudioDevicePropertyScopeOutput)
        let muteAddress = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        let newVolume: Float32? = Self.read(currentID, volumeAddress)
        let muted: UInt32 = Self.read(currentID, muteAddress) ?? 0
        if volume != newVolume { volume = newVolume }
        if isMuted != (muted != 0) { isMuted = muted != 0 }
    }

    private static func outputDevice(_ id: AudioDeviceID) -> Device? {
        let output = kAudioDevicePropertyScopeOutput
        var streams = address(kAudioDevicePropertyStreams, scope: output)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0 else { return nil }
        let canBeDefault: UInt32 = read(id, address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: output)) ?? 1
        let hidden: UInt32 = read(id, address(kAudioDevicePropertyIsHidden)) ?? 0
        guard canBeDefault != 0, hidden == 0, let name = readName(id) else { return nil }
        let transport: UInt32 = read(id, address(kAudioDevicePropertyTransportType)) ?? 0
        return Device(id: id, name: name, symbol: symbol(name: name, transport: transport))
    }

    private static func symbol(name: String, transport: UInt32) -> String {
        let lowercased = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lowercased.contains("airpods max") { return "airpodsmax" }
            if lowercased.contains("airpods pro") { return "airpodspro" }
            if lowercased.contains("airpods") { return "airpods" }
            if lowercased.contains("beats") { return "beats.headphones" }
            return lowercased.contains("speaker") ? "hifispeaker" : "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeBuiltIn:
            return lowercased.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform"
        default:
            return "hifispeaker"
        }
    }

    // MARK: CoreAudio plumbing

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> T? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    private static func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(size) / MemoryLayout<T>.stride))
    }

    private static func readName(_ id: AudioObjectID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private func listen(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ handler: @escaping @MainActor (AudioOutputs) -> Void
    ) -> Listener {
        var address = Self.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler(AudioOutputs.shared) }
        }
        AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
        return Listener(object: object, address: address, block: block)
    }

    private func remove(_ listener: Listener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, .main, listener.block)
    }
}
