import AppKit

/// Full Disk Access cannot be requested with a prompt: the user has to add the
/// app in System Settings themselves. This checks whether it has been granted
/// and walks the user to the right place.
enum FullDiskAccess {
    /// A file every Mac has and only Full Disk Access may open.
    private static let probe = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")

    /// True once MacCharge is switched on under Full Disk Access. Opening the
    /// file (not just checking its permission bits) is what TCC actually guards.
    static var isGranted: Bool {
        guard let handle = try? FileHandle(forReadingFrom: probe) else { return false }
        try? handle.close()
        return true
    }

    /// Opens Privacy & Security ▸ Full Disk Access and shows MacCharge.app in
    /// Finder, so it can be dragged into the list (or picked with +).
    static func openSettings() {
        // A denied attempt also lets macOS know the app wants the access.
        _ = isGranted
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
