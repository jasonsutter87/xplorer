import SwiftUI
import AppKit
import Quartz

// MARK: - Preview pane (⌥P, like Alt+P in Explorer): live Quick Look of the selection + a few details

struct PreviewPane: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        let sel = model.selectedItems
        VStack(spacing: 0) {
            if sel.count == 1, let item = sel.first {
                QuickLookView(url: item.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                details(item)
            } else {
                Spacer()
                Image(systemName: sel.isEmpty ? "eye" : "square.stack.3d.up")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 6)
                Text(sel.isEmpty ? "Select a file to preview." : "\(sel.count) items selected")
                    .foregroundStyle(.secondary)
                if sel.count > 1 {
                    let (bytes, pending) = model.selectionSize
                    Text(pending ? "Calculating…" : Fmt.size(bytes)).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    func details(_ item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.name).font(.headline).lineLimit(2).textSelection(.enabled)
            Text(item.kind).foregroundStyle(.secondary)
            HStack {
                Text(item.size >= 0 ? Fmt.size(item.size) : (item.measurable ? "Calculating…" : ""))
                Spacer()
                Text(Fmt.date.string(from: item.modified))
            }
            .foregroundStyle(.secondary)
            Button("Properties…") { model.showInfo([item.id]) }
                .buttonStyle(.link).padding(.top, 2)
        }
        .font(.system(size: 11))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true          // play audio/video previews without an extra click
        v.shouldCloseWithWindow = true
        v.previewItem = url as NSURL
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) {
        v.close()   // stop any playing media when the pane hides or the item changes view type
    }
}
