import SwiftUI

struct ContentView: View {
    @ObservedObject private var monitor = PowerMonitor.shared
    @ObservedObject private var sys = SystemMonitor.shared
    @State private var selection: SidebarItem = .overview
    @ObservedObject private var prefs = Preferences.shared
    @State private var spin = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.separator)
            content
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)

    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: monitor.snapshot.batterySymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(monitor.snapshot.batteryTint)
                    .frame(width: 34, height: 34)
                    .background(monitor.snapshot.batteryTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacCharge").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text("Battery & Power").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ForEach(SidebarItem.allCases) { item in
                sidebarRow(item)
            }

            Spacer()

            // Live battery pill at bottom
            HStack(spacing: 10) {
                Image(systemName: monitor.snapshot.batterySymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(monitor.snapshot.batteryTint)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(monitor.snapshot.currentCapacity)% · \(monitor.snapshot.chargeStateText)")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(monitor.snapshot.timeRemainingText)
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .frame(width: 210)
        .background(Theme.sidebar)
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { selection = item }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(item.rawValue).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selection == item ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selection == item ? Theme.green.opacity(0.16) : .clear)
            )
            .overlay(alignment: .leading) {
                if selection == item {
                    Capsule().fill(Theme.green).frame(width: 3, height: 16).padding(.leading, 2)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(alignment: .top) {
                SectionHeader(title: selection.rawValue, subtitle: subtitle(for: selection))
                Spacer()
                Text("Updated \(monitor.lastUpdated.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    .padding(.top, 6)
                Button(action: doRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh (⌘R)")
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Group {
                switch selection {
                case .overview: OverviewSection(monitor: monitor, sys: sys)
                case .health:   HealthSection(monitor: monitor)
                case .charger:  ChargerSection(monitor: monitor)
                case .power:    PowerSection(monitor: monitor, sys: sys)
                case .system:   SystemSection(sys: sys)
                case .settings: SettingsSection(monitor: monitor, prefs: prefs)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 26)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func doRefresh() {
        monitor.refresh()
        sys.refresh()
        withAnimation(.easeInOut(duration: 0.5)) { spin.toggle() }
    }

    private func subtitle(for item: SidebarItem) -> String {
        switch item {
        case .overview: return "Real-time information about your Mac's battery and power."
        case .health:   return "Battery wear, capacity and lifespan indicators."
        case .charger:  return "Details about the connected power adapter."
        case .power:    return "Live voltage, current and wattage measurements."
        case .system:   return "CPU/GPU temperature, fans and the most demanding apps."
        case .settings: return "Configure how MacCharge refreshes."
        }
    }
}
