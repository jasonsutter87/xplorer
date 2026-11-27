import AppKit
import ObjectiveC

/// SwiftUI's Table swallows every file drop that lands on it (its NSTableView accepts the drag, then
/// does nothing), so `.onDrop` on the Table never fires. We take over the NSTableView's dragging-
/// destination methods by giving that one instance a tiny runtime subclass.
final class TableDropHandler: NSObject {
    let update: (NSTableView, NSDraggingInfo) -> NSDragOperation
    let perform: (NSTableView, NSDraggingInfo) -> Bool
    let exit: () -> Void
    init(update: @escaping (NSTableView, NSDraggingInfo) -> NSDragOperation,
         perform: @escaping (NSTableView, NSDraggingInfo) -> Bool,
         exit: @escaping () -> Void) {
        self.update = update; self.perform = perform; self.exit = exit
    }
}

private var handlerKey: UInt8 = 0
private let prefix = "XplorerDrop_"

enum TableDrop {
    static func install(on table: NSTableView, handler: TableDropHandler) {
        objc_setAssociatedObject(table, &handlerKey, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        var types = table.registeredDraggedTypes
        if !types.contains(.fileURL) { types.append(.fileURL); table.registerForDraggedTypes(types) }

        guard let base = object_getClass(table) else { return }
        let baseName = NSStringFromClass(base)
        if baseName.hasPrefix(prefix) { return }        // already installed
        let name = prefix + baseName
        if let existing = NSClassFromString(name) { object_setClass(table, existing); return }
        guard let cls = objc_allocateClassPair(base, name, 0) else { return }

        func add(_ sel: Selector, _ block: Any) {
            guard let m = class_getInstanceMethod(base, sel) else { return }
            class_addMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m))
        }
        let update: @convention(block) (NSTableView, NSDraggingInfo) -> NSDragOperation = { t, info in
            handlerFor(t)?.update(t, info) ?? []
        }
        let prepare: @convention(block) (NSTableView, NSDraggingInfo) -> Bool = { _, _ in true }
        let perform: @convention(block) (NSTableView, NSDraggingInfo) -> Bool = { t, info in
            handlerFor(t)?.perform(t, info) ?? false
        }
        let exit: @convention(block) (NSTableView, NSDraggingInfo?) -> Void = { t, _ in handlerFor(t)?.exit() }
        add(#selector(NSView.draggingEntered(_:)), update)
        add(#selector(NSView.draggingUpdated(_:)), update)
        add(#selector(NSView.prepareForDragOperation(_:)), prepare)
        add(#selector(NSView.performDragOperation(_:)), perform)
        add(#selector(NSView.draggingExited(_:)), exit)
        add(#selector(NSView.concludeDragOperation(_:)), exit)
        add(#selector(NSView.draggingEnded(_:)), exit)
        objc_registerClassPair(cls)
        object_setClass(table, cls)
    }

    private static func handlerFor(_ t: NSTableView) -> TableDropHandler? {
        objc_getAssociatedObject(t, &handlerKey) as? TableDropHandler
    }

    /// File URLs on a drag pasteboard.
    static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// The operation to show: move unless ⌥ is held (or the source only allows copying).
    static func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if !NSEvent.modifierFlags.contains(.option), mask.contains(.move) { return .move }
        if mask.contains(.copy) { return .copy }
        return .generic
    }
}
