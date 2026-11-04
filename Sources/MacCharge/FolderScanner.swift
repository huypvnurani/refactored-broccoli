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
    /// Live preview only: the folder is still being measured.
    var pending = false
    /// Large-files list only: when the file was last read.
    var accessDate: Date?
    weak var parent: FolderNode?

    /// The path: stable across rescans and live previews, so expansion and
    /// selection survive the tree being rebuilt.
    var id: String { url.path }

    init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
        self.name = url.lastPathComponent
    }

    /// The node at `path` in this subtree, if it is listed.
    func find(_ path: String) -> FolderNode? {
        if id == path { return self }
        let prefix = id == "/" ? "/" : id + "/"
        guard path.hasPrefix(prefix) else { return nil }
        for c in children {
            if let hit = c.find(path) { return hit }
        }
        return nil
    }
}

/// Thread-safe state the walker writes and the UI polls while a scan runs:
/// counters, the live preview of the top few levels, and the largest files.
final class ScanProgress: @unchecked Sendable {
    struct LiveEntry {
        let url: URL
        let kind: FolderNode.Kind
        let parent: String
        /// nil while a folder is still being measured.
        var size: Int64?
    }

    private let lock = NSLock()
    private var items = 0
    private var unreadable = 0
    private var current = ""
    private var cancelled = false

    private var live: [String: LiveEntry] = [:]
    private var liveRevision = 0

    static let largeFileCapacity = 300
    private var largest: [FolderNode] = []
    private var largestFloor: Int64 = 0

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

    // MARK: Live preview

    func register(_ entries: [LiveEntry]) {
        lock.lock()
        for e in entries { live[e.url.path] = e }
        liveRevision += 1
        lock.unlock()
    }
    func complete(_ path: String, size: Int64) {
        lock.lock()
        live[path]?.size = size
        liveRevision += 1
        lock.unlock()
    }
    /// The live entries, or nil when nothing changed since `revision`.
    func liveSnapshot(since revision: Int) -> (entries: [String: LiveEntry], revision: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard liveRevision != revision else { return nil }
        return (live, liveRevision)
    }

    // MARK: Largest files

    func offer(_ node: FolderNode) {
        lock.lock(); defer { lock.unlock() }
        if largest.count < Self.largeFileCapacity {
            largest.append(node)
            if largest.count == Self.largeFileCapacity { largestFloor = largest.map(\.size).min() ?? 0 }
        } else if node.size > largestFloor, let i = largest.firstIndex(where: { $0.size == largestFloor }) {
            largest[i] = node
            largestFloor = largest.map(\.size).min() ?? 0
        }
    }
    func largestFiles() -> [FolderNode] {
        lock.lock(); defer { lock.unlock() }
        return largest.sorted { $0.size > $1.size }
    }
}

/// Walks a directory tree and adds up allocated sizes. Runs off the main thread.
struct FolderWalker: Sendable {
    let progress: ScanProgress
    /// Feed the live preview and the largest-files list (off for the Trash).
    var collect = true

    /// Smaller items are summed into their parent but not kept as nodes, which
    /// keeps a whole-disk tree to a few hundred thousand objects.
    static let listThreshold: Int64 = 1 << 20

    /// Levels below the scanned folder that show up while the scan still runs.
    static let liveDepth = 4

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

    /// Display name for a scan root ("Macintosh HD" for /).
    static func rootName(_ url: URL) -> String {
        if url.path == "/", let name = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName {
            return name
        }
        return url.lastPathComponent
    }

    /// Measures `url`. The first `parallelDepth` levels fan out across cores.
    func scan(_ url: URL, parallelDepth: Int = 2) -> FolderNode {
        let node = FolderNode(url: url, kind: .folder)
        node.name = Self.rootName(url)
        fill(node, depth: 0, parallelDepth: parallelDepth, threshold: Self.listThreshold)
        return node
    }

    /// The user's Trash, every top-level item listed. nil when macOS refuses to
    /// list it (the Trash needs Full Disk Access on recent systems).
    func scanTrash() -> FolderNode? {
        let url = Self.trashURL
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
        let node = FolderNode(url: url, kind: .folder)
        node.name = "Trash"
        fill(node, depth: 0, parallelDepth: 1, threshold: 0)
        return node
    }

