import SwiftUI
import SMCCore

/// Fan control: live speeds, an Auto/Manual switch and one slider that scales
/// every fan across its own min–max range.
struct CoolingSection: View {
    @ObservedObject var fan: FanController
    @ObservedObject var sys: SystemMonitor

    /// Slider position while dragging — the hardware only hears about it when
    /// the drag ends (or a preset is tapped).
    @State private var draft: Double = 50

    private var tint: Color { fan.isControllingFans ? Theme.orange : Theme.blue }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                fanCards
                if fan.hasFans {
                    controlCard
                    explainerCard
                } else {
                    fanlessCard
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            draft = fan.percent
            fan.uiVisible = true
        }
        .onDisappear { fan.uiVisible = false }
        // Presets and the safety cutoff change the value behind the slider's back.
        .onChange(of: fan.percent) { _, new in
            if abs(new - draft) > 0.5 { draft = new }
        }
    }

    // MARK: Cards

    private var fanCards: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14),
                                 count: max(2, min(4, fan.fans.count + 2))),
                  spacing: 14) {
            ForEach(fan.fans) { f in
                StatCard(icon: "fanblades.fill",
                         iconColor: f.forced ? Theme.orange : Theme.blue,
                         title: "Fan \(f.id + 1)",
                         value: "\(f.rpm) RPM",
                         subtitle: fanSubtitle(f),
                         subtitleColor: f.forced ? Theme.orange : Theme.textSecondary,
                         help: "Live speed of fan \(f.id + 1). Range \(f.min)–\(f.max) RPM.") {
                    AnyView(BatteryBar(fraction: fan.fraction(of: f),
                                       color: f.forced ? Theme.orange : Theme.blue))
                }
            }
            StatCard(icon: fan.mode == .manual ? "slider.horizontal.3" : "gearshape.2.fill",
                     iconColor: tint,
                     title: "Control",
                     value: fan.mode == .manual ? "Manual" : "Auto",
                     subtitle: fan.mode == .manual ? "\(Int(fan.percent))% of range"
                                                   : "macOS decides",
                     subtitleColor: tint,
                     help: "Auto leaves the fans to the Mac's firmware. Manual holds them at the speed you pick below.")
            StatCard(icon: "thermometer.high",
                     iconColor: tempColor(sys.hottest),
                     title: "Hottest Sensor",
                     value: sys.hottest.map { String(format: "%.0f°C", $0) } ?? "—",
                     subtitle: "Cutoff \(Int(FanController.safetyCutoffC))°C",
                     subtitleColor: tempColor(sys.hottest),
                     help: "The hottest sensor in the Mac. At \(Int(FanController.safetyCutoffC))°C MacCharge drops manual control so the firmware can spin the fans up.")
        }
        .frame(height: 170)
    }

    private var controlCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Fan control", systemImage: "fanblades.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if fan.busy {
                        ProgressView().controlSize(.small)
                    }
                }

                if fan.helper != .ready {
                    helperBanner
                }

                Picker("", selection: Binding(get: { fan.mode },
                                              set: { fan.mode = $0 })) {
                    Text("Auto").tag(FanController.Mode.auto)
                    Text("Manual").tag(FanController.Mode.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(fan.helper != .ready || !fan.canControl)
                .frame(maxWidth: 240)

                Divider().overlay(Theme.separator)

                HStack {
                    Text("Target speed")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(Int(draft))%")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                }
                Slider(value: $draft, in: 0...100, step: 1) { editing in
                    if !editing { fan.percent = draft }
                }
                .tint(tint)
                .disabled(!sliderEnabled)

                HStack(spacing: 8) {
                    ForEach(Preset.allCases) { preset in
                        PresetButton(title: preset.title, detail: "\(preset.percent)%",
                                     tint: tint,
                                     selected: fan.mode == .manual && Int(fan.percent) == preset.percent,
                                     enabled: sliderEnabled) {
                            draft = Double(preset.percent)
                            fan.percent = Double(preset.percent)
                        }
                    }
                    Spacer(minLength: 0)
                }

                // What that percentage means for each fan, in real RPM.
                VStack(spacing: 0) {
                    ForEach(fan.controllableFans) { f in
                        InfoRow(label: "Fan \(f.id + 1) target",
                                value: "\(targetPreview(f)) RPM",
                                valueColor: fan.mode == .manual ? tint : Theme.textSecondary,
                                icon: "arrow.right.circle",
                                iconColor: fan.mode == .manual ? tint : Theme.textMuted,
                                help: "\(f.min) RPM at 0%, \(f.max) RPM at 100%.")
                        if f.id != fan.controllableFans.last?.id {
                            Divider().overlay(Theme.separator)
                        }
                    }
                }

                if let message = fan.message {
                    HStack(spacing: 8) {
                        Image(systemName: fan.messageIsError
                              ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 12))
                        Text(message).font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Dismiss") { fan.clearMessage() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .foregroundStyle(fan.messageIsError ? Theme.orange : Theme.green)
                    .padding(10)
                    .background((fan.messageIsError ? Theme.orange : Theme.green).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    /// Shown until the privileged helper is in place — fan writes need root.
    private var helperBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.yellow)
                Text(fan.helper == .outdated ? "The installed fan helper is out of date"
                                             : "Fan control needs a one-time setup")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text("""
                 The SMC only accepts fan commands from root, so MacCharge installs a small \
                 helper tool at \(FanController.helperPath). macOS will ask for your admin \
                 password once; after that the slider works without prompting.
                 """)
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(fan.helper == .outdated ? "Update helper…" : "Install helper…") {
                    Task { await fan.installHelper() }
                }
                .disabled(fan.busy)
                if fan.helper == .outdated {
                    Button("Remove") { Task { await fan.removeHelper() } }
                        .disabled(fan.busy)
                }
            }
        }
        .padding(12)
        .background(Theme.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.yellow.opacity(0.25)))
    }

    private var explainerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Good to know", systemImage: "info.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                bullet("0% is each fan's own minimum, not off. A Mac fan cannot be stopped from software, and MacCharge never asks for a speed below what the firmware reports.")
                bullet("A forced fan does not react to heat by itself. MacCharge keeps watching: at \(Int(FanController.safetyCutoffC))°C on any sensor it returns the fans to macOS automatically — except at 100%, where the fans are already as fast as they go.")
                bullet("Fans also go back to automatic when you quit MacCharge, so nothing is left forced behind the app's back. Manual mode is restored on the next launch.")
                bullet("Raising the speed keeps the Mac cooler and holds turbo clocks longer; lowering it is quieter but the chip will throttle sooner.")
                if fan.helper == .ready {
                    Divider().overlay(Theme.separator)
                    HStack {
                        Text("Helper installed at \(FanController.helperPath)")
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        Spacer()
                        Button("Remove helper…") { Task { await fan.removeHelper() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.orange)
                            .disabled(fan.busy)
                    }
                }
            }
        }
    }

    private var fanlessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("No fans on this Mac", systemImage: "wind")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("This model cools passively through its chassis, so there is no fan speed to set. The temperature cards above still work.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Helpers

    private var sliderEnabled: Bool {
        fan.helper == .ready && fan.canControl && fan.mode == .manual
    }

    /// RPM the draft slider position works out to, so the row tracks the drag.
    private func targetPreview(_ f: SMC.Fan) -> Int {
        guard f.isControllable else { return f.rpm }
        return f.min + Int((Double(f.max - f.min) * draft / 100).rounded())
    }

    private func fanSubtitle(_ f: SMC.Fan) -> String {
        guard f.isControllable else { return "No adjustable range" }
        if f.forced { return "Manual → \(f.target) RPM" }
        return f.rpm == 0 ? "Idle · auto" : "Auto · max \(f.max)"
    }

    private func tempColor(_ t: Double?) -> Color {
        guard let t else { return Theme.textMuted }
        switch t {
        case ..<50: return Theme.green
        case ..<70: return Theme.yellow
        case ..<85: return Theme.orange
        default:    return Theme.red
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Theme.textMuted).frame(width: 4, height: 4).padding(.top, 6)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The three speeds worth one click.
    private enum Preset: CaseIterable, Identifiable {
        case quiet, balanced, full
        var id: Self { self }
        var title: String {
            switch self {
            case .quiet:    return "Quiet"
            case .balanced: return "Balanced"
            case .full:     return "Full blast"
            }
        }
        var percent: Int {
            switch self {
            case .quiet:    return 0
            case .balanced: return 50
            case .full:     return 100
            }
        }
    }
}

/// Small pill button used for the speed presets.
private struct PresetButton: View {
    let title: String
    let detail: String
    let tint: Color
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? tint.opacity(0.9) : Theme.textMuted)
            }
            .foregroundStyle(selected ? tint : Theme.textSecondary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(selected ? tint.opacity(0.16) : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? tint.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
