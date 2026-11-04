import Foundation
import Combine
import IOKit
import IOKit.ps

/// Reads battery + adapter information from IOKit and publishes it on a timer.
@MainActor
final class PowerMonitor: ObservableObject {
    /// One instance for the whole process: it keeps polling while the app runs
    /// as a menu-bar service with no window open.
    static let shared = PowerMonitor()

    @Published private(set) var snapshot = PowerSnapshot()
    @Published private(set) var lastUpdated = Date()
    /// Rolling history of battery power draw (watts) for the usage chart.
    @Published private(set) var powerHistory: [PowerSample] = []
    /// The level + time the battery was last topped up (persisted across launches).
    @Published private(set) var lastCharge: LastCharge?

    struct LastCharge: Equatable { var level: Int; var date: Date }

    private var prevCharging = false
    private var prevFully = false
    private let defaults = UserDefaults.standard

    struct PowerSample: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let watts: Double
    }

    private var timer: Timer?
    private let maxSamples = 120

    /// Auto-refresh interval in seconds.
    var interval: TimeInterval = 2 {
        didSet { start() }
    }

    init() {
        loadLastCharge()
        refresh()
        start()
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Manual refresh (bound to the refresh button and ⌘R).
    func refresh() {
        var snap = readIORegistry()
        applyPowerSources(to: &snap)
        snap.timestamp = Date()
        self.snapshot = snap
        self.lastUpdated = snap.timestamp

        if snap.batteryInstalled {
            powerHistory.append(.init(time: snap.timestamp, watts: snap.batteryPowerW))
            if powerHistory.count > maxSamples {
                powerHistory.removeFirst(powerHistory.count - maxSamples)
            }
        }

        trackLastCharge(snap)
    }

    // MARK: - "Last charged to X%" tracking

    private func trackLastCharge(_ s: PowerSnapshot) {
        guard s.batteryInstalled else { return }
        // Record when a top-up completes: charging just stopped, or battery is full.
        if s.fullyCharged && !prevFully {
            setLastCharge(level: max(s.currentCapacity, 100), date: Date())
        } else if prevCharging && !s.isCharging && s.currentCapacity > 0 {
            setLastCharge(level: s.currentCapacity, date: Date())
        } else if lastCharge == nil && (s.fullyCharged || s.currentCapacity >= 95) {
            // Seed a sensible value on first run so the field isn't empty.
            setLastCharge(level: s.currentCapacity, date: Date())
        }
        prevCharging = s.isCharging
        prevFully = s.fullyCharged
    }

    private func setLastCharge(level: Int, date: Date) {
        lastCharge = LastCharge(level: min(level, 100), date: date)
        defaults.set(level, forKey: "lastChargeLevel")
        defaults.set(date, forKey: "lastChargeDate")
    }

    private func loadLastCharge() {
        if let date = defaults.object(forKey: "lastChargeDate") as? Date {
            lastCharge = LastCharge(level: defaults.integer(forKey: "lastChargeLevel"), date: date)
        }
    }

    // MARK: - IORegistry (AppleSmartBattery)

    private func readIORegistry() -> PowerSnapshot {
        var snap = PowerSnapshot()
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return snap }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else {
            return snap
        }

        func int(_ key: String) -> Int? { props[key] as? Int }
        func bool(_ key: String) -> Bool? { props[key] as? Bool }
        /// Intel Macs store negative readings (current while discharging) as
        /// unsigned 64-bit, which `as? Int` rejects; reinterpret the bits.
        func signed(_ key: String) -> Int? {
            (props[key] as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
        }

        snap.batteryInstalled = bool("BatteryInstalled") ?? true
        // Apple silicon reports CurrentCapacity/MaxCapacity as a percentage
        // (MaxCapacity == 100); Intel reports both in mAh, e.g. 3399 of 4300.
        let current = int("CurrentCapacity") ?? 0
        let maxCapacity = int("MaxCapacity") ?? 100
        if maxCapacity > 100 {
            snap.currentCapacity = min(100, Int((Double(current) / Double(maxCapacity) * 100).rounded()))
        } else {
            snap.currentCapacity = current
        }
        snap.isCharging = bool("IsCharging") ?? false
        snap.fullyCharged = bool("FullyCharged") ?? false
        snap.externalConnected = bool("ExternalConnected") ?? false
        snap.cycleCount = int("CycleCount") ?? 0
        snap.designCapacity = int("DesignCapacity") ?? 0
        snap.nominalChargeCapacity = int("NominalChargeCapacity")
            ?? int("AppleRawMaxCapacity") ?? (maxCapacity > 100 ? maxCapacity : 0)
        if let t = int("Temperature") { snap.temperatureC = Double(t) / 100.0 }
        if let v = int("Voltage") { snap.voltageV = Double(v) / 1000.0 }
        snap.amperageMA = signed("InstantAmperage") ?? signed("Amperage") ?? 0
        snap.serial = props["Serial"] as? String ?? props["BatterySerialNumber"] as? String ?? "—"
        if let tr = int("TimeRemaining") {
            snap.timeRemainingMinutes = (tr == 65535 || tr <= 0) ? -1 : tr
        }
        if let md = int("ManufactureDate"), md > 0 {
            // Packed: bits 0-4 day, 5-8 month, 9-15 year offset from 1980.
            let day = md & 0x1F
            let month = (md >> 5) & 0x0F
            let year = ((md >> 9) & 0x7F) + 1980
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day
            snap.manufactureDate = Calendar.current.date(from: comps)
        }

        if let adapter = props["AdapterDetails"] as? [String: Any] {
            let watts = adapter["Watts"] as? Int
            let av = adapter["AdapterVoltage"] as? Int
            let ac = adapter["Current"] as? Int
            snap.adapterVoltageV = av.map { Double($0) / 1000.0 } ?? 0
            snap.adapterCurrentA = ac.map { Double($0) / 1000.0 } ?? 0
            if let w = watts {
                snap.adapterWatts = w
            } else if let av, let ac {
                snap.adapterWatts = Int((Double(av) / 1000.0 * Double(ac) / 1000.0).rounded())
            }
            snap.adapterID = adapter["AdapterID"] as? Int ?? 0
            snap.adapterFamilyCode = adapter["FamilyCode"] as? Int ?? 0
            snap.adapterDescription = adapter["Description"] as? String ?? ""
            snap.adapterIsWireless = adapter["IsWireless"] as? Bool ?? false
            snap.adapterConnected = snap.adapterWatts > 0 || snap.adapterVoltageV > 0
        }
        return snap
    }

    // MARK: - IOPowerSources (connection + robust time estimate)

    private func applyPowerSources(to snap: inout PowerSnapshot) {
        // Power-source connection state.
        guard let infoRef = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let listRef = IOPSCopyPowerSourcesList(infoRef)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for ps in listRef {
            guard let desc = IOPSGetPowerSourceDescription(infoRef, ps)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                let onAC = (state == kIOPSACPowerValue)
                snap.externalConnected = onAC
                if onAC { snap.adapterConnected = true }
            }
            if snap.timeRemainingMinutes < 0 {
                if let ttf = desc[kIOPSTimeToFullChargeKey] as? Int, ttf > 0 {
                    snap.timeRemainingMinutes = ttf
                } else if let tte = desc[kIOPSTimeToEmptyKey] as? Int, tte > 0 {
                    snap.timeRemainingMinutes = tte
                }
            }
        }

        if snap.fullyCharged || (snap.externalConnected && !snap.isCharging && snap.currentCapacity >= 100) {
            snap.timeRemainingMinutes = -2
        }
    }
}
