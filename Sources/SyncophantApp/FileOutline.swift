import SwiftUI
import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import CoreKit

/// What the outline needs from its owner. Closures keep the AppKit view unaware of AppModel.
/// The fields after `quickLookURL` are optional; Files sets them, the snapshot outline does not.
struct OutlineActions {
    var status: (FileNode) -> FileStatus
    var expand: ((FileNode) -> Void)?
    var select: ([FileNode]) -> Void
    var menu: (([FileNode]) -> [OutlineMenuItem])?
    var drop: (([URL], FileNode?) -> Void)?
    var quickLookURL: ((FileNode) async -> URL?)?
    /// Badge state for the "Where it lives" column. When nil the column is not shown.
    var state: ((FileNode) -> FileState?)? = nil
    /// Words beside the badge.
    var words: ((FileNode, FileState) -> String)? = nil
    /// Orange second line under the name (conflict copies).
    var note: ((FileNode) -> String?)? = nil
    /// Size column text; folders show an item count only when the caller knows it.
    var sizeText: ((FileNode) -> String)? = nil
    /// Double-click and Return.
    var open: ((FileNode) -> Void)? = nil
    /// Trailing actions; `hovered` is true while the pointer is over the row.
    var rowActions: ((FileNode, _ hovered: Bool) -> AnyView)? = nil
    /// Drag of files over the list: active, the folder row being targeted (nil = shown folder), item count.
    var dragChanged: ((Bool, FileNode?, Int) -> Void)? = nil
}

struct OutlineMenuItem {
    var title: String
    var key: String = ""
    var modifiers: NSEvent.ModifierFlags = []
    var enabled = true
    var isSeparator = false
    var children: [OutlineMenuItem]? = nil
    var run: () -> Void = {}
    static var separator: OutlineMenuItem { OutlineMenuItem(title: "", isSeparator: true) }
}

