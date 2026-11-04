import Foundation

/// The last finished FolderTree scan, kept in Application Support so the next
/// launch opens on it instead of an empty tab.
enum ScanStore {
    /// Bump when the saved shape changes; older files are then ignored.
    static let formatVersion = 1

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacCharge/FolderTree/last-scan.json")
    }

    struct Saved: Codable {
        var version: Int
        /// "wholeMac", "home", or the path of a chosen folder.
        var scope: String
        var date: Date
        var duration: TimeInterval
        var unreadable: Int
        var rootPath: String
        var rootName: String
        var root: Node
        var largeFiles: [LargeFile]
        var breakdown: DiskBreakdown?
    }

    /// One tree item. Children hold only their own name; the path is rebuilt
    /// from the parent's, which keeps a whole-disk file to a few megabytes.
    struct Node: Codable {
        var n: String          // name
        var k: UInt8           // kind: 0 folder, 1 package, 2 file
        var s: Int64           // size
        var f: Int             // files
        var os: Int64?         // otherSize
        var oc: Int?           // otherCount
        var u: Bool?           // unreadable
        var c: [Node]?         // children
    }

    struct LargeFile: Codable {
        var path: String
        var opened: Date?
    }

    // MARK: Snapshot ↔ tree

    @MainActor
    static func snapshot(root: FolderNode, scope: FolderScanner.Scope, date: Date, duration: TimeInterval,
                         unreadable: Int, largeFiles: [FolderNode], breakdown: DiskBreakdown?) -> Saved {
        Saved(version: formatVersion, scope: encode(scope), date: date, duration: duration,
              unreadable: unreadable, rootPath: root.url.path, rootName: root.name,
              root: node(from: root),
              largeFiles: largeFiles.map { LargeFile(path: $0.url.path, opened: $0.accessDate) },
              breakdown: breakdown)
    }

    private static func node(from n: FolderNode) -> Node {
        Node(n: n.url.lastPathComponent,
             k: n.kind == .folder ? 0 : (n.kind == .package ? 1 : 2),
             s: n.size, f: n.fileCount,
             os: n.otherSize == 0 ? nil : n.otherSize,
             oc: n.otherCount == 0 ? nil : n.otherCount,
             u: n.unreadable ? true : nil,
             c: n.children.isEmpty ? nil : n.children.map(node(from:)))
    }

    /// Rebuilds the tree and resolves the large files to nodes inside it.
    static func restore(_ saved: Saved) -> (root: FolderNode, largeFiles: [FolderNode], scope: FolderScanner.Scope) {
        func build(_ s: Node, url: URL, parent: FolderNode?) -> FolderNode {
            let kind: FolderNode.Kind = s.k == 0 ? .folder : (s.k == 1 ? .package : .file)
            let n = FolderNode(url: url, kind: kind)
            n.size = s.s
            n.fileCount = s.f
            n.otherSize = s.os ?? 0
            n.otherCount = s.oc ?? 0
            n.unreadable = s.u ?? false
            n.parent = parent
            n.children = (s.c ?? []).map {
                build($0, url: url.appendingPathComponent($0.n, isDirectory: $0.k != 2), parent: n)
            }
            return n
        }
        let root = build(saved.root, url: URL(fileURLWithPath: saved.rootPath, isDirectory: true), parent: nil)
        root.name = saved.rootName
        let large: [FolderNode] = saved.largeFiles.compactMap { f in
            guard let n = root.find(f.path) else { return nil }
            n.accessDate = f.opened
            return n
        }
        return (root, large, decode(saved.scope))
    }

    // MARK: Disk

    static func write(_ saved: Saved) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(saved)
            let url = fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("MacCharge: could not save the FolderTree scan: \(error.localizedDescription)")
        }
    }

    /// nil when there is no saved scan, or it was written by another format version.
    static func read() -> Saved? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let saved = try? decoder.decode(Saved.self, from: data),
              saved.version == formatVersion else { return nil }
        return saved
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Scope

    private static func encode(_ scope: FolderScanner.Scope) -> String {
        switch scope {
        case .wholeMac: return "wholeMac"
        case .home: return "home"
        case .custom(let u): return u.path
        }
    }

    private static func decode(_ s: String) -> FolderScanner.Scope {
        switch s {
        case "wholeMac": return .wholeMac
        case "home": return .home
        default: return .custom(URL(fileURLWithPath: s, isDirectory: true))
        }
    }
}
