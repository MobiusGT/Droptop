import AppKit
import SwiftUI

struct ShelfDragSource: NSViewRepresentable {
    let shelfID: UUID
    let resolveDragItems: () -> [ShelfItem]
    let contextMenuItem: ShelfItem?
    var onDragCompleted: ((Set<UUID>, Set<String>) -> Void)?
    var onTap: ((Bool, Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onQuickLookItem: ((ShelfItem) -> Void)?
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
        nsView.onQuickLookItem = onQuickLookItem
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
    var onDragCompleted: ((Set<UUID>, Set<String>) -> Void)?
    var onTap: ((Bool, Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onQuickLookItem: ((ShelfItem) -> Void)?
    var onRemoveItem: ((ShelfItem) -> Void)?
    var onSelectAll: (() -> Void)?
    var onCopySelection: (() -> Void)?
    var onClearShelf: (() -> Void)?
    var onHoverChanged: ((Bool, NSRect, NSRect) -> Void)?

    private var mouseDownLocation: NSPoint?
    private var mouseDownEvent: NSEvent?
    private var draggedItemIDs: Set<UUID> = []
    private var draggedContainsTemporaryCopy: Bool = false
    private var trackingAreaRef: NSTrackingArea?
    private var isPointerInside: Bool = false
    private let dragThreshold: CGFloat = 4.0

    static func outsideApplicationOperationMask(containsTemporaryCopy: Bool) -> NSDragOperation {
        containsTemporaryCopy ? [.copy, .generic] : [.copy, .move, .link, .generic]
    }

    /// Crucial for Dropshelf non-activating panel UX: allows immediate drag-out or click
    /// on the very first mouseDown without ever stealing focus from Finder.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func pointerIsInsideVisibleBounds() -> Bool {
        guard let window, window.isVisible, !window.ignoresMouseEvents else { return false }
        let visibleBounds = bounds.intersection(visibleRect)
        guard !visibleBounds.isNull, !visibleBounds.isEmpty else { return false }
        let rectInWindow = convert(visibleBounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow).intersection(window.frame)
        guard !screenRect.isNull, !screenRect.isEmpty else { return false }
        return screenRect.contains(NSEvent.mouseLocation)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil && isPointerInside {
            isPointerInside = false
            DispatchQueue.main.async { [weak self] in
                self?.onHoverChanged?(false, .zero, .zero)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let currentlyInside = pointerIsInsideVisibleBounds()
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if currentlyInside {
            options.insert(.assumeInside)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area

        if isPointerInside && !currentlyInside {
            isPointerInside = false
            DispatchQueue.main.async { [weak self] in
                self?.onHoverChanged?(false, .zero, .zero)
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isPointerInside = true
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
        isPointerInside = false
        onHoverChanged?(false, .zero, .zero)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            return Self.outsideApplicationOperationMask(containsTemporaryCopy: draggedContainsTemporaryCopy)
        case .withinApplication:
            return [.move, .copy]
        @unknown default:
            return [.copy]
        }
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        (window as? ShelfWindow)?.releaseKeyFocus()
        FilenameTooltipController.shared.hide()
        SelfDragState.begin(fromShelf: shelfID)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let adoptedPaths = SelfDragState.consumeAdoptedStagedSourcePaths()
        SelfDragState.end()
        GlobalDragMonitor.shared.syncAfterInternalDragEnded()

        let finishedIDs = draggedItemIDs
        draggedItemIDs = []
        draggedContainsTemporaryCopy = false

        if operation != [], !finishedIDs.isEmpty {
            let droppedOnSameShelf = window?.frame.contains(screenPoint) ?? false
            if !droppedOnSameShelf && AppSettings.shared.autoRemoveOnDragOut {
                onDragCompleted?(finishedIDs, adoptedPaths)
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
        draggedContainsTemporaryCopy = itemsToDrag.contains(where: \.isTemporaryCopy)
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
            (window as? ShelfWindow)?.acquireKeyFocusForKeyboard()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        FilenameTooltipController.shared.hide()
        let menu = NSMenu()

        if let item = contextMenuItem {
            let quickLookItem = NSMenuItem(title: "Quick Look", action: #selector(handleQuickLook), keyEquivalent: "")
            quickLookItem.target = self
            menu.addItem(quickLookItem)

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

    @objc private func handleQuickLook() {
        guard let item = contextMenuItem else { return }
        onQuickLookItem?(item)
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