/// NSOutlineView file browser: native selection, keyboard, drag and drop, 100k-row scrolling.
/// Badge-only changes (`badgeStamp`) redraw the visible rows in place instead of reloading the list.
struct FileOutline: NSViewRepresentable {
    let nodes: [FileNode]
    /// Changing any of these forces a redraw of the visible rows.
    let stamp: Int
    let flat: Bool
    let actions: OutlineActions
    var badgeStamp: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let files = actions.state != nil
        let outline = FileOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = false
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = false
        outline.style = .inset
        outline.rowSizeStyle = .custom
        outline.rowHeight = files ? 40 : 34
        outline.intercellSpacing = NSSize(width: 10, height: files ? 1 : 2)
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 18
        outline.autosaveName = files ? "SyncophantFiles.v3" : "SyncophantOutline.v1"
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autosaveTableColumns = true
        outline.setAccessibilityLabel("Files")
        var columns: [(String, String, CGFloat, CGFloat)] = [("name", "Name", 320, 160)]
        if files { columns.append(("status", "Where it lives", 190, 140)) }
        columns += [("size", "Size", 80, 64), ("modified", "Modified", 140, 110)]
        if actions.rowActions != nil { columns.append(("actions", "", 72, 72)) }
        for (id, title, width, minWidth) in columns {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title; c.width = width; c.minWidth = minWidth
            c.resizingMask = id == "actions" ? [] : [.autoresizingMask, .userResizingMask]
            if id == "size" { c.headerCell.alignment = .right }
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.coordinator = context.coordinator
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        // Columns re-fit whenever the visible width changes, so the last column never slides under the edge.
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.fitObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak outline] _ in
            MainActor.assumeIsolated { outline?.sizeToFit() }
        }
        DispatchQueue.main.async { [weak outline] in outline?.sizeToFit() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.actions = actions
        c.flat = flat
        guard let outline = c.outline else { return }
        if c.stamp != stamp || c.nodes.count != nodes.count || c.nodes.first !== nodes.first {
            c.nodes = nodes
            c.stamp = stamp
            c.badgeStamp = badgeStamp
            let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
            c.reloading = true
            outline.reloadData()
            let rows = IndexSet(selected.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            c.reloading = false
        } else if c.badgeStamp != badgeStamp {
            c.badgeStamp = badgeStamp
            c.redrawVisibleRows()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var nodes: [FileNode] = []
        var stamp = Int.min
        var badgeStamp = Int.min
        var flat = false
        var reloading = false
        var actions = OutlineActions(status: { _ in .none }, select: { _ in })
        weak var outline: FileOutlineView?
        private var iconCache: [String: NSImage] = [:]
        var fitObserver: NSObjectProtocol?
        private var hoveredRow = -1
        private var dropTarget: FileNode?
        private var dragging = false

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? FileNode else { return nodes.count }
            return node.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? FileNode else { return nodes[index] }
            return node.children![index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !flat && actions.expand != nil && (item as? FileNode)?.isDirectory == true
        }

        // MARK: Expansion

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            node.isExpanded = true
            actions.expand?(node)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            (notification.userInfo?["NSObject"] as? FileNode)?.isExpanded = false
        }

        // MARK: Selection and opening

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !reloading, let outline else { return }
            actions.select(outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode })
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
            openOrToggle(node)
        }

        func openOrToggle(_ node: FileNode) {
            if let open = actions.open { open(node); return }
            guard let outline, outline.isExpandable(node) else { return }
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        }

        // MARK: Hover

        func hover(_ row: Int, inside: Bool) {
            guard actions.rowActions != nil else { return }
            let old = hoveredRow
            if inside { hoveredRow = row } else if hoveredRow == row { hoveredRow = -1 }
            guard old != hoveredRow, let outline, let column = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == "actions" }) else { return }
            let rows = IndexSet([old, hoveredRow].filter { $0 >= 0 && $0 < outline.numberOfRows })
            outline.reloadData(forRowIndexes: rows, columnIndexes: [column])
        }

        func redrawVisibleRows() {
            guard let outline else { return }
            let range = outline.rows(in: outline.visibleRect)
            guard range.length > 0 else { return }
            outline.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<(range.location + range.length)),
                               columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
        }

        // MARK: Cells

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode, let id = tableColumn?.identifier.rawValue else { return nil }
            switch id {
            case "name": return nameCell(outlineView, node)
            case "size":
                let text = actions.sizeText?(node) ?? (node.isDirectory ? "" : Format.bytes(node.item.entry.size))
                return textCell(outlineView, id, text, align: .right, monospaced: true)
            case "modified": return textCell(outlineView, id, Format.modified.string(from: node.item.entry.modifiedAt), align: .left, monospaced: false)
            case "status": return host(outlineView, id, AnyView(WhereCell(text: statusText(node), state: node.isLoading ? nil : actions.state?(node))))
            case "actions":
                let row = outlineView.row(forItem: node)
                return host(outlineView, id, actions.rowActions?(node, row == hoveredRow) ?? AnyView(EmptyView()))
            default: return nil
            }
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            guard let node = item as? FileNode else { return nil }
            let row = FileRowView()
            row.onHover = { [weak self, weak outlineView, weak row] inside in
                guard let self, let outlineView, let row else { return }
                self.hover(outlineView.row(for: row), inside: inside)
            }
            let e = node.item.entry
            let kind = node.isDirectory ? "Folder" : Format.bytes(e.size)
            row.setAccessibilityLabel("\(node.displayName), \(kind), modified \(Format.modified.string(from: e.modifiedAt)), \(statusText(node))")
            return row
        }

        private func icon(for node: FileNode) -> NSImage {
            let key = node.isDirectory ? "/folder" : (node.item.entry.name as NSString).pathExtension.lowercased()
            if let cached = iconCache[key] { return cached }
            let type = node.isDirectory ? UTType.folder : (UTType(filenameExtension: key) ?? .data)
            let image = NSWorkspace.shared.icon(for: type)
            image.size = NSSize(width: 24, height: 24)
            iconCache[key] = image
            return image
        }

        private func host(_ outline: NSOutlineView, _ id: String, _ view: AnyView) -> NSView {
            let cell = (outline.makeView(withIdentifier: .init(id), owner: nil) as? HostCell) ?? {
                let c = HostCell(); c.identifier = .init(id); return c
            }()
            cell.host.rootView = view
            return cell
        }

        private func reuse(_ outline: NSOutlineView, _ id: String) -> NSTableCellView {
            if let v = outline.makeView(withIdentifier: .init(id), owner: nil) as? NSTableCellView { return v }
            if id == "name" { let c = NameCellView(); c.identifier = .init(id); return c }
            let cell = NSTableCellView()
            cell.identifier = .init(id)
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text); cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func nameCell(_ outline: NSOutlineView, _ node: FileNode) -> NSView {
            let cell = reuse(outline, "name") as! NameCellView
            cell.configure(icon: icon(for: node), title: node.displayName, note: actions.note?(node), folder: node.isDirectory)
            return cell
        }

        private func textCell(_ outline: NSOutlineView, _ id: String, _ value: String, align: NSTextAlignment, monospaced: Bool) -> NSView {
            let cell = reuse(outline, id)
            cell.textField?.stringValue = value
            cell.textField?.alignment = align
            cell.textField?.font = monospaced ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }

        private func statusText(_ node: FileNode) -> String {
            if node.isLoading { return "Loading…" }
            if let e = node.loadError { return "Could not list: \(e)" }
            if let state = actions.state?(node) { return actions.words?(node, state) ?? state.words(storage: "your storage") }
            return actions.status(node).label
        }

        // MARK: Context menu

        func menu(for nodes: [FileNode]) -> NSMenu? {
            guard let items = actions.menu?(nodes), !items.isEmpty else { return nil }
            return makeMenu(items)
        }

        private func makeMenu(_ items: [OutlineMenuItem]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for i in items {
                if i.isSeparator { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: i.title, action: #selector(runMenuItem(_:)), keyEquivalent: i.key)
                item.keyEquivalentModifierMask = i.modifiers
                item.target = self
                item.isEnabled = i.enabled
                item.representedObject = MenuHandler(i.run)
                if let children = i.children { item.action = nil; item.submenu = makeMenu(children) }
                menu.addItem(item)
            }
            return menu
        }

        @objc private func runMenuItem(_ sender: NSMenuItem) { (sender.representedObject as? MenuHandler)?.run() }

        final class MenuHandler: NSObject {
            let run: () -> Void
            init(_ run: @escaping () -> Void) { self.run = run }
        }

        // MARK: Drag and drop (uploads)

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard actions.drop != nil, info.draggingSource as? NSOutlineView == nil else { return [] }
            // A folder row takes the drop; anywhere else uploads into the folder on screen.
            let folder = (item as? FileNode).flatMap { $0.isDirectory ? $0 : nil }
            outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
            let count = info.draggingPasteboard.pasteboardItems?.count ?? 0
            if !dragging || folder !== dropTarget {
                dragging = true
                dropTarget = folder
                actions.dragChanged?(true, folder, count)
            }
            return .copy
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            endDrag()
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return false }
            actions.drop?(urls, item as? FileNode)
            return true
        }

        func endDrag() {
            guard dragging else { return }
            dragging = false
            dropTarget = nil
            actions.dragChanged?(false, nil, 0)
        }

        // MARK: Quick Look

        func quickLook() {
            guard let outline, let node = outline.selectedRowIndexes.first.flatMap({ outline.item(atRow: $0) as? FileNode }),
                  !node.isDirectory, let provider = actions.quickLookURL else { NSSound.beep(); return }
            Task {
                guard let url = await provider(node) else { return }
                outline.previewURL = url
                QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
                QLPreviewPanel.shared().reloadData()
            }
        }
    }
}

