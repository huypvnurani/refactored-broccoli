import AppKit
import Combine

/// Publishes the live wattage outside the main window: as a menu-bar item that
/// survives the window being closed, and as a badge on the Dock icon.
///
/// macOS gives no API for the Dock hover tooltip (it always shows the app name),
/// so the number is drawn on the icon itself instead.
@MainActor
final class StatusPresenter {
    static let shared = StatusPresenter()
    private init() {}

    /// Called when the user clicks the menu-bar item.
    var onOpenApp: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var cancellable: AnyCancellable?
    private var menuLines: [String] = ["Reading…"]

    /// Creates the menu-bar item (if enabled) and starts mirroring the shared monitor.
    func install() {
        applyPreferences()
        cancellable = PowerMonitor.shared.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in self?.update(snap) }
    }

    /// Adds or removes the menu-bar item and the Dock badge to match Preferences.
    func applyPreferences() {
        if Preferences.shared.showMenuBarItem {
            if statusItem == nil { statusItem = makeStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        update(PowerMonitor.shared.snapshot)
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.title = "–"
        item.button?.toolTip = "MacCharge"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        return item
    }

    // MARK: Rendering

    private func update(_ s: PowerSnapshot) {
        statusItem?.button?.title = menuBarText(s)
        // Dock badge is hidden instead of showing a bare 0W.
        NSApp.dockTile.badgeLabel = Preferences.shared.showDockBadge ? dockBadge(s) : nil
        menuLines = detailLines(s)
    }

    /// Menu-bar text: always a number, including 0W. A leading "›" means the Mac
    /// is running on battery; plugged into the charger, the number stands alone.
    func menuBarText(_ s: PowerSnapshot) -> String {
        let mark = s.adapterConnected ? "" : "›"
        return mark + String(format: "%.0fW", watts(s).rounded())
    }

    /// Real adapter output when it is reported, else the adapter's rated wattage;
    /// on battery, the power flowing out of the cell.
    private func watts(_ s: PowerSnapshot) -> Double {
        guard s.adapterConnected else { return s.batteryPowerW }
        let out = s.adapterVoltageV * s.adapterCurrentA
        return out > 0.5 ? out : Double(s.adapterWatts)
    }

    /// Same "›" prefix as the menu bar. The badge oval fits about five
    /// characters, so "›23W" stays legible.
    private func dockBadge(_ s: PowerSnapshot) -> String? {
        let rounded = watts(s).rounded()
        guard rounded >= 1 else { return nil }
        let mark = s.adapterConnected ? "" : "›"
        return mark + String(format: "%.0fW", rounded)
    }

    private func detailLines(_ s: PowerSnapshot) -> [String] {
        guard s.adapterConnected else {
            return ["Charger: unplugged",
                    String(format: "Battery draw: %.1f W", s.batteryPowerW),
                    "Battery: \(s.currentCapacity)% · \(s.timeRemainingText)"]
        }
        let out = s.adapterVoltageV * s.adapterCurrentA
        return [out > 0.5 ? String(format: "Charger: %.1f W / %d W", out, s.adapterWatts)
                          : "Charger: \(s.adapterWatts) W",
                String(format: "Adapter: %.1f V · %.2f A", s.adapterVoltageV, s.adapterCurrentA),
                "Battery: \(s.currentCapacity)% · \(s.chargeStateText)"]
    }

    // MARK: Interaction

    /// Left click opens the window; right click drops the detail menu.
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            onOpenApp?()
        }
    }

    private func showMenu() {
        guard let item = statusItem else { return }
        item.menu = detailMenu()
        item.button?.performClick(nil)
        item.menu = nil          // keep left-click bound to the action above
    }

    /// Read-only rows, also used for the Dock icon's right-click menu.
    func detailMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for line in menuLines {
            let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open MacCharge", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit MacCharge", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openApp() { onOpenApp?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
