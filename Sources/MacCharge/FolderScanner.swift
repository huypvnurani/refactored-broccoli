import AppKit
import Combine

/// One folder (or large file) in the FolderTree, with its total on-disk size.
final class FolderNode: Identifiable, @unchecked Sendable {
    enum Kind { case folder, package, file }

    let url: URL
    let kind: Kind
    var name: String
    /// Allocated bytes on disk, everything underneath included.
    var size: Int64 = 0
    /// Files underneath (a package counts as one).
    var fileCount = 0
    /// Items big enough to list, largest first.
    var children: [FolderNode] = []
    /// Everything under the listing threshold, folded into one summary line.
    var otherSize: Int64 = 0
    var otherCount = 0
    /// The folder could not be listed (permissions), so its size is a lower bound.
    var unreadable = false
    weak var parent: FolderNode?

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
        self.name = url.lastPathComponent
    }
}

/// Thread-safe counters the walker bumps and the UI polls while a scan runs.
final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var items = 0
    private var unreadable = 0
    private var current = ""
    private var cancelled = false

    func visit(_ path: String, items n: Int) {
        lock.lock(); current = path; items += n; lock.unlock()
    }
    func markUnreadable() {
        lock.lock(); unreadable += 1; lock.unlock()
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
    func snapshot() -> (items: Int, unreadable: Int, current: String) {
        lock.lock(); defer { lock.unlock() }; return (items, unreadable, current)
    }
}

/// Walks a directory tree and adds up allocated sizes. Runs off the main thread.
struct FolderWalker: Sendable {
    let progress: ScanProgress

    /// Smaller items are summed into their parent but not kept as nodes, which
    /// keeps a whole-disk tree to a few hundred thousand objects.
    static let listThreshold: Int64 = 1 << 20

    /// Mount points and the system's own mirrors of the disk (/.nofollow and
    /// /.resolve re-expose the whole volume): walking them would leave the disk
    /// or count the same files twice.
    static let skipped: Set<String> = [
        "/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/Network",
        "/.vol", "/.nofollow", "/.resolve",
    ]

