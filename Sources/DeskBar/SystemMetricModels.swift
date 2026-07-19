import Foundation

struct MetricHistory: Equatable, Sendable {
    private(set) var values: [Double] = []
    let capacity: Int

    init(capacity: Int = 30) {
        self.capacity = max(2, capacity)
    }

    mutating func append(_ value: Double?) {
        guard let value, value.isFinite, value >= 0 else { return }
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }
}

enum SystemPowerSource: String, Sendable {
    case ac
    case battery
    case unknown

    var displayName: String {
        switch self {
        case .ac: "Power adapter"
        case .battery: "Battery"
        case .unknown: "Unknown"
        }
    }
}

struct SystemBatteryMetric: Equatable, Sendable {
    let level: Int?
    let isCharging: Bool
    let powerSource: SystemPowerSource

    static let unavailable = SystemBatteryMetric(
        level: nil,
        isCharging: false,
        powerSource: .unknown
    )

    var displayValue: String {
        guard let level else { return powerSource == .ac ? "AC" : "—" }
        if isCharging {
            return "\(level)% · Charging"
        }
        return "\(level)%"
    }
}

enum SystemThermalMetric: String, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    var displayName: String {
        rawValue.capitalized
    }
}

struct SystemDiskMetric: Equatable, Sendable {
    let totalBytes: UInt64
    let availableBytes: UInt64

    var usedBytes: UInt64 {
        totalBytes >= availableBytes ? totalBytes - availableBytes : 0
    }

    var usagePercentage: Int? {
        guard totalBytes > 0 else { return nil }
        let percentage = Double(usedBytes) / Double(totalBytes) * 100
        return Int(percentage.rounded()).clamped(to: 0...100)
    }

    var displayValue: String {
        "\(SystemMetricFormatter.byteCount(availableBytes)) free of \(SystemMetricFormatter.byteCount(totalBytes))"
    }
}

enum SystemMetricFormatter {
    static func percentage(_ value: Int?) -> String {
        value.map { "\($0.clamped(to: 0...100))%" } ?? "—"
    }

    static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: safeSignedByteCount(bytes),
            countStyle: .decimal
        )
    }

    static func transferRate(bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else {
            return "—"
        }
        guard bytesPerSecond < Double(Int64.max) else {
            return "\(byteCount(UInt64(Int64.max)))/s"
        }
        let rounded = UInt64(bytesPerSecond.rounded())
        return "\(byteCount(rounded))/s"
    }

    private static func safeSignedByteCount(_ bytes: UInt64) -> Int64 {
        bytes > UInt64(Int64.max) ? Int64.max : Int64(bytes)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
