import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case health = "Battery"
    case charger = "AC Charger"
    case power = "Power"
    case system = "System"
    case cooling = "Cooling"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "battery.100percent"
        case .health: return "heart.fill"
        case .charger: return "powerplug.fill"
        case .power: return "bolt.fill"
        case .system: return "cpu.fill"
        case .cooling: return "fanblades.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - Overview

struct OverviewSection: View {
    @ObservedObject var monitor: PowerMonitor
    @ObservedObject var sys: SystemMonitor
    private var s: PowerSnapshot { monitor.snapshot }
    private var batteryColor: Color { s.batteryTint }

    /// Real power figure for the hero card: system total draw (SMC) with a
    /// V×A battery-power fallback for Macs that don't expose the rail.
    private var powerValue: String {
        if let w = sys.systemPowerW { return String(format: "%.1f W", w) }
        return String(format: "%.1f W", s.batteryPowerW)
    }
    private var powerSubtitle: String {
        if s.isCharging, let c = sys.batteryChargeW, c > 0.3 {
            return String(format: "Charging +%.1f W to battery", c)
        }
        if s.isEffectivelyFull && s.externalConnected { return "System · battery full" }
        if s.externalConnected { return "System · on adapter" }
        return "System · on battery"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Top stat row — Power/Wattage is the hero metric.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                StatCard(icon: "bolt.fill", iconColor: Theme.purple,
                         title: "Power Draw", value: powerValue,
                         subtitle: powerSubtitle,
                         emphasized: true,
                         help: "Total power the Mac is drawing right now (watts), read from the SMC sensor. While charging, the line below also shows the power going into the battery.")

                StatCard(icon: s.batterySymbol, iconColor: batteryColor,
                         title: "Battery", value: "\(s.currentCapacity)%",
                         valueColor: Theme.textPrimary,
                         subtitle: "\(s.chargingSpeed) · \(s.timeRemainingText)",
                         subtitleColor: speedColor(s),
                         help: "Charge left and charging state. The icon carries a bolt while plugged in; the colour shifts green→yellow→orange→red as the level drops.") {
                    AnyView(
                        BatteryBar(fraction: Double(s.currentCapacity) / 100, color: batteryColor)
                            .padding(.top, 2)
                    )
                }

                StatCard(icon: "powerplug.fill",
                         iconColor: s.adapterConnected ? Theme.green : Theme.textMuted,
                         title: "AC Charger",
                         value: s.adapterConnected ? "\(s.adapterWatts) W" : "Unplugged",
                         valueColor: s.adapterConnected ? Theme.green : Theme.textSecondary,
                         help: "Charger status and its rated output in watts — for example 67W / 96W / 140W.") {
                    AnyView(
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.adapterConnected ? "Connected" : "Running on battery")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(s.adapterConnected ? Theme.green : Theme.textSecondary)
                                .lineLimit(1)
                            if s.adapterConnected {
                                Text("USB-C Power Adapter")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Theme.textMuted)
                                    .lineLimit(1)
                            }
                        }
                    )
                }

                StatCard(icon: "arrow.triangle.2.circlepath", iconColor: Theme.blue,
                         title: "Charge Cycle", value: "\(s.cycleCount)",
                         subtitle: "Design Capacity 100%", subtitleColor: Theme.blue,
                         help: "Charge cycles used so far. Every 100% of battery drained in total counts as one cycle. A MacBook typically lasts around 1000 cycles.")
            }
            .frame(height: 164)

            // Health + Power usage
            HStack(alignment: .top, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("Health Information", systemImage: "heart.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                        }
                        .padding(.bottom, 6)
                        healthRows
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Power Usage", systemImage: "bolt.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("Live · updates every \(Int(monitor.interval))s")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                        }
                        PowerChart(samples: sys.powerHistory.isEmpty ? monitor.powerHistory
                                                                      : sys.powerHistory)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            // Bottom metric row
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                MetricCard(icon: "thermometer.medium", iconColor: Theme.orange,
                           title: "Temperature", value: String(format: "%.1f °C", s.temperatureC),
                           status: s.temperatureC < 35 ? "Normal" : "Warm",
                           statusColor: s.temperatureC < 35 ? Theme.green : Theme.orange,
                           help: "Battery cell temperature. Sitting above 35°C regularly wears the battery out faster.")
                MetricCard(icon: "bolt.batteryblock.fill", iconColor: Theme.blue,
                           title: "Voltage", value: String(format: "%.2f V", s.voltageV),
                           status: "Normal",
                           help: "Current battery voltage (typically 11–13V on a MacBook).")
                MetricCard(icon: "a.circle", iconColor: Theme.purple,
                           title: "Current",
                           value: String(format: "%.2f A", Double(abs(s.amperageMA)) / 1000),
                           status: s.isCharging ? "Charging" : (s.externalConnected ? "Idle" : "Discharging"),
                           statusColor: s.isCharging ? Theme.green : Theme.textSecondary,
                           help: "Current flowing through the battery (amps). Charging = current into the cell; on battery = current out of it.")
                MetricCard(icon: "checkmark.shield.fill",
                           iconColor: s.conditionIsGood ? Theme.green : Theme.orange,
                           title: "Condition", value: s.condition,
                           status: s.conditionIsGood ? "No Issues" : "Check battery",
                           statusColor: s.conditionIsGood ? Theme.green : Theme.orange,
                           help: "Overall battery condition, judged from wear and cycle count.")
            }

            // Battery status strip (Power Source · charge speed · last charged)
            Card(padding: 14) {
                HStack(spacing: 0) {
                    statusSegment(icon: s.externalConnected ? "powerplug.fill" : "battery.50",
                                  iconColor: s.externalConnected ? Theme.green : Theme.yellow,
                                  title: "Power Source", value: s.powerSourceLabel,
                                  valueColor: Theme.textPrimary,
                                  help: "What is powering the Mac right now: the charger (Power Adapter) or the battery.")
                    statusDivider
                    statusSegment(icon: speedIcon(s), iconColor: speedColor(s),
                                  title: "Charge Status", value: s.chargingSpeed,
                                  valueColor: speedColor(s),
                                  help: "Charging state and speed: Fully Charged, Fast Charge, Charging, Slow Charge or On Battery.")
                    statusDivider
                    statusSegment(icon: "clock.arrow.circlepath", iconColor: Theme.blue,
                                  title: "Last Charged",
                                  value: lastChargedValue, valueColor: Theme.textPrimary,
                                  help: "The last time the battery was topped up to a high level, and when — recorded by the app.")
                }
            }
        }
    }

    // MARK: Status strip helpers

    private var lastChargedValue: String {
        guard let lc = monitor.lastCharge else { return "—" }
        let rel = Self.relDate.localizedString(for: lc.date, relativeTo: Date())
        return "to \(lc.level)% · \(rel)"
    }
    private static let relDate: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()

    private func speedColor(_ s: PowerSnapshot) -> Color {
        switch s.chargingSpeed {
        case "Fast Charge": return Theme.green
        case "Charging":    return Theme.green
        case "Slow Charge": return Theme.orange
        case "Fully Charged": return Theme.green
        case "Not Charging":  return Theme.textSecondary
        default: return Theme.yellow
        }
    }
    private func speedIcon(_ s: PowerSnapshot) -> String {
        switch s.chargingSpeed {
        case "Fast Charge":   return "bolt.fill"
        case "Charging":      return "battery.100percent.bolt"
        case "Slow Charge":   return "tortoise.fill"
        case "Fully Charged": return "checkmark.circle.fill"
        case "Not Charging":  return "pause.circle.fill"
        default:              return "battery.50"
        }
    }

    private func statusSegment(icon: String, iconColor: Color, title: String,
                               value: String, valueColor: Color, help: String = "") -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.4)
                    .foregroundStyle(Theme.textMuted)
                Text(value)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(help)
    }
    private var statusDivider: some View {
        Rectangle().fill(Theme.separator).frame(width: 1, height: 30).padding(.horizontal, 6)
    }

    @ViewBuilder private var healthRows: some View {
        InfoRow(label: "Health Status", value: s.conditionIsGood ? "Good" : "Fair",
                valueColor: s.conditionIsGood ? Theme.green : Theme.orange)
        Divider().overlay(Theme.separator)
        InfoRow(label: "Maximum Capacity", value: "\(Int(s.maxCapacityPercent))%")
        Divider().overlay(Theme.separator)
        InfoRow(label: "Design Capacity", value: "\(s.designCapacity) mAh")
        Divider().overlay(Theme.separator)
        InfoRow(label: "Full Charge Capacity", value: "\(s.nominalChargeCapacity) mAh")
        Divider().overlay(Theme.separator)
        InfoRow(label: "Cycle Count", value: "\(s.cycleCount)")
        Divider().overlay(Theme.separator)
        InfoRow(label: "Temperature", value: String(format: "%.1f °C", s.temperatureC))
        Divider().overlay(Theme.separator)
        InfoRow(label: "Battery Serial", value: s.serial)
    }
}

