import AppKit
import Foundation
import QuickLookUI

final class ShelfWindow: NSPanel {
    let shelfID: UUID
    let dropContainerView: ShelfDropContainerView
    var onManualMoveBegan: (() -> Void)?
    var onManualMoveUpdated: ((NSRect, NSPoint) -> Void)?
    var onManualMoveEnded: ((NSRect) -> Void)?
    var onQuickLookRequested: (() -> Void)?
    var onNavigateSelection: ((Int) -> Void)?

    private(set) var allowsKeyStatus: Bool = false
    private(set) var allowsMainStatus: Bool = false

    init(
        shelfID: UUID,
        stagingDirectory: URL,
        stagingRoot: URL = ShelfStore.rootStagingDirectory,
        contentRect: NSRect,
        theme: ShelfTheme? = nil
    ) {
        self.shelfID = shelfID
        self.dropContainerView = ShelfDropContainerView(
            shelfID: shelfID,
            stagingDirectory: stagingDirectory,
            stagingRoot: stagingRoot,
            frame: NSRect(origin: .zero, size: contentRect.size)
        )

        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        animationBehavior = .none
        appearance = (theme ?? AppSettings.shared.shelfTheme).nsAppearance

        // Explicitly allow shrinking down to a thin 14pt/26pt Auto-Hide strip
        // so the window frame ALWAYS stays 100% inside `screen.frame` (zero Spaces bleed!).
        minSize = NSSize(width: 10, height: 80)
        contentMinSize = NSSize(width: 10, height: 80)

        dropContainerView.autoresizingMask = [.width, .height]
        dropContainerView.wantsLayer = true
        dropContainerView.layer?.cornerRadius = Constants.Shelf.cornerRadius
        dropContainerView.layer?.masksToBounds = true
        contentView = dropContainerView
    }

    override var canBecomeKey: Bool {
        allowsKeyStatus && isVisible && !dropContainerView.highlightState.isAutoHidden
    }

    override var canBecomeMain: Bool {
        allowsMainStatus && isVisible
    }

    func acquireKeyFocusForKeyboard() {
        guard isVisible, !dropContainerView.highlightState.isAutoHidden else { return }
        allowsKeyStatus = true
        makeKey()
        makeFirstResponder(self)
    }

    func releaseKeyFocus() {
        allowsKeyStatus = false
        if isKeyWindow {
            resignKey()
        }
    }

    /// Temporarily permits key + main window status while `QLPreviewPanel` is open so
    /// this shelf stays in AppKit's responder chain even after `QLPreviewPanel` becomes key.
    func beginQuickLookControlFocus() {
        guard isVisible else { return }
        allowsKeyStatus = true
        allowsMainStatus = true
        makeKey()
        makeMain()
        makeFirstResponder(self)
    }

    func endQuickLookControlFocus() {
        allowsMainStatus = false
        if isMainWindow {
            resignMain()
        }
    }

    override func resignKey() {
        super.resignKey()
        if !allowsMainStatus {
            allowsKeyStatus = false
        }
    }

    override func keyDown(with event: NSEvent) {
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let modifiers = event.modifierFlags.intersection(relevant)
        guard modifiers.isEmpty else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 49: // Spacebar
            if !event.isARepeat {
                onQuickLookRequested?()
            }
            return

        case 53: // Escape
            if ShelfQuickLookController.shared.isPreviewing(shelfID: shelfID) {
                ShelfQuickLookController.shared.closePanel(restoreShelfFocus: true)
            } else {
                releaseKeyFocus()
            }
            return

        case 125, 126: // Down / Up arrows
            onNavigateSelection?(event.keyCode == 125 ? 1 : -1)
            return

        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - QLPreviewPanelController

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        ShelfQuickLookController.shared.acceptsPreviewPanelControl(panel)
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        ShelfQuickLookController.shared.beginPreviewPanelControl(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        ShelfQuickLookController.shared.endPreviewPanelControl(panel)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func attachHostingView(_ hostingView: NSView) {
        // Use classic autoresizing rather than Auto Layout constraints pinned to contentView
        // so NSHostingView can NEVER propagate a child minWidth constraint up to NSWindow.minSize.
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.frame = dropContainerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dropContainerView.addSubview(hostingView)
    }

    func prepareForShow() {
        ignoresMouseEvents = false
        dropContainerView.registerAllDraggedTypes()
    }

    /// Always called BEFORE any hide/slide-out animation so macOS 26 CoreDragMessageHandler
    /// never delivers a reentrant drag-enter message to a disappearing window.
    func prepareForHide() {
        ShelfQuickLookController.shared.closeIfShowing(forShelfID: shelfID)
        endQuickLookControlFocus()
        releaseKeyFocus()
        FilenameTooltipController.shared.hide()
        dropContainerView.unregisterAllDraggedTypes()
        ignoresMouseEvents = true
    }

    /// Deterministic cleanup for permanently closed shelves (never called on Hide All / Show All).
    /// Breaks closure/view references immediately and closes the panel safely under ARC.
    func teardown() {
        prepareForHide()
        onManualMoveBegan = nil
        onManualMoveUpdated = nil
        onManualMoveEnded = nil
        onQuickLookRequested = nil
        onNavigateSelection = nil
        dropContainerView.onItemsDropped = nil
        dropContainerView.onHoverChanged = nil
        dropContainerView.onDragHoverChanged = nil
        dropContainerView.onDraggingSessionEnded = nil
        isReleasedWhenClosed = false
        for subview in dropContainerView.subviews {
            subview.removeFromSuperview()
        }
        contentView = nil
        close()
    }
}
