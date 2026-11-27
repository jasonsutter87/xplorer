import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers

// MARK: - File item

let itemKeys: [URLResourceKey] = [
    .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
    .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey,
]

struct FileItem: Identifiable, Hashable {
    let id: String          // absolute path (no trailing slash)
    let url: URL
    let name: String
    let isDir: Bool         // a folder you can walk into (not an .app bundle)
    let isPackage: Bool
    let isHidden: Bool
    let measurable: Bool    // a real directory (incl. .app bundles): its size is the sum of everything inside
    var size: Int64         // -1 = not known yet (folder size still being calculated)
    let modified: Date
    let kind: String

    init(url raw: URL) {
        let path = raw.path
        url = URL(fileURLWithPath: path, isDirectory: false)
        id = path
        name = raw.lastPathComponent
        let v = try? raw.resourceValues(forKeys: Set(itemKeys))
        var dir = v?.isDirectory ?? false
        if v?.isSymbolicLink == true {
            var d: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &d) { dir = d.boolValue }
        }
        isPackage = v?.isPackage ?? false
        isDir = dir && !isPackage
        isHidden = v?.isHidden ?? name.hasPrefix(".")
        measurable = dir
        size = dir ? (FolderSizer.shared.cached(path) ?? -1) : Int64(v?.fileSize ?? 0)
        modified = v?.contentModificationDate ?? .distantPast
        kind = isDir ? "File folder" : (v?.localizedTypeDescription ?? "File")
    }
}

func isNavigableDir(_ url: URL) -> Bool {
    var d: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &d), d.boolValue else { return false }
    let pkg = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    return !pkg
}

func displayName(_ path: String) -> String {
    if path == "/" {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey])
        return v?.volumeLocalizedName ?? "Macintosh HD"
    }
    return (path as NSString).lastPathComponent
}

enum Fmt {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 16, height: 16)
        if cache.count > 5000 { cache.removeAll() }
        cache[path] = i
        return i
    }
}

// MARK: - Folder sizes (recursive, background, cached app-wide)

final class FolderSizer {
    static let shared = FolderSizer()
    private var cache: [String: Int64] = [:]
    private let lock = NSLock()

    func cached(_ path: String) -> Int64? { lock.lock(); defer { lock.unlock() }; return cache[path] }
    func store(_ path: String, _ size: Int64) { lock.lock(); cache[path] = size; lock.unlock() }
    func clear() { lock.lock(); cache.removeAll(); lock.unlock() }

    /// Forget `path`, everything inside it, and every folder containing it (their totals changed too).
    func invalidate(_ paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        for p in paths {
            cache = cache.filter { k, _ in !(k == p || k.hasPrefix(p + "/") || p.hasPrefix(k == "/" ? "/" : k + "/")) }
        }
    }

    /// Sum of file sizes under `url`. Doesn't follow symlinks or cross into other volumes. nil = cancelled.
    static func compute(_ url: URL, cancelled: () -> Bool) -> Int64? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isVolumeKey]
        let keySet = Set(keys)
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var n = 0
        while let u = en.nextObject() as? URL {
            n += 1
            if n & 1023 == 0, cancelled() { return nil }
            guard let v = try? u.resourceValues(forKeys: keySet) else { continue }
            if v.isVolume == true { en.skipDescendants(); continue }  // e.g. /System/Volumes/Data, mounted disks
            if v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }
}

// MARK: - Shared state: clipboard (with real Cut) & Quick Access pins

final class Clip: ObservableObject {
    static let shared = Clip()
    @Published private(set) var cutPaths: Set<String> = []
    private var cutChangeCount = -1

    func write(_ urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        if cut {
            cutPaths = Set(urls.map(\.path))
            cutChangeCount = pb.changeCount
        } else {
            cutPaths = []
            cutChangeCount = -1
        }
    }

    func read() -> (urls: [URL], isCut: Bool) {
        let pb = NSPasteboard.general
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let isCut = pb.changeCount == cutChangeCount
        if !isCut && !cutPaths.isEmpty { cutPaths = [] } // something else was copied since
        return (urls, isCut)
    }

