import AppKit
import Foundation

final class ShelfWindow: NSPanel {
    let shelfID: UUID
    let dropContainerView: ShelfDropContainerView
    var onManualMoveBegan: (() -> Void)?
    var onManualMoveUpdated: ((NSRect, NSPoint) -> Void)?
    var onManualMoveEnded: ((NSRect) -> Void)?

    init(shelfID: UUID, stagingDirectory: URL, contentRect: NSRect) {
        self.shelfID = shelfID
        self.dropContainerView = ShelfDropContainerView(
            shelfID: shelfID,
            stagingDirectory: stagingDirectory,
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
        appearance = AppSettings.shared.shelfTheme.nsAppearance

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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

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
        FilenameTooltipController.shared.hide()
        dropContainerView.unregisterAllDraggedTypes()
        ignoresMouseEvents = true
    }
}
