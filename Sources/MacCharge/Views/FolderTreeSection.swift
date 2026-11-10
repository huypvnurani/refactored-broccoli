import SwiftUI
import AppKit
import Quartz
import QuickLookThumbnailing

/// Disk usage by folder: one scan measures every folder, the tree lists the
/// biggest first, and right-clicking an item offers Finder actions. Large files
/// and the Trash get their own tabs.
struct FolderTreeSection: View {
    @ObservedObject var scanner: FolderScanner

    enum Tab: Hashable { case folders, largeFiles, trash }
    private enum ScopeChoice: Hashable { case wholeMac, home, folder }

    @State private var tab: Tab = .folders
    @State private var expanded: Set<String> = []
    @State private var selection: Set<String> = []
    /// Where ⇧-click and ⇧-arrow ranges start.
    @State private var anchor: String?
    /// The row the arrow keys move from.
    @State private var cursor: String?
    @State private var scrollTarget: String?
    @State private var query = ""
    @State private var fileKind: FileKind = .all
    @State private var staleOnly = false
    @State private var pendingTrash: [FolderNode] = []
    @State private var pendingDelete: [FolderNode] = []
    @State private var confirmEmpty = false
    @State private var dropTargeted = false
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted
    @State private var showFullDiskAccessHelp = false
    @AppStorage("folderTree.showGapDetails") private var showGapDetails = false
    @State private var keyMonitor: Any?
    @AppStorage("folderTree.showChart") private var showChart = false
    @AppStorage("folderTree.colorByShare") private var colorByShare = false
    /// Biggest first unless the user picks otherwise; not remembered across launches.
    @State private var sortKey: SortKey = .size
    @State private var sortAscending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statCards
            controlCard
            treeCard
            gapCard
        }
        .onAppear(perform: installKeyMonitor)
        // Back from Finder (where the Trash may have just been emptied) while the
        // Trash tab is open: measure it again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if tab == .trash { scanner.refreshTrash() }
        }
        // Coming back from System Settings: pick up a newly granted permission.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted
        }
        .alert("Add MacCharge to Full Disk Access", isPresented: $showFullDiskAccessHelp) {
            Button("Open System Settings") { FullDiskAccess.openSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                 macOS doesn't list apps there by itself. System Settings will open on Full Disk Access \
                 and Finder will show MacCharge:

                 1. Drag MacCharge from Finder into the list (or click + and choose it).
                 2. Turn the switch next to MacCharge on.
                 3. Come back and press Rescan.
                 """)
        }
        .onDisappear(perform: removeKeyMonitor)
        .alert(trashTitle, isPresented: present($pendingTrash)) {
            Button("Move to Trash", role: .destructive) { scanner.moveToTrash(pendingTrash) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(describe(pendingTrash)) will be moved to the Trash. You can put it back from there.")
        }
        .alert("Delete immediately?", isPresented: present($pendingDelete)) {
            Button("Delete", role: .destructive) { scanner.deleteImmediately(pendingDelete) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(describe(pendingDelete)) will be deleted permanently. This cannot be undone.")
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
                     subtitle: scanner.root.map { "\($0.fileCount.formatted()) files · \($0.name)" }
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
        .frame(height: 140)
    }

    private var lastScanText: String {
        guard let date = scanner.lastScan else {
            return "macOS may ask for access to Desktop, Documents and other folders."
        }
        let when = date.formatted(date: .abbreviated, time: .shortened)
        guard scanner.isRestored else { return "Last scan \(when)" }
        let ago = Self.relative.localizedString(for: date, relativeTo: Date())
        return "Saved scan from \(when) · \(ago)"
    }

    private var trashSubtitle: String {
        if !scanner.trashReadable { return "Needs Full Disk Access" }
        guard let t = scanner.trash else { return "Scanned with the folders" }
        return t.children.isEmpty ? "Empty" : "\(t.children.count) item\(t.children.count == 1 ? "" : "s")"
    }

    /// What to scan and the scan buttons (wrapping onto two lines when narrow),
    /// then the scan status. Buttons keep their full width; only the status
    /// text may shorten.
    private var controlCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SplitBar(spacing: 12) {
                    SegmentBar(selection: scopeBinding, items: [
                        (.wholeMac, "Whole Mac"), (.home, "Home"), (.folder, customName ?? "Folder…"),
                    ])
                    .frame(width: 300)
                    .disabled(scanner.isScanning)
                    Button {
                        chooseFolder()
                    } label: {
                        Label("Choose Folder…", systemImage: "folder.badge.plus")
                    }
                    .fixedSize()
                    .disabled(scanner.isScanning)
                    .help("Pick any folder or drive to scan. You can also drop a folder onto this bar.")
                } trailing: {
                    Button {
                        openFullDiskAccess()
                    } label: {
                        if hasFullDiskAccess {
                            Label("Full Disk Access", systemImage: "checkmark.shield.fill")
                        } else {
                            Text("Full Disk Access…")
                        }
                    }
                    .foregroundStyle(hasFullDiskAccess ? Theme.green : Theme.textPrimary)
                    .fixedSize()
                    .help(hasFullDiskAccess
                          ? "MacCharge has Full Disk Access, so scans can read the Trash and private folders."
                          : "A complete scan, the Trash included, needs MacCharge in System Settings → Privacy & Security → Full Disk Access.")
                    if scanner.isScanning {
                        Button("Stop") { scanner.cancel() }
                            .fixedSize()
                    } else {
                        Button(scanner.root == nil ? "Scan" : "Rescan") { startScan(scanner.scope) }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.green)
                            .fixedSize()
                    }
                }

                HStack(spacing: 8) {
                    if scanner.isScanning {
                        ProgressView().controlSize(.small)
                        Text("Scanning · \(scanner.scannedItems.formatted()) items")
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            .fixedSize()
                        Text(scanner.currentPath)
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Image(systemName: scanner.isRestored ? "clock.arrow.circlepath" : "clock")
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        Text(lastScanText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(scanner.isRestored ? Theme.textSecondary : Theme.textMuted)
                            .lineLimit(1).truncationMode(.tail)
                            .help(scanner.isRestored
                                  ? "These results were saved after the last scan, so they open without scanning. Rescan for fresh numbers."
                                  : "")
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 16)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.green, lineWidth: dropTargeted ? 2 : 0)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard !scanner.isScanning,
                  let url = urls.first(where: { $0.hasDirectoryPath || isFolder($0) }) else { return false }
            startScan(.custom(url))
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    /// Where the disk space the folders don't account for goes. Shown only after
    /// a whole-Mac scan, and only when `diskutil` could be read; it sits under
    /// the list as one line until opened.
    @ViewBuilder private var gapCard: some View {
        if !scanner.isScanning, scanner.lastScanScope == .wholeMac,
           let b = scanner.breakdown, let root = scanner.root {
            let trashSize = scanner.trash?.size ?? 0
            let hidden = max(0, b.browsable - root.size - trashSize)
            let others = b.volumes.filter { $0.role != "System" && $0.role != "Data" && $0.used > 0 }
            let rest = max(0, b.used - root.size - trashSize)
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showGapDetails.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(showGapDetails ? 90 : 0))
                            Image(systemName: "chart.pie.fill").foregroundStyle(Theme.purple)
                            Text("Disk in use \(bytes(b.used)) · folders found \(bytes(root.size)) · \(bytes(rest)) elsewhere")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(showGapDetails ? "Hide" : "Where is it?")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)

                    if showGapDetails {
                        VStack(spacing: 0) {
                            gapRow("Folders found by the scan", root.size, Theme.green)
                            if trashSize > 0 { gapRow("Trash", trashSize, Theme.orange) }
                            if hidden > 0 {
                                gapRow("Out of the scan's reach", hidden, Theme.yellow,
                                       note: hiddenNote(b))
                            }
                            ForEach(others) { v in
                                gapRow(volumeLabel(v), v.used, Theme.blue, note: volumeNote(v.role))
                            }
                        }
                    }
                }
            }
        }
    }

    private func gapRow(_ label: String, _ size: Int64, _ color: Color, note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
            Spacer()
            Text(bytes(size)).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.vertical, 4)
        .padding(.leading, 22)
    }

    private func hiddenNote(_ b: DiskBreakdown) -> String {
        var parts = ["folders macOS keeps private", "file-system metadata"]
        if scanner.unreadableCount > 0 { parts[0] = "\(scanner.unreadableCount.formatted()) private folders" }
        if b.snapshotCount > 0 {
            parts.insert("\(b.snapshotCount) local Time Machine snapshot\(b.snapshotCount == 1 ? "" : "s")", at: 0)
        }
        return parts.joined(separator: ", ")
    }

    private func volumeLabel(_ v: DiskBreakdown.Volume) -> String {
        v.role.isEmpty ? v.name : "\(v.name) volume"
    }

    private func volumeNote(_ role: String) -> String? {
        switch role {
        case "VM": return "Swap and the sleep image, managed by macOS"
        case "Preboot": return "Files the Mac needs to start up"
        case "Recovery": return "macOS Recovery"
        case "Update": return "Staged macOS updates"
        default: return nil
        }
    }

    private var treeCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                treeHeader
                if tab == .largeFiles {
                    Divider().overlay(Theme.separator)
                    largeFilesBar
                }
                Divider().overlay(Theme.separator)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        columnHeader
                        Divider().overlay(Theme.separator)
                        treeBody
                    }
                    if showChart, tab != .largeFiles, let root = currentRoot, !root.children.isEmpty {
                        Divider().overlay(Theme.separator)
                        SunburstChart(focus: chartFocus(in: root),
                                      onPick: { reveal($0) },
                                      onUp: { goUp(in: root) })
                            .frame(width: 260)
                            .padding(14)
                    }
                }
                if tab == .trash && scanner.trashReadable {
                    Divider().overlay(Theme.separator)
                    HStack(spacing: 10) {
                        Text("Right-click an item to delete it on its own.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                        Spacer()
                        Button("Open Trash") { scanner.openTrash() }
                        Button("Empty Trash…") { confirmEmpty = true }
                            .disabled(scanner.trash?.children.isEmpty ?? true)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
    }

    /// Tabs and the name filter on the left, sort and view options on the right;
    /// on a narrow window the right half drops to its own line.
    private var treeHeader: some View {
        SplitBar(spacing: 12) {
            SegmentBar(selection: tabBinding, items: [
                (.folders, "Folders"), (.largeFiles, "Large Files"),
                (.trash, scanner.trash.map { "Trash · \(bytes($0.size))" } ?? "Trash"),
            ])
            .frame(width: 340)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                TextField("Filter by name", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .frame(width: 200)
        } trailing: {
            sortControl
                .fixedSize()
            Toggle("Color by share", isOn: $colorByShare)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Mark items yellow (≥25%), orange (≥50%) or red (≥75%) by how much of their parent folder they take.")
            Toggle("Chart", isOn: $showChart)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Show a ring chart of the selected folder next to the list.")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var largeFilesBar: some View {
        HStack(spacing: 12) {
            Picker("Kind", selection: $fileKind) {
                ForEach(FileKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 230)
            Toggle("Not opened in 6 months", isOn: $staleOnly)
                .toggleStyle(.checkbox)
            Spacer()
            Text("\(filteredLargeFiles.count) of the \(scanner.largeFiles.count) biggest files")
                .foregroundStyle(Theme.textMuted)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text(headerTitle)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if colorByShare {
                // Dropped when the list is too narrow for it (chart on, small window).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        legendDot(Theme.yellow, "25%")
                        legendDot(Theme.orange, "50%")
                        legendDot(Theme.red, "75%")
                    }
                    .fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            Text("OF PARENT").frame(width: 170, alignment: .leading)
            Text("SIZE").frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(0.4)
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("≥" + label)
        }
    }

    private var headerTitle: String {
        if !query.isEmpty { return "MATCHING “\(query.uppercased())”" }
        switch tab {
        case .folders: return currentRoot?.name.uppercased() ?? "NAME"
        case .largeFiles: return "BIGGEST FILES"
        case .trash: return "IN THE TRASH"
        }
    }

    @ViewBuilder private var treeBody: some View {
        if tab == .trash && !scanner.trashReadable {
            placeholder(icon: "lock.fill",
                        text: "macOS keeps the Trash private. Add MacCharge under Full Disk Access, then rescan.",
                        button: ("Open Full Disk Access…", openFullDiskAccess))
        } else if tab == .largeFiles && scanner.root == nil {
            placeholder(icon: scanner.isScanning ? "hourglass" : "doc.badge.ellipsis",
                        text: scanner.isScanning ? "The biggest files are listed when the scan finishes."
                                                 : "Scan to list the biggest files.")
        } else if currentRoot != nil || tab == .largeFiles {
            let lines = visibleLines
            if lines.isEmpty {
                placeholder(icon: query.isEmpty ? (tab == .trash ? "trash" : "folder") : "magnifyingglass",
                            text: emptyText)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(lines) { line in
                                FolderRow(line: line,
                                          isExpanded: line.node.map { expanded.contains($0.id) } ?? false,
                                          isSelected: line.node.map { selection.contains($0.id) } ?? false,
                                          shareColor: colorByShare ? shareColor(line.share) : nil,
                                          subtitle: subtitle(for: line),
                                          toggle: { toggle(line.node) },
                                          click: { click(line) },
                                          openMenu: { showMenu(for: line) })
                                    .id(line.id)
                            }
                        }
                        .padding(.vertical, 4)
                        .id(scanner.revision)
                    }
                    .onChange(of: scrollTarget) { target in
                        guard let target else { return }
                        proxy.scrollTo(target)
                        scrollTarget = nil
                    }
                }
            }
        } else if scanner.isScanning {
            placeholder(icon: "hourglass", text: "Measuring every folder… big disks take a minute or two.")
        } else {
            placeholder(icon: "folder.badge.questionmark",
                        text: tab == .trash ? "Scan to measure the Trash." : "Press Scan to measure every folder on this Mac.")
        }
    }

    private var emptyText: String {
        if !query.isEmpty { return "Nothing named like “\(query)”. Only items of 1 MB or more are listed." }
        switch tab {
        case .folders: return "Nothing here."
        case .largeFiles: return "No file matches these filters."
        case .trash: return "The Trash is empty."
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

    // MARK: Rows

    /// The tree on screen: the live preview while a scan runs.
    private var currentRoot: FolderNode? {
        switch tab {
        case .trash: return scanner.trash
        case .folders, .largeFiles: return scanner.isScanning ? scanner.livePreview : scanner.root
        }
    }

    /// Whether rows are a flat list (search hits, large files) rather than the tree.
    private var isFlat: Bool { tab == .largeFiles || !query.isEmpty }

    private var visibleLines: [TreeLine] {
        if tab == .largeFiles {
            return filteredLargeFiles.map { TreeLine(node: $0, owner: $0.parent ?? $0, depth: 0) }
        }
        guard let root = currentRoot else { return [] }
        if !query.isEmpty {
            return search(root).map { TreeLine(node: $0, owner: $0.parent ?? root, depth: 0) }
        }
        var out: [TreeLine] = []
        func walk(_ n: FolderNode, depth: Int) {
            for c in ordered(n.children) {
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

    /// The 500 biggest listed items whose name contains the query, in sort order.
    private func search(_ root: FolderNode) -> [FolderNode] {
        let q = query.lowercased()
        var hits: [FolderNode] = []
        func walk(_ n: FolderNode) {
            for c in n.children {
                if c.name.lowercased().contains(q) { hits.append(c) }
                walk(c)
            }
        }
        walk(root)
        return ordered(Array(hits.sorted { $0.size > $1.size }.prefix(500)))
    }

    private var filteredLargeFiles: [FolderNode] {
        let cutoff = Date().addingTimeInterval(-182 * 86_400)
        let q = query.lowercased()
        return ordered(scanner.largeFiles.filter { f in
            (fileKind == .all || FileKind.of(f.url) == fileKind)
                && (!staleOnly || (f.accessDate ?? .distantPast) < cutoff)
                && (q.isEmpty || f.name.lowercased().contains(q))
        })
    }

    // MARK: Sorting

    /// `nodes` in the chosen order. Folders still being measured stay last, and
    /// ties fall back to size so the order never jumps around.
    private func ordered(_ nodes: [FolderNode]) -> [FolderNode] {
        let key = sortKey
        let asc = sortAscending
        return nodes.sorted { a, b in
            if a.pending != b.pending { return !a.pending }
            let r = key.compare(a, b)
            if r != .orderedSame { return asc ? r == .orderedAscending : r == .orderedDescending }
            return a.size > b.size
        }
    }

    /// Sort key picker plus a button that flips the direction.
    private var sortControl: some View {
        HStack(spacing: 4) {
            Picker("Sort by", selection: Binding(get: { sortKey }, set: { key in
                // Each key starts in its natural direction; the arrow flips it.
                guard key != sortKey else { return }
                sortKey = key
                sortAscending = key.ascendingByDefault
            })) {
                ForEach(SortKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Button {
                sortAscending.toggle()
            } label: {
                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .help(sortAscending ? "Ascending — click for descending" : "Descending — click for ascending")
        }
        .help("Sort the list. Biggest first by default.")
    }

    private func subtitle(for line: TreeLine) -> String? {
        guard isFlat, let node = line.node else { return nil }
        var s = abbreviate(node.url.deletingLastPathComponent().path)
        if tab == .largeFiles, let d = node.accessDate {
            s += " · opened " + Self.relative.localizedString(for: d, relativeTo: Date())
        }
        return s
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func shareColor(_ share: Double) -> Color? {
        switch share {
        case 0.75...: return Theme.red
        case 0.50...: return Theme.orange
        case 0.25...: return Theme.yellow
        default: return nil
        }
    }

    // MARK: Selection

    private var selectedNodes: [FolderNode] {
        visibleLines.compactMap(\.node).filter { selection.contains($0.id) }
    }

    /// Plain click selects the row and opens or closes it; ⌘-click adds or
    /// removes it from the selection; ⇧-click selects a range.
    private func click(_ line: TreeLine) {
        guard let node = line.node else { return }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(node.id) { selection.remove(node.id) } else { selection.insert(node.id) }
            anchor = node.id
        } else if flags.contains(.shift), let anchor {
            selection = Set(range(from: anchor, to: node.id))
        } else {
            selection = [node.id]
            anchor = node.id
            if !isFlat { toggle(node) }
        }
        cursor = node.id
        QuickLook.shared.update(selectedNodes.map(\.url))
    }

    private func range(from a: String, to b: String) -> [String] {
        let ids = visibleLines.compactMap { $0.node?.id }
        guard let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: b) else { return [b] }
        return Array(ids[min(i, j)...max(i, j)])
    }

    private func toggle(_ node: FolderNode?) {
        guard let node, !node.children.isEmpty else { return }
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
    }

    /// Selects `node` in the tree: clears the filter, opens its ancestors and
    /// scrolls to it.
    private func reveal(_ node: FolderNode) {
        if tab == .largeFiles { tab = .folders }
        query = ""
        var p = node.parent
        while let a = p {
            expanded.insert(a.id)
            p = a.parent
        }
        selection = [node.id]
        anchor = node.id
        cursor = node.id
        scrollTarget = node.id
    }

    // MARK: Chart

    /// The selected folder (or the scanned root when nothing fitting is selected).
    private func chartFocus(in root: FolderNode) -> FolderNode {
        if selection.count == 1, let id = selection.first, let n = root.find(id) {
            if !n.children.isEmpty { return n }
            if let p = n.parent { return p }
        }
        return root
    }

    private func goUp(in root: FolderNode) {
        let focus = chartFocus(in: root)
        if let p = focus.parent, p !== root { reveal(p) } else { selection = [] }
    }

    // MARK: Menu

    /// Right-click pops a native menu with what can be done to the item, or to
    /// the whole selection when the item is part of a multi-selection.
    private func showMenu(for line: TreeLine) {
        guard let node = line.node else { return }
        if !selection.contains(node.id) || selection.count < 2 {
            selection = [node.id]
            anchor = node.id
            cursor = node.id
        }
        let targets = selection.count > 1 ? selectedNodes : [node]
        let inTrash = tab == .trash
        let menu = ActionMenu()

        if targets.count > 1 {
            menu.add("\(targets.count) items · \(bytes(targets.reduce(0) { $0 + $1.size }))",
                     symbol: "checklist", enabled: false) {}
            menu.separator()
            menu.add("Reveal in Finder", symbol: "magnifyingglass") { scanner.reveal(targets) }
            menu.add("Quick Look", symbol: "eye") { QuickLook.shared.show(targets.map(\.url)) }
            menu.add("Copy Paths", symbol: "doc.on.doc") { scanner.copyPaths(targets) }
        } else {
            if !isFlat && !node.children.isEmpty {
                let open = expanded.contains(node.id)
                menu.add(open ? "Collapse" : "Expand", symbol: open ? "chevron.down" : "chevron.right") { toggle(node) }
                menu.separator()
            } else if isFlat && !inTrash && scanner.root != nil {
                menu.add("Show in Folder Tree", symbol: "list.bullet.indent") { reveal(node) }
                menu.separator()
            }
            menu.add("Reveal in Finder", symbol: "magnifyingglass") { scanner.reveal([node]) }
            menu.add("Get Info", symbol: "info.circle") { scanner.showInfo(node) }
            menu.add("Quick Look", symbol: "eye") { QuickLook.shared.show([node.url]) }
            menu.add("Copy Path", symbol: "doc.on.doc") { scanner.copyPaths([node]) }
            menu.add("Open in Terminal", symbol: "terminal") { scanner.openInTerminal(node) }
        }
        menu.separator()
        if inTrash {
            menu.add(targets.count > 1 ? "Delete \(targets.count) Items Immediately…" : "Delete Immediately…",
                     symbol: "xmark.bin") { pendingDelete = targets }
        } else if targets.allSatisfy({ scanner.canTrash($0) }) {
            menu.add(targets.count > 1 ? "Move \(targets.count) Items to Trash…" : "Move to Trash…",
                     symbol: "trash") { pendingTrash = targets }
        } else {
            menu.add(scanner.isScanning ? "Move to Trash — wait for the scan to finish"
                                        : "Move to Trash — needs admin rights",
                     symbol: "lock", enabled: false) {}
        }
        menu.popUp()
    }

    // MARK: Keyboard

    /// Arrow keys, Space, ⌘⌫, ⌘A, ⌘C and Esc work on the list while this tab is
    /// on screen, except when the filter field has the keyboard.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSTextView) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)
        let lines = visibleLines.compactMap(\.node)
        guard !lines.isEmpty else { return false }

        switch event.keyCode {
        case 125: move(1, extend: shift, in: lines); return true          // ↓
        case 126: move(-1, extend: shift, in: lines); return true         // ↑
        case 124:                                                          // →
            guard !isFlat, let n = cursorNode(in: lines) else { return true }
            if !n.children.isEmpty && !expanded.contains(n.id) { expanded.insert(n.id) } else { move(1, extend: false, in: lines) }
            return true
        case 123:                                                          // ←
            guard !isFlat, let n = cursorNode(in: lines) else { return true }
            if expanded.contains(n.id) { expanded.remove(n.id) } else if let p = n.parent, lines.contains(where: { $0 === p }) { select(p) }
            return true
        case 49 where !cmd:                                                // Space
            QuickLook.shared.show(selectedNodes.map(\.url))
            return true
        case 51 where cmd:                                                 // ⌘⌫
            let targets = selectedNodes
            guard !targets.isEmpty else { return true }
            if tab == .trash { pendingDelete = targets }
            else if targets.allSatisfy({ scanner.canTrash($0) }) { pendingTrash = targets }
            else { NSSound.beep() }
            return true
        case 53:                                                           // Esc
            if !query.isEmpty { query = "" } else { selection = [] }
            return true
        default:
            guard cmd, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
            if key == "a" { selection = Set(lines.map(\.id)); return true }
            if key == "c", !selection.isEmpty { scanner.copyPaths(selectedNodes); return true }
            return false
        }
    }

    private func cursorNode(in lines: [FolderNode]) -> FolderNode? {
        lines.first { $0.id == cursor } ?? lines.first { selection.contains($0.id) }
    }

    private func move(_ delta: Int, extend: Bool, in lines: [FolderNode]) {
        let ids = lines.map(\.id)
        let current = cursor.flatMap { ids.firstIndex(of: $0) }
        let next = current.map { min(max($0 + delta, 0), ids.count - 1) } ?? (delta > 0 ? 0 : ids.count - 1)
        let id = ids[next]
        if extend, let anchor {
            selection = Set(range(from: anchor, to: id))
        } else {
            selection = [id]
            anchor = id
        }
        cursor = id
        scrollTarget = id
        QuickLook.shared.update(selectedNodes.map(\.url))
    }

    private func select(_ node: FolderNode) {
        selection = [node.id]
        anchor = node.id
        cursor = node.id
        scrollTarget = node.id
    }

    // MARK: Helpers

    private var tabBinding: Binding<Tab> {
        Binding(get: { tab }, set: { new in
            // Coming (back) to the Trash re-measures it: it may have been
            // emptied in Finder since.
            if new == .trash { scanner.refreshTrash() }
            guard new != tab else { return }
            tab = new
            selection = []
            cursor = nil
            anchor = nil
        })
    }

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
        selection = []
        cursor = nil
        anchor = nil
        if tab == .trash { tab = .folders }
        scanner.scan()
    }

    private func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private var customName: String? {
        if case .custom(let u) = scanner.scope { return u.lastPathComponent }
        return nil
    }

    private var trashTitle: String {
        pendingTrash.count > 1 ? "Move \(pendingTrash.count) items to the Trash?" : "Move to Trash?"
    }

    private func describe(_ nodes: [FolderNode]) -> String {
        let total = bytes(nodes.reduce(0) { $0 + $1.size })
        if nodes.count == 1, let n = nodes.first { return "“\(n.name)” (\(total))" }
        return "\(nodes.count) items (\(total))"
    }

    private func present(_ items: Binding<[FolderNode]>) -> Binding<Bool> {
        Binding(get: { !items.wrappedValue.isEmpty }, set: { if !$0 { items.wrappedValue = [] } })
    }

    /// Already granted: just open the pane. Otherwise explain the steps first,
    /// since macOS never lists an app there on its own.
    private func openFullDiskAccess() {
        if hasFullDiskAccess {
            FullDiskAccess.openSettings()
        } else {
            showFullDiskAccessHelp = true
        }
    }
}

private func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

private func abbreviate(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

/// A segmented control drawn in SwiftUI: equal-width segments in a fixed frame
/// with a sliding highlight. NSSegmentedControl (Picker .segmented) re-sizes
/// itself to the selected label for a moment on every change, which made the
/// whole toolbar stretch and snap back.
private struct SegmentBar<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(Value, String)]

    @Namespace private var highlight
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let (value, title) = items[i]
                let isOn = value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = value }
                } label: {
                    Text(title)
                        .font(.system(size: 12.5, weight: isOn ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(isOn ? Color.white : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.accentColor)
                                    .matchedGeometryEffect(id: "highlight", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Puts `leading` and `trailing` on one line when they fit, with the gap in
/// between; otherwise on two lines, the first flush left and the second
/// flush right. Children should have fixed widths so the fit is measurable.
///
/// A custom Layout rather than ViewThatFits: ViewThatFits builds one copy of the
/// content per candidate, so every flip between one and two lines recreated the
/// segmented control and text field, which popped in at their natural size and
/// then snapped to the set width. Here the same views are only moved.
private struct SplitBar<Leading: View, Trailing: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        SplitLayout(spacing: spacing) {
            HStack(spacing: spacing) { leading }
            HStack(spacing: spacing) { trailing }
        }
    }
}

/// Lays out exactly two subviews: side by side when both fit at their ideal
/// width, otherwise stacked with the second right-aligned.
private struct SplitLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat = 8

    private func measure(_ subviews: Subviews) -> (CGSize, CGSize) {
        (subviews[0].sizeThatFits(.unspecified), subviews[1].sizeThatFits(.unspecified))
    }

    private func fits(_ l: CGSize, _ t: CGSize, in width: CGFloat) -> Bool {
        l.width + spacing + t.width <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let (l, t) = measure(subviews)
        let width = proposal.width ?? (l.width + spacing + t.width)
        if fits(l, t, in: width) {
            return CGSize(width: width, height: max(l.height, t.height))
        }
        return CGSize(width: width, height: l.height + lineSpacing + t.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (l, t) = measure(subviews)
        if fits(l, t, in: bounds.width) {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY),
                              anchor: .leading, proposal: ProposedViewSize(l))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY),
                              anchor: .trailing, proposal: ProposedViewSize(t))
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY),
                              anchor: .topLeading, proposal: ProposedViewSize(l))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + l.height + lineSpacing),
                              anchor: .topTrailing, proposal: ProposedViewSize(t))
        }
    }
}

/// What the list can be sorted by.
private enum SortKey: String, CaseIterable {
    case size, name, files, kind, opened

    var title: String {
        switch self {
        case .size: return "Size"
        case .name: return "Name"
        case .files: return "Number of files"
        case .kind: return "Kind"
        case .opened: return "Last opened"
        }
    }

    /// Names read A→Z and kinds group naturally; amounts and dates go biggest
    /// or newest first.
    var ascendingByDefault: Bool { self == .name || self == .kind }

    func compare(_ a: FolderNode, _ b: FolderNode) -> ComparisonResult {
        switch self {
        case .size:
            return a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .files:
            return a.fileCount == b.fileCount ? .orderedSame
                : (a.fileCount < b.fileCount ? .orderedAscending : .orderedDescending)
        case .kind:
            if a.kind != b.kind { return Self.rank(a.kind) < Self.rank(b.kind) ? .orderedAscending : .orderedDescending }
            let r = a.url.pathExtension.lowercased().localizedStandardCompare(b.url.pathExtension.lowercased())
            return r != .orderedSame ? r : a.name.localizedStandardCompare(b.name)
        case .opened:
            // Only large files carry a date; everything else ties and falls back to size.
            let da = a.accessDate ?? .distantPast
            let db = b.accessDate ?? .distantPast
            return da == db ? .orderedSame : (da < db ? .orderedAscending : .orderedDescending)
        }
    }

    private static func rank(_ k: FolderNode.Kind) -> Int {
        switch k {
        case .folder: return 0
        case .package: return 1
        case .file: return 2
        }
    }
}

/// Groups for the Large Files filter, by file extension.
private enum FileKind: String, CaseIterable {
    case all = "All kinds"
    case video = "Video"
    case archive = "Disk images & archives"
    case audio = "Audio"
    case image = "Images"
    case document = "Documents"
    case other = "Other"

    private static let extensions: [FileKind: Set<String>] = [
        .video: ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"],
        .archive: ["dmg", "iso", "img", "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "pkg", "xip", "ipsw", "vmdk", "qcow2", "sparseimage", "sparsebundle"],
        .audio: ["mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "ogg", "caf"],
        .image: ["jpg", "jpeg", "png", "heic", "tiff", "tif", "gif", "raw", "cr2", "nef", "arw", "dng", "psd", "webp"],
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "csv", "epub"],
    ]

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        for (kind, set) in extensions where set.contains(ext) { return kind }
        return .other
    }
}

/// One visible row: an item, or (node == nil) the "smaller items" line of `owner`.
private struct TreeLine: Identifiable {
    let node: FolderNode?
    let owner: FolderNode
    let depth: Int

    var id: String { node?.id ?? "smaller:" + owner.id }
    var size: Int64 { node?.size ?? owner.otherSize }
    var share: Double {
        guard node !== owner else { return 1 }
        return Double(size) / Double(max(1, owner.size))
    }
}

private struct FolderRow: View {
    let line: TreeLine
    let isExpanded: Bool
    let isSelected: Bool
    /// Set when "Color by share" is on and the item is big for its folder.
    let shareColor: Color?
    let subtitle: String?
    let toggle: () -> Void
    let click: () -> Void
    let openMenu: () -> Void

    @State private var isHovering = false

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

    private var pending: Bool { line.node?.pending == true }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(line.depth) * 18, height: 1)
            Group {
                if subtitle == nil, let node = line.node, !node.children.isEmpty {
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
            if let node = line.node, node.kind != .folder {
                ItemIcon(node: node, fallback: icon, tint: tint)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
            }
            if let shareColor {
                Circle().fill(shareColor).frame(width: 7, height: 7)
            }
            Text(line.node?.name ?? "\(line.owner.otherCount.formatted()) smaller item\(line.owner.otherCount == 1 ? "" : "s")")
                .font(.system(size: 12.5, weight: line.node == nil ? .regular : .medium))
                .foregroundStyle(line.node == nil ? Theme.textMuted : Theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                BatteryBar(fraction: pending ? 0 : line.share,
                           color: (shareColor ?? tint).opacity(line.node == nil ? 0.5 : 1))
                    .frame(width: 120)
                Text(pending ? "" : (line.share < 0.001 ? "<0.1%" : String(format: "%.1f%%", line.share * 100)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(shareColor ?? Theme.textMuted)
                    .frame(width: 42, alignment: .trailing)
            }
            .frame(width: 170, alignment: .leading)
            Text(pending ? "measuring…" : ByteCountFormatter.string(fromByteCount: line.size, countStyle: .file))
                .font(.system(size: pending ? 11 : 12.5, weight: pending ? .regular : .semibold, design: .rounded))
                .foregroundStyle(pending || line.node == nil ? Theme.textMuted : Theme.textPrimary)
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
        // Left click selects and opens or closes the folder; right click (or ⌃-click) shows the actions.
        .onTapGesture(perform: click)
        .overlay(RightClickCatcher(action: openMenu))
        .onHover { isHovering = $0 }
        .help(line.node?.url.path ?? "Items under 1 MB, added into the folder's total")
    }
}

/// A file's Finder thumbnail (or an app/bundle's own icon), loaded when the row
/// scrolls into view. The SF Symbol shows until it arrives.
private struct ItemIcon: View {
    let node: FolderNode
    let fallback: String
    let tint: Color

    static let side: CGFloat = 20

    @State private var image: NSImage?
    @State private var request: QLThumbnailGenerator.Request?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: fallback)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .onAppear(perform: load)
        .onDisappear {
            if let request { QLThumbnailGenerator.shared.cancel(request) }
            request = nil
        }
    }

    private func load() {
        let url = node.url
        if let hit = ThumbnailCache.image(for: url) {
            image = hit
            return
        }
        // Apps and bundles are better known by their icon than by a preview,
        // and the icon is cheap.
        if node.kind == .package {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            ThumbnailCache.store(icon, for: url)
            image = icon
            return
        }
        let req = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: Self.side, height: Self.side),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: [.icon, .thumbnail])
        request = req
        // Called once with the file-type icon, then again with the real
        // thumbnail when the file has one.
        QLThumbnailGenerator.shared.generateRepresentations(for: req) { rep, type, _ in
            guard let rep else { return }
            let img = rep.nsImage
            // A preview of a tiny image comes back a few points wide; blown up
            // it is a smudge, so the file-type icon stays instead.
            if type == .thumbnail && max(img.size.width, img.size.height) < Self.side * 0.6 { return }
            DispatchQueue.main.async {
                if type == .thumbnail || ThumbnailCache.image(for: url) == nil {
                    ThumbnailCache.store(img, for: url)
                }
                image = img
            }
        }
    }
}

/// Thumbnails already made this session, keyed by path. NSCache drops the
/// oldest under memory pressure on its own.
private enum ThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        return c
    }()

    static func image(for url: URL) -> NSImage? { cache.object(forKey: url.path as NSString) }
    static func store(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url.path as NSString) }
}

/// Ring chart of a folder: each ring is one level deeper, each slice as wide
/// as its share of the parent. Clicking a slice selects it in the list;
/// clicking the middle goes up a level.
private struct SunburstChart: View {
    let focus: FolderNode
    let onPick: (FolderNode) -> Void
    let onUp: () -> Void

    private let rings = 3
    private static let palette: [Color] = [
        Theme.blue, Theme.green, Theme.purple, Theme.orange, Theme.yellow, Color(hex: 0x4FD1C5), Theme.red,
    ]

    @State private var hovered: FolderNode?

    private struct Slice {
        let node: FolderNode
        let start: Double
        let end: Double
        let ring: Int
        let color: Color
    }

    private var slices: [Slice] {
        var out: [Slice] = []
        func add(_ n: FolderNode, from start: Double, to end: Double, ring: Int, color: Color?) {
            guard ring < rings, n.size > 0 else { return }
            var a = start
            for (i, c) in n.children.enumerated() where !c.pending {
                let span = (end - start) * Double(c.size) / Double(n.size)
                defer { a += span }
                // Slivers under ~0.3° are not worth drawing or aiming at.
                guard span > 0.005 else { continue }
                let col = color ?? Self.palette[i % Self.palette.count]
                out.append(Slice(node: c, start: a, end: a + span, ring: ring, color: col))
                add(c, from: a, to: a + span, ring: ring + 1, color: col)
            }
        }
        add(focus, from: 0, to: 2 * .pi, ring: 0, color: nil)
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let inner = side * 0.2
            let ringWidth = (side / 2 - inner - 2) / CGFloat(rings)
            let all = slices

            ZStack {
                Canvas { ctx, _ in
                    for s in all {
                        let r0 = inner + CGFloat(s.ring) * ringWidth
                        var path = Path()
                        path.addArc(center: center, radius: r0 + ringWidth - 1,
                                    startAngle: .radians(s.start - .pi / 2), endAngle: .radians(s.end - .pi / 2),
                                    clockwise: false)
                        path.addArc(center: center, radius: r0,
                                    startAngle: .radians(s.end - .pi / 2), endAngle: .radians(s.start - .pi / 2),
                                    clockwise: true)
                        path.closeSubpath()
                        let lit = hovered === s.node
                        ctx.fill(path, with: .color(s.color.opacity(lit ? 1 : 0.9 - Double(s.ring) * 0.22)))
                        ctx.stroke(path, with: .color(Theme.card), lineWidth: 1)
                    }
                }
                VStack(spacing: 2) {
                    Text((hovered ?? focus).name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                        .minimumScaleFactor(0.7)
                    Text(bytes((hovered ?? focus).size))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(width: inner * 1.7)
                .position(center)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                switch hit(v.location, center: center, inner: inner, ringWidth: ringWidth, in: all) {
                case .some(let n): onPick(n)
                case .none where distance(v.location, center) < inner: onUp()
                default: break
                }
            })
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    hovered = hit(p, center: center, inner: inner, ringWidth: ringWidth, in: all)
                } else {
                    hovered = nil
                }
            }
        }
        .help("Click a slice to select it, the middle to go up a level.")
    }

    private func distance(_ p: CGPoint, _ c: CGPoint) -> CGFloat {
        hypot(p.x - c.x, p.y - c.y)
    }

    private func hit(_ p: CGPoint, center: CGPoint, inner: CGFloat, ringWidth: CGFloat,
                     in all: [Slice]) -> FolderNode? {
        let r = distance(p, center)
        guard r >= inner else { return nil }
        let ring = Int((r - inner) / ringWidth)
        var angle = Double(atan2(p.y - center.y, p.x - center.x)) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return all.first { $0.ring == ring && angle >= $0.start && angle < $0.end }?.node
    }
}

/// Quick Look panel fed directly with file URLs.
private final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []

    /// Opens the panel on `urls`, or closes it when it already shows them.
    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible && urls == self.urls {
            panel.orderOut(nil)
            return
        }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Follows the selection while the panel is open.
    func update(_ urls: [URL]) {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, !urls.isEmpty, urls != self.urls else { return }
        self.urls = urls
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

/// Transparent layer that takes only right clicks and ⌃-clicks; every other
/// event falls through to the SwiftUI row underneath.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let isRight = e.type == .rightMouseDown
                || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return isRight ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { action?() }
        // Only reached for ⌃-click, which hitTest lets through.
        override func mouseDown(with event: NSEvent) { action?() }
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