// MARK: - Battery (health)

struct HealthSection: View {
    @ObservedObject var monitor: PowerMonitor
    private var s: PowerSnapshot { monitor.snapshot }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                StatCard(icon: "heart.fill", iconColor: Theme.red, title: "Maximum Capacity",
                         value: "\(Int(s.maxCapacityPercent))%",
                         subtitle: "Design: \(s.designCapacity) mAh",
                         help: "Current maximum capacity against new (Full Charge ÷ Design). The lower it goes, the more worn the battery is. Below 80% it is worth replacing.")
                StatCard(icon: "arrow.triangle.2.circlepath", iconColor: Theme.blue,
                         title: "Cycle Count", value: "\(s.cycleCount)",
                         subtitle: "Condition: \(s.condition)",
                         subtitleColor: s.conditionIsGood ? Theme.green : Theme.orange,
                         help: "Charge cycles used so far (every 100% of battery drained in total = one cycle). A MacBook typically lasts around 1000 cycles.")
                StatCard(icon: "checkmark.shield.fill",
                         iconColor: s.conditionIsGood ? Theme.green : Theme.orange,
                         title: "Condition", value: s.condition,
                         valueColor: s.conditionIsGood ? Theme.green : Theme.orange,
                         subtitle: "Based on wear & capacity",
                         help: "Battery condition: Normal, Replace Soon, or Service Recommended — derived from wear and cycle count.")
            }
            .frame(height: 150)

            HStack(alignment: .top, spacing: 14) {
                DetailCard(title: "Capacity", titleIcon: "gauge.medium", rows: [
                    DetailRow(label: "Maximum Capacity", value: "\(Int(s.maxCapacityPercent))%",
                              valueColor: s.maxCapacityPercent >= 80 ? Theme.green : Theme.orange,
                              icon: "gauge.medium", iconColor: Theme.green,
                              help: "Capacity left as a percentage of the original design capacity."),
                    DetailRow(label: "Design Capacity", value: "\(s.designCapacity) mAh",
                              icon: "square.dashed", iconColor: Theme.blue,
                              help: "The capacity this cell was manufactured with."),
                    DetailRow(label: "Full Charge Capacity", value: "\(s.nominalChargeCapacity) mAh",
                              icon: "battery.100percent", iconColor: Theme.green,
                              help: "The real capacity of a full 100% charge as of today."),
                    DetailRow(label: "Cycle Count", value: "\(s.cycleCount)",
                              icon: "arrow.triangle.2.circlepath", iconColor: Theme.blue,
                              help: "Total charge cycles the battery has been through."),
                ])
                DetailCard(title: "Condition & Info", titleIcon: "info.circle.fill", rows: [
                    DetailRow(label: "Temperature", value: String(format: "%.1f °C", s.temperatureC),
                              icon: "thermometer.medium", iconColor: Theme.orange,
                              help: "Battery cell temperature. Running hot (>35°C) regularly wears the battery out faster."),
                    DetailRow(label: "Voltage", value: String(format: "%.2f V", s.voltageV),
                              icon: "bolt.fill", iconColor: Theme.yellow,
                              help: "Current battery voltage. A MacBook battery usually sits around 11–13V."),
                    DetailRow(label: "Manufacture Date",
                              value: s.manufactureDate.map { Self.df.string(from: $0) } ?? "—",
                              icon: "calendar", iconColor: Theme.purple,
                              help: "The date this cell was manufactured — useful for estimating its age."),
                    DetailRow(label: "Serial Number", value: s.serial,
                              icon: "number", iconColor: Theme.textSecondary,
                              help: "The battery's own serial number."),
                ])
            }
            .frame(maxHeight: .infinity)
        }
    }
    static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
}

