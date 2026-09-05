import Foundation

/// A single point-in-time reading of the Mac's battery and power state.
struct PowerSnapshot: Equatable {
    var timestamp: Date = Date()

    // MARK: Battery
    var batteryInstalled: Bool = false
    var currentCapacity: Int = 0        // charge %
    var isCharging: Bool = false
    var fullyCharged: Bool = false
    var externalConnected: Bool = false // running on AC power
    var cycleCount: Int = 0
    var designCapacity: Int = 0         // mAh
    var nominalChargeCapacity: Int = 0  // mAh (real full-charge capacity now)
    var temperatureC: Double = 0
    var voltageV: Double = 0
    var amperageMA: Int = 0             // signed: + charging, - discharging
    var serial: String = ""
    var manufactureDate: Date? = nil
    var timeRemainingMinutes: Int = -1  // -1 = calculating, -2 = unlimited/charged

    // MARK: AC Charger / Adapter
    var adapterConnected: Bool = false
    var adapterWatts: Int = 0
    var adapterVoltageV: Double = 0
    var adapterCurrentA: Double = 0
    var adapterID: Int = 0
    var adapterFamilyCode: Int = 0
    var adapterDescription: String = ""
    var adapterIsWireless: Bool = false

    // MARK: Derived
    /// Maximum capacity relative to design (what Settings shows as "Maximum Capacity").
    var maxCapacityPercent: Double {
        guard designCapacity > 0 else { return 0 }
        return min(100, Double(nominalChargeCapacity) / Double(designCapacity) * 100.0)
    }

    /// Instantaneous power flowing in/out of the battery, in watts (always positive magnitude).
    var batteryPowerW: Double {
        voltageV * (Double(abs(amperageMA)) / 1000.0)
    }

    /// Battery condition label, mirroring macOS wording.
    var condition: String {
        if !batteryInstalled { return "Unknown" }
        let cap = maxCapacityPercent
        if cap >= 80 { return "Normal" }
        if cap >= 60 { return "Replace Soon" }
        return "Service Recommended"
    }

    var conditionIsGood: Bool { condition == "Normal" }

    var familyCodeHex: String {
        String(format: "0x%08x", UInt32(bitPattern: Int32(truncatingIfNeeded: adapterFamilyCode)))
    }

    var adapterIDHex: String {
        String(format: "0x%04x", adapterID)
    }

    var timeRemainingText: String {
        switch timeRemainingMinutes {
        case -2: return isCharging ? "Fully charged" : "On battery"
        case ..<0: return "Calculating…"
        case 0: return fullyCharged ? "Fully charged" : "0m"
        default:
            let h = timeRemainingMinutes / 60
            let m = timeRemainingMinutes % 60
            return h > 0 ? "\(h)h \(m)m" : "\(m)m"
        }
    }

    /// Treat a battery held at 100% on AC as full even when the SMC
    /// FullyCharged flag hasn't flipped yet.
    var isEffectivelyFull: Bool {
        fullyCharged || (externalConnected && currentCapacity >= 100)
    }

    var chargeStateText: String {
        if isEffectivelyFull { return "Fully Charged" }
        if isCharging { return "Charging" }
        if externalConnected { return "Not Charging" }
        return "On Battery"
    }

    /// "Power Adapter" when running on AC, otherwise "Battery" (mirrors macOS).
    var powerSourceLabel: String {
        externalConnected ? "Power Adapter" : "Battery"
    }

    /// Charging speed, classified from the power flowing into the battery.
    /// macOS surfaces this as Fully Charged / Fast Charge / Slow Charge.
    var chargingSpeed: String {
        if isEffectivelyFull { return "Fully Charged" }
        if isCharging {
            let w = batteryPowerW
            if w >= 30 { return "Fast Charge" }
            if w >= 8  { return "Charging" }
            return "Slow Charge"
        }
        if externalConnected { return "Not Charging" }
        return "On Battery"
    }
}
