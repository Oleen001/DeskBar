import Combine
import Darwin
import Foundation
import IOKit.ps

@MainActor
final class SystemMonitor: ObservableObject {
    enum PollingMode: Sendable, Equatable {
        /// Live metrics while DeskBar is visible and relevant to the user.
        case active
        /// Reduced wakeups while the user is active in another application.
        case idle
        /// Low-frequency updates while the Desktop surface is hidden.
        case hidden
        /// No automatic collection. Calling `refresh()` still performs one sample.
        case paused

        fileprivate var interval: TimeInterval? {
            switch self {
            case .active: 2
            case .idle: 6
            case .hidden: 20
            case .paused: nil
            }
        }
    }

    @Published private(set) var cpuUsage: Int?
    @Published private(set) var memoryUsage: Int?
    @Published private(set) var memoryActiveUsage: Int?
    @Published private(set) var networkRate = "—"
    @Published private(set) var networkBytesPerSecond: Double?
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var memoryActiveHistory: [Double] = []
    @Published private(set) var networkHistory: [Double] = []
    @Published private(set) var disk: SystemDiskMetric?
    @Published private(set) var diskUsage: Int?
    @Published private(set) var diskCapacity = "—"
    @Published private(set) var battery = SystemBatteryMetric.unavailable
    @Published private(set) var thermalState = SystemThermalMetric.unknown
    @Published private(set) var pollingMode = PollingMode.active
    @Published private(set) var sampleGeneration: UInt64 = 0

    private var timer: Timer?
    private var isRunning = false
    private var previousCPUTicks: host_cpu_load_info?
    private var previousNetworkBytes: UInt64?
    private var previousNetworkDate: Date?
    private var lastDiskRefresh: Date?
    private var cpuHistoryBuffer = MetricHistory()
    private var memoryHistoryBuffer = MetricHistory()
    private var memoryActiveHistoryBuffer = MetricHistory()
    private var networkHistoryBuffer = MetricHistory()
    private var pollingIntervalScale = 1.0

    /// The actual cadence after applying the selected mode and power-saving policy.
    var effectivePollingInterval: TimeInterval? {
        guard let baseInterval = pollingMode.interval else { return nil }
        let powerScale = battery.powerSource == .battery ? 2.0 : 1.0
        return baseInterval * pollingIntervalScale * powerScale
    }

    var cpuUsageText: String { SystemMetricFormatter.percentage(cpuUsage) }
    var memoryUsageText: String { SystemMetricFormatter.percentage(memoryUsage) }
    var memoryActiveUsageText: String { SystemMetricFormatter.percentage(memoryActiveUsage) }
    var batteryStatus: String { battery.displayValue }
    var thermalStatus: String { thermalState.displayName }

    func start() {
        start(mode: pollingMode)
    }

    func start(mode: PollingMode) {
        pollingMode = mode
        isRunning = true
        refresh()
        scheduleTimer()
    }

    func setPollingMode(_ mode: PollingMode) {
        guard pollingMode != mode else { return }
        pollingMode = mode
        if mode == .paused {
            resetSamplingBaselines()
        }
        if isRunning {
            if mode != .paused {
                refresh()
            }
            scheduleTimer()
        }
    }

