import AppKit
import Combine
import Foundation
import SMCCore

/// Manual fan control: keeps the chosen mode/speed, drives the privileged helper
/// that performs the actual SMC writes, and watches the temperature so a forced
/// fan can never cook the machine.
///
/// Reads happen in-process (they need no privileges); every write goes through
/// `maccharge-fanhelper`, which the user installs once behind an admin prompt.
@MainActor
final class FanController: ObservableObject {
    static let shared = FanController()

    enum Mode: String { case auto, manual }

    /// What the installed helper looks like from the app's point of view.
    enum HelperState: Equatable { case missing, outdated, ready }

    /// Helper command surface this build expects — bump it in both places when
    /// the helper's arguments change, so an old installed copy is spotted.
    nonisolated static let expectedHelperVersion = "1"

    /// Hottest sensor reading that hands the fans straight back to the firmware.
    /// A forced fan does not spin up on its own, so this is the safety net.
    static let safetyCutoffC: Double = 92

    nonisolated private static let helperName = "maccharge-fanhelper"
    nonisolated static let helperDirectory = "/Library/Application Support/MacCharge"
    nonisolated static let helperPath = helperDirectory + "/" + helperName

    // MARK: Published state

    /// Who decides the fan speed: the firmware, or the slider below.
    @Published var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Key.mode)
            if mode == .manual { safetyTripped = false }
            applyNow()
        }
    }

    /// Requested speed as a percentage of each fan's own min–max range, so one
    /// slider fits fans with different ceilings.
    @Published var percent: Double {
        didSet {
            guard percent != oldValue else { return }
            defaults.set(percent, forKey: Key.percent)
            guard mode == .manual else { return }
            scheduleApply()          // dragging must not spawn a process per frame
        }
    }

    @Published private(set) var fans: [SMC.Fan] = []
    @Published private(set) var helper: HelperState = .missing
    @Published private(set) var busy = false
    /// Last thing worth telling the user, nil when everything is uneventful.
    @Published private(set) var message: String?
    @Published private(set) var messageIsError = false
    /// Set when the safety cutoff, not the user, put the fans back on automatic.
    @Published private(set) var safetyTripped = false

    // MARK: Internals

    private enum Key {
        static let mode = "fanControlMode"
        static let percent = "fanTargetPercent"
    }

    private let defaults = UserDefaults.standard
    private let smc = SMC()
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var applyWork: DispatchWorkItem?

    /// True only while the Cooling tab is on screen — it polls faster there.
    var uiVisible = false {
        didSet {
            guard uiVisible != oldValue else { return }
            if uiVisible { refresh() }
            retuneTimer()
        }
    }

    private init() {
        defaults.register(defaults: [Key.mode: Mode.auto.rawValue, Key.percent: 50.0])
        mode = Mode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .auto
        percent = min(100, max(0, defaults.double(forKey: Key.percent)))

        smc.open()
        fans = smc.fans()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        Task { await detectHelper(thenReassert: true) }
        retuneTimer()
    }

    // MARK: Derived values

    var hasFans: Bool { !fans.isEmpty }
    var controllableFans: [SMC.Fan] { fans.filter(\.isControllable) }
    var canControl: Bool { !controllableFans.isEmpty }

    /// RPM this fan should hold at the current slider position.
    func targetRPM(for fan: SMC.Fan) -> Int {
        guard fan.isControllable else { return fan.rpm }
        let span = Double(fan.max - fan.min)
        return fan.min + Int((span * percent / 100).rounded())
    }

    /// Where a fan's live speed sits inside its own range (0…1), for the gauges.
    func fraction(of fan: SMC.Fan) -> Double {
        guard fan.max > fan.min else { return 0 }
        return min(1, max(0, Double(fan.rpm - fan.min) / Double(fan.max - fan.min)))
    }

    var isControllingFans: Bool { mode == .manual && helper == .ready }

    // MARK: Polling

    /// One timer covers both jobs: refreshing the tab while it is open, and the
    /// safety watchdog, which has to keep running with no window on screen.
    private func retuneTimer() {
        let wanted: TimeInterval? = uiVisible ? 2 : (mode == .manual ? 5 : nil)
        guard let interval = wanted else {
            timer?.invalidate(); timer = nil; timerInterval = 0
            return
        }
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timerInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func refresh() { fans = smc.fans() }

    private func tick() {
        fans = smc.fans()
        guard mode == .manual, helper == .ready, !busy else { return }

        // Safety first: a forced fan holds its speed no matter how hot it gets.
        // Fans already pinned at 100% are the exception — the firmware has no
        // faster setting to reach for, so taking the user's choice away there
        // would only surprise them mid-render.
        if percent < 100, let hottest = smc.thermal().hottest, hottest >= Self.safetyCutoffC {
            safetyTripped = true
            mode = .auto            // didSet releases the fans
            note(String(format: "%.0f°C reached — fans handed back to macOS for safety.",
                        hottest), error: true)
            return
        }

        // Waking from sleep (and the odd firmware reset) drops forced mode, so
        // the watchdog re-asserts it instead of silently leaving fans on auto.
        let drifted = controllableFans.contains {
            !$0.forced || abs($0.target - targetRPM(for: $0)) > 60
        }
        if drifted { applyNow(quiet: true) }
    }

    @objc private func systemDidWake() {
        Task { @MainActor in
            guard mode == .manual, helper == .ready else { return }
            refresh()
            applyNow(quiet: true)
        }
    }

    // MARK: Applying

    private func scheduleApply() {
        applyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyNow() }
        applyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Push the current mode/speed to the hardware. `quiet` suppresses the
    /// success note for the watchdog's own re-assertions.
    private func applyNow(quiet: Bool = false) {
        applyWork?.cancel()
        retuneTimer()

        guard hasFans else { return note("This Mac has no fans to control.", error: false) }
        guard mode == .auto || canControl else {
            return note("The firmware reports no adjustable range for this fan.", error: true)
        }
        guard helper == .ready else {
            if mode == .manual { note(helperHint, error: true) }
            return
        }

        let commands: [[String]] = mode == .manual
            ? controllableFans.map { ["set", "\($0.id)", "\(targetRPM(for: $0))"] }
            : [["auto"]]
        let path = Self.helperPath
        busy = true
        Task {
            var failure: String?
            for command in commands {
                let result = await Self.runDetached(path, command)
                if result.code != 0 {
                    failure = Self.describe(result)
                    break
                }
            }
            busy = false
            refresh()
            if let failure {
                note(failure, error: true)
                await detectHelper(thenReassert: false)   // helper may have been removed
            } else if !quiet {
                if mode == .manual {
                    let rpms = controllableFans.map { "\(targetRPM(for: $0))" }.joined(separator: " / ")
                    note("Holding \(rpms) RPM.", error: false)
                } else {
                    note("Fans back under macOS control.", error: false)
                }
            }
        }
    }

    /// Release the fans and wait for it, for use on the way out of the app.
    /// Leaving a forced fan behind with nothing watching the temperature is the
    /// one state this feature must never exit in.
    func releaseFansBeforeQuit() {
        guard mode == .manual, helper == .ready else { return }
        _ = Self.run(Self.helperPath, ["auto"])
    }

    func clearMessage() { message = nil; messageIsError = false }

    private func note(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    private var helperHint: String {
        switch helper {
        case .missing:  return "Fan control needs its helper installed first."
        case .outdated: return "The installed helper is from an older MacCharge — update it."
        case .ready:    return ""
        }
    }

    // MARK: Helper installation

    /// The copy shipped inside the app bundle, which the install step copies out.
    private static var bundledHelper: URL? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: helperName) { return url }
        // `swift run` builds have no bundle: the helper sits next to the binary.
        guard let dev = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent(helperName),
              FileManager.default.isExecutableFile(atPath: dev.path) else { return nil }
        return dev
    }

    @discardableResult
    func detectHelper(thenReassert: Bool) async -> HelperState {
        let state = await Task.detached { Self.inspectHelper() }.value
        helper = state
        if thenReassert, state == .ready, mode == .manual { applyNow(quiet: true) }
        retuneTimer()
        return state
    }

    /// Installs (or re-installs) the helper as root:wheel, mode 4755. Needs the
    /// user's admin password — macOS shows its own authorisation dialog.
    func installHelper() async {
        guard let source = Self.bundledHelper else {
            return note("The helper is missing from this build of MacCharge.", error: true)
        }
        busy = true
        let script = Self.installScript(from: source.path)
        let result = await Task.detached { Self.authorize(script) }.value
        busy = false
        switch result {
        case .cancelled:
            note("Installation cancelled — fan control stays off.", error: false)
        case .failed(let why):
            note("Could not install the helper: \(why)", error: true)
        case .ok:
            let state = await detectHelper(thenReassert: true)
            note(state == .ready ? "Helper installed — fan control is ready."
                                 : "The helper installed but does not answer; try again.",
                 error: state != .ready)
        }
    }

    /// Removes the helper again, which also takes fan control away.
    func removeHelper() async {
        if mode == .manual { mode = .auto }
        busy = true
        let script = "/bin/rm -f \(Self.shellQuote(Self.helperPath))"
        let result = await Task.detached { Self.authorize(script) }.value
        busy = false
        switch result {
        case .cancelled: break
        case .failed(let why): note("Could not remove the helper: \(why)", error: true)
        case .ok: note("Helper removed.", error: false)
        }
        await detectHelper(thenReassert: false)
    }

    private static func installScript(from source: String) -> String {
        let dir = shellQuote(helperDirectory)
        let dst = shellQuote(helperPath)
        return "/bin/mkdir -p \(dir)"
            + " && /bin/cp \(shellQuote(source)) \(dst)"
            + " && /usr/sbin/chown root:wheel \(dst)"
            + " && /bin/chmod 4755 \(dst)"
    }

    // MARK: Process plumbing

    private enum AuthResult { case ok, cancelled, failed(String) }

    /// Runs one shell line as root through AppleScript's authorisation dialog.
    /// Nothing user-supplied reaches it: the only variable part is the app's own path.
    nonisolated private static func authorize(_ shellLine: String) -> AuthResult {
        let escaped = shellLine
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = run("/usr/bin/osascript",
                         ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        if result.code == 0 { return .ok }
        // -128 is the user dismissing the password dialog.
        if result.err.contains("-128") || result.err.lowercased().contains("user canceled") {
            return .cancelled
        }
        let why = result.err.split(separator: "\n").last.map(String.init) ?? "exit \(result.code)"
        return .failed(why)
    }

    nonisolated private static func runDetached(_ path: String,
                                                _ args: [String]) async -> (code: Int32, out: String, err: String) {
        await Task.detached { run(path, args) }.value
    }

    nonisolated private static func run(_ path: String,
                                        _ args: [String]) -> (code: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated private static func describe(_ result: (code: Int32, out: String, err: String)) -> String {
        if !result.err.isEmpty {
            return result.err.replacingOccurrences(of: "maccharge-fanhelper: ", with: "")
        }
        return "The fan helper failed (exit \(result.code))."
    }

    /// Is the installed helper there, root-owned, setuid and the version we speak?
    nonisolated private static func inspectHelper() -> HelperState {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: helperPath) else { return .missing }
        let owner = (attrs[.ownerAccountID] as? NSNumber)?.intValue ?? -1
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        // Without the setuid bit and root ownership it cannot write the SMC; if it
        // is writable by anyone else, it is not a helper worth trusting either.
        guard owner == 0, perms & 0o4000 != 0, perms & 0o022 == 0 else { return .missing }
        let version = run(helperPath, ["version"])
        guard version.code == 0 else { return .missing }
        return version.out == expectedHelperVersion ? .ready : .outdated
    }

    nonisolated private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
