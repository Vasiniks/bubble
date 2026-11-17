import Darwin

/// CPU core temperature, read straight from the SMC on Apple Silicon.
///
/// Each core's thermal sensor is published as three consecutive float keys, e.g. Tp00/Tp01/Tp02.
/// The middle key is the calibrated core temperature: it always equals the first plus a fixed
/// per-core offset, and the third tracks the hot spot above it. Performance-core sensors live
/// under "Tp0", efficiency-core sensors under "Te0".
///
/// Instead of a per-model key table, Bubble discovers those triplets once at launch by
/// binary-searching the SMC's sorted key index (under 100 calls, ~14 ms), then each sample reads only the
/// core keys: about ten 4-byte reads, roughly 1–2 ms in total.
///
/// An idle cluster is power-gated and its sensors drop to near zero, so readings outside
/// 20–115 °C are skipped; the average then covers the cores that are actually reporting.
/// Each sensor is weighted by how many cores it covers (a cluster sensor counts once per
/// core), so every CPU core contributes equally to the average.
final class TemperatureSensor {
    private struct Sensor {
        var key: SMC.Key
        var weight: Double
    }

    private static let validRange: ClosedRange<Float> = 20...115

    private let smc: SMC?
    private let sensors: [Sensor]

    init() {
        let smc = SMC()
        self.smc = smc
        sensors = smc.map(Self.discoverSensors) ?? []
    }

    func read() -> CoreTemperature? {
        guard let smc else { return nil }
        var total = 0.0
        var weight = 0.0
        var hottest: Float = 0
        for sensor in sensors {
            guard let value = smc.readFloat(sensor.key), Self.validRange.contains(value) else { continue }
            total += Double(value) * sensor.weight
            weight += sensor.weight
            hottest = max(hottest, value)
        }
        guard weight > 0 else { return nil }
        return CoreTemperature(average: Int((total / weight).rounded()), hottest: Int(hottest.rounded()))
    }

    // MARK: Discovery

    private static func discoverSensors(_ smc: SMC) -> [Sensor] {
        let count = smc.keyCount
        guard count > 0 else { return [] }
        let performance = coreKeys(in: smc, count: count, family: "Tp0")
        let efficiency = coreKeys(in: smc, count: count, family: "Te0")

        // With separate families, weight each sensor by the cores it stands for. If every
        // core is under "Tp0" (or core counts are unknown), each sensor is one core.
        let performanceCores = sysctlInt("hw.perflevel0.logicalcpu")
        let efficiencyCores = sysctlInt("hw.perflevel1.logicalcpu")
        let separate = !efficiency.isEmpty && performanceCores > 0 && efficiencyCores > 0
        let performanceWeight = separate ? Double(performanceCores) / Double(max(1, performance.count)) : 1
        let efficiencyWeight = separate ? Double(efficiencyCores) / Double(efficiency.count) : 1

        return performance.map { Sensor(key: $0, weight: performanceWeight) }
            + efficiency.map { Sensor(key: $0, weight: efficiencyWeight) }
    }

    /// Middle keys of every run of three consecutive float keys under `family` (3 characters).
    private static func coreKeys(in smc: SMC, count: Int, family: String) -> [SMC.Key] {
        let prefix = SMC.key(family) << 8

        // Lower bound of the family in the sorted index.
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            guard let key = smc.key(at: middle) else { return [] }
            if key < prefix { low = middle + 1 } else { high = middle }
        }

        var keys: [SMC.Key] = []
        var run: [SMC.Key] = []
        var lastPosition = -2

        func closeRun() {
            var index = 0
            while index + 2 < run.count {
                keys.append(run[index + 1])
                index += 3
            }
            run.removeAll(keepingCapacity: true)
        }

        var index = low
        while index < count, let key = smc.key(at: index), key & 0xFFFF_FF00 == prefix {
            index += 1
            guard let position = alphabetPosition(UInt8(key & 0xFF)), smc.isFloat(key) else { continue }
            if position != lastPosition + 1 { closeRun() }
            run.append(key)
            lastPosition = position
        }
        closeRun()
        return keys
    }

    /// 0–9, A–Z, a–z in ASCII order, so consecutive positions are consecutive sensor slots.
    private static func alphabetPosition(_ character: UInt8) -> Int? {
        switch character {
        case 0x30...0x39: return Int(character - 0x30)
        case 0x41...0x5A: return Int(character - 0x41) + 10
        case 0x61...0x7A: return Int(character - 0x61) + 36
        default: return nil
        }
    }

    private static func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
    }
}
