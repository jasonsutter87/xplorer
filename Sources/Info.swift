import SwiftUI
import AppKit
import CoreServices

// MARK: - Get Info / Properties (⌘I or ⌥Enter) — one small window per request, like Explorer's Properties

enum InfoWindow {
    private static var windows: [NSWindow] = []
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Already open for exactly these items? Just bring it forward.
        if let w = windows.first(where: { ($0.contentViewController as? NSHostingController<InfoView>)?.rootView.m.urls == urls }) {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: InfoView(m: InfoModel(urls: urls)))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = urls.count == 1 ? "\(displayName(urls[0].path)) Properties" : "\(urls.count) Items Properties"
        w.isReleasedWhenClosed = false
        if let key = NSApp.keyWindow {
            w.setFrameTopLeftPoint(NSPoint(x: key.frame.midX - 200 + CGFloat(windows.count % 6) * 24,
                                           y: key.frame.maxY - 60 - CGFloat(windows.count % 6) * 24))
        } else {
            w.center()
        }
        // Closing drops the model, which stops any size calculation still running.
        let key = ObjectIdentifier(w)
        observers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            windows.removeAll { ObjectIdentifier($0) == key }
            if let o = observers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(o) }
        }
        windows.append(w)
        w.makeKeyAndOrderFront(nil)
    }
}

final class InfoModel: ObservableObject {
    let urls: [URL]
    var single: URL? { urls.count == 1 ? urls[0] : nil }

    // Size (filled in progressively in the background)
    @Published var bytes: Int64 = 0
    @Published var onDisk: Int64 = 0
    @Published var files = 0
    @Published var folders = 0
    @Published var counting = true

    // Single-item details
    @Published var kind = ""
    @Published var isFolder = false
    @Published var created: Date?
    @Published var modified: Date?
    @Published var lastOpened: Date?
    @Published var owner = ""
    @Published var group = ""
    @Published var perms = 0
    @Published var hidden = false
    @Published var locked = false
    @Published var linkTarget: String?
    @Published var version: String?
    @Published var opensWith: String?
    @Published var error: String?

    init(urls: [URL]) {
        self.urls = urls
        readAttributes()
        measure()
    }

    var location: String? {
        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        return parents.count == 1 ? parents.first : nil
    }

    func readAttributes() {
        guard let url = single else {
            kind = "Multiple items"
            return
        }
        let path = url.path
        let fm = FileManager.default
        let rv = try? url.resourceValues(forKeys: [
            .localizedTypeDescriptionKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isUserImmutableKey,
            .creationDateKey, .contentModificationDateKey, .isSymbolicLinkKey,
        ])
        kind = rv?.localizedTypeDescription ?? "File"
        isFolder = rv?.isDirectory == true
        if isFolder && rv?.isPackage != true { kind = "File folder" }
        created = rv?.creationDate
        modified = rv?.contentModificationDate
        hidden = rv?.isHidden ?? false
        locked = rv?.isUserImmutable ?? false
        if let attrs = try? fm.attributesOfItem(atPath: path) {
            owner = attrs[.ownerAccountName] as? String ?? ""
            group = attrs[.groupOwnerAccountName] as? String ?? ""
            perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        }
        if rv?.isSymbolicLink == true { linkTarget = try? fm.destinationOfSymbolicLink(atPath: path) }
        if let md = MDItemCreateWithURL(nil, url as CFURL),
           let d = MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date { lastOpened = d }
        if rv?.isPackage == true, let b = Bundle(url: url) {
            let short = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let build = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            version = [short, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            if version?.isEmpty == true { version = nil }
        }
        if !isFolder, let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            opensWith = fm.displayName(atPath: app.path)
        }
    }

    /// Walk everything selected, publishing running totals ~4×/sec so big folders count up visibly.
    private func measure() {
        let urls = self.urls
        let singleFolder = single.flatMap { u in isFolder ? u.path : nil }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                             .fileSizeKey, .totalFileAllocatedSizeKey, .isVolumeKey]
            var b: Int64 = 0, d: Int64 = 0, f = 0, fo = 0
            var last = Date()
            func add(_ v: URLResourceValues) {
                if v.isDirectory == true && v.isSymbolicLink != true { fo += 1; return }
                f += 1
                b += Int64(v.fileSize ?? 0)
                d += Int64(v.totalFileAllocatedSize ?? 0)
            }
            func publish(done: Bool) {
                let (b2, d2, f2, fo2) = (b, d, f, fo)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.bytes = b2; self.onDisk = d2; self.files = f2; self.folders = fo2
                    if done { self.counting = false }
                }
            }
            for url in urls {
                guard let v = try? url.resourceValues(forKeys: keys) else { continue }
                guard v.isDirectory == true, v.isSymbolicLink != true else { add(v); continue }
                guard let en = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
                else { continue }
                if urls.count > 1 { fo += 1 }
                while let u = en.nextObject() as? URL {
                    if self == nil { return }  // window closed
                    guard let cv = try? u.resourceValues(forKeys: keys) else { continue }
                    if cv.isVolume == true { en.skipDescendants(); continue }
                    add(cv)
                    if Date().timeIntervalSince(last) > 0.25 { last = Date(); publish(done: false) }
                }
            }
            if let singleFolder { FolderSizer.shared.store(singleFolder, b) }
            publish(done: true)
        }
    }

    // MARK: Edits

    func setPerm(_ bit: Int, _ on: Bool) {
        guard let url = single else { return }
        let new = on ? perms | bit : perms & ~bit
        do {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: new)], ofItemAtPath: url.path)
            perms = new
            error = nil
        } catch { self.error = (error as NSError).localizedDescription }
    }

    func setHidden(_ on: Bool) { setFlag { $0.isHidden = on }; readAttributes() }
    func setLocked(_ on: Bool) { setFlag { $0.isUserImmutable = on }; readAttributes() }

    private func setFlag(_ change: (inout URLResourceValues) -> Void) {
        guard var url = single else { return }
        var rv = URLResourceValues()
        change(&rv)
        do { try url.setResourceValues(rv); error = nil }
        catch { self.error = (error as NSError).localizedDescription }
    }
}