    private func fill(_ node: FolderNode, depth: Int, parallelDepth: Int, threshold: Int64) {
        guard !progress.isCancelled else { return }
        // Each listing autoreleases a URL per entry; a pool per folder stops a
        // whole-disk walk from holding millions of them until the scan ends.
        guard let listing = autoreleasepool(invoking: { list(node, threshold: threshold) }) else {
            if collect && depth >= 1 && depth <= Self.liveDepth { progress.complete(node.id, size: 0) }
            return
        }

        if collect && depth < Self.liveDepth {
            progress.register(listing.kids.map {
                .init(url: $0.url, kind: $0.kind, parent: node.id, size: $0.kind == .folder ? nil : $0.size)
            })
        }

        if parallelDepth > 0 && listing.subfolders.count > 1 {
            DispatchQueue.concurrentPerform(iterations: listing.subfolders.count) { i in
                fill(listing.subfolders[i], depth: depth + 1, parallelDepth: parallelDepth - 1,
                     threshold: Self.listThreshold)
            }
        } else {
            for s in listing.subfolders {
                fill(s, depth: depth + 1, parallelDepth: 0, threshold: Self.listThreshold)
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

        if collect && depth >= 1 && depth <= Self.liveDepth { progress.complete(node.id, size: total) }
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
                    if collect { progress.offer(n) }
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

/// How the startup disk's APFS container is split between its volumes, read
/// from `diskutil apfs list` (no admin rights needed).
struct DiskBreakdown: Sendable {
    struct Volume: Sendable, Identifiable {
        let name: String
        let role: String
        let used: Int64
        var id: String { name + role }
    }

    let capacity: Int64
    let free: Int64
    let volumes: [Volume]
    /// Local Time Machine snapshots on /, when `tmutil` lists them.
    let snapshotCount: Int

    var used: Int64 { capacity - free }
    /// Bytes on the System + Data volumes: the part a folder scan of / can see.
    var browsable: Int64 {
        volumes.filter { $0.role == "System" || $0.role == "Data" }.reduce(0) { $0 + $1.used }
    }

    /// nil when either tool is missing or prints something unexpected.
    static func read() -> DiskBreakdown? {
        guard let info = run("/usr/sbin/diskutil", ["info", "-plist", "/"]),
              let infoPlist = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              let containerRef = infoPlist["APFSContainerReference"] as? String,
              let list = run("/usr/sbin/diskutil", ["apfs", "list", "-plist"]),
              let listPlist = try? PropertyListSerialization.propertyList(from: list, format: nil) as? [String: Any],
              let containers = listPlist["Containers"] as? [[String: Any]],
              let c = containers.first(where: { $0["ContainerReference"] as? String == containerRef }),
              let capacity = (c["CapacityCeiling"] as? NSNumber)?.int64Value,
              let free = (c["CapacityFree"] as? NSNumber)?.int64Value,
              let vols = c["Volumes"] as? [[String: Any]] else { return nil }

        let volumes: [Volume] = vols.compactMap { v in
            guard let name = v["Name"] as? String,
                  let used = (v["CapacityInUse"] as? NSNumber)?.int64Value else { return nil }
            let role = (v["Roles"] as? [String])?.first ?? ""
            return Volume(name: name, role: role, used: used)
        }
        .sorted { $0.used > $1.used }

        var snapshots = 0
        if let out = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]),
           let text = String(data: out, encoding: .utf8) {
            snapshots = text.split(separator: "\n").filter { $0.hasPrefix("com.apple.") }.count
        }
        return DiskBreakdown(capacity: capacity, free: free, volumes: volumes, snapshotCount: snapshots)
    }

    private static func run(_ tool: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
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
    /// The top levels measured so far, rebuilt while a scan runs.
    @Published private(set) var livePreview: FolderNode?
    @Published private(set) var trash: FolderNode?
    /// The biggest single files of the last scan, largest first.
    @Published private(set) var largeFiles: [FolderNode] = []
    /// false when macOS would not let MacCharge list the Trash.
    @Published private(set) var trashReadable = true
    @Published private(set) var breakdown: DiskBreakdown?
    @Published private(set) var isScanning = false
    @Published private(set) var scannedItems = 0
    @Published private(set) var unreadableCount = 0
    @Published private(set) var currentPath = ""
    @Published private(set) var lastScan: Date?
    @Published private(set) var lastScanScope: Scope?
    @Published private(set) var scanDuration: TimeInterval = 0
    /// Bumped when the tree changes in place (an item left it), so views redraw.
    @Published private(set) var revision = 0
    @Published var lastError: String?

    private var progress: ScanProgress?
    private var pollTimer: Timer?
    private var liveRevision = -1

    private init() {}

    // MARK: Scanning

    func scan() {
        guard !isScanning else { return }
        let target = scope.url
        let scanScope = scope
        let p = ScanProgress()
        progress = p
        isScanning = true
        scannedItems = 0
        unreadableCount = 0
        currentPath = target.path
        liveRevision = -1
        livePreview = nil
        let start = Date()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullProgress() }
        }

        Task.detached(priority: .utility) {
            let walker = FolderWalker(progress: p)
            let tree = walker.scan(target)
            let trashTree = FolderWalker(progress: p, collect: false).scanTrash()
            let large = p.largestFiles()
            for f in large {
                f.accessDate = try? f.url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
            }
            let disk = scanScope == .wholeMac ? DiskBreakdown.read() : nil
            await MainActor.run {
                self.finishScan(p, tree: tree, trash: trashTree, large: large, disk: disk,
                                scope: scanScope, started: start)
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
        if let live = p.liveSnapshot(since: liveRevision) {
            liveRevision = live.revision
            livePreview = buildPreview(live.entries)
        }
    }

    /// A throwaway tree of what has been measured so far; folders still being
    /// walked are marked pending and sorted last.
    private func buildPreview(_ entries: [String: ScanProgress.LiveEntry]) -> FolderNode {
        let rootURL = scope.url
        let root = FolderNode(url: rootURL, kind: .folder)
        root.name = FolderWalker.rootName(rootURL)
        var nodes: [String: FolderNode] = [root.id: root]
        for (path, e) in entries {
            // Same cut as the finished tree: tiny measured items stay hidden.
            if let s = e.size, s < FolderWalker.listThreshold { continue }
            let n = FolderNode(url: e.url, kind: e.kind)
            n.size = e.size ?? 0
            n.pending = e.size == nil
            nodes[path] = n
        }
        for (path, e) in entries {
            guard let n = nodes[path], let parent = nodes[e.parent] else { continue }
            n.parent = parent
            parent.children.append(n)
        }
        func sortChildren(_ n: FolderNode) {
            n.children.forEach(sortChildren)
            n.children.sort {
                if $0.pending != $1.pending { return !$0.pending }
                return $0.pending ? $0.name < $1.name : $0.size > $1.size
            }
        }
        sortChildren(root)
        root.size = root.children.reduce(0) { $0 + $1.size }
        return root
    }

    private func finishScan(_ p: ScanProgress, tree: FolderNode, trash trashTree: FolderNode?,
                            large: [FolderNode], disk: DiskBreakdown?, scope scanScope: Scope, started: Date) {
        pullProgress()
        pollTimer?.invalidate()
        pollTimer = nil
        progress = nil
        isScanning = false
        livePreview = nil
        guard !p.isCancelled else { return }
        root = tree
        trash = trashTree
        trashReadable = trashTree != nil
        largeFiles = large
        breakdown = disk
        lastScan = Date()
        lastScanScope = scanScope
        scanDuration = Date().timeIntervalSince(started)
    }

    /// Re-measures just the Trash (after something was moved into it or emptied).
    func refreshTrash() {
        Task.detached(priority: .utility) {
            let t = FolderWalker(progress: ScanProgress(), collect: false).scanTrash()
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

    func reveal(_ nodes: [FolderNode]) {
        NSWorkspace.shared.activateFileViewerSelecting(nodes.map(\.url))
    }

    /// Opens Finder's Get Info window through Finder's own "Show Info" service,
    /// which needs no Automation permission (an AppleScript would).
    func showInfo(_ node: FolderNode) {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.urani.maccharge.showinfo"))
        pb.clearContents()
        pb.writeObjects([node.url as NSURL])
        if !NSPerformService("Finder/Show Info", pb) {
            reveal([node])
        }
    }

    func copyPaths(_ nodes: [FolderNode]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(nodes.map(\.url.path).joined(separator: "\n"), forType: .string)
    }

    /// A Terminal window at the folder (or at a file's folder).
    func openInTerminal(_ node: FolderNode) {
        let folder = node.kind == .file ? node.url.deletingLastPathComponent() : node.url
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Task { @MainActor in self.lastError = "Could not open Terminal: \(error.localizedDescription)" }
            }
        }
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
        if node.pending || isScanning { return false }
        if Self.protectedPaths.contains(path) { return false }
        if node === root || node === trash { return false }
        return FileManager.default.isDeletableFile(atPath: path)
    }

    func moveToTrash(_ nodes: [FolderNode]) {
        var failures: [String] = []
        for node in Self.outermost(nodes) {
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                detach(node)
            } catch {
                failures.append("“\(node.name)”: \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            lastError = "Could not move to the Trash:\n" + failures.joined(separator: "\n")
        }
        refreshTrash()
    }

    /// Permanently removes items that are already in the Trash.
    func deleteImmediately(_ nodes: [FolderNode]) {
        var failures: [String] = []
        for node in Self.outermost(nodes) {
            do {
                try FileManager.default.removeItem(at: node.url)
                detach(node)
            } catch {
                failures.append("“\(node.name)”: \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            lastError = "Could not delete:\n" + failures.joined(separator: "\n")
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

    /// Drops items that sit inside another selected item: moving the outer one
    /// takes them along.
    private static func outermost(_ nodes: [FolderNode]) -> [FolderNode] {
        let paths = Set(nodes.map(\.id))
        return nodes.filter { n in
            var p = n.parent
            while let a = p {
                if paths.contains(a.id) { return false }
                p = a.parent
            }
            return true
        }
    }

    /// Takes a removed item out of the tree and its size out of every ancestor.
    private func detach(_ node: FolderNode) {
        let prefix = node.id + "/"
        largeFiles.removeAll { $0 === node || $0.id.hasPrefix(prefix) }
        guard let parent = node.parent else { revision += 1; return }
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