// MARK: - AC Charger

struct ChargerSection: View {
    @ObservedObject var monitor: PowerMonitor
    private var s: PowerSnapshot { monitor.snapshot }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                StatCard(icon: "powerplug.fill",
                         iconColor: s.adapterConnected ? Theme.green : Theme.textMuted,
                         title: "Connection",
                         value: s.adapterConnected ? "Connected" : "Unplugged",
                         valueColor: s.adapterConnected ? Theme.green : Theme.textSecondary,
                         subtitle: s.adapterIsWireless ? "Wireless" : "USB-C",
                         help: "Whether a charger is plugged into the Mac.")
                StatCard(icon: "bolt.fill", iconColor: Theme.yellow, title: "Adapter Power",
                         value: "\(s.adapterWatts) W",
                         subtitle: String(format: "%.1fV · %.2fA", s.adapterVoltageV, s.adapterCurrentA),
                         help: "Maximum output of the charger in use (V×A) — for example 67W, 96W, 140W.")
                StatCard(icon: s.isCharging ? "battery.100percent.bolt" : "pause.circle",
                         iconColor: s.isCharging ? Theme.green : Theme.textSecondary,
                         title: "Charging",
                         value: s.isCharging ? "Yes" : "No",
                         valueColor: s.isCharging ? Theme.green : Theme.textSecondary,
                         subtitle: s.chargeStateText,
                         help: "Whether the battery is actually taking a charge. It stops once full, even while still plugged in.")
            }
            .frame(height: 150)

            HStack(alignment: .top, spacing: 14) {
                DetailCard(title: "Connection", titleIcon: "cable.connector", rows: [
                    DetailRow(label: "Power Source", value: s.powerSourceLabel,
                              icon: s.externalConnected ? "powerplug.fill" : "battery.50",
                              iconColor: s.externalConnected ? Theme.green : Theme.yellow,
                              help: "What is powering the Mac right now: the charger (Power Adapter) or the battery."),
                    DetailRow(label: "Connected", value: s.adapterConnected ? "Yes" : "No",
                              valueColor: s.adapterConnected ? Theme.green : Theme.textSecondary,
                              icon: "cable.connector", iconColor: Theme.green,
                              help: "Whether the charger is physically connected to the Mac."),
                    DetailRow(label: "Adapter ID", value: s.adapterIDHex,
                              icon: "number", iconColor: Theme.blue,
                              help: "The charger's identifier in hex, as reported by the hardware."),
                    DetailRow(label: "Family", value: s.familyCodeHex,
                              icon: "cpu", iconColor: Theme.purple,
                              help: "The charger's family code — how the hardware classifies its type and standard."),
                    DetailRow(label: "Type", value: s.adapterIsWireless ? "Wireless" : "USB-C",
                              icon: "bolt.horizontal.circle", iconColor: Theme.textSecondary,
                              help: "How the charger connects."),
                ])
                DetailCard(title: "Power Delivery", titleIcon: "bolt.fill", rows: [
                    DetailRow(label: "Wattage", value: "\(s.adapterWatts) W",
                              valueColor: Theme.green,
                              icon: "bolt.fill", iconColor: Theme.yellow,
                              help: "The charger's rated output."),
                    DetailRow(label: "Adapter Voltage", value: String(format: "%.1f V", s.adapterVoltageV),
                              icon: "bolt.batteryblock.fill", iconColor: Theme.blue,
                              help: "The voltage the charger is supplying — for example 20V on USB-C PD."),
                    DetailRow(label: "Adapter Current", value: String(format: "%.2f A", s.adapterCurrentA),
                              icon: "a.circle", iconColor: Theme.orange,
                              help: "The maximum current the charger can supply."),
                    DetailRow(label: "Charging", value: s.isCharging ? "Yes" : "No",
                              valueColor: s.isCharging ? Theme.green : Theme.textSecondary,
                              icon: "battery.100percent.bolt", iconColor: Theme.green,
                              help: "Whether the battery is charging."),
                    DetailRow(label: "Charge Speed", value: s.chargingSpeed,
                              valueColor: s.chargingSpeed == "Slow Charge" ? Theme.orange : Theme.green,
                              icon: "gauge.with.dots.needle.67percent", iconColor: Theme.purple,
                              help: "Charging speed: Fast Charge (≥30W into the battery), Charging (normal), Slow Charge (<8W), Fully Charged."),
                ])
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Power

struct PowerSection: View {
    @ObservedObject var monitor: PowerMonitor
    @ObservedObject var sys: SystemMonitor
    private var s: PowerSnapshot { monitor.snapshot }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                StatCard(icon: "bolt.fill", iconColor: Theme.purple, title: "System Power",
                         value: sys.systemPowerW.map { String(format: "%.1f W", $0) }
                                ?? String(format: "%.1f W", s.batteryPowerW),
                         subtitle: "Total draw right now", emphasized: true,
                         help: "Total power the Mac is drawing right now, read from the SMC sensor. It never reaches 0, even on a full battery.")
                StatCard(icon: "bolt.batteryblock.fill", iconColor: Theme.blue, title: "Voltage",
                         value: String(format: "%.2f V", s.voltageV), subtitle: "Battery terminal",
                         help: "Current battery voltage.")
                StatCard(icon: "a.circle", iconColor: Theme.orange, title: "Current",
                         value: String(format: "%.2f A", Double(abs(s.amperageMA)) / 1000),
                         subtitle: s.amperageMA >= 0 ? "Into battery" : "Out of battery",
                         help: "Current through the battery. Positive = charging the cell, negative = the cell discharging.")
                StatCard(icon: "battery.100percent.bolt", iconColor: Theme.green, title: "Charge Power",
                         value: sys.batteryChargeW.map { String(format: "%.1f W", max(0, $0)) } ?? "—",
                         subtitle: s.isCharging ? "Into battery" : "Idle",
                         help: "Power going into the battery (charging watts). Zero when the battery is full or not charging.")
            }
            .frame(height: 150)

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Power Usage (Live)", systemImage: "bolt.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("updates every \(Int(sys.systemPowerW == nil ? 2 : 4))s")
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                    PowerChart(samples: sys.powerHistory.isEmpty ? monitor.powerHistory
                                                                 : sys.powerHistory,
                               tint: Theme.purple)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Settings

struct SettingsSection: View {
    @ObservedObject var monitor: PowerMonitor
    @ObservedObject var prefs: Preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        cardTitle("Startup", icon: "power")
                        Toggle(isOn: $prefs.launchAtLogin) {
                            settingLabel("Launch at login",
                                         "MacCharge starts in the background every time you log in to macOS.")
                        }
                        .toggleStyle(.switch).tint(Theme.green)
                        if let err = prefs.loginItemError {
                            Text("macOS refused: \(err)")
                                .font(.system(size: 11)).foregroundStyle(Theme.orange)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        cardTitle("Wattage display", icon: "bolt.fill")
                        Toggle(isOn: $prefs.showMenuBarItem) {
                            settingLabel("Show in the menu bar",
                                         "Text badge in the menu bar — always shown, including at 0W. A leading * means running on battery.")
                        }
                        .toggleStyle(.switch).tint(Theme.green)
                        Divider().overlay(Theme.separator)
                        Toggle(isOn: $prefs.showDockBadge) {
                            settingLabel("Show badge on the Dock icon",
                                         "Bubble on the Dock icon. Hidden automatically when the wattage is 0.")
                        }
                        .toggleStyle(.switch).tint(Theme.green)
                        Divider().overlay(Theme.separator)
                        Toggle(isOn: $prefs.hideDockOnClose) {
                            settingLabel("Hide from the Dock when the window closes",
                                         "The app keeps running in the background with only the menu-bar wattage left. Click it to reopen, right-click to quit.")
                        }
                        .toggleStyle(.switch).tint(Theme.green)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        cardTitle("Refresh", icon: "arrow.clockwise")
                        HStack {
                            Text("Auto-refresh interval")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text("\(Int(prefs.interval))s")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.green)
                        }
                        Slider(value: $prefs.interval, in: 1...30, step: 1)
                            .tint(Theme.green)
                        Text("Data reloads automatically — no need to press ⌘R. You can still force a refresh anytime with the ↻ button or ⌘R.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                }

                Text("Every option is saved — they survive quitting and relaunching the app.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                Spacer(minLength: 0)
            }
        }
    }

    private func cardTitle(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
    }

    private func settingLabel(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Text(note).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
