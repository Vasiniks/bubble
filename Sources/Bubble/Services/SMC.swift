import IOKit

/// A minimal AppleSMC client: walk the key index and read 4-byte float keys.
/// Every call reuses the same two 80-byte buffers, so reads allocate nothing.
/// Not thread-safe; confine to one queue.
final class SMC {
    typealias Key = UInt32

    // Field offsets in the driver's 80-byte SMCKeyData_t.
    private enum Field {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let index = 44
        static let bytes = 48
    }

    private enum Command: UInt8 {
        case read = 5
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private static let handleEvent: UInt32 = 2 // kSMCHandleYPCEvent
    private static let floatType = SMC.key("flt ")

    private var connection: io_connect_t = 0
    private var input = [UInt8](repeating: 0, count: 80)
    private var output = [UInt8](repeating: 0, count: 80)

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    static func key(_ name: String) -> Key {
        name.utf8.reduce(0) { $0 << 8 | Key($1) }
    }

    /// Number of keys the SMC publishes. Keys are indexed in ascending order.
    var keyCount: Int {
        guard call(.read, key: Self.key("#KEY"), size: 4) else { return 0 }
        return output[Field.bytes ..< Field.bytes + 4].reduce(0) { $0 << 8 | Int($1) }
    }

    func key(at index: Int) -> Key? {
        call(.keyAtIndex, index: UInt32(index)) ? load(Field.key) : nil
    }

    /// True if `key` holds a 4-byte float ('flt '), the format of Apple Silicon temperatures.
    func isFloat(_ key: Key) -> Bool {
        call(.keyInfo, key: key) && load(Field.dataSize) == 4 && load(Field.dataType) == Self.floatType
    }

    func readFloat(_ key: Key) -> Float? {
        guard call(.read, key: key, size: 4) else { return nil }
        return output.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Field.bytes, as: Float.self) }
    }

    private func load(_ offset: Int) -> UInt32 {
        output.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private func call(_ command: Command, key: Key = 0, size: UInt32 = 0, index: UInt32 = 0) -> Bool {
        input.withUnsafeMutableBytes { raw in
            memset(raw.baseAddress, 0, raw.count)
            raw.storeBytes(of: key, toByteOffset: Field.key, as: UInt32.self)
            raw.storeBytes(of: size, toByteOffset: Field.dataSize, as: UInt32.self)
            raw.storeBytes(of: command.rawValue, toByteOffset: Field.command, as: UInt8.self)
            raw.storeBytes(of: index, toByteOffset: Field.index, as: UInt32.self)
        }
        var outputSize = output.count
        let status = input.withUnsafeBytes { inBuffer in
            output.withUnsafeMutableBytes { outBuffer in
                IOConnectCallStructMethod(connection, Self.handleEvent, inBuffer.baseAddress, inBuffer.count, outBuffer.baseAddress, &outputSize)
            }
        }
        return status == kIOReturnSuccess && output[Field.result] == 0
    }
}