    var hasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func finishCut() {
        cutPaths = []
        cutChangeCount = -1
    }
}

final class Favorites: ObservableObject {
    static let shared = Favorites()
    @Published var paths: [String] {
        didSet { UserDefaults.standard.set(paths, forKey: "pinned") }
    }
    init() {
        let home = NSHomeDirectory()
        paths = UserDefaults.standard.stringArray(forKey: "pinned") ?? [
            home + "/Desktop", home + "/Documents", home + "/Downloads", "/Applications",
        ]
    }
    func pin(_ path: String) { if !paths.contains(path) { paths.append(path) } }
    func unpin(_ path: String) { paths.removeAll { $0 == path } }
}

// MARK: - Tree

struct TreeRow: Identifiable {
    let id: String      // "t:<root>:<path>"
    let path: String
    let name: String
    let depth: Int
    let isExpanded: Bool
    let isLeaf: Bool
    let isVolume: Bool
}

// MARK: - Browser model (one per window)

final class BrowserModel: ObservableObject {
    @Published private(set) var current: URL
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var displayed: [FileItem] = []
    @Published var selection: Set<String> = [] {
        didSet { AppDelegate.updateQuickLook(selectedURLs) }
    }
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)] {
        didSet { recompute() }
    }
    @Published var filter = "" { didSet { if filter != oldValue { recompute() } } }
    @Published var showHidden = UserDefaults.standard.bool(forKey: "showHidden") {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "showHidden")
            childCache.removeAll()
            reload()
        }
    }
    @Published var loadError: String?
    @Published var alertMessage: String?
    @Published var renameTarget: FileItem?
    @Published var addressEditing = false
    @Published var searchFocusToken = 0
    @Published var expanded: Set<String> = []
    @Published var sidebarSelection: String?
    @Published var busy = 0
    @Published var dropTarget: String?   // folder row highlighted while dragging over the list
    @Published var freeSpace = ""
    @Published var roots: [URL] = []
    @Published private(set) var maxSize: Int64 = 0   // biggest item in view, for the size bars
    @Published var showPreview = UserDefaults.standard.bool(forKey: "showPreview") {
        didSet { UserDefaults.standard.set(showPreview, forKey: "showPreview") }
    }
    @Published var showSizeBars = UserDefaults.standard.object(forKey: "showSizeBars") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSizeBars, forKey: "showSizeBars") }
    }

    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []
    weak var window: NSWindow?
    private var childCache: [String: [String]] = [:]
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var keyMonitor: Any?
    private var typeBuffer = ""
    private var typeBufferTime = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private let sizeQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()
    private var sizing: Set<String> = []
    private var sizeFlush: DispatchWorkItem?

    init(start: URL, select: String? = nil) {
        current = URL(fileURLWithPath: NSHomeDirectory())
        refreshRoots()
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refreshRoots() })
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.handleKey(e) ? nil : e
        }
        navigate(to: isNavigableDir(start) ? start : URL(fileURLWithPath: NSHomeDirectory()), record: false, select: select)
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        watcher?.cancel()
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { current.path != "/" }

    var selectedItems: [FileItem] { displayed.filter { selection.contains($0.id) } }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    func items(for ids: Set<String>) -> [FileItem] {
        let found = items.filter { ids.contains($0.id) }
        return found.isEmpty ? ids.map { FileItem(url: URL(fileURLWithPath: $0)) } : found
    }

    // MARK: Navigation

    func navigate(to url: URL, record: Bool = true, force: Bool = false, select: String? = nil) {
        let u = URL(fileURLWithPath: url.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: false)
        guard force || isNavigableDir(u) else {
            if FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.open(u) }
            else { alertMessage = "Can't find '\(url.path)'." }
            return
        }
        if record && u.path != current.path {
            backStack.append(current)
            forwardStack.removeAll()
        }
        current = u
        filter = ""
        selection = []
        sizeQueue.cancelAllOperations()
        sizing.removeAll()
        load()
        if let select { selection = [select]; scrollToSelection() }
        watch()
        revealInTree()
        updateFreeSpace()
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(current)
        let from = current.path
        navigate(to: prev, record: false, force: true, select: from.hasPrefix(prev.path) ? childOf(prev.path, toward: from) : nil)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        navigate(to: next, record: false, force: true)
    }

    func goUp() {
        guard canGoUp else { return }
        let from = current.path
        navigate(to: current.deletingLastPathComponent(), select: from)
    }

    private func childOf(_ parent: String, toward path: String) -> String? {
        let rest = path.dropFirst(parent == "/" ? 1 : parent.count + 1)
        guard let first = rest.split(separator: "/").first else { return nil }
        return (parent as NSString).appendingPathComponent(String(first))
    }

    func go(typed: String) {
        var p = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("\"") && p.hasSuffix("\"") && p.count > 1 { p = String(p.dropFirst().dropLast()) }
        if p.isEmpty { return }
        p = (p as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = (current.path as NSString).appendingPathComponent(p) }
        addressEditing = false
        navigate(to: URL(fileURLWithPath: p))
        focusTable()
    }

    // MARK: Loading

    func load() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: current, includingPropertiesForKeys: itemKeys,
                options: showHidden ? [] : [.skipsHiddenFiles])
            items = urls.map(FileItem.init)
            loadError = nil
        } catch {
            items = []
            loadError = (error as NSError).localizedDescription
        }
        let ids = Set(items.map(\.id))
        let kept = selection.intersection(ids)
        if kept != selection { selection = kept }
        recompute()
        measureFolders()
    }

    /// Kick off background size calculations for folders in this listing that we don't know yet.
    private func measureFolders() {
        for item in items where item.measurable && item.size < 0 && !sizing.contains(item.id) {
            let path = item.id
            sizing.insert(path)
            let op = BlockOperation()
            op.addExecutionBlock { [weak self, weak op] in
                guard let size = FolderSizer.compute(URL(fileURLWithPath: path), cancelled: { op?.isCancelled ?? true })
                else { return }
                FolderSizer.shared.store(path, size)
                DispatchQueue.main.async { self?.applySize(path, size) }
            }
            sizeQueue.addOperation(op)
        }
    }

    private func applySize(_ path: String, _ size: Int64) {
        sizing.remove(path)
        guard let i = items.firstIndex(where: { $0.id == path }) else { return }
        items[i].size = size
        // Coalesce: many small folders finish at once; re-sort/redraw at most ~6×/sec.
        guard sizeFlush == nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.sizeFlush = nil; self?.recompute() }
        sizeFlush = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    /// Selected items' total, and whether any selected folder is still being measured.
    var selectionSize: (bytes: Int64, pending: Bool) {
        let sel = selectedItems
        return (sel.filter { $0.size > 0 }.reduce(0) { $0 + $1.size }, sel.contains { $0.measurable && $0.size < 0 })
    }

    func reload() {
        childCache.removeValue(forKey: current.path)
        load()
        updateFreeSpace()
    }

    func hardRefresh() {
        childCache.removeAll()
        FolderSizer.shared.clear()
        sizeQueue.cancelAllOperations()
        sizing.removeAll()
        reload()
        objectWillChange.send()
    }

    func recompute() {
        var list = items
        if !filter.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        list.sort(using: sortOrder)
        displayed = list.filter(\.isDir) + list.filter { !$0.isDir }
        maxSize = list.map(\.size).max() ?? 0
    }

    private func watch() {
        watcher?.cancel()
        watcher = nil
        let fd = Darwin.open(current.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    private func updateFreeSpace() {
        let v = try? current.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let cap = v?.volumeAvailableCapacityForImportantUsage {
            freeSpace = Fmt.size(cap) + " free"
        } else {
            freeSpace = ""
        }
    }

    // MARK: Tree

    func refreshRoots() {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        roots = [URL(fileURLWithPath: NSHomeDirectory())] + vols.map { URL(fileURLWithPath: $0.path) }
    }

    func treeChildren(_ path: String) -> [String] {
        if let c = childCache[path] { return c }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
            options: showHidden ? [] : [.skipsHiddenFiles])) ?? []
        let dirs = urls.filter(isNavigableDir)
            .map(\.path)
            .sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
        childCache[path] = dirs
        return dirs
    }

    var treeRows: [TreeRow] {
        var rows: [TreeRow] = []
        func add(_ path: String, root: Int, depth: Int) {
            let exp = expanded.contains(path)
            let leaf = childCache[path]?.isEmpty == true
            let name: String
            if depth == 0 {
                name = path == NSHomeDirectory() ? "Home (\(NSUserName()))" : displayName(path)
            } else {
                name = displayName(path)
            }
            rows.append(TreeRow(id: "t:\(root):\(path)", path: path, name: name, depth: depth,
                                isExpanded: exp && !leaf, isLeaf: leaf, isVolume: depth == 0 && root > 0))
            guard exp, depth < 40 else { return }
            for c in treeChildren(path) { add(c, root: root, depth: depth + 1) }
        }
        for (i, r) in roots.enumerated() { add(r.path, root: i, depth: 0) }
        return rows
    }

    func toggleExpand(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else {
            childCache.removeValue(forKey: path)
            expanded.insert(path)
        }
    }

    /// Expand the tree down to the current folder and highlight it (like Explorer's nav pane).
    private func revealInTree() {
        let p = current.path
        var best: (Int, String)?
        for (i, r) in roots.enumerated() {
            let rp = r.path
            if p == rp || p.hasPrefix(rp == "/" ? "/" : rp + "/") {
                if best == nil || rp.count > best!.1.count { best = (i, rp) }
            }
        }
        guard let (idx, rootPath) = best else { sidebarSelection = nil; return }
        var anc = (p as NSString).deletingLastPathComponent
        var toExpand: [String] = []
        if p == rootPath && idx == 0 { toExpand.append(rootPath) }
        if p != rootPath {
            while true {
                toExpand.append(anc)
                if anc == rootPath || anc == "/" { break }
                anc = (anc as NSString).deletingLastPathComponent
            }
        }
        let missing = toExpand.filter { !expanded.contains($0) }
        if !missing.isEmpty { expanded.formUnion(missing) }
        sidebarSelection = "t:\(idx):\(p)"
    }

    // MARK: Opening

    func open(_ ids: Set<String>) {
        let list = items(for: ids)
        if list.count == 1, list[0].isDir {
            navigate(to: list[0].url)
            return
        }
        for item in list where !item.isDir { NSWorkspace.shared.open(item.url) }
        if let d = list.first(where: \.isDir) { navigate(to: d.url) }
    }

    func open(_ urls: [URL], with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func openTerminal(_ url: URL) {
        let ws = NSWorkspace.shared
        guard let term = ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        ws.open([url], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Always the real Finder (Xplorer may be the system file viewer, so don't use activateFileViewerSelecting).
    func reveal(_ urls: [URL]) {
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", finder.path, "-R"] + urls.map(\.path)
        try? p.run()
    }

    /// New tab in this window (⌘T), showing `path` (default: the current folder).
    func newTab(_ path: String? = nil) {
        AppDelegate.tabParent = window
        AppDelegate.openHandler?(path ?? current.path, nil)
    }

    /// Properties window for the selection, or for the current folder when nothing is selected.
    func showInfo(_ ids: Set<String>) {
        InfoWindow.show(ids.isEmpty ? [current] : items(for: ids).map(\.url))
    }

    func quickLook(_ ids: Set<String>) {
        let urls = items(for: ids).map(\.url)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true {
            AppDelegate.updateQuickLook(urls)   // already open: switch to these instead of closing
        } else {
            AppDelegate.toggleQuickLook(urls)
        }
    }

    // MARK: Clipboard

    func copy(_ ids: Set<String>) { if !ids.isEmpty { Clip.shared.write(items(for: ids).map(\.url), cut: false) } }
    func cut(_ ids: Set<String>) { if !ids.isEmpty { Clip.shared.write(items(for: ids).map(\.url), cut: true) } }

    func copyPath(_ ids: Set<String>) {
        let paths = ids.isEmpty ? [current.path] : ids.sorted()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func paste(into dest: URL? = nil) {
        let (urls, isCut) = Clip.shared.read()
        guard !urls.isEmpty else { return }
        transfer(urls, to: dest ?? current, move: isCut)
        if isCut { Clip.shared.finishCut() }
    }

    /// Copy or move files. Never overwrites: name clashes become "name - Copy.ext" (Windows style).
    func transfer(_ urls: [URL], to dest: URL, move: Bool) {
        let fm = FileManager.default
        busy += 1
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            var created: [String] = []
            for src in urls {
                let srcDir = src.deletingLastPathComponent().path
                if move && srcDir == dest.path { continue }
                if dest.path == src.path || dest.path.hasPrefix(src.path + "/") {
                    errors.append("Can't put '\(src.lastPathComponent)' inside itself.")
                    continue
                }
                let target = Self.uniqueURL(for: src.lastPathComponent, in: dest, copyStyle: true)
                do {
                    if move { try fm.moveItem(at: src, to: target) } else { try fm.copyItem(at: src, to: target) }
                    created.append(target.path)
                } catch {
                    errors.append((error as NSError).localizedDescription)
                }
            }
            DispatchQueue.main.async {
                self.busy -= 1
                self.childCache.removeAll()
                FolderSizer.shared.invalidate([dest.path] + (move ? urls.map(\.path) : []))
                self.reload()
                if dest.path == self.current.path, !created.isEmpty {
                    self.selection = Set(created)
                    self.scrollToSelection()
                }
                if !errors.isEmpty { self.alertMessage = errors.joined(separator: "\n") }
            }
        }
    }

    static func uniqueURL(for name: String, in dir: URL, copyStyle: Bool) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 1
        repeat {
            let suffix = copyStyle ? (n == 1 ? " - Copy" : " - Copy (\(n))") : " (\(n + 1))"
            candidate = dir.appendingPathComponent(base + suffix + (ext.isEmpty ? "" : "." + ext))
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    // MARK: File operations

    func trash(_ ids: Set<String>) {
        let urls = items(for: ids).map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { _, error in
            DispatchQueue.main.async {
                if let error { self.alertMessage = error.localizedDescription }
                self.childCache.removeAll()
                FolderSizer.shared.invalidate(urls.map(\.path))
                self.reload()
            }
        }
    }

    func beginRename(_ ids: Set<String>) {
        guard let first = items(for: ids).first else { return }
        renameTarget = first
    }

    func commitRename(_ item: FileItem, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        renameTarget = nil
        guard !name.isEmpty, name != item.name else { return }
        guard !name.contains("/") else { alertMessage = "A file name can't contain '/'."; return }
        let target = item.url.deletingLastPathComponent().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) && target.path.lowercased() != item.id.lowercased() {
            alertMessage = "'\(name)' already exists here."
            return
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            childCache.removeAll()
            FolderSizer.shared.invalidate([item.id])
            reload()
            selection = [target.path]
        } catch {
            alertMessage = (error as NSError).localizedDescription
        }
    }

    func newFolder() {
        let url = Self.uniqueURL(for: "New Folder", in: current, copyStyle: false)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            created(url)
        } catch { alertMessage = (error as NSError).localizedDescription }
    }

    func newTextFile() {
        let url = Self.uniqueURL(for: "New Text Document.txt", in: current, copyStyle: false)
        if FileManager.default.createFile(atPath: url.path, contents: Data()) { created(url) }
        else { alertMessage = "Couldn't create a file here." }
    }

    private func created(_ url: URL) {
        childCache.removeValue(forKey: current.path)
        load()
        selection = [url.path]
        scrollToSelection()
        renameTarget = items.first { $0.id == url.path }
    }

    func compress(_ ids: Set<String>) {
        let list = items(for: ids)
        guard !list.isEmpty else { return }
        let dir = current
        let zipName = list.count == 1 ? list[0].name + ".zip" : "Archive.zip"
        let dest = Self.uniqueURL(for: zipName, in: dir, copyStyle: false)
        busy += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            if list.count == 1 {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", list[0].id, dest.path]
            } else {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                p.currentDirectoryURL = dir
                p.arguments = ["-r", "-q", dest.path] + list.map(\.name)
            }
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.busy -= 1
                self.reload()
                if p.terminationStatus == 0 { self.selection = [dest.path]; self.scrollToSelection() }
                else { self.alertMessage = "Couldn't create the zip file." }
            }
        }
    }

    func eject(_ path: String) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
            if current.path.hasPrefix(path) { navigate(to: URL(fileURLWithPath: NSHomeDirectory())) }
        } catch { alertMessage = (error as NSError).localizedDescription }
    }

    func dropFiles(_ providers: [NSItemProvider], into dest: URL) -> Bool {
        let copyOnly = NSEvent.modifierFlags.contains(.option)
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                if let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { self.handleDrop(urls, into: dest, copyOnly: copyOnly) }
        return true
    }

    /// Same disk = move, different disk = copy (like Windows). Hold Option to force copy.
    func handleDrop(_ urls: [URL], into dest: URL, copyOnly: Bool = NSEvent.modifierFlags.contains(.option)) {
        // Dropping a folder back onto itself is a no-op, not an error.
        let urls = urls.filter { $0.isFileURL && $0.standardizedFileURL.path != dest.standardizedFileURL.path }
        guard !urls.isEmpty else { return }
        let destVol = (try? dest.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let srcVol = (try? urls[0].resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let sameDisk = destVol != nil && destVol == srcVol
        transfer(urls, to: dest, move: sameDisk && !copyOnly)
    }

    /// Drag payload: a file URL, which Terminal/iTerm turn into an escaped path and Finder/other apps accept as the file.
    static func dragProvider(for url: URL) -> NSItemProvider {
        let p = NSItemProvider()
        p.suggestedName = url.lastPathComponent
        p.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in
            done(url.dataRepresentation, nil); return nil
        }
        return p
    }

    // MARK: Table helpers (SwiftUI's Table can't scroll programmatically, so poke the NSTableView)

    private func fileTable() -> NSTableView? {
        func find(_ v: NSView) -> NSTableView? {
            if let t = v as? NSTableView, t.tableColumns.count >= 4 { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        guard let root = window?.contentView else { return nil }
        return find(root)
    }

    /// Drag & drop onto the file list: on a folder row = into that folder; anywhere else = into the current folder.
    func installTableDrop() {
        guard let t = fileTable() else { return }
        func folder(_ t: NSTableView, _ info: NSDraggingInfo) -> FileItem? {
            let row = t.row(at: t.convert(info.draggingLocation, from: nil))
            guard row >= 0, row < displayed.count, displayed[row].isDir else { return nil }
            return displayed[row]
        }
        TableDrop.install(on: t, handler: TableDropHandler(
            update: { [weak self] t, info in
                guard let self, !TableDrop.fileURLs(info).isEmpty else { return [] }
                let target = folder(t, info)?.id
                if self.dropTarget != target { self.dropTarget = target }
                return TableDrop.operation(info)
            },
            perform: { [weak self] t, info in
                guard let self else { return false }
                let urls = TableDrop.fileURLs(info)
                let dest = folder(t, info)?.url ?? self.current
                self.dropTarget = nil
                guard !urls.isEmpty else { return false }
                self.handleDrop(urls, into: dest)
                return true
            },
            exit: { [weak self] in if self?.dropTarget != nil { self?.dropTarget = nil } }))
    }

    func scrollToSelection() {
        DispatchQueue.main.async {
            guard let t = self.fileTable(),
                  let idx = self.displayed.firstIndex(where: { self.selection.contains($0.id) }) else { return }
            t.scrollRowToVisible(idx)
        }
    }

    func focusTable() {
        DispatchQueue.main.async {
            if let t = self.fileTable() { self.window?.makeFirstResponder(t) }
            self.installTableDrop()
        }
    }

    // MARK: Keyboard (Explorer-style shortcuts)

    private func handleKey(_ e: NSEvent) -> Bool {
        guard let window, e.window === window else { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = (e.charactersIgnoringModifiers ?? "").lowercased()
        let cmdOrCtrl = mods == [.command] || mods == [.control]
        let cmdShift = mods == [.command, .shift] || mods == [.control, .shift]

        // Let text fields (address bar, search) keep their keys.
        if window.firstResponder is NSText {
            if e.keyCode == 53, addressEditing { addressEditing = false; focusTable(); return true }
            if e.keyCode == 53, !filter.isEmpty { filter = ""; focusTable(); return true }
            if e.keyCode == 125, mods.isEmpty, !addressEditing { focusTable(); return true } // ↓ from search into list
            return false
        }

        switch e.keyCode {
        case 36, 76: // Return  (⌥Return = Properties, like Alt+Enter on Windows)
            if mods.isEmpty, !selection.isEmpty { open(selection); return true }
            if mods == [.option] { showInfo(selection); return true }
        case 125 where mods == [.command]: // ⌘↓ open (Finder habit)
            if !selection.isEmpty { open(selection); return true }
        case 51: // Backspace
            if mods.isEmpty { goUp(); return true }
            if mods == [.command] { trash(selection); return true }
        case 117: // Forward delete
            trash(selection); return true
        case 120: // F2
            beginRename(selection); return true
        case 96: // F5
            hardRefresh(); return true
        case 49 where mods.isEmpty: // Space = Quick Look
            AppDelegate.toggleQuickLook(selectedURLs); return true
        case 123 where mods == [.option] || mods == [.command]: // ← back
            goBack(); return true
        case 124 where mods == [.option] || mods == [.command]: // → forward
            goForward(); return true
        case 126 where mods == [.option] || mods == [.command]: // ↑ up
            goUp(); return true
        case 33 where mods == [.command]: goBack(); return true      // ⌘[
        case 30 where mods == [.command]: goForward(); return true   // ⌘]
        case 47 where mods == [.command, .shift]: showHidden.toggle(); return true // ⌘⇧.
        case 35 where mods == [.option]: showPreview.toggle(); return true          // ⌥P preview pane
        case 53: // Esc
            if !filter.isEmpty { filter = "" } else { selection = [] }
            return true
        default: break
        }

        if cmdOrCtrl {
            switch chars {
            case "c": copy(selection); return true
            case "x": cut(selection); return true
            case "v": paste(); return true
            case "a": selection = Set(displayed.map(\.id)); return true
            case "l": addressEditing = true; return true
            case "f": searchFocusToken += 1; return true
            case "r": hardRefresh(); return true
            case "i": showInfo(selection); return true
            case "t": newTab(); return true
            default: break
            }
        }
        if cmdShift {
            switch chars {
            case "n": newFolder(); return true
            case "c": copyPath(selection); return true
            case "t": openTerminal(current); return true
            default: break
            }
        }
        if mods.isEmpty || mods == [.shift], let ch = e.characters, ch.count == 1,
           ch.rangeOfCharacter(from: .alphanumerics.union(.punctuationCharacters)) != nil {
            typeSelect(ch)
            return true
        }
        return false
    }

    /// Type a few letters to jump to a file (Explorer/Finder type-ahead).
    private func typeSelect(_ ch: String) {
        let now = Date()
        typeBuffer = now.timeIntervalSince(typeBufferTime) > 1.0 ? ch : typeBuffer + ch
        typeBufferTime = now
        let q = typeBuffer.lowercased()
        let match = displayed.first { $0.name.lowercased().hasPrefix(q) }
            ?? (q.count > 1 ? nil : displayed.first { $0.name.lowercased().hasPrefix(String(q.prefix(1))) })
        if let match {
            selection = [match.id]
            scrollToSelection()
        }
    }
}
