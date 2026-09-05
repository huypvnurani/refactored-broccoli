import SwiftUI

struct SystemSection: View {
    @ObservedObject var sys: SystemMonitor

    private func tempColor(_ t: Double?) -> Color {
        guard let t else { return Theme.textMuted }
        switch t {
        case ..<50: return Theme.green
        case ..<70: return Theme.yellow
        case ..<85: return Theme.orange
        default:    return Theme.red
        }
    }
    private func tempText(_ t: Double?) -> String {
        t.map { String(format: "%.0f°C", $0) } ?? "—"
    }
    private func tempStatus(_ t: Double?) -> String {
        guard let t else { return "N/A" }
        switch t {
        case ..<50: return "Cool"
        case ..<70: return "Normal"
        case ..<85: return "Warm"
        default:    return "Hot"
        }
    }

    private var fansAllIdle: Bool { !sys.fans.isEmpty && sys.fans.allSatisfy { $0.rpm == 0 } }
    private var maxFanRPM: Int { sys.fans.map(\.rpm).max() ?? 0 }
    private var fanValue: String {
        guard sys.hasFans, !sys.fans.isEmpty else { return "Fanless" }
        return "\(maxFanRPM) RPM"
    }
    private var fanSubtitle: String {
        guard sys.hasFans, !sys.fans.isEmpty else { return "No cooling fan" }
        let per = sys.fans.map { "F\($0.id + 1): \($0.rpm)" }.joined(separator: " · ")
        return fansAllIdle ? "Idle — \(per)" : per
    }
    private var fanHelp: String {
        guard sys.hasFans, let f = sys.fans.first else {
            return "This Mac has no fans (passive cooling)."
        }
        let range = f.max > 0 ? " Range: \(f.min)–\(f.max) RPM." : ""
        return "Cooling fan speed in revolutions per minute." + range +
               " 0 RPM is normal — Apple Silicon MacBooks stop the fans when the machine is cool enough and only spin them up under load."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Temperature + fan cards
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                StatCard(icon: "cpu.fill", iconColor: tempColor(sys.cpuTemp),
                         title: "CPU Temp", value: tempText(sys.cpuTemp),
                         subtitle: tempStatus(sys.cpuTemp),
                         subtitleColor: tempColor(sys.cpuTemp), emphasized: true,
                         help: "CPU die temperature, averaged across cores. The hotter it runs, the harder the fans work.")
                StatCard(icon: "cpu", iconColor: tempColor(sys.gpuTemp),
                         title: "GPU Temp", value: tempText(sys.gpuTemp),
                         subtitle: sys.gpuTemp == nil ? "Not reported" : tempStatus(sys.gpuTemp),
                         help: "Graphics chip (GPU) temperature.")
                StatCard(icon: sys.hasFans ? "fanblades.fill" : "wind",
                         iconColor: sys.hasFans ? Theme.blue : Theme.textMuted,
                         title: "Cooling Fan", value: fanValue, subtitle: fanSubtitle,
                         help: fanHelp)
                StatCard(icon: "thermometer.high", iconColor: tempColor(sys.hottest),
                         title: "Peak Sensor", value: tempText(sys.hottest),
                         subtitle: "\(sys.sensorCount) sensors",
                         help: "The hottest of this Mac's \(sys.sensorCount) thermal sensors right now.")
            }
            .frame(height: 150)

            // Top processes
            HStack(alignment: .top, spacing: 14) {
                ProcCard(title: "Top CPU", icon: "gauge.high", tint: Theme.purple,
                         unit: "", rows: sys.topCPU,
                         help: "The 5 processes using the most CPU (% CPU).")
                ProcCard(title: "Top Memory", icon: "memorychip.fill", tint: Theme.blue,
                         unit: "", rows: sys.topRAM,
                         help: "The 5 processes holding the most RAM (MB/GB).")
                ProcCard(title: "Top Power", icon: "bolt.fill", tint: Theme.orange,
                         unit: "", rows: sys.topPower,
                         help: "The 5 most energy-hungry processes (relative figure from 'top').")
            }
            .frame(maxHeight: .infinity)
        }
        // Sampling the process lists is expensive, so it only runs while this
        // tab is actually on screen.
        .onAppear { sys.processListsVisible = true }
        .onDisappear { sys.processListsVisible = false }
    }
}

/// A card listing five processes with a coloured value on the right.
struct ProcCard: View {
    let title: String
    let icon: String
    let tint: Color
    let unit: String
    let rows: [ProcInfo]
    var help: String? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 26, height: 26)
                        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    if help != nil {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 10)).foregroundStyle(Theme.textMuted.opacity(0.7))
                    }
                    Spacer()
                }
                .padding(.bottom, 4)
                .help(help ?? "")

                if rows.isEmpty {
                    Text("Sampling…").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, p in
                        HStack(spacing: 10) {
                            Text("\(idx + 1)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 16)
                            Text(p.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(p.display)
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                                .foregroundStyle(tint)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .help("PID \(p.pid) · \(p.name)")
                        if idx < rows.count - 1 { Divider().overlay(Theme.separator) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