    static let trashURL: URL =
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]
    private static let keySet = Set(keys)

    /// Measures `url`. The first `parallelDepth` levels fan out across cores.
    func scan(_ url: URL, parallelDepth: Int = 2) -> FolderNode {
        let node = FolderNode(url: url, kind: .folder)
        if url.path == "/",
           let name = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName {
            node.name = name
        }
        fill(node, parallelDepth: parallelDepth, threshold: Self.listThreshold)
        return node
    }

    /// The user's Trash, every top-level item listed. nil when macOS refuses to
    /// list it (the Trash needs Full Disk Access on recent systems).
    func scanTrash() -> FolderNode? {
        let url = Self.trashURL
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
        let node = FolderNode(url: url, kind: .folder)
        node.name = "Trash"
        fill(node, parallelDepth: 1, threshold: 0)
        return node
    }

    private func fill(_ node: FolderNode, parallelDepth: Int, threshold: Int64) {
        guard !progress.isCancelled else { return }
        // Each listing autoreleases a URL per entry; a pool per folder stops a
        // whole-disk walk from holding millions of them until the scan ends.
        guard let listing = autoreleasepool(invoking: { list(node, threshold: threshold) }) else { return }

        if parallelDepth > 0 && listing.subfolders.count > 1 {
            DispatchQueue.concurrentPerform(iterations: listing.subfolders.count) { i in
                fill(listing.subfolders[i], parallelDepth: parallelDepth - 1, threshold: Self.listThreshold)
            }
        } else {
            for s in listing.subfolders {
                fill(s, parallelDepth: 0, threshold: Self.listThreshold)
            }
        }

        var total = listing.smallSize
        var files = listing.smallFiles
        var smallSize = listing.smallSize
        var smallCount = listing.smallFiles
        var listed: [FolderNode] = []
        for k in listing.kids {
            total += k.size
            files += k.fileCount
            if k.size >= threshold {
                k.parent = node
                listed.append(k)
            } else {
                smallSize += k.size
                smallCount += 1
            }
        }
        node.size = total
        node.fileCount = files
        node.otherSize = smallSize
        node.otherCount = smallCount
        node.children = listed.sorted { $0.size > $1.size }
    }

    private struct Listing {
        var kids: [FolderNode] = []
        var subfolders: [FolderNode] = []
        /// Files under the threshold, summed instead of kept as nodes.
        var smallSize: Int64 = 0
        var smallFiles = 0
    }

    /// Reads one folder's entries. nil when macOS refuses to list it.
    private func list(_ node: FolderNode, threshold: Int64) -> Listing? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: node.url, includingPropertiesForKeys: Self.keys, options: []) else {
            node.unreadable = true
            progress.markUnreadable()
            return nil
        }
        progress.visit(node.url.path, items: entries.count)

        var l = Listing()
        for entry in entries {
            guard let v = try? entry.resourceValues(forKeys: Self.keySet) else { continue }
            // A link is a few bytes; following it would count its target twice.
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                // Some special folders come back as "/.nofollow/": drop the slash.
                var path = entry.path
                if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if Self.skipped.contains(path) || path == Self.trashURL.path { continue }
                if v.isPackage == true {
                    let n = FolderNode(url: entry, kind: .package)
                    measurePackage(n)
                    l.kids.append(n)
                } else {
                    let n = FolderNode(url: entry, kind: .folder)
                    l.subfolders.append(n)
                    l.kids.append(n)
                }
            } else {
                let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                if size >= threshold {
                    let n = FolderNode(url: entry, kind: .file)
                    n.size = size
                    n.fileCount = 1
                    l.kids.append(n)
                } else {
                    l.smallSize += size
                    l.smallFiles += 1
                }
            }
        }
        return l
    }

    /// Apps, libraries and bundles show as one item: their insides are rarely
    /// what the user is hunting for, and skipping them keeps the tree small.
    private func measurePackage(_ node: FolderNode) {
        node.fileCount = 1
        guard let e = FileManager.default.enumerator(
            at: node.url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [], errorHandler: { _, _ in true }) else { return }
        var total: Int64 = 0
        var count = 0
        while let url = autoreleasepool(invoking: { e.nextObject() as? URL }) {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            count += 1
        }
        node.size = total
        progress.visit(node.url.path, items: count)
    }
}

/// Owns the FolderTree scan and the actions taken on its items.
@MainActor
final class FolderScanner: ObservableObject {
    static let shared = FolderScanner()

    enum Scope: Hashable {
        case wholeMac, home, custom(URL)

        var url: URL {
            switch self {
            case .wholeMac: return URL(fileURLWithPath: "/")
            case .home: return FileManager.default.homeDirectoryForCurrentUser
            case .custom(let u): return u
            }
        }
    }

    @Published var scope: Scope = .wholeMac
    @Published private(set) var root: FolderNode?
    @Published private(set) var trash: FolderNode?
    /// false when macOS would not let MacCharge list the Trash.
    @Published private(set) var trashReadable = true
    @Published private(set) var isScanning = false
    @Published private(set) var scannedItems = 0
    @Published private(set) var unreadableCount = 0
    @Published private(set) var currentPath = ""
    @Published private(set) var lastScan: Date?
    @Published private(set) var scanDuration: TimeInterval = 0
    /// Bumped when the tree changes in place (an item left it), so views redraw.
    @Published private(set) var revision = 0
    @Published var lastError: String?

    private var progress: ScanProgress?
    private var pollTimer: Timer?

    private init() {}

    // MARK: Scanning

