import AppKit
import Combine
import ServiceManagement

/// User-facing options, persisted in UserDefaults so they survive a relaunch.
/// `launchAtLogin` is the exception: the system owns that state, so it is read
/// back from `LoginItem` rather than from defaults.
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

    /// Start MacCharge automatically when the user logs in.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LoginItem.isEnabled else { return }
            do {
                try LoginItem.setEnabled(launchAtLogin)
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
                launchAtLogin = LoginItem.isEnabled
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
        launchAtLogin = LoginItem.isEnabled
    }

    /// Re-reads the login-item state from the system (it can change outside the app).
    func refreshLoginItemState() {
        let enabled = LoginItem.isEnabled
        if launchAtLogin != enabled { launchAtLogin = enabled }
    }
}

/// Start-at-login: `SMAppService` on macOS 13+, a per-user LaunchAgent on
/// macOS 12, which has no API for registering the main app itself.
enum LoginItem {
    private static let label = "com.urani.maccharge.login"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return
        }
        if enabled {
            // `open` rather than the binary itself, so a moved or updated app
            // is still found by its bundle path at the next login.
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: agentURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: agentURL.path) {
            try FileManager.default.removeItem(at: agentURL)
        }
    }
}
