import SwiftUI

@main
struct MacChargeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The main window is owned by AppDelegate so the app can keep running as a
    // menu-bar service after the user closes it.
    var body: some Scene {
        Settings { AboutPane() }
    }
}

/// Minimal pane behind ⌘, — the Settings scene exists only so the App has a
/// scene; the real UI lives in the AppDelegate-owned window.
private struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MacCharge").font(.system(size: 15, weight: .bold))
            Text("Version 1.3.1").font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            Text("The wattage shows in the menu bar and on the Dock icon.\nClosing the window keeps the app running in the background; click the wattage to bring it back.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 320)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Touch the shared monitors so polling starts even if no window opens.
        _ = PowerMonitor.shared
        _ = SystemMonitor.shared
        _ = FanController.shared
        PowerMonitor.shared.interval = Preferences.shared.interval

        StatusPresenter.shared.onOpenApp = { [weak self] in self?.showMainWindow() }
        StatusPresenter.shared.install()

        showMainWindow()
    }

    /// Closing the window leaves the menu-bar item running; quit from its menu or ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Never leave a fan forced with the app gone and nothing watching the
    /// temperature — manual mode is restored on the next launch instead.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { FanController.shared.releaseFansBeforeQuit() }
    }

    /// Closing the window drops the app out of the Dock and the ⌘-Tab switcher,
    /// the way a Vietnamese IME does — only the menu-bar wattage stays behind.
    func windowWillClose(_ notification: Notification) {
        // Nothing is reading the SMC values with no window on screen.
        SystemMonitor.shared.windowVisible = false
        FanController.shared.uiVisible = false
        guard Preferences.shared.hideDockOnClose else { return }
        // Deferred: switching policy inside the close itself upsets AppKit.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Preferences.shared.refreshLoginItemState()
    }

    /// Right-click / long-press on the Dock icon shows the live wattage.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        StatusPresenter.shared.detailMenu()
    }

    @MainActor func showMainWindow() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 840),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "MacCharge"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false          // so it can be reopened later
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentMinSize = NSSize(width: 1060, height: 800)
            w.contentView = NSHostingView(rootView: ContentView())
            w.center()
            w.setFrameAutosaveName("MacChargeMain")
            w.delegate = self
            window = w
        }
        // Coming back from the menu bar: put the Dock icon back first.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        SystemMonitor.shared.windowVisible = true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