    func setPollingIntervalScale(_ scale: Double) {
        let normalized = min(max(scale, 0.5), 2)
        guard normalized != pollingIntervalScale else { return }
        pollingIntervalScale = normalized
        if isRunning { scheduleTimer() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil

        guard isRunning, let interval = effectivePollingInterval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = min(1, interval * 0.15)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func refresh() {
        let previousInterval = effectivePollingInterval
        let nextCPUUsage = currentCPUUsage()
        if cpuUsage != nextCPUUsage { cpuUsage = nextCPUUsage }
        cpuHistoryBuffer.append(nextCPUUsage.map(Double.init))
        if cpuHistory != cpuHistoryBuffer.values { cpuHistory = cpuHistoryBuffer.values }

        let nextMemory = currentMemoryUsage()
        if memoryUsage != nextMemory?.total { memoryUsage = nextMemory?.total }
        if memoryActiveUsage != nextMemory?.active { memoryActiveUsage = nextMemory?.active }
        memoryHistoryBuffer.append(nextMemory.map { Double($0.total) })
        if memoryHistory != memoryHistoryBuffer.values { memoryHistory = memoryHistoryBuffer.values }
        memoryActiveHistoryBuffer.append(nextMemory.map { Double($0.active) })
        if memoryActiveHistory != memoryActiveHistoryBuffer.values {
            memoryActiveHistory = memoryActiveHistoryBuffer.values
        }

        updateNetworkRate()
        updateDiskCapacityIfNeeded()

        let nextBattery = currentBatteryMetric()
        if battery != nextBattery { battery = nextBattery }

        let nextThermalState = currentThermalState()
        if thermalState != nextThermalState { thermalState = nextThermalState }

        sampleGeneration &+= 1

        if isRunning, effectivePollingInterval != previousInterval {
            scheduleTimer()
        }
    }

    private func currentCPUUsage() -> Int? {
        var ticks = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &ticks) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        defer { previousCPUTicks = ticks }
        guard let previous = previousCPUTicks else { return nil }
        // Mach tick counters are fixed-width and can wrap during a long-running
        // session. Wrapping subtraction avoids a process-ending overflow trap.
        let user = tickDelta(ticks.cpu_ticks.0, previous.cpu_ticks.0)
        let system = tickDelta(ticks.cpu_ticks.1, previous.cpu_ticks.1)
        let idle = tickDelta(ticks.cpu_ticks.2, previous.cpu_ticks.2)
        let nice = tickDelta(ticks.cpu_ticks.3, previous.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        let percentage = Double(user + system + nice) / Double(total) * 100
        return min(max(Int(percentage.rounded()), 0), 100)
    }

    private func tickDelta(_ current: natural_t, _ previous: natural_t) -> UInt64 {
        UInt64(current &- previous)
    }

    private func currentMemoryUsage() -> (total: Int, active: Int)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(getpagesize())
        let totalPages = UInt64(stats.active_count)
            + UInt64(stats.inactive_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let activePages = UInt64(stats.active_count) + UInt64(stats.wire_count)
        let (used, overflowed) = totalPages.multipliedReportingOverflow(by: pageSize)
        let (active, activeOverflowed) = activePages.multipliedReportingOverflow(by: pageSize)
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0, !overflowed, !activeOverflowed else { return nil }
        let totalPercentage = Double(used) / Double(total) * 100
        let activePercentage = Double(active) / Double(total) * 100
        return (
            min(max(Int(totalPercentage.rounded()), 0), 100),
            min(max(Int(activePercentage.rounded()), 0), 100)
        )
    }

    private func updateNetworkRate() {
        let now = Date()
        guard let totalBytes = networkBytes() else { return }
        defer {
            previousNetworkBytes = totalBytes
            previousNetworkDate = now
        }

        guard let previousBytes = previousNetworkBytes,
              let previousDate = previousNetworkDate else { return }
        let interval = now.timeIntervalSince(previousDate)
        let delta = totalBytes >= previousBytes ? totalBytes - previousBytes : 0
        guard interval > 0 else { return }
        let bytesPerSecond = Double(delta) / interval
        let nextNetworkRate = SystemMetricFormatter.transferRate(
            bytesPerSecond: bytesPerSecond
        )
        if networkRate != nextNetworkRate { networkRate = nextNetworkRate }
        if networkBytesPerSecond != bytesPerSecond { networkBytesPerSecond = bytesPerSecond }
        networkHistoryBuffer.append(bytesPerSecond)
        if networkHistory != networkHistoryBuffer.values {
            networkHistory = networkHistoryBuffer.values
        }
    }

    private func networkBytes() -> UInt64? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var total: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let namePointer = interface.ifa_name,
                  let data = interface.ifa_data else { continue }
            let name = String(cString: namePointer)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let usage = data.assumingMemoryBound(to: if_data.self).pointee
            total += UInt64(usage.ifi_ibytes) + UInt64(usage.ifi_obytes)
        }
        return total
    }

    private func updateDiskCapacityIfNeeded(now: Date = Date()) {
        let diskRefreshInterval: TimeInterval = 30
        guard lastDiskRefresh.map({ now.timeIntervalSince($0) >= diskRefreshInterval }) ?? true else {
            return
        }
        lastDiskRefresh = now

        guard let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        ),
        let total = unsignedByteCount(attributes[.systemSize]),
        let available = unsignedByteCount(attributes[.systemFreeSize]) else {
            if disk != nil { disk = nil }
            if diskUsage != nil { diskUsage = nil }
            if diskCapacity != "—" { diskCapacity = "—" }
            return
        }

        let metric = SystemDiskMetric(
            totalBytes: total,
            availableBytes: min(available, total)
        )
        if disk != metric { disk = metric }
        if diskUsage != metric.usagePercentage { diskUsage = metric.usagePercentage }
        if diskCapacity != metric.displayValue { diskCapacity = metric.displayValue }
    }

    private func unsignedByteCount(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        return value as? UInt64
    }

    private func currentBatteryMetric() -> SystemBatteryMetric {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .unavailable
        }

        let source: SystemPowerSource
        if let providingSource = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() {
            switch providingSource as String {
            case kIOPSACPowerValue: source = .ac
            case kIOPSBatteryPowerValue: source = .battery
            default: source = .unknown
            }
        } else {
            source = .unknown
        }

        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return SystemBatteryMetric(level: nil, isCharging: false, powerSource: source)
        }

        for powerSource in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, powerSource)?
                .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else {
                continue
            }

            let current = description[kIOPSCurrentCapacityKey] as? NSNumber
            let maximum = description[kIOPSMaxCapacityKey] as? NSNumber
            let level: Int?
            if let current, let maximum, maximum.doubleValue > 0 {
                level = min(max(Int((current.doubleValue / maximum.doubleValue * 100).rounded()), 0), 100)
            } else {
                level = nil
            }

            return SystemBatteryMetric(
                level: level,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                powerSource: source
            )
        }

        return SystemBatteryMetric(level: nil, isCharging: false, powerSource: source)
    }

    private func currentThermalState() -> SystemThermalMetric {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }

    private func resetSamplingBaselines() {
        previousCPUTicks = nil
        previousNetworkBytes = nil
        previousNetworkDate = nil
        if cpuUsage != nil { cpuUsage = nil }
        if networkRate != "—" { networkRate = "—" }
        if networkBytesPerSecond != nil { networkBytesPerSecond = nil }
    }
}