struct InfoView: View {
    @ObservedObject var m: InfoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                if m.single != nil { row("Type", m.kind) }
                if let loc = m.location { row("Location", loc, copyable: true) }
                if let t = m.linkTarget { row("Points to", t, copyable: true) }
                if let ver = m.version { row("Version", ver) }
                if let app = m.opensWith { row("Opens with", app) }
                GridRow { Divider().gridCellColumns(2) }
                row("Size", sizeText(m.bytes))
                row("Size on disk", sizeText(m.onDisk))
                if m.isFolder || m.urls.count > 1 {
                    row("Contains", "\(m.files.formatted()) files, \(m.folders.formatted()) folders" + (m.counting ? "…" : ""))
                }
                if m.single != nil {
                    GridRow { Divider().gridCellColumns(2) }
                    row("Created", date(m.created))
                    row("Modified", date(m.modified))
                    row("Last opened", date(m.lastOpened))
                }
            }
            if m.single != nil {
                Divider()
                attributes
                Divider()
                permissions
            }
            if let err = m.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            // Esc closes, like a dialog.
            Button("") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        }
        .padding(18)
        .frame(width: 400)
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: bigIcon).resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.single.map { displayName($0.path) } ?? "\(m.urls.count) items")
                    .font(.headline).textSelection(.enabled).lineLimit(2)
                Text(m.kind).foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            if m.counting { ProgressView().controlSize(.small) }
        }
    }

    var bigIcon: NSImage {
        let i = m.single.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .folder)
        let copy = i.copy() as! NSImage
        copy.size = NSSize(width: 64, height: 64)
        return copy
    }

    var attributes: some View {
        HStack(spacing: 20) {
            Text("Attributes").foregroundStyle(.secondary)
            Toggle("Hidden", isOn: Binding(get: { m.hidden }, set: { m.setHidden($0) }))
            Toggle("Locked", isOn: Binding(get: { m.locked }, set: { m.setLocked($0) }))
                .help("Locked items can't be changed, renamed or moved to Trash")
        }
        .toggleStyle(.checkbox)
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Permissions").foregroundStyle(.secondary)
                Spacer()
                Text(symbolic(m.perms) + "  (\(String(m.perms & 0o777, radix: 8)))")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    Text("Read").font(.caption).foregroundStyle(.secondary)
                    Text("Write").font(.caption).foregroundStyle(.secondary)
                    Text("Execute").font(.caption).foregroundStyle(.secondary)
                }
                permRow("Owner (\(m.owner))", shift: 6)
                permRow("Group (\(m.group))", shift: 3)
                permRow("Everyone", shift: 0)
            }
            .toggleStyle(.checkbox)
            .disabled(m.locked)
        }
    }

    func permRow(_ who: String, shift: Int) -> some View {
        GridRow {
            Text(who).lineLimit(1)
            ForEach([4, 2, 1], id: \.self) { b in
                let bit = b << shift
                Toggle("", isOn: Binding(get: { m.perms & bit != 0 }, set: { m.setPerm(bit, $0) }))
                    .labelsHidden()
            }
        }
    }

    @ViewBuilder
    func row(_ label: String, _ value: String, copyable: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            HStack(spacing: 4) {
                Text(value).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                if copyable {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.caption) }
                    .buttonStyle(.borderless).help("Copy")
                }
            }
        }
    }

    func sizeText(_ b: Int64) -> String {
        "\(Fmt.size(b))  (\(b.formatted()) bytes)" + (m.counting ? "…" : "")
    }

    func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(date: .long, time: .shortened)
    }

    func symbolic(_ p: Int) -> String {
        let prefix = m.linkTarget != nil ? "l" : (m.isFolder ? "d" : "-")
        return prefix + (0..<9).map { i -> String in
            let bit = 1 << (8 - i)
            return p & bit != 0 ? ["r", "w", "x"][i % 3] : "-"
        }.joined()
    }
}
