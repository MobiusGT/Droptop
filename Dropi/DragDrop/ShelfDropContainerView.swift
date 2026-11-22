import AppKit
import Combine
import Foundation

@MainActor
final class ShelfDropHighlightState: ObservableObject {
    @Published var isDropTargeted: Bool = false
    @Published var isAutoHidden: Bool = false
    @Published var dockedEdge: ScreenEdge = .right
    @Published var isPointerInsideShelf: Bool = false
}

/// Native AppKit NSDraggingDestination container hosting a shelf's SwiftUI view.
/// - Each shelf instance owns its own `ShelfDropContainerView` and `ShelfDropHighlightState`.
/// - Uses an `.activeAlways` NSTrackingArea so 80% off-screen peek/un-peek works reliably
///   even when Finder or another app holds focus.
/// - Explicitly registers/unregisters dragged types in lockstep with window visibility
///   so macOS 26 CoreDragMessageHandler never enters a fading-out or closing window.
final class ShelfDropContainerView: NSView {
    let shelfID: UUID
    let stagingDirectory: URL
    let stagingRoot: URL
    let highlightState = ShelfDropHighlightState()

    var onItemsDropped: (([ShelfItem]) -> Void)?
    var onDraggingSessionEnded: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragHoverChanged: ((Bool) -> Void)?

    private var isRegisteredForDrags = false
    private var hoverTrackingArea: NSTrackingArea?

    init(
        shelfID: UUID,
        stagingDirectory: URL,
        stagingRoot: URL = ShelfStore.rootStagingDirectory,
        frame frameRect: NSRect = .zero
    ) {
        self.shelfID = shelfID
        self.stagingDirectory = stagingDirectory
        self.stagingRoot = stagingRoot
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        highlightState.isPointerInsideShelf = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        highlightState.isPointerInsideShelf = false
        FilenameTooltipController.shared.hide()
        onHoverChanged?(false)
    }

    func registerAllDraggedTypes() {
        guard !isRegisteredForDrags else { return }
        registerForDraggedTypes(PasteboardHandler.registeredDraggedTypes)
        isRegisteredForDrags = true
    }

    func unregisterAllDraggedTypes() {
        if isRegisteredForDrags {
            unregisterDraggedTypes()
            isRegisteredForDrags = false
        }
        highlightState.isDropTargeted = false
        highlightState.isPointerInsideShelf = false
    }

    private func canAcceptDrag(_ sender: any NSDraggingInfo) -> Bool {
        guard isRegisteredForDrags else { return false }

        if SelfDragState.isDraggingFromShelf {
            guard SelfDragState.sourceShelfID != shelfID else { return false }
        } else if sender.draggingSource != nil {
            return false
        }

        return PasteboardHandler.canAccept(sender.draggingPasteboard)
    }

    private func preferredOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        if SelfDragState.isDraggingFromShelf && SelfDragState.sourceShelfID != shelfID {
            return .move
        }
        return .copy
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        FilenameTooltipController.shared.hide()
        guard canAcceptDrag(sender) else { return [] }
        highlightState.isDropTargeted = true
        onDragHoverChanged?(true)
        return preferredOperation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrag(sender) else { return [] }
        return preferredOperation(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        highlightState.isDropTargeted = false
        onDragHoverChanged?(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        canAcceptDrag(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlightState.isDropTargeted = false
        onDragHoverChanged?(false)
        guard canAcceptDrag(sender) else { return false }

        let accepted = PasteboardHandler.extractItems(
            from: sender.draggingPasteboard,
            stagingDirectory: stagingDirectory,
            stagingRoot: stagingRoot
        ) { [weak self] items in
            guard !items.isEmpty else { return }
            guard let self, let onItemsDropped = self.onItemsDropped else {
                ShelfStore.purgeOrphanedTemporaryFiles(in: items)
                return
            }
            onItemsDropped(items)
        }

        if accepted && !SelfDragState.isDraggingFromShelf {
            GlobalDragMonitor.shared.notifyDropCompletedOnShelf()
        }

        return accepted
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        highlightState.isDropTargeted = false
        onDragHoverChanged?(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        highlightState.isDropTargeted = false
        onDragHoverChanged?(false)
        onDraggingSessionEnded?()
    }
}