    func scan() {
        guard !isScanning else { return }
        let target = scope.url
        let p = ScanProgress()
        progress = p
        isScanning = true
        scannedItems = 0
        unreadableCount = 0
        currentPath = target.path
        let start = Date()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullProgress() }
        }

        Task.detached(priority: .utility) {
            let walker = FolderWalker(progress: p)
            let tree = walker.scan(target)
            let trashTree = walker.scanTrash()
            await MainActor.run {
                self.finishScan(p, tree: tree, trash: trashTree, started: start)
            }
        }
    }

    /// Stops the walk; the previous result, if any, stays on screen.
    func cancel() {
        progress?.cancel()
    }

    private func pullProgress() {
        guard let p = progress else { return }
        let s = p.snapshot()
        scannedItems = s.items
        unreadableCount = s.unreadable
        currentPath = s.current
    }

    private func finishScan(_ p: ScanProgress, tree: FolderNode, trash trashTree: FolderNode?, started: Date) {
        pullProgress()
        pollTimer?.invalidate()
        pollTimer = nil
        progress = nil
        isScanning = false
        guard !p.isCancelled else { return }
        root = tree
        trash = trashTree
        trashReadable = trashTree != nil
        lastScan = Date()
        scanDuration = Date().timeIntervalSince(started)
    }

    /// Re-measures just the Trash (after something was moved into it or emptied).
    func refreshTrash() {
        Task.detached(priority: .utility) {
            let t = FolderWalker(progress: ScanProgress()).scanTrash()
            await MainActor.run {
                self.trash = t
                self.trashReadable = t != nil
            }
        }
    }

    // MARK: Disk

    /// (used, total) bytes of the startup disk.
    var diskUsage: (used: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity,
              let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Int64(total) - free, Int64(total))
    }

    // MARK: Actions

    func reveal(_ node: FolderNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    /// Opens Finder's Get Info window through Finder's own "Show Info" service,
    /// which needs no Automation permission (an AppleScript would).
    func showInfo(_ node: FolderNode) {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.urani.maccharge.showinfo"))
        pb.clearContents()
        pb.writeObjects([node.url as NSURL])
        if !NSPerformService("Finder/Show Info", pb) {
            reveal(node)
        }
    }

    func copyPath(_ node: FolderNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    func openTrash() {
        NSWorkspace.shared.open(FolderWalker.trashURL)
    }

    /// Folders a slip of the mouse should never send to the Trash, even though
    /// the user owns them.
    private static let protectedPaths: Set<String> = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var s: Set<String> = ["/", "/Users", "/Applications", "/Library", "/System", home]
        for sub in ["Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Applications", "Public"] {
            s.insert(home + "/" + sub)
        }
        return s
    }()

    /// True when the item can go to the Trash without an admin password.
    func canTrash(_ node: FolderNode) -> Bool {
        let path = node.url.path
        if Self.protectedPaths.contains(path) { return false }
        if node === root || node === trash { return false }
        return FileManager.default.isDeletableFile(atPath: path)
    }

    func moveToTrash(_ node: FolderNode) {
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            detach(node)
            refreshTrash()
        } catch {
            lastError = "Could not move “\(node.name)” to the Trash: \(error.localizedDescription)"
        }
    }

    /// Permanently removes one item that is already in the Trash.
    func deleteImmediately(_ node: FolderNode) {
        do {
            try FileManager.default.removeItem(at: node.url)
            detach(node)
        } catch {
            lastError = "Could not delete “\(node.name)”: \(error.localizedDescription)"
        }
    }

    func emptyTrash() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: FolderWalker.trashURL, includingPropertiesForKeys: nil)) ?? []
        var failed = 0
        for url in items {
            do { try fm.removeItem(at: url) } catch { failed += 1 }
        }
        if failed > 0 {
            lastError = "\(failed) item(s) could not be deleted — they may need an admin password. Empty the Trash from Finder for those."
        }
        refreshTrash()
    }

    /// Takes a removed item out of the tree and its size out of every ancestor.
    private func detach(_ node: FolderNode) {
        guard let parent = node.parent else { return }
        parent.children.removeAll { $0 === node }
        var p: FolderNode? = parent
        while let a = p {
            a.size -= node.size
            a.fileCount -= node.fileCount
            p = a.parent
        }
        revision += 1
    }
}
