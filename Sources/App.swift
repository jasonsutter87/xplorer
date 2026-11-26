import SwiftUI
import Quartz

struct WindowSpec: Codable, Hashable {
    var path: String
    var select: String? = nil
    var token = UUID()
}

@main
struct XplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup(for: WindowSpec.self) { $spec in
            ContentView(spec: $spec)
        } defaultValue: {
            WindowSpec(path: NSHomeDirectory())
        }
        .defaultSize(width: 1150, height: 700)
        .handlesExternalEvents(matching: [])  // folder-open requests go through AppDelegate instead
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static weak var shared: AppDelegate?
    var previewItems: [URL] = []

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    /// Set by the first window: opens a new Xplorer window for (folder, file-to-select).
    static var openHandler: ((String, String?) -> Void)?
    /// Requests that arrived before any window existed (cold launch from `open ~/Downloads`, Dock, etc.).
    static var pending: [(String, String?)] = []
    /// When set, the next window that appears joins this window as a tab (⌘T / "Open in New Tab").
    static weak var tabParent: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // "Reveal in Finder" from other apps arrives as the Finder 'misc/mvis' Apple Event when NSFileViewer = Xplorer.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleReveal(_:reply:)),
            forEventClass: AEEventClass(kAEMiscStandards), andEventID: AEEventID(kAEMakeObjectsVisible))
    }

    @objc func handleReveal(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        var urls: [URL] = []
        let n = direct.numberOfItems
        if n > 0 {
            for i in 1...n { if let u = direct.atIndex(i)?.fileURLValue { urls.append(u) } }
        } else if let u = direct.fileURLValue {
            urls.append(u)
        }
        urls.forEach { route($0, revealOnly: true) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { route($0, revealOnly: false) }
    }

    private func route(_ url: URL, revealOnly: Bool) {
        let path = url.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        let target: (String, String?)
        if isDir.boolValue && !revealOnly {  // open the folder itself; "reveal" shows the parent with it selected
            target = (path, nil)
        } else {
            target = ((path as NSString).deletingLastPathComponent, path)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let h = AppDelegate.openHandler { h(target.0, target.1) } else { AppDelegate.pending.append(target) }
        // Safety net: if the handler belonged to a window that's gone and nothing appeared, open one that takes the request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let anyVisible = NSApp.windows.contains { !($0 is NSPanel) && $0.canBecomeMain && $0.isVisible }
            if !anyVisible {
                if !AppDelegate.pending.contains(where: { $0 == target }) { AppDelegate.pending.append(target) }
                AppDelegate.openFreshWindow()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dock icon clicked while running. `.handlesExternalEvents(matching: [])` stops SwiftUI from doing this itself,
    /// so: un-minimize / bring back an existing window, or open a fresh one if the last window was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let wins = NSApp.windows.filter { !($0 is NSPanel) && $0.canBecomeMain }
        if let w = wins.first(where: \.isVisible) ?? wins.first(where: \.isMiniaturized) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            // Rescue windows stranded on a disconnected display.
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }) { w.center() }
            w.makeKeyAndOrderFront(nil)
        } else {
            Self.openFreshWindow()
        }
        return false
    }

    /// Opens a new window via SwiftUI's own File › New Window item (works with zero windows open).
    static func openFreshWindow() {
        let item = NSApp.mainMenu?.items.lazy.compactMap(\.submenu).flatMap(\.items)
            .first { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == [.command] && $0.title.hasPrefix("New") }
        if let item, let menu = item.menu {
            menu.performActionForItem(at: menu.index(of: item))
        } else {
            openHandler?(NSHomeDirectory(), nil)
        }
    }

    // MARK: Quick Look (Space bar)
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItems[index] as NSURL
    }

    static func toggleQuickLook(_ urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !urls.isEmpty else { return }
        shared?.previewItems = urls
        panel.updateController()
        panel.reloadData()
        panel.orderFront(nil)
    }

    static func updateQuickLook(_ urls: [URL]) {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
              !urls.isEmpty else { return }
        shared?.previewItems = urls
        panel.reloadData()
    }
}