final class FileOutlineView: NSOutlineView, @preconcurrency QLPreviewPanelDataSource {
    weak var coordinator: FileOutline.Coordinator?
    var previewURL: URL?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return coordinator?.menu(for: selectedRowIndexes.compactMap { item(atRow: $0) as? FileNode })
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ": coordinator?.quickLook()
        case "\r":
            guard let node = selectedRowIndexes.first.flatMap({ item(atRow: $0) as? FileNode }) else { return }
            coordinator?.openOrToggle(node)
        default: super.keyDown(with: event)
        }
    }

    /// Clicks on the hover buttons go to them, not to row selection.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let view = responder as? NSView,
           sequence(first: view, next: \.superview).contains(where: { ($0 as? HostCell)?.identifier?.rawValue == "actions" }) {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        coordinator?.endDrag()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        coordinator?.endDrag()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { panel.dataSource = self } }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { panel.dataSource = nil } }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL as NSURL? }
}

/// Row with a 10 pt rounded selection that stays under the text colour, plus a faint hover wash.
/// Drawing is two filled rounded rects; nothing allocates per frame, so scrolling stays cheap.
final class FileRowView: NSTableRowView {
    var onHover: ((Bool) -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true; onHover?(hovered) } } }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private var pillRect: NSRect { bounds.insetBy(dx: 8, dy: 0.5) }
    private var pill: NSBezierPath { NSBezierPath(roundedRect: pillRect, xRadius: 10, yRadius: 10) }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovered, !isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        pill.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let path = pill
        (isEmphasized ? Palette.accentNS.withAlphaComponent(0.18) : NSColor.labelColor.withAlphaComponent(0.09)).setFill()
        path.fill()
        if isEmphasized {
            Palette.accentNS.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override var isEmphasized: Bool { didSet { needsDisplay = true } }
}

/// Icon, name and an optional orange second line.
final class NameCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.setAccessibilityElement(false)
        title.lineBreakMode = .byTruncatingMiddle
        note.lineBreakMode = .byTruncatingTail
        note.font = .systemFont(ofSize: 11)
        note.textColor = Palette.cautionNS
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, note])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for v in [icon, text] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        textField = title
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24), icon.heightAnchor.constraint(equalToConstant: 24),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(icon image: NSImage, title text: String, note line: String?, folder: Bool) {
        icon.image = image
        title.stringValue = text
        title.font = .systemFont(ofSize: 13, weight: folder ? .medium : .regular)
        title.textColor = .labelColor
        note.stringValue = line ?? ""
        note.isHidden = line == nil
    }
}

/// A reusable cell hosting a small SwiftUI view (badges and hover buttons).
final class HostCell: NSTableCellView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Badge plus words, coloured by state; neutral states stay secondary. Colour always comes with glyph and words.
struct WhereCell: View {
    let text: String
    let state: FileState?

    var body: some View {
        HStack(spacing: 7) {
            if let state { FileStateBadge(state: state, size: 16) }
            Text(text)
                .font(.system(size: 12, weight: state.map { $0.tone == .neutral ? .regular : .medium } ?? .regular))
                .foregroundStyle(state.map { $0.tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle($0.tone.text) } ?? AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
