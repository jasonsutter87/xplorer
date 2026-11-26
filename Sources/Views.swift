import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Window

struct ContentView: View {
    @Binding var spec: WindowSpec
    @StateObject private var model: BrowserModel
    @Environment(\.openWindow) private var openWindow

    init(spec: Binding<WindowSpec>) {
        _spec = spec
        _model = StateObject(wrappedValue: BrowserModel(
            start: URL(fileURLWithPath: spec.wrappedValue.path), select: spec.wrappedValue.select))
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(model: model)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            Divider()
            HSplitView {
                Sidebar(model: model)
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 340)
                FileList(model: model)
                    .frame(minWidth: 420, maxWidth: .infinity)
                    .layoutPriority(1)
                if model.showPreview {
                    PreviewPane(model: model)
                        .frame(minWidth: 220, idealWidth: 320, maxWidth: 700)
                }
            }
            Divider()
            StatusBar(model: model)
        }
        .frame(minWidth: 760, minHeight: 420)
        .navigationTitle(displayName(model.current.path))
        .background(WindowGrabber { win in
            model.window = win
            if let parent = AppDelegate.tabParent, parent !== win {
                AppDelegate.tabParent = nil
                parent.addTabbedWindow(win, ordered: .above)
                win.makeKeyAndOrderFront(nil)
            }
            model.focusTable()
        })
        .onChange(of: model.current) { spec.path = $0.path; spec.select = nil }
        .onAppear {
            let open = openWindow
            AppDelegate.openHandler = { dir, sel in open(value: WindowSpec(path: dir, select: sel)) }
            // Cold launch via "open folder": reuse this first window for the first request.
            if !AppDelegate.pending.isEmpty {
                let first = AppDelegate.pending.removeFirst()
                model.navigate(to: URL(fileURLWithPath: first.0), record: false, select: first.1)
                for (d, sel) in AppDelegate.pending { open(value: WindowSpec(path: d, select: sel)) }
                AppDelegate.pending.removeAll()
            }
        }
        .sheet(item: $model.renameTarget) { item in
            RenameSheet(item: item) { model.commitRename(item, to: $0) } cancel: { model.renameTarget = nil }
        }
        .alert("Xplorer", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

struct WindowGrabber: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    final class V: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { onWindow?(w) }
        }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.onWindow = onWindow; return v }
    func updateNSView(_ v: V, context: Context) {}
}

// MARK: - Top bar: back / forward / up / refresh / address / search

struct NavBar: View {
    @ObservedObject var model: BrowserModel
    @FocusState private var searchFocused: Bool
    @State private var showHelp = false

