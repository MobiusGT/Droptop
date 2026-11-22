import AppKit
import SwiftUI

struct ShelfDragSource: NSViewRepresentable {
    let shelfID: UUID
    let resolveDragItems: () -> [ShelfItem]
    let contextMenuItem: ShelfItem?
    var onDragCompleted: ((Set<UUID>) -> Void)?
    var onTap: ((Bool, Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRemoveItem: ((ShelfItem) -> Void)?
    var onSelectAll: (() -> Void)?
    var onCopySelection: (() -> Void)?
    var onClearShelf: (() -> Void)?
    var onHoverChanged: ((Bool, NSRect, NSRect) -> Void)?

    func makeNSView(context: Context) -> ShelfDragSourceNSView {
        ShelfDragSourceNSView()
    }

    func updateNSView(_ nsView: ShelfDragSourceNSView, context: Context) {
        nsView.shelfID = shelfID
        nsView.resolveDragItems = resolveDragItems
        nsView.contextMenuItem = contextMenuItem
        nsView.onDragCompleted = onDragCompleted
        nsView.onTap = onTap
        nsView.onDoubleClick = onDoubleClick
        nsView.onRemoveItem = onRemoveItem
        nsView.onSelectAll = onSelectAll
        nsView.onCopySelection = onCopySelection
        nsView.onClearShelf = onClearShelf
        nsView.onHoverChanged = onHoverChanged
    }
}

final class ShelfDragSourceNSView: NSView, NSDraggingSource {
    var shelfID: UUID = UUID()
    var resolveDragItems: (() -> [ShelfItem])?
    var contextMenuItem: ShelfItem?
    var onDragCompleted: ((Set<UUID>) -> Void)?
    var onTap: ((Bool, Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRemoveItem: ((ShelfItem) -> Void)?
    var onSelectAll: (() -> Void)?
    var onCopySelection: (() -> Void)?
    var onClearShelf: (() -> Void)?
    var onHoverChanged: ((Bool, NSRect, NSRect) -> Void)?

    private var mouseDownLocation: NSPoint?
    private var mouseDownEvent: NSEvent?
    private var draggedItemIDs: Set<UUID> = []
    private var trackingAreaRef: NSTrackingArea?
    private let dragThreshold: CGFloat = 4.0

    /// Crucial for Dropshelf non-activating panel UX: allows immediate drag-out or click
    /// on the very first mouseDown without ever stealing focus from Finder.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        let rowScreenRect: NSRect
        let shelfScreenRect: NSRect
        if let window {
            let rectInWindow = convert(bounds, to: nil)
            rowScreenRect = window.convertToScreen(rectInWindow)
            shelfScreenRect = window.frame
        } else {
            rowScreenRect = .zero
            shelfScreenRect = .zero
        }
        onHoverChanged?(true, rowScreenRect, shelfScreenRect)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false, .zero, .zero)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            return [.copy, .move, .link, .generic]
        case .withinApplication:
            return [.move, .copy]
        @unknown default:
            return [.copy]
        }
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        FilenameTooltipController.shared.hide()
        SelfDragState.begin(fromShelf: shelfID)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        SelfDragState.end()
        GlobalDragMonitor.shared.syncAfterInternalDragEnded()

        let finishedIDs = draggedItemIDs
        draggedItemIDs = []

        if operation != [], !finishedIDs.isEmpty {
            let droppedOnSameShelf = window?.frame.contains(screenPoint) ?? false
            if !droppedOnSameShelf && AppSettings.shared.autoRemoveOnDragOut {
                onDragCompleted?(finishedIDs)
            }
        }

        // After dragging out of a shelf, allow 80% off-screen peek to re-engage if pointer left the shelf.
        if let shelfWindow = window as? ShelfWindow,
           !shelfWindow.frame.contains(NSEvent.mouseLocation) {
            shelfWindow.dropContainerView.onHoverChanged?(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        FilenameTooltipController.shared.hide()
        mouseDownLocation = event.locationInWindow
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = mouseDownLocation else { return }
        let current = event.locationInWindow
        let dx = current.x - startLocation.x
        let dy = current.y - startLocation.y
        guard hypot(dx, dy) >= dragThreshold else { return }

        let itemsToDrag = resolveDragItems?() ?? []
        guard !itemsToDrag.isEmpty else { return }

        FilenameTooltipController.shared.hide()

        let anchorInView = convert(startLocation, from: nil)
        let originEvent = mouseDownEvent ?? event
        mouseDownLocation = nil
        mouseDownEvent = nil

        let draggingItems = ShelfItemDragWriter.draggingItems(for: itemsToDrag, anchorPoint: anchorInView)
        guard !draggingItems.isEmpty else { return }

        draggedItemIDs = Set(itemsToDrag.map(\.id))
        let session = beginDraggingSession(with: draggingItems, event: originEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = draggingItems.count > 1 ? .pile : .none
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownLocation != nil else { return }
        mouseDownLocation = nil
        mouseDownEvent = nil

        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            onTap?(cmd, shift)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        FilenameTooltipController.shared.hide()
        let menu = NSMenu()

        if let item = contextMenuItem {
            if item.canOpen {
                let openItem = NSMenuItem(title: "Open", action: #selector(handleOpen), keyEquivalent: "")
                openItem.target = self
                menu.addItem(openItem)
            }
            if item.canRevealInFinder {
                let revealItem = NSMenuItem(title: "Show in Finder", action: #selector(handleReveal), keyEquivalent: "")
                revealItem.target = self
                menu.addItem(revealItem)
            }

            let copyItem = NSMenuItem(title: "Copy", action: #selector(handleCopy), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)

            if item.canSaveAsFile {
                let ext = item.suggestedExportFilename.split(separator: ".").last.map(String.init) ?? "file"
                let saveItem = NSMenuItem(title: "Save as .\(ext) File…", action: #selector(handleSaveAsFile), keyEquivalent: "")
                saveItem.target = self
                menu.addItem(saveItem)
            }

            menu.addItem(.separator())

            let selectAllItem = NSMenuItem(title: "Select All in Shelf", action: #selector(handleSelectAll), keyEquivalent: "")
            selectAllItem.target = self
            menu.addItem(selectAllItem)

            let removeItem = NSMenuItem(title: "Remove from Shelf", action: #selector(handleRemove), keyEquivalent: "")
            removeItem.target = self
            menu.addItem(removeItem)
        } else {
            let copyAll = NSMenuItem(title: "Copy Items", action: #selector(handleCopySelection), keyEquivalent: "")
            copyAll.target = self
            menu.addItem(copyAll)

            let selectAllItem = NSMenuItem(title: "Select All in Shelf", action: #selector(handleSelectAll), keyEquivalent: "")
            selectAllItem.target = self
            menu.addItem(selectAllItem)

            menu.addItem(.separator())

            let clearAll = NSMenuItem(title: "Clear This Shelf", action: #selector(handleClearShelf), keyEquivalent: "")
            clearAll.target = self
            menu.addItem(clearAll)
        }

        return menu.items.isEmpty ? nil : menu
    }

    @objc private func handleOpen() {
        contextMenuItem?.openItem()
    }

    @objc private func handleReveal() {
        contextMenuItem?.revealInFinder()
    }

    @objc private func handleCopy() {
        contextMenuItem?.copyToGeneralPasteboard()
    }

    @objc private func handleSaveAsFile() {
        contextMenuItem?.saveAsFile()
    }

    @objc private func handleRemove() {
        guard let item = contextMenuItem else { return }
        onRemoveItem?(item)
    }

    @objc private func handleSelectAll() {
        onSelectAll?()
    }

    @objc private func handleCopySelection() {
        onCopySelection?()
    }

    @objc private func handleClearShelf() {
        onClearShelf?()
    }
}
