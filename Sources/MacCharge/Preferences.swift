import AppKit
import Combine
import ServiceManagement

/// User-facing options, persisted in UserDefaults so they survive a relaunch.
/// `launchAtLogin` is the exception: the system owns that state, so it is read
/// back from `SMAppService` rather than from defaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let menuBarItem = "showMenuBarItem"
        static let dockBadge = "showDockBadge"
        static let hideDockOnClose = "hideDockOnClose"
        static let interval = "refreshInterval"
    }

    /// Show the wattage in the menu bar.
    @Published var showMenuBarItem: Bool {
        didSet {
            defaults.set(showMenuBarItem, forKey: Key.menuBarItem)
            // Never leave the app with no way back: without a menu-bar item the
            // Dock icon has to stay.
            if !showMenuBarItem && hideDockOnClose { hideDockOnClose = false }
            StatusPresenter.shared.applyPreferences()
        }
    }

    /// Show the wattage badge on the Dock icon.
    @Published var showDockBadge: Bool {
        didSet {
            defaults.set(showDockBadge, forKey: Key.dockBadge)
            StatusPresenter.shared.applyPreferences()
        }
    }

    /// Closing the window hides the app from the Dock and ⌘-Tab (menu-bar only).
    @Published var hideDockOnClose: Bool {
        didSet {
            defaults.set(hideDockOnClose, forKey: Key.hideDockOnClose)
            if hideDockOnClose && !showMenuBarItem { showMenuBarItem = true }
        }
    }

    /// Seconds between automatic refreshes.
    @Published var interval: Double {
        didSet {
            defaults.set(interval, forKey: Key.interval)
            PowerMonitor.shared.interval = interval
        }
    }

    /// Start Mac Charge automatically when the user logs in.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    /// Set when macOS refuses the login-item change, shown under the toggle.
    @Published private(set) var loginItemError: String?

    private init() {
        defaults.register(defaults: [
            Key.menuBarItem: true,
            Key.dockBadge: true,
            Key.hideDockOnClose: true,
            Key.interval: 2.0,
        ])
        showMenuBarItem = defaults.bool(forKey: Key.menuBarItem)
        showDockBadge = defaults.bool(forKey: Key.dockBadge)
        hideDockOnClose = defaults.bool(forKey: Key.hideDockOnClose)
        interval = defaults.double(forKey: Key.interval)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Re-reads the login-item state from the system (it can change outside the app).
    func refreshLoginItemState() {
        let enabled = SMAppService.mainApp.status == .enabled
        if launchAtLogin != enabled { launchAtLogin = enabled }
    }
}
