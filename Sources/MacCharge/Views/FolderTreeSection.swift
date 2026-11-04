import SwiftUI
import AppKit

/// Disk usage by folder: one scan measures every folder, the tree lists the
/// biggest first, and clicking an item offers Finder actions. The Trash gets
/// its own tab.
struct FolderTreeSection: View {
    @ObservedObject var scanner: FolderScanner

    enum Tab: Hashable { case folders, trash }
    private enum ScopeChoice: Hashable { case wholeMac, home, folder }

    @State private var tab: Tab = .folders
    @State private var expanded: Set<ObjectIdentifier> = []
    @State private var selected: ObjectIdentifier?
    @State private var pendingTrash: FolderNode?
    @State private var pendingDelete: FolderNode?
    @State private var confirmEmpty = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statCards
            controlCard
            treeCard
        }
        .alert("Move to Trash?", isPresented: present($pendingTrash), presenting: pendingTrash) { node in
            Button("Move to Trash", role: .destructive) { scanner.moveToTrash(node) }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text("“\(node.name)” (\(bytes(node.size))) will be moved to the Trash. You can put it back from there.")
        }
        .alert("Delete immediately?", isPresented: present($pendingDelete), presenting: pendingDelete) { node in
            Button("Delete", role: .destructive) { scanner.deleteImmediately(node) }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text("“\(node.name)” (\(bytes(node.size))) will be deleted permanently. This cannot be undone.")
        }
        .alert("Empty the Trash?", isPresented: $confirmEmpty) {
            Button("Empty Trash", role: .destructive) { scanner.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the Trash (\(bytes(scanner.trash?.size ?? 0))) will be deleted permanently. This cannot be undone.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { scanner.lastError != nil },
            set: { if !$0 { scanner.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scanner.lastError ?? "")
        }
    }

    // MARK: Cards

    private var statCards: some View {
        let disk = scanner.diskUsage
        return HStack(spacing: 14) {
            StatCard(icon: "internaldrive.fill", iconColor: Theme.blue,
                     title: "Startup Disk",
                     value: disk.map { bytes($0.used) } ?? "—",
                     subtitle: disk.map { "of \(bytes($0.total)) · \(bytes($0.total - $0.used)) free" },
                     help: "Space used on the startup disk, as macOS reports it.") {
                AnyView(BatteryBar(fraction: disk.map { Double($0.used) / Double(max(1, $0.total)) } ?? 0,
                                   color: Theme.blue))
            }
            StatCard(icon: "folder.fill", iconColor: Theme.green,
                     title: "Scanned",
                     value: scanner.root.map { bytes($0.size) } ?? "—",
                     subtitle: scanner.root.map { "\($0.fileCount.formatted()) files · \(scanner.root?.name ?? "")" }
                         ?? "Not scanned yet",
                     help: "Total size of everything the last scan could read.")
            StatCard(icon: "trash.fill", iconColor: Theme.orange,
                     title: "Trash",
                     value: scanner.trash.map { bytes($0.size) } ?? "—",
                     subtitle: trashSubtitle,
                     subtitleColor: scanner.trashReadable ? Theme.textSecondary : Theme.yellow,
                     help: "What emptying the Trash would free.")
            StatCard(icon: scanner.unreadableCount > 0 ? "lock.fill" : "checkmark.shield.fill",
                     iconColor: scanner.unreadableCount > 0 ? Theme.yellow : Theme.purple,
                     title: "Not Readable",
                     value: scanner.lastScan == nil && !scanner.isScanning ? "—" : scanner.unreadableCount.formatted(),
                     subtitle: scanner.lastScan.map { _ in "folders · scan took \(Int(scanner.scanDuration.rounded()))s" }
                         ?? "folders macOS keeps private",
                     help: "Folders macOS would not let MacCharge list. Their size is missing from the totals; Full Disk Access fixes most of them.")
        }
        .frame(height: 150)
    }

    private var trashSubtitle: String {
        if !scanner.trashReadable { return "Needs Full Disk Access" }
        guard let t = scanner.trash else { return "Scanned with the folders" }
        return t.children.isEmpty ? "Empty" : "\(t.children.count) item\(t.children.count == 1 ? "" : "s")"
    }

    private var controlCard: some View {
        Card(padding: 14) {
            HStack(spacing: 14) {
                Picker("", selection: scopeBinding) {
                    Text("Whole Mac").tag(ScopeChoice.wholeMac)
                    Text("Home").tag(ScopeChoice.home)
                    Text(customName ?? "Folder…").tag(ScopeChoice.folder)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
                .disabled(scanner.isScanning)
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                .disabled(scanner.isScanning)
                .help("Pick any folder or drive to scan. You can also drop a folder onto this bar.")

                if scanner.isScanning {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scanning · \(scanner.scannedItems.formatted()) items")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(scanner.currentPath)
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Button("Stop") { scanner.cancel() }
                } else {
                    Text(scanner.lastScan.map { "Last scan \($0.formatted(date: .omitted, time: .shortened))" }
                         ?? "macOS may ask for access to Desktop, Documents and other folders.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Full Disk Access…") { openFullDiskAccess() }
                        .help("A complete scan, the Trash included, needs MacCharge in System Settings → Privacy & Security → Full Disk Access.")
                    Button(scanner.root == nil ? "Scan" : "Rescan") { startScan(scanner.scope) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.green)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.green, lineWidth: dropTargeted ? 2 : 0)
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !scanner.isScanning, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, isFolder(url) else { return }
                DispatchQueue.main.async { startScan(.custom(url)) }
            }
            return true
        }
    }

    private var treeCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Picker("", selection: $tab) {
                        Text("Folders").tag(Tab.folders)
                        Text(scanner.trash.map { "Trash · \(bytes($0.size))" } ?? "Trash").tag(Tab.trash)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                    Spacer()
                    if tab == .trash {
                        Button("Open Trash") { scanner.openTrash() }
                        Button("Empty Trash…") { confirmEmpty = true }
                            .disabled(scanner.trash?.children.isEmpty ?? true)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider().overlay(Theme.separator)
                columnHeader
                Divider().overlay(Theme.separator)
                treeBody
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text(tab == .trash ? "IN THE TRASH" : (scanner.root?.name.uppercased() ?? "NAME"))
            Spacer()
            Text("SHARE").frame(width: 170, alignment: .leading)
            Text("SIZE").frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .compatTracking(0.4)
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    @ViewBuilder private var treeBody: some View {
        let node = tab == .folders ? scanner.root : scanner.trash
        if tab == .trash && !scanner.trashReadable {
            placeholder(icon: "lock.fill",
                        text: "macOS keeps the Trash private. Add MacCharge under Full Disk Access, then rescan.",
                        button: ("Open Full Disk Access…", openFullDiskAccess))
        } else if let node {
            if node.children.isEmpty && node.otherCount == 0 {
                placeholder(icon: tab == .trash ? "trash" : "folder",
                            text: tab == .trash ? "The Trash is empty." : "Nothing here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(lines(of: node)) { line in
                            FolderRow(line: line,
                                      isExpanded: line.node.map { expanded.contains($0.id) } ?? false,
                                      isSelected: line.node.map { $0.id == selected } ?? false,
                                      toggle: { toggle(line.node) },
                                      openMenu: { showMenu(for: line.node) })
                        }
                    }
                    .padding(.vertical, 4)
                    .id(scanner.revision)
                }
            }
        } else if scanner.isScanning {
            placeholder(icon: "hourglass", text: "Measuring every folder… big disks take a minute or two.")
        } else {
            placeholder(icon: "folder.badge.questionmark",
                        text: tab == .trash ? "Scan to measure the Trash." : "Press Scan to measure every folder on this Mac.")
        }
    }

    private func placeholder(icon: String, text: String,
                             button: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Theme.textMuted)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let button { Button(button.0, action: button.1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: Tree

    /// The visible rows: every child of an expanded folder, depth-first.
    private func lines(of root: FolderNode) -> [TreeLine] {
        var out: [TreeLine] = []
        func walk(_ n: FolderNode, depth: Int) {
            for c in n.children {
                out.append(TreeLine(node: c, owner: n, depth: depth))
                if expanded.contains(c.id) { walk(c, depth: depth + 1) }
            }
            if n.otherCount > 0 {
                out.append(TreeLine(node: nil, owner: n, depth: depth))
            }
        }
        walk(root, depth: 0)
        return out
    }

    private func toggle(_ node: FolderNode?) {
        guard let node, !node.children.isEmpty else { return }
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
    }

    /// Clicking an item pops a native menu at the pointer with what can be done to it.
    private func showMenu(for node: FolderNode?) {
        guard let node else { return }
        selected = node.id
        let inTrash = tab == .trash
        let menu = ActionMenu()
        if !node.children.isEmpty {
            let open = expanded.contains(node.id)
            menu.add(open ? "Collapse" : "Expand", symbol: open ? "chevron.down" : "chevron.right") { toggle(node) }
            menu.separator()
        }
        menu.add("Reveal in Finder", symbol: "magnifyingglass") { scanner.reveal(node) }
        menu.add("Get Info", symbol: "info.circle") { scanner.showInfo(node) }
        menu.add("Copy Path", symbol: "doc.on.doc") { scanner.copyPath(node) }
        menu.separator()
        if inTrash {
            menu.add("Delete Immediately…", symbol: "xmark.bin") { pendingDelete = node }
        } else if scanner.canTrash(node) {
            menu.add("Move to Trash…", symbol: "trash") { pendingTrash = node }
        } else {
            menu.add("Move to Trash — needs admin rights", symbol: "lock", enabled: false) {}
        }
        menu.popUp()
    }

    // MARK: Helpers

    private var scopeBinding: Binding<ScopeChoice> {
        Binding(
            get: {
                switch scanner.scope {
                case .wholeMac: return .wholeMac
                case .home: return .home
                case .custom: return .folder
                }
            },
            set: { choice in
                switch choice {
                case .wholeMac: scanner.scope = .wholeMac
                case .home: scanner.scope = .home
                case .folder:
                    // Back to a folder picked earlier, or ask for one.
                    if case .custom = scanner.scope { return }
                    chooseFolder()
                }
            })
    }

    /// Asks for a folder and scans it straight away.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or drive to measure."
        if case .custom(let u) = scanner.scope { panel.directoryURL = u }
        if panel.runModal() == .OK, let url = panel.url {
            startScan(.custom(url))
        }
    }

    private func startScan(_ scope: FolderScanner.Scope) {
        scanner.scope = scope
        expanded = []
        selected = nil
        tab = .folders
        scanner.scan()
    }

    private func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private var customName: String? {
        if case .custom(let u) = scanner.scope { return u.lastPathComponent }
        return nil
    }

    private func present(_ item: Binding<FolderNode?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

private func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

/// One visible row: an item, or (node == nil) the "smaller items" line of `owner`.
private struct TreeLine: Identifiable {
    let node: FolderNode?
    let owner: FolderNode
    let depth: Int

    var id: String {
        if let node { return "n\(node.id.hashValue)" }
        return "o\(owner.id.hashValue)"
    }
    var size: Int64 { node?.size ?? owner.otherSize }
}

private struct FolderRow: View {
    let line: TreeLine
    let isExpanded: Bool
    let isSelected: Bool
    let toggle: () -> Void
    let openMenu: () -> Void

    @State private var isHovering = false

    private var share: Double {
        Double(line.size) / Double(max(1, line.owner.size))
    }

    private var tint: Color {
        switch line.node?.kind {
        case .folder: return Theme.blue
        case .package: return Theme.purple
        case .file: return Theme.orange
        case nil: return Theme.textMuted
        }
    }

    private var icon: String {
        switch line.node?.kind {
        case .folder: return line.node?.unreadable == true ? "lock.fill" : "folder.fill"
        case .package: return "shippingbox.fill"
        case .file: return "doc.fill"
        case nil: return "ellipsis.circle"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(line.depth) * 18, height: 1)
            Group {
                if let node = line.node, !node.children.isEmpty {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 16, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                } else {
                    Color.clear.frame(width: 16, height: 20)
                }
            }
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(line.node?.name ?? "\(line.owner.otherCount.formatted()) smaller item\(line.owner.otherCount == 1 ? "" : "s")")
                .font(.system(size: 12.5, weight: line.node == nil ? .regular : .medium))
                .foregroundStyle(line.node == nil ? Theme.textMuted : Theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                BatteryBar(fraction: share, color: tint.opacity(line.node == nil ? 0.5 : 1))
                    .frame(width: 120)
                Text(share < 0.001 ? "<0.1%" : String(format: "%.1f%%", share * 100))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 42, alignment: .trailing)
            }
            .frame(width: 170, alignment: .leading)
            Text(ByteCountFormatter.string(fromByteCount: line.size, countStyle: .file))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(line.node == nil ? Theme.textMuted : Theme.textPrimary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Theme.green.opacity(0.14)
                      : (isHovering && line.node != nil ? Color.white.opacity(0.05) : .clear))
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: openMenu)
        .onHover { isHovering = $0 }
        .help(line.node?.url.path ?? "Items under 1 MB, added into the folder's total")
    }
}

/// An NSMenu whose items run closures, popped up at the mouse pointer.
@MainActor
private final class ActionMenu: NSObject {
    private let menu = NSMenu()
    private var handlers: [() -> Void] = []

    override init() {
        super.init()
        menu.autoenablesItems = false
    }

    func add(_ title: String, symbol: String, enabled: Bool = true, _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = self
        item.tag = handlers.count
        item.isEnabled = enabled
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        handlers.append(action)
        menu.addItem(item)
    }

    func separator() {
        menu.addItem(.separator())
    }

    /// Blocks until the menu closes, which keeps `self` alive for the click.
    func popUp() {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func fire(_ sender: NSMenuItem) {
        handlers[sender.tag]()
    }
}