    var body: some View {
        HStack(spacing: 4) {
            navButton("arrow.left", "Back (⌥←)", enabled: model.canGoBack) { model.goBack() }
            navButton("arrow.right", "Forward (⌥→)", enabled: model.canGoForward) { model.goForward() }
            navButton("arrow.up", "Up one level (Backspace)", enabled: model.canGoUp) { model.goUp() }
            navButton("arrow.clockwise", "Refresh (F5)", enabled: true) { model.hardRefresh() }
                .padding(.trailing, 4)

            AddressBar(model: model)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(displayName(model.current.path))", text: $model.filter)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !model.filter.isEmpty {
                    Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 230, height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            .onChange(of: model.searchFocusToken) { _ in searchFocused = true }

            Button { model.showHidden.toggle() } label: {
                Image(systemName: model.showHidden ? "eye" : "eye.slash")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.showHidden ? Color.accentColor : Color.secondary)
            .help(model.showHidden ? "Hide hidden files (⌘⇧.)" : "Show hidden files (⌘⇧.)")

            Button { model.showPreview.toggle() } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.showPreview ? Color.accentColor : Color.secondary)
            .help(model.showPreview ? "Hide preview pane (⌥P)" : "Show preview pane (⌥P)")

            Menu {
                Group {
                    Toggle("Show Hidden Files  (⌘⇧.)", isOn: $model.showHidden)
                    Toggle("Preview Pane  (⌥P)", isOn: $model.showPreview)
                    Toggle("Size Bars", isOn: $model.showSizeBars)
                    Divider()
                    Button("New Tab  (⌘T)") { model.newTab() }
                    Divider()
                }
                Button("New Folder  (⌘⇧N)") { model.newFolder() }
                Button("New Text Document") { model.newTextFile() }
                Divider()
                Button("Open Terminal Here  (⌘⇧T)") { model.openTerminal(model.current) }
                Button("Show in Finder") { model.reveal([model.current]) }
                Button("Pin Folder to Quick Access") { Favorites.shared.pin(model.current.path) }
                Divider()
                Button("Keyboard Shortcuts…") { showHelp = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .popover(isPresented: $showHelp) { ShortcutHelp() }
        }
    }

    func navButton(_ icon: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}

struct AddressBar: View {
    @ObservedObject var model: BrowserModel
    @State private var text = ""
    @FocusState private var focused: Bool

    struct Segment: Identifiable { let id: String; let name: String }

    var segments: [Segment] {
        let p = model.current.path
        let home = NSHomeDirectory()
        var segs: [Segment] = []
        var rest: String
        var base: String
        if p == home || p.hasPrefix(home + "/") {
            segs.append(Segment(id: home, name: "Home"))
            rest = String(p.dropFirst(home.count))
            base = home
        } else {
            segs.append(Segment(id: "/", name: displayName("/")))
            rest = p
            base = ""
        }
        for comp in rest.split(separator: "/") {
            base += "/" + comp
            segs.append(Segment(id: base, name: String(comp)))
        }
        return segs
    }

    var body: some View {
        Group {
            if model.addressEditing {
                TextField("Type a path, e.g. ~/Downloads", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { model.go(typed: text) }
                    .onAppear {
                        text = model.current.path
                        focused = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                        }
                    }
                    .onChange(of: focused) { if !$0 { model.addressEditing = false } }
            } else {
                HStack(spacing: 1) {
                    Image(nsImage: IconCache.shared.icon(model.current.path))
                        .padding(.trailing, 4)
                    ForEach(segments) { seg in
                        Button { model.navigate(to: URL(fileURLWithPath: seg.id)) } label: {
                            Text(seg.name).lineLimit(1).padding(.horizontal, 4).padding(.vertical, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(CrumbStyle())
                        Button { showSubfolderMenu(seg.id) } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 14, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(CrumbStyle())
                        .help("Jump to a subfolder")
                    }
                    Spacer(minLength: 20)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.addressEditing = true }
                .help("Click empty space (or ⌘L) to type a path")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(model.addressEditing ? Color.accentColor : Color.secondary.opacity(0.3)))
    }

    /// Explorer's breadcrumb ">" dropdown listing subfolders.
    func showSubfolderMenu(_ path: String) {
        let menu = NSMenu()
        let kids = model.treeChildren(path)
        if kids.isEmpty {
            let empty = NSMenuItem(title: "(no folders)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for k in kids.prefix(200) {
            let item = ClosureMenuItem(title: displayName(k)) { [model] in model.navigate(to: URL(fileURLWithPath: k)) }
            item.image = IconCache.shared.icon(k)
            if model.current.path == k || model.current.path.hasPrefix(k + "/") { item.state = .on }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

struct CrumbStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.15 : (hover ? 0.08 : 0))))
            .onHover { hover = $0 }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

// MARK: - Left pane: Quick Access + folder tree

struct Sidebar: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var favs = Favorites.shared
    @Environment(\.openWindow) private var openWindow

    var selection: Binding<String?> {
        Binding(
            get: { model.sidebarSelection },
            set: { id in
                guard let id, let slash = id.firstIndex(of: "/") else { return }
                let path = String(id[slash...])
                if path != model.current.path { model.navigate(to: URL(fileURLWithPath: path)) }
                else { model.sidebarSelection = id }
            })
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                Section("Quick Access") {
                    ForEach(favs.paths, id: \.self) { p in
                        HStack(spacing: 6) {
                            Image(nsImage: IconCache.shared.icon(p))
                            Text(displayName(p)).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                        .tag("qa:" + p)
                        .onDrop(of: [.fileURL], isTargeted: nil) { model.dropFiles($0, into: URL(fileURLWithPath: p)) }
                        .contextMenu { folderMenu(p, pinned: true) }
                    }
                    .onMove { favs.paths.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("This Mac") {
                    ForEach(model.treeRows) { row in
                        TreeRowView(row: row, model: model)
                            .tag(row.id)
                            .id(row.id)
                            .onDrop(of: [.fileURL], isTargeted: nil) { model.dropFiles($0, into: URL(fileURLWithPath: row.path)) }
                            .contextMenu {
                                folderMenu(row.path, pinned: favs.paths.contains(row.path))
                                if row.isVolume && row.path != "/" {
                                    Divider()
                                    Button("Eject") { model.eject(row.path) }
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: model.sidebarSelection) { id in
                guard let id else { return }
                DispatchQueue.main.async { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder
    func folderMenu(_ path: String, pinned: Bool) -> some View {
        let url = URL(fileURLWithPath: path)
        Group {
            Button("Open") { model.navigate(to: url) }
            Button("Open in New Tab") { model.newTab(path) }
            Button("Open in New Window") { openWindow(value: WindowSpec(path: path)) }
            Button("Open Terminal Here") { model.openTerminal(url) }
            Button("Show in Finder") { model.reveal([url]) }
        }
        Divider()
        Button("Paste Into Folder") { model.paste(into: url) }.disabled(!Clip.shared.hasFiles)
        Button("Copy Path") { model.copyPath([path]) }
        Button("Properties") { InfoWindow.show([url]) }
        Divider()
        if pinned { Button("Unpin from Quick Access") { Favorites.shared.unpin(path) } }
        else { Button("Pin to Quick Access") { Favorites.shared.pin(path) } }
    }
}

struct TreeRowView: View {
    let row: TreeRow
    @ObservedObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 3) {
            Color.clear.frame(width: CGFloat(row.depth) * 13, height: 1)
            Button { model.toggleExpand(row.path) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(row.isLeaf ? 0 : 1)
            .disabled(row.isLeaf)
            Image(nsImage: IconCache.shared.icon(row.path))
            Text(row.name).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Main pane: details view

struct FileList: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var clip = Clip.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Table(of: FileItem.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.shared.icon(item.id))
                    Text(item.name).lineLimit(1)
                }
                .opacity(clip.cutPaths.contains(item.id) || item.isHidden ? 0.5 : 1)
            }
            .width(min: 160, ideal: 340)

            TableColumn("Date Modified", value: \.modified) { item in
                Text(Fmt.date.string(from: item.modified)).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Type", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 150)

            TableColumn("Size", value: \.size) { item in
                Text(item.size >= 0 ? Fmt.size(item.size) : (item.measurable ? "Calculating…" : ""))
                    .foregroundStyle(item.size >= 0 ? .secondary : .tertiary)
                    .padding(.trailing, 3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .background(alignment: .leading) {
                        if model.showSizeBars, item.size > 0, model.maxSize > 0 {
                            SizeBar(fraction: Double(item.size) / Double(model.maxSize))
                        }
                    }
            }
            .width(min: 70, ideal: 110)
        } rows: {
            ForEach(model.displayed) { item in
                TableRow(item)
                    .itemProvider { NSItemProvider(object: item.url as NSURL) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(ids)
        } primaryAction: { ids in
            model.open(ids)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { model.dropFiles($0, into: model.current) }
        .overlay {
            if let err = model.loadError {
                VStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Can't open this folder").font(.headline)
                    Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("Tip: give Xplorer Full Disk Access in System Settings › Privacy & Security.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(40)
            } else if model.displayed.isEmpty {
                Text(model.filter.isEmpty ? "This folder is empty." : "No items match your search.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    func menu(_ ids: Set<String>) -> some View {
        if ids.isEmpty {
            Group {
                Button("Paste") { model.paste() }.disabled(!clip.hasFiles)
                Divider()
                Button("New Folder") { model.newFolder() }
                Button("New Text Document") { model.newTextFile() }
                Divider()
            }
            Button("Open Terminal Here") { model.openTerminal(model.current) }
            Button("Show in Finder") { model.reveal([model.current]) }
            Button("Copy Path") { model.copyPath([]) }
            Button("Properties  (⌘I)") { model.showInfo([]) }
            Button("Pin to Quick Access") { Favorites.shared.pin(model.current.path) }
            Divider()
            Toggle("Show Hidden Files", isOn: $model.showHidden)
            Button("Refresh") { model.hardRefresh() }
        } else {
            let items = model.items(for: ids)
            let single = items.count == 1 ? items[0] : nil
            Button("Open") { model.open(ids) }
            Button("Quick Look  (Space)") { model.quickLook(ids) }
            if let single {
                if single.isDir {
                    Button("Open in New Tab") { model.newTab(single.id) }
                    Button("Open in New Window") { openWindow(value: WindowSpec(path: single.id)) }
                    Button("Open Terminal Here") { model.openTerminal(single.url) }
                } else {
                    Menu("Open With") {
                        ForEach(apps(for: single.url), id: \.self) { app in
                            Button(FileManager.default.displayName(atPath: app.path)) { model.open([single.url], with: app) }
                        }
                    }
                }
                if single.isPackage {
                    Button("Show Package Contents") { model.navigate(to: single.url, force: true) }
                }
            }
            Group {
                Divider()
                Button("Cut") { model.cut(ids) }
                Button("Copy") { model.copy(ids) }
                Button("Copy Path") { model.copyPath(ids) }
                if let single, single.isDir {
                    Button("Paste Into Folder") { model.paste(into: single.url) }.disabled(!clip.hasFiles)
                }
            }
            Group {
                Divider()
                Button("Rename") { model.beginRename(ids) }
                Button("Compress to ZIP") { model.compress(ids) }
                Button("Move to Trash") { model.trash(ids) }
                Divider()
            }
            if let single, single.isDir {
                Button("Pin to Quick Access") { Favorites.shared.pin(single.id) }
            }
            Button("Show in Finder") { model.reveal(items.map(\.url)) }
            Divider()
            Button("Properties  (⌘I)") { model.showInfo(ids) }
        }
    }

    func apps(for url: URL) -> [URL] {
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        var seen = Set<String>()
        return all.filter { seen.insert(FileManager.default.displayName(atPath: $0.path)).inserted }.prefix(20).map { $0 }
    }
}

/// Faint bar behind the size text: how big this item is next to the biggest one in the folder.
struct SizeBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.12), Color.accentColor.opacity(fraction > 0.5 ? 0.35 : 0.25)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: max(3, g.size.width * min(1, fraction)))
                .frame(maxHeight: .infinity)
                .padding(.vertical, 2)
        }
    }
}

// MARK: - Bottom status bar

struct StatusBar: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 10) {
            Text("\(model.displayed.count) item\(model.displayed.count == 1 ? "" : "s")")
            if !model.selection.isEmpty {
                Divider().frame(height: 12)
                let (bytes, pending) = model.selectionSize
                Text("\(model.selection.count) selected"
                     + (pending ? "  ·  calculating…" + (bytes > 0 ? " (\(Fmt.size(bytes)) so far)" : "")
                                : "  ·  \(Fmt.size(bytes))"))
            }
            Spacer()
            if model.busy > 0 {
                ProgressView().controlSize(.small)
                Text("Working…")
            }
            Text(model.freeSpace)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

// MARK: - Rename sheet (F2)

struct RenameSheet: View {
    let item: FileItem
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: IconCache.shared.icon(item.id))
                Text("Rename").font(.headline)
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit(name) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Rename") { commit(name) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            name = item.name
            focused = true
            // Select just the name, not the extension (like Windows).
            let base = item.isDir ? item.name : (item.name as NSString).deletingPathExtension
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                    tv.setSelectedRange(NSRange(location: 0, length: (base as NSString).length))
                }
            }
        }
    }
}

// MARK: - Shortcut cheat sheet

struct ShortcutHelp: View {
    let rows: [(String, String)] = [
        ("Enter / double-click", "Open"),
        ("Backspace  or  ⌥↑", "Up one folder"),
        ("⌥← / ⌥→   (⌘[ / ⌘])", "Back / Forward"),
        ("⌘L  or  click address bar", "Type a path (~ works)"),
        ("⌘F", "Search this folder"),
        ("⌘C / ⌘X / ⌘V", "Copy / Cut / Paste files"),
        ("F2", "Rename"),
        ("Delete  or  ⌘⌫", "Move to Trash"),
        ("⌘⇧N", "New folder"),
        ("⌘⇧C", "Copy path"),
        ("⌘⇧T", "Open Terminal here"),
        ("⌘⇧.", "Show/hide hidden files"),
        ("Space", "Quick Look"),
        ("⌘I  or  ⌥Enter", "Properties (size, dates, permissions)"),
        ("⌘T  /  ⌃Tab", "New tab / next tab  (⌘W closes)"),
        ("⌥P", "Preview pane"),
        ("F5  or  ⌘R", "Refresh"),
        ("Type letters", "Jump to file"),
        ("Drag files", "Same disk = move, other disk = copy (⌥ = copy)"),
        ("Ctrl also works", "Ctrl+C/X/V/A/L/F like Windows"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard Shortcuts").font(.headline).padding(.bottom, 4)
            ForEach(rows, id: \.0) { r in
                HStack {
                    Text(r.0).font(.system(.body, design: .monospaced)).frame(width: 230, alignment: .leading)
                    Text(r.1).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }
}
