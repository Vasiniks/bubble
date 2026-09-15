import Foundation

// Apple Silicon only exposes die temperatures through the IOHIDEventSystem, which has no
// public header. These C functions are exported by IOKit.framework and have been stable
// since M1. If they ever stop matching sensors, temperature simply reads as unavailable.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ matching: OpaquePointer?, _ options: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

/// CPU die temperature on Apple Silicon. Not thread-safe; confine to one queue.
final class TemperatureSensor {
    private static let temperatureEventType: Int64 = 15   // kIOHIDEventTypeTemperature
    private static let temperatureField: Int32 = 15 << 16 // kIOHIDEventFieldTemperatureLevel

    // Kept alive for as long as the service clients are used.
    private let client: AnyObject?
    private let sensors: [AnyObject]

    init() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else {
            self.client = nil
            sensors = []
            return
        }
        // Apple vendor usage page 0xff00, usage 5 = temperature sensors.
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
        self.client = client
        sensors = services.filter { service in
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else {
                return false
            }
            // "PMU tdie*" on M1 Pro and later, "pACC/eACC MTR Temp" on base M1.
            return name.hasPrefix("PMU tdie") || name.hasPrefix("pACC MTR") || name.hasPrefix("eACC MTR")
        }
    }

    func read() -> Double? {
        var sum = 0.0
        var count = 0
        for sensor in sensors {
            guard let event = IOHIDServiceClientCopyEvent(sensor, Self.temperatureEventType, nil, 0)?.takeRetainedValue() else {
                continue
            }
            let value = IOHIDEventGetFloatValue(event, Self.temperatureField)
            if value > 1, value < 130 {
                sum += value
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }
}
