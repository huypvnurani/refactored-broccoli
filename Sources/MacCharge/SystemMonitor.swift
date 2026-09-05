import Foundation
import Combine

struct ProcInfo: Identifiable, Equatable {
    let id = UUID()
    let pid: Int
    let name: String
    let value: Double      // %cpu, MB, or relative power
    let display: String    // preformatted value string
}

/// Reads SMC thermals/fans and the top processes (CPU / RAM / power) on a timer.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var cpuTemp: Double? = nil
    @Published private(set) var gpuTemp: Double? = nil
    @Published private(set) var hottest: Double? = nil
    @Published private(set) var sensorCount: Int = 0
    @Published private(set) var fans: [SMC.Fan] = []
    @Published private(set) var hasFans = true

    // Real power rails from SMC (watts). nil when the Mac doesn't expose them.
    @Published private(set) var systemPowerW: Double? = nil   // PSTR – total system draw
    @Published private(set) var dcInPowerW: Double? = nil     // PDTR – delivered from adapter
    @Published private(set) var batteryChargeW: Double? = nil // PPBR – power into/out of battery
    /// Rolling history of system power draw (watts) for the usage chart.
    @Published private(set) var powerHistory: [PowerMonitor.PowerSample] = []
    private let maxSamples = 120

    @Published private(set) var topCPU: [ProcInfo] = []
    @Published private(set) var topRAM: [ProcInfo] = []
    @Published private(set) var topPower: [ProcInfo] = []
    @Published private(set) var lastUpdated = Date()

    private let smc = SMC()
    private var timer: Timer?
    private let work = DispatchQueue(label: "system.monitor", qos: .utility)
    private var busy = false
    private var lastProcessSample = Date.distantPast

    /// `top -l 2` costs about a second of CPU per call, so the process lists are
    /// sampled far less often than the thermals — and only while on screen.
    private let processInterval: TimeInterval = 15

    /// False while the app sits in the menu bar with no window: the SMC timer
    /// stops entirely, since nothing is reading these values.
    var windowVisible = true {
        didSet {
            guard windowVisible != oldValue else { return }
            windowVisible ? start() : stop()
        }
    }

    /// True only while the System tab is showing. The process lists shell out to
    /// `ps` and `top`; nothing else in the app uses them.
    var processListsVisible = false {
        didSet {
            guard processListsVisible, processListsVisible != oldValue else { return }
            lastProcessSample = .distantPast   // fill the tab in immediately
            refresh()
        }
    }

    init() {
        _ = smc.open()
        start()
    }

    deinit { smc.close() }

    private func start() {
        timer?.invalidate()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        // Thermals/fans are cheap IOKit reads.
        let t = smc.thermal()
        let f = smc.fans()
        cpuTemp = t.cpu ?? t.hottest
        gpuTemp = t.gpu
        hottest = t.hottest
        sensorCount = t.sensorCount
        fans = f
        hasFans = !f.isEmpty
        systemPowerW = smc.readDouble("PSTR").flatMap { $0 > 0 ? $0 : nil }
        dcInPowerW = smc.readDouble("PDTR").flatMap { $0 > 0 ? $0 : nil }
        batteryChargeW = smc.readDouble("PPBR")
        if let w = systemPowerW {
            powerHistory.append(.init(time: Date(), watts: w))
            if powerHistory.count > maxSamples {
                powerHistory.removeFirst(powerHistory.count - maxSamples)
            }
        }

        // Process lists shell out — run off the main actor, publish back.
        guard processListsVisible, !busy,
              Date().timeIntervalSince(lastProcessSample) >= processInterval else { return }
        busy = true
        lastProcessSample = Date()
        work.async { [weak self] in
            let cpu = Self.parse(Self.run("/bin/ps", ["-Aceo", "pid=,comm=,%cpu=", "-r"]),
                                 limit: 5) { String(format: "%.1f%%", $0) }
            let ram = Self.parse(Self.run("/bin/ps", ["-Aceo", "pid=,comm=,rss=", "-m"]),
                                 limit: 5) { Self.formatMB($0 / 1024) }
            let pow = Self.parse(Self.topPowerOutput(), limit: 5) { String(format: "%.1f", $0) }
            Task { @MainActor in
                guard let self else { return }
                if !cpu.isEmpty { self.topCPU = cpu }
                if !ram.isEmpty { self.topRAM = ram }
                if !pow.isEmpty { self.topPower = pow }
                self.lastUpdated = Date()
                self.busy = false
            }
        }
    }

    // MARK: Shell helpers

    nonisolated private static func run(_ launch: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `top` gives a relative energy/power column; take the 2nd sample so %cpu settles.
    nonisolated private static func topPowerOutput() -> String {
        let out = run("/usr/bin/top", ["-l", "2", "-n", "8",
                                       "-stats", "pid,command,power", "-o", "power"])
        // Keep only the last sample (after the final "Processes:" header block).
        if let range = out.range(of: "PID", options: .backwards) {
            return String(out[range.lowerBound...])
        }
        return out
    }

    /// Parse "pid name … value" lines into ProcInfo, sorted desc, truncated to `limit`.
    nonisolated private static func parse(_ text: String, limit: Int,
                              format: (Double) -> String) -> [ProcInfo] {
        var rows: [ProcInfo] = []
        for line in text.split(separator: "\n") {
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard toks.count >= 3, let pid = Int(toks[0]),
                  let value = Double(toks[toks.count - 1].replacingOccurrences(of: "%", with: ""))
            else { continue }
            let name = toks[1..<(toks.count - 1)].joined(separator: " ")
            if name == "top" || pid == 0 { continue }
            rows.append(ProcInfo(pid: pid, name: name, value: value, display: format(value)))
        }
        return Array(rows.prefix(limit))
    }

    nonisolated private static func formatMB(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}
