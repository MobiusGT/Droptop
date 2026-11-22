import AppKit
import Combine
import Foundation
import QuartzCore

@MainActor
final class ShelfInstance {
    let id: UUID
    let store: ShelfStore
    let panel: ShelfWindow
    let viewController: ShelfViewController

    var dockedEdge: ScreenEdge {
        didSet {
            panel.dropContainerView.highlightState.dockedEdge = dockedEdge
        }
    }
    var dockedScreen: NSScreen?
    var isDockedToEdge: Bool = true
    var expandedFrame: NSRect
    var isAutoHidden: Bool = false {
        didSet {
            panel.dropContainerView.highlightState.isAutoHidden = isAutoHidden
        }
    }
    var isManuallyMoving: Bool = false
    var isHovered: Bool = false
    var isDragHovered: Bool = false
    var openedTemporarilyForDrag: Bool = false
    var pendingDropGraceTask: DispatchWorkItem?
    var pendingAutoHideTask: DispatchWorkItem?
    var visibilityGeneration: UInt64 = 0
    var cancellables = Set<AnyCancellable>()

    init(
        store: ShelfStore,
        panel: ShelfWindow,
        viewController: ShelfViewController,
        dockedEdge: ScreenEdge,
        dockedScreen: NSScreen?,
        expandedFrame: NSRect
    ) {
        self.id = store.id
        self.store = store
        self.panel = panel
        self.viewController = viewController
        self.dockedEdge = dockedEdge
        self.dockedScreen = dockedScreen
        self.expandedFrame = expandedFrame
        panel.dropContainerView.highlightState.dockedEdge = dockedEdge
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var isDropTargeted: Bool {
        panel.dropContainerView.highlightState.isDropTargeted
    }
}

@MainActor
final class ShelfManager {
    static weak var shared: ShelfManager?

    private(set) var shelves: [ShelfInstance] = []
    private var settingsWindow: SettingsWindow?
    private let triggerEngine = TriggerEngine()
    private var cancellables = Set<AnyCancellable>()
    private var lastEdgeUsed: ScreenEdge = .right

    // Live edge-snap preview indicator while user drags a shelf across the screen
    private var snapPreviewIndicator: EdgeIndicatorWindow?
    private var snapPreviewEdge: ScreenEdge?
    private var snapPreviewScreen: NSScreen?

    // Virtual Desktop (Space) & hover reconciliation so open shelves NEVER stay stuck
    // expanded after switching Spaces or when AppKit drops a mouseExited event.
    private var spaceChangeObserver: NSObjectProtocol?
    private var autoHideWatchdogTimer: Timer?

    var hasVisibleShelves: Bool {
        shelves.contains { $0.isVisible }
    }

    init() {
        Self.shared = self

        triggerEngine.onTrigger = { [weak self] event in
            self?.handleTrigger(event)
        }
        triggerEngine.onExternalDragEnded = { [weak self] droppedOnShelf in
            self?.handleExternalDragEnded(droppedOnShelf: droppedOnShelf)
        }
        triggerEngine.start()

        AppSettings.shared.$autoHideEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                DispatchQueue.main.async { [weak self] in
                    self?.handleAutoHidePreferenceChanged(enabled: enabled)
                }
            }
            .store(in: &cancellables)

        // IMPORTANT: Combine `@Published` emits during `willSet`, BEFORE the property stores
        // the new value — pass the emitted `pretty` / `style` directly so collapsed shelf width
        // resizes IMMEDIATELY when switching Clean Auto hide styles (no unhide/rehide required!).
        AppSettings.shared.$prettyAutoHideTab
            .dropFirst()
            .sink { [weak self] pretty in
                self?.refreshAutoHiddenShelfFrames(
                    prettyTab: pretty,
                    style: AppSettings.shared.autoHideTabStyle
                )
            }
            .store(in: &cancellables)

        AppSettings.shared.$autoHideTabStyle
            .dropFirst()
            .sink { [weak self] style in
                self?.refreshAutoHiddenShelfFrames(
                    prettyTab: AppSettings.shared.prettyAutoHideTab,
                    style: style
                )
            }
            .store(in: &cancellables)

        AppSettings.shared.$shelfTheme
            .dropFirst()
            .sink { [weak self] theme in
                self?.applyThemeAppearanceToAllWindows(theme)
            }
            .store(in: &cancellables)

        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleActiveSpaceDidChange()
            }
        }
    }

    func shutdown() {
        autoHideWatchdogTimer?.invalidate()
        autoHideWatchdogTimer = nil
        if let observer = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceChangeObserver = nil
        }
        FilenameTooltipController.shared.hide()
        hideSnapPreview()
        triggerEngine.stop()
        for shelf in shelves {
            shelf.pendingDropGraceTask?.cancel()
            shelf.pendingDropGraceTask = nil
            shelf.pendingAutoHideTask?.cancel()
            shelf.pendingAutoHideTask = nil
            shelf.panel.prepareForHide()
            shelf.panel.orderOut(nil)
        }
        shelves.removeAll()
        settingsWindow?.orderOut(nil)
        ShelfStore.cleanupAllStagingDirectories()
    }

    func refreshPermissionsIfNeeded() {
        triggerEngine.refreshPermissionsIfNeeded()
    }

    private func applyThemeAppearanceToAllWindows(_ theme: ShelfTheme) {
        let appearance = theme.nsAppearance
        for shelf in shelves {
            shelf.panel.appearance = appearance
        }
        settingsWindow?.appearance = appearance
    }

    private func currentAutoHideVisibleWidth() -> CGFloat {
        let settings = AppSettings.shared
        return Constants.Shelf.autoHideVisibleWidth(
            prettyTab: settings.prettyAutoHideTab,
            style: settings.autoHideTabStyle
        )
    }

    // MARK: - Trigger Handling

    private func handleTrigger(_ event: TriggerEvent) {
        switch event {
        case .edge(let edge, let location, let screen):
            showForEdgeDrag(edge: edge, cursorLocation: location, screen: screen)
        case .shake(let location):
            showForShake(at: location)
        case .hotkey(let location):
            toggleOrCreateManual(near: location)
        }
    }

    func showForEdgeDrag(edge: ScreenEdge, cursorLocation: NSPoint, screen: NSScreen) {
        lastEdgeUsed = edge

        if let hovered = shelves.first(where: { $0.isVisible && $0.panel.frame.insetBy(dx: -14, dy: -14).contains(cursorLocation) }) {
            hovered.pendingDropGraceTask?.cancel()
            hovered.pendingDropGraceTask = nil
            hovered.panel.prepareForShow()
            hovered.panel.orderFrontRegardless()
            revealShelfFromAutoHide(hovered)
            return
        }

        if let emptyShelf = shelves.first(where: {
            $0.isVisible && $0.store.items.isEmpty && $0.dockedEdge == edge && $0.dockedScreen == screen
        }) {
            emptyShelf.pendingDropGraceTask?.cancel()
            emptyShelf.pendingDropGraceTask = nil
            emptyShelf.pendingAutoHideTask?.cancel()
            emptyShelf.pendingAutoHideTask = nil
            emptyShelf.isAutoHidden = false
            emptyShelf.visibilityGeneration &+= 1
            emptyShelf.panel.prepareForShow()
            emptyShelf.panel.alphaValue = 1.0
            emptyShelf.panel.orderFrontRegardless()

            let target = computeDockedFrame(
                size: NSSize(width: Constants.Shelf.width, height: emptyShelf.expandedFrame.height),
                edge: edge,
                preferredCenterY: cursorLocation.y,
                on: screen,
                excluding: emptyShelf.id
            )
            emptyShelf.expandedFrame = target
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
                emptyShelf.panel.animator().setFrame(target, display: true)
            }
            return
        }

        _ = createAndPresentShelf(
            edge: edge,
            preferredCenterY: cursorLocation.y,
            on: screen,
            temporaryForDrag: true
        )
    }

    func showForShake(at location: NSPoint) {
        guard let screen = ScreenGeometry.screen(containing: location) else { return }
        let edge: ScreenEdge = location.x < screen.frame.midX ? .left : .right
        showForEdgeDrag(edge: edge, cursorLocation: location, screen: screen)
    }

    func toggleOrCreateManual(near location: NSPoint? = nil) {
        if hasVisibleShelves {
            hideAllShelves()
        } else if !shelves.isEmpty {
            showAllShelves()
        } else {
            createManualShelf(near: location)
        }
    }

    @discardableResult
    func createManualShelf(
        edge: ScreenEdge? = nil,
        near location: NSPoint? = nil,
        initialItems: [ShelfItem] = []
    ) -> ShelfInstance? {
        let anchor = location ?? NSEvent.mouseLocation
        guard let screen = ScreenGeometry.screen(containing: anchor) ?? NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }
        let targetEdge = edge ?? lastEdgeUsed
        lastEdgeUsed = targetEdge

        let shelf = createAndPresentShelf(
            edge: targetEdge,
            preferredCenterY: screen.visibleFrame.midY,
            on: screen,
            temporaryForDrag: false
        )
        if !initialItems.isEmpty {
            shelf.store.addMany(initialItems)
        }
        return shelf
    }

    func createShelfFromClipboard() {
        let tempDir = ShelfStore.rootStagingDirectory.appendingPathComponent("clipboard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let accepted = PasteboardHandler.extractItems(
            from: NSPasteboard.general,
            stagingDirectory: tempDir
        ) { [weak self] items in
            guard let self else { return }
            _ = self.createManualShelf(initialItems: items)
        }

        if !accepted {
            _ = createManualShelf()
        }
    }

    func showAllShelves() {
        for shelf in shelves {
            presentExistingShelf(shelf)
        }
    }

    func hideAllShelves() {
        FilenameTooltipController.shared.hide()
        for shelf in shelves {
            hideShelfAnimated(shelf, removeAfterHide: shelf.store.items.isEmpty)
        }
    }

    func clearAndCloseAllShelves() {
        FilenameTooltipController.shared.hide()
        let copy = shelves
        for shelf in copy {
            shelf.store.clearAll()
            closeShelf(id: shelf.id)
        }
    }

    func focusOrToggleShelf(id: UUID) {
        guard let shelf = shelves.first(where: { $0.id == id }) else { return }
        if shelf.isVisible {
            revealShelfFromAutoHide(shelf)
            shelf.panel.orderFrontRegardless()
            scheduleAutoHideIfEligible(shelf, delay: Constants.Shelf.postDropPeekGrace)
        } else {
            presentExistingShelf(shelf)
        }
    }

    func closeShelf(id: UUID) {
        guard let shelf = shelves.first(where: { $0.id == id }) else { return }
        hideShelfAnimated(shelf, removeAfterHide: true)
    }

    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
        }
        settingsWindow?.appearance = AppSettings.shared.shelfTheme.nsAppearance
        let screen = ScreenGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            settingsWindow?.showCentered(on: screen)
        }
    }

    // MARK: - Smooth "Growing" Auto Hide / Unhide

    func handleActiveSpaceDidChange() {
        FilenameTooltipController.shared.hide()
        guard AppSettings.shared.autoHideEnabled else {
            updateAutoHideWatchdog()
            return
        }
        guard NSEvent.pressedMouseButtons == 0 else { return }

        // Switching Virtual Desktops (Spaces) frequently swallows AppKit `mouseExited` events
        // for `.canJoinAllSpaces` panels. Reset stale hover flags and auto-hide open shelves cleanly.
        for shelf in shelves {
            guard shelf.isVisible,
                  shelf.isDockedToEdge,
                  !shelf.isAutoHidden,
                  !shelf.isManuallyMoving,
                  !shelf.openedTemporarilyForDrag,
                  !shelf.isDragHovered,
                  !shelf.isDropTargeted,
                  SelfDragState.sourceShelfID != shelf.id else {
                continue
            }
            shelf.isHovered = false
            scheduleAutoHideIfEligible(shelf, delay: 0.22, ignorePointerPosition: true)
        }
        updateAutoHideWatchdog()
    }

    func reconcileAutoHideForExpandedShelves(delay: TimeInterval? = nil) {
        guard AppSettings.shared.autoHideEnabled else {
            updateAutoHideWatchdog()
            return
        }
        guard NSEvent.pressedMouseButtons == 0 else { return }

        let resolvedDelay = delay ?? Constants.Shelf.peekDelay
        let cursor = NSEvent.mouseLocation
        for shelf in shelves {
            guard shelf.isVisible,
                  shelf.isDockedToEdge,
                  !shelf.isAutoHidden,
                  !shelf.isManuallyMoving,
                  !shelf.openedTemporarilyForDrag,
                  !shelf.isDragHovered,
                  !shelf.isDropTargeted,
                  SelfDragState.sourceShelfID != shelf.id else {
                continue
            }

            if !isPointInShelfOrEdgeGutter(cursor, shelf: shelf) {
                shelf.isHovered = false
                if shelf.pendingAutoHideTask == nil {
                    scheduleAutoHideIfEligible(shelf, delay: resolvedDelay)
                }
            }
        }
        updateAutoHideWatchdog()
    }

    private func updateAutoHideWatchdog() {
        let needsWatchdog = AppSettings.shared.autoHideEnabled && shelves.contains {
            $0.isVisible && $0.isDockedToEdge && !$0.isAutoHidden
        }

        if needsWatchdog {
            guard autoHideWatchdogTimer == nil else { return }
            let timer = Timer(timeInterval: 0.40, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcileAutoHideForExpandedShelves(delay: Constants.Shelf.peekDelay)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            autoHideWatchdogTimer = timer
        } else {
            autoHideWatchdogTimer?.invalidate()
            autoHideWatchdogTimer = nil
        }
    }

    private func handleAutoHidePreferenceChanged(enabled: Bool) {
        for shelf in shelves where shelf.isVisible {
            if enabled {
                if !isPointInShelfOrEdgeGutter(NSEvent.mouseLocation, shelf: shelf) {
                    shelf.isHovered = false
                }
                scheduleAutoHideIfEligible(shelf, delay: 0.15)
            } else {
                revealShelfFromAutoHide(shelf)
            }
        }
        updateAutoHideWatchdog()
    }

    func refreshAutoHiddenShelfFrames(
        prettyTab: Bool? = nil,
        style: AutoHideTabStyle? = nil
    ) {
        let resolvedPretty = prettyTab ?? AppSettings.shared.prettyAutoHideTab
        let resolvedStyle = style ?? AppSettings.shared.autoHideTabStyle
        let visibleWidth = Constants.Shelf.autoHideVisibleWidth(
            prettyTab: resolvedPretty,
            style: resolvedStyle
        )
        for shelf in shelves where shelf.isVisible && shelf.isAutoHidden {
            guard let screen = shelf.dockedScreen
                    ?? ScreenGeometry.screen(containing: NSPoint(x: shelf.expandedFrame.midX, y: shelf.expandedFrame.midY))
                    ?? NSScreen.main else {
                continue
            }
            let updatedFrame = ShelfLayoutSolver.autoHideFrame(
                from: shelf.expandedFrame,
                edge: shelf.dockedEdge,
                screenFrame: screen.frame,
                visibleWidth: visibleWidth
            )
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
                ctx.allowsImplicitAnimation = true
                shelf.panel.animator().setFrame(updatedFrame, display: true)
            }
        }
    }

    private func isPointInShelfOrEdgeGutter(_ point: NSPoint, shelf: ShelfInstance) -> Bool {
        let frame = shelf.panel.frame
        if frame.insetBy(dx: -2, dy: -2).contains(point) {
            return true
        }
        // Include the thin outer margin between the shelf and the exact monitor border so
        // parking the mouse right against the screen edge after un-hiding never causes bounce.
        guard let screen = shelf.dockedScreen ?? NSScreen.main else { return false }
        let inVerticalSpan = point.y >= frame.minY - 2 && point.y <= frame.maxY + 2
        guard inVerticalSpan else { return false }
        switch shelf.dockedEdge {
        case .left:
            return point.x >= screen.frame.minX && point.x <= frame.maxX + 2
        case .right:
            return point.x >= frame.minX - 2 && point.x <= screen.frame.maxX
        }
    }

    private func handleShelfHoverChanged(_ shelf: ShelfInstance, isHovering: Bool) {
        if isHovering {
            shelf.isHovered = true
            revealShelfFromAutoHide(shelf)
        } else {
            // If the pointer is still in the thin outer edge gutter next to the shelf, keep it open!
            if !shelf.isAutoHidden && isPointInShelfOrEdgeGutter(NSEvent.mouseLocation, shelf: shelf) {
                shelf.isHovered = true
                updateAutoHideWatchdog()
                return
            }
            shelf.isHovered = false
            if !shelf.isManuallyMoving {
                scheduleAutoHideIfEligible(shelf, delay: Constants.Shelf.peekDelay)
            }
        }
    }

    private func handleShelfDragHoverChanged(_ shelf: ShelfInstance, isDragHovering: Bool) {
        shelf.isDragHovered = isDragHovering
        if isDragHovering {
            revealShelfFromAutoHide(shelf)
        } else {
            scheduleAutoHideIfEligible(shelf, delay: Constants.Shelf.peekDelay)
        }
    }

    func revealShelfFromAutoHide(_ shelf: ShelfInstance) {
        shelf.pendingAutoHideTask?.cancel()
        shelf.pendingAutoHideTask = nil

        guard shelf.isAutoHidden else { return }
        shelf.isAutoHidden = false

        let targetFrame = shelf.expandedFrame
        // Silky cubic-bezier deceleration curve so the shelf visibly "grows" smoothly out
        // of the unhidden edge tab into its full width.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
            ctx.allowsImplicitAnimation = true
            shelf.panel.animator().setFrame(targetFrame, display: true)
            shelf.panel.animator().alphaValue = 1.0
        }
        updateAutoHideWatchdog()
    }

    private func scheduleAutoHideIfEligible(
        _ shelf: ShelfInstance,
        delay: TimeInterval,
        ignorePointerPosition: Bool = false
    ) {
        shelf.pendingAutoHideTask?.cancel()
        shelf.pendingAutoHideTask = nil

        guard AppSettings.shared.autoHideEnabled,
              shelf.isVisible,
              shelf.isDockedToEdge,
              !shelf.isManuallyMoving,
              !shelf.openedTemporarilyForDrag else {
            updateAutoHideWatchdog()
            return
        }

        let work = DispatchWorkItem { [weak self, weak shelf] in
            Task { @MainActor [weak self, weak shelf] in
                guard let self, let shelf else { return }
                shelf.pendingAutoHideTask = nil
                self.autoHideShelfIfStillEligible(shelf, ignorePointerPosition: ignorePointerPosition)
            }
        }
        shelf.pendingAutoHideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        updateAutoHideWatchdog()
    }

    private func autoHideShelfIfStillEligible(
        _ shelf: ShelfInstance,
        ignorePointerPosition: Bool = false
    ) {
        guard AppSettings.shared.autoHideEnabled,
              shelf.isVisible,
              shelf.isDockedToEdge,
              !shelf.isAutoHidden,
              !shelf.isManuallyMoving,
              !shelf.isHovered,
              !shelf.isDragHovered,
              !shelf.isDropTargeted,
              !shelf.openedTemporarilyForDrag,
              SelfDragState.sourceShelfID != shelf.id else {
            updateAutoHideWatchdog()
            return
        }

        if !ignorePointerPosition && isPointInShelfOrEdgeGutter(NSEvent.mouseLocation, shelf: shelf) {
            shelf.isHovered = true
            updateAutoHideWatchdog()
            return
        }

        guard let screen = shelf.dockedScreen
                ?? ScreenGeometry.screen(containing: NSPoint(x: shelf.expandedFrame.midX, y: shelf.expandedFrame.midY))
                ?? NSScreen.main else {
            return
        }

        FilenameTooltipController.shared.hide()

        let targetHiddenFrame = ShelfLayoutSolver.autoHideFrame(
            from: shelf.expandedFrame,
            edge: shelf.dockedEdge,
            screenFrame: screen.frame,
            visibleWidth: currentAutoHideVisibleWidth()
        )

        shelf.isAutoHidden = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.40, 0.0, 0.20, 1.0)
            ctx.allowsImplicitAnimation = true
            shelf.panel.animator().setFrame(targetHiddenFrame, display: true)
            shelf.panel.animator().alphaValue = 0.96
        }
        updateAutoHideWatchdog()
    }

    // MARK: - Custom Drag Shelf Up/Down or Past Halfway to Opposite Side (No macOS Tiling!)

    private func handleShelfManualMoveBegan(_ shelf: ShelfInstance) {
        shelf.isManuallyMoving = true
        shelf.pendingAutoHideTask?.cancel()
        shelf.pendingAutoHideTask = nil
        FilenameTooltipController.shared.hide()
        if shelf.isAutoHidden {
            revealShelfFromAutoHide(shelf)
        }
    }

    private func occupiedFramesByEdge(
        on screen: NSScreen,
        excluding excludedID: UUID
    ) -> (left: [NSRect], right: [NSRect]) {
        var left: [NSRect] = []
        var right: [NSRect] = []
        for other in shelves where other.id != excludedID && other.isVisible {
            let otherScreen = other.dockedScreen
                ?? ScreenGeometry.screen(containing: NSPoint(x: other.expandedFrame.midX, y: other.expandedFrame.midY))
            guard otherScreen == screen else { continue }
            switch other.dockedEdge {
            case .left:
                left.append(other.expandedFrame)
            case .right:
                right.append(other.expandedFrame)
            }
        }
        return (left, right)
    }

    private func handleShelfManualMoveUpdated(_ shelf: ShelfInstance, currentFrame: NSRect, cursorPoint: NSPoint) {
        let center = NSPoint(x: currentFrame.midX, y: currentFrame.midY)
        guard let screen = ScreenGeometry.screen(containing: center) ?? shelf.dockedScreen ?? NSScreen.main else {
            return
        }
        let normalizedDragged = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y,
            width: Constants.Shelf.width,
            height: shelf.expandedFrame.height
        )
        let occupied = occupiedFramesByEdge(on: screen, excluding: shelf.id)
        let anchored = ShelfLayoutSolver.anchoredFrameAfterDrag(
            draggedFrame: normalizedDragged,
            cursorPoint: cursorPoint,
            visibleFrame: screen.visibleFrame,
            existingFramesOnLeftEdge: occupied.left,
            existingFramesOnRightEdge: occupied.right
        )
        showSnapPreview(edge: anchored.edge, screen: screen, centerY: anchored.frame.midY)
    }

    private func handleShelfManualMoveEnded(_ shelf: ShelfInstance, movedFrame: NSRect) {
        shelf.isManuallyMoving = false
        hideSnapPreview()

        let center = NSPoint(x: movedFrame.midX, y: movedFrame.midY)
        guard let screen = ScreenGeometry.screen(containing: center) ?? shelf.dockedScreen ?? NSScreen.main else {
            shelf.expandedFrame = movedFrame
            return
        }

        let normalizedDragged = NSRect(
            x: movedFrame.origin.x,
            y: movedFrame.origin.y,
            width: Constants.Shelf.width,
            height: shelf.expandedFrame.height
        )
        let occupied = occupiedFramesByEdge(on: screen, excluding: shelf.id)
        let anchored = ShelfLayoutSolver.anchoredFrameAfterDrag(
            draggedFrame: normalizedDragged,
            cursorPoint: NSEvent.mouseLocation,
            visibleFrame: screen.visibleFrame,
            existingFramesOnLeftEdge: occupied.left,
            existingFramesOnRightEdge: occupied.right
        )

        shelf.dockedScreen = screen
        shelf.dockedEdge = anchored.edge
        shelf.isDockedToEdge = true
        shelf.expandedFrame = anchored.frame
        shelf.isAutoHidden = false
        lastEdgeUsed = anchored.edge

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
            shelf.panel.animator().setFrame(anchored.frame, display: true)
            shelf.panel.animator().alphaValue = 1.0
        }

        let pointerInside = isPointInShelfOrEdgeGutter(NSEvent.mouseLocation, shelf: shelf)
        shelf.isHovered = pointerInside
        if !pointerInside {
            scheduleAutoHideIfEligible(shelf, delay: Constants.Shelf.peekDelay)
        } else {
            updateAutoHideWatchdog()
        }
    }

    private func showSnapPreview(edge: ScreenEdge, screen: NSScreen, centerY: CGFloat) {
        if let existing = snapPreviewIndicator, snapPreviewEdge == edge, snapPreviewScreen == screen {
            existing.repositionVertically(around: centerY, on: screen)
            return
        }
        hideSnapPreview()
        let indicator = EdgeIndicatorWindow(edge: edge, screen: screen, centerY: centerY)
        indicator.fadeIn()
        snapPreviewIndicator = indicator
        snapPreviewEdge = edge
        snapPreviewScreen = screen
    }

    private func hideSnapPreview() {
        snapPreviewIndicator?.fadeOut()
        snapPreviewIndicator = nil
        snapPreviewEdge = nil
        snapPreviewScreen = nil
    }

    // MARK: - Shelf Creation & Presentation

    private func nextAvailableShelfNumber() -> Int {
        let used = Set(shelves.map { $0.store.shelfNumber })
        var candidate = 1
        while used.contains(candidate) {
            candidate += 1
        }
        return candidate
    }

    private func pickColorVariation(forShelfNumber number: Int) -> ShelfColorVariation {
        guard number > 1 else { return .identity }
        let usedSlots = Set(shelves.map { $0.store.colorVariation.slotIndex })
        return ShelfColorVariation.randomVariant(excluding: usedSlots)
    }

    private func createAndPresentShelf(
        edge: ScreenEdge,
        preferredCenterY: CGFloat,
        on screen: NSScreen,
        temporaryForDrag: Bool
    ) -> ShelfInstance {
        let number = nextAvailableShelfNumber()
        let variation = pickColorVariation(forShelfNumber: number)
        let store = ShelfStore(shelfNumber: number, colorVariation: variation)
        let initialSize = NSSize(
            width: Constants.Shelf.width,
            height: Constants.Shelf.preferredHeight(forItemCount: 0)
        )
        let targetFrame = computeDockedFrame(
            size: initialSize,
            edge: edge,
            preferredCenterY: preferredCenterY,
            on: screen,
            excluding: store.id
        )
        let startFrame = offscreenStartFrame(from: targetFrame, edge: edge, on: screen)

        let panel = ShelfWindow(
            shelfID: store.id,
            stagingDirectory: store.stagingDirectory,
            contentRect: NSRect(origin: .zero, size: initialSize)
        )

        let shelfID = store.id
        let vc = ShelfViewController(
            store: store,
            dropHighlight: panel.dropContainerView.highlightState,
            onRequestClose: { [weak self] in
                self?.closeShelf(id: shelfID)
            },
            onRequestNewShelf: { [weak self] in
                guard let self else { return }
                let currentEdge = self.shelves.first(where: { $0.id == shelfID })?.dockedEdge ?? edge
                _ = self.createManualShelf(edge: currentEdge)
            },
            onRequestSettings: { [weak self] in
                self?.openSettings()
            },
            onRequestResize: { [weak self] newHeight in
                self?.resizeShelf(id: shelfID, height: newHeight)
            }
        )

        panel.attachHostingView(vc.view)

        let shelf = ShelfInstance(
            store: store,
            panel: panel,
            viewController: vc,
            dockedEdge: edge,
            dockedScreen: screen,
            expandedFrame: targetFrame
        )
        shelf.openedTemporarilyForDrag = temporaryForDrag

        panel.onManualMoveBegan = { [weak self, weak shelf] in
            guard let self, let shelf else { return }
            self.handleShelfManualMoveBegan(shelf)
        }
        panel.onManualMoveUpdated = { [weak self, weak shelf] frame, cursor in
            guard let self, let shelf else { return }
            self.handleShelfManualMoveUpdated(shelf, currentFrame: frame, cursorPoint: cursor)
        }
        panel.onManualMoveEnded = { [weak self, weak shelf] movedFrame in
            guard let self, let shelf else { return }
            self.handleShelfManualMoveEnded(shelf, movedFrame: movedFrame)
        }
        panel.dropContainerView.onHoverChanged = { [weak self, weak shelf] hovering in
            guard let self, let shelf else { return }
            self.handleShelfHoverChanged(shelf, isHovering: hovering)
        }
        panel.dropContainerView.onDragHoverChanged = { [weak self, weak shelf] dragHovering in
            guard let self, let shelf else { return }
            self.handleShelfDragHoverChanged(shelf, isDragHovering: dragHovering)
        }
        panel.dropContainerView.onItemsDropped = { [weak self, weak shelf] items in
            guard let self, let shelf else { return }
            self.handleItemsDropped(items, into: shelf)
        }
        panel.dropContainerView.onDraggingSessionEnded = { [weak self, weak shelf] in
            guard let self, let shelf else { return }
            if shelf.openedTemporarilyForDrag && shelf.store.items.isEmpty {
                self.scheduleTemporaryRetraction(for: shelf)
            } else {
                self.scheduleAutoHideIfEligible(shelf, delay: Constants.Shelf.postDropPeekGrace)
            }
        }

        store.$items
            .dropFirst()
            .sink { [weak self, weak shelf] items in
                guard let self, let shelf else { return }
                if items.isEmpty && AppSettings.shared.autoHideWhenEmpty && !shelf.openedTemporarilyForDrag {
                    self.closeShelf(id: shelf.id)
                }
            }
            .store(in: &shelf.cancellables)

        shelves.append(shelf)

        shelf.visibilityGeneration &+= 1
        panel.prepareForShow()
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1.0
        }

        if !temporaryForDrag {
            scheduleAutoHideIfEligible(shelf, delay: Constants.Shelf.postDropPeekGrace)
        }

        return shelf
    }

    private func presentExistingShelf(_ shelf: ShelfInstance) {
        shelf.pendingDropGraceTask?.cancel()
        shelf.pendingDropGraceTask = nil
        shelf.pendingAutoHideTask?.cancel()
        shelf.pendingAutoHideTask = nil
        shelf.openedTemporarilyForDrag = false
        shelf.isAutoHidden = false
        shelf.visibilityGeneration &+= 1

        let screen = shelf.dockedScreen ?? ScreenGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        let size = NSSize(
            width: Constants.Shelf.width,
            height: Constants.Shelf.preferredHeight(forItemCount: shelf.store.items.count)
        )

        if let screen {
            let targetFrame = computeDockedFrame(
                size: size,
                edge: shelf.dockedEdge,
                preferredCenterY: shelf.expandedFrame.midY == 0 ? screen.visibleFrame.midY : shelf.expandedFrame.midY,
                on: screen,
                excluding: shelf.id
            )
            shelf.expandedFrame = targetFrame
            let startFrame = offscreenStartFrame(from: targetFrame, edge: shelf.dockedEdge, on: screen)
            shelf.panel.prepareForShow()
            shelf.panel.setFrame(startFrame, display: false)
            shelf.panel.alphaValue = 0.0
            shelf.panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
                shelf.panel.animator().setFrame(targetFrame, display: true)
                shelf.panel.animator().alphaValue = 1.0
            }
        } else {
            shelf.panel.prepareForShow()
            shelf.panel.alphaValue = 1.0
            shelf.panel.orderFrontRegardless()
        }

        scheduleAutoHideIfEligible(shelf, delay: Constants.Shelf.postDropPeekGrace)
    }

    private func hideShelfAnimated(_ shelf: ShelfInstance, removeAfterHide: Bool) {
        shelf.pendingDropGraceTask?.cancel()
        shelf.pendingDropGraceTask = nil
        shelf.pendingAutoHideTask?.cancel()
        shelf.pendingAutoHideTask = nil
        shelf.openedTemporarilyForDrag = false
        shelf.isAutoHidden = false

        shelf.visibilityGeneration &+= 1
        let expectedGen = shelf.visibilityGeneration
        let panel = shelf.panel

        // CRITICAL (macOS 26 CoreDrag fix): Unregister dragged types & disable hit testing
        // BEFORE starting any hide/collapse animation.
        panel.prepareForHide()

        let finalize: @MainActor () -> Void = { [weak self, weak shelf] in
            guard let self, let shelf, shelf.visibilityGeneration == expectedGen else { return }
            shelf.panel.orderOut(nil)
            shelf.panel.alphaValue = 1.0
            if removeAfterHide {
                shelf.store.cleanupStagingDirectory()
                self.shelves.removeAll { $0.id == shelf.id }
            }
            self.updateAutoHideWatchdog()
        }

        guard panel.isVisible else {
            finalize()
            return
        }

        let screen = shelf.dockedScreen ?? ScreenGeometry.screen(containing: panel.frame.origin) ?? NSScreen.main
        let currentFrame = panel.frame
        let endFrame = screen.map { offscreenStartFrame(from: currentFrame, edge: shelf.dockedEdge, on: $0) } ?? currentFrame

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            MainActor.assumeIsolated {
                finalize()
            }
        })
    }

    func resizeShelf(id: UUID, height: CGFloat) {
        guard let shelf = shelves.first(where: { $0.id == id }) else { return }
        let panel = shelf.panel
        let oldExpanded = shelf.expandedFrame
        let width = Constants.Shelf.width
        guard abs(oldExpanded.height - height) > 1.0 || abs(oldExpanded.width - width) > 1.0 else { return }

        let screen = ScreenGeometry.screen(containing: NSPoint(x: oldExpanded.midX, y: oldExpanded.midY))
            ?? shelf.dockedScreen
            ?? NSScreen.main

        var newY = oldExpanded.maxY - height
        var newX = oldExpanded.origin.x

        if let screen {
            let visible = screen.visibleFrame
            let margin = Constants.Shelf.edgeMargin
            newX = min(max(newX, visible.minX + margin), visible.maxX - width - margin)
            let minY = visible.minY + margin
            let maxY = max(minY, visible.maxY - height - margin)
            let clampedY = min(max(newY, minY), maxY)

            let occupied = occupiedFramesByEdge(on: screen, excluding: shelf.id)
            let sameEdge = (shelf.dockedEdge == .left) ? occupied.left : occupied.right
            let sameColumn = sameEdge.filter { abs($0.origin.x - newX) <= 24 }
            if let resolvedY = ShelfLayoutSolver.resolveNonOverlappingY(
                desiredY: clampedY,
                height: height,
                minY: minY,
                maxY: maxY,
                gap: Constants.Shelf.stackSpacing,
                occupied: sameColumn
            ) {
                newY = resolvedY
            } else {
                newY = clampedY
            }
        }

        let newExpanded = NSRect(x: newX, y: newY, width: width, height: height)
        shelf.expandedFrame = newExpanded

        let targetFrame: NSRect
        if shelf.isAutoHidden, let screen {
            targetFrame = ShelfLayoutSolver.autoHideFrame(
                from: newExpanded,
                edge: shelf.dockedEdge,
                screenFrame: screen.frame,
                visibleWidth: currentAutoHideVisibleWidth()
            )
        } else {
            targetFrame = newExpanded
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    // MARK: - Drop & Drag Lifecycle

    private func handleItemsDropped(_ items: [ShelfItem], into shelf: ShelfInstance) {
        shelf.pendingDropGraceTask?.cancel()
        shelf.pendingDropGraceTask = nil
        shelf.openedTemporarilyForDrag = false
        shelf.store.addMany(items)
        revealShelfFromAutoHide(shelf)
        scheduleAutoHideIfEligible(shelf, delay: Constants.Shelf.postDropPeekGrace)
    }

    private func handleExternalDragEnded(droppedOnShelf: Bool) {
        for shelf in shelves {
            if shelf.openedTemporarilyForDrag {
                if droppedOnShelf && !shelf.store.items.isEmpty {
                    shelf.pendingDropGraceTask?.cancel()
                    shelf.pendingDropGraceTask = nil
                    shelf.openedTemporarilyForDrag = false
                    scheduleAutoHideIfEligible(shelf, delay: Constants.Shelf.postDropPeekGrace)
                } else {
                    scheduleTemporaryRetraction(for: shelf)
                }
            } else {
                scheduleAutoHideIfEligible(shelf, delay: Constants.Shelf.peekDelay)
            }
        }
    }

    private func scheduleTemporaryRetraction(for shelf: ShelfInstance) {
        shelf.pendingDropGraceTask?.cancel()
        let work = DispatchWorkItem { [weak self, weak shelf] in
            Task { @MainActor [weak self, weak shelf] in
                guard let self, let shelf else { return }
                shelf.pendingDropGraceTask = nil
                guard shelf.openedTemporarilyForDrag else { return }
                if shelf.store.items.isEmpty && !shelf.isDropTargeted {
                    self.hideShelfAnimated(shelf, removeAfterHide: true)
                } else {
                    shelf.openedTemporarilyForDrag = false
                    self.scheduleAutoHideIfEligible(shelf, delay: Constants.Shelf.postDropPeekGrace)
                }
            }
        }
        shelf.pendingDropGraceTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    // MARK: - Geometry Helpers

    private func computeDockedFrame(
        size: NSSize,
        edge: ScreenEdge,
        preferredCenterY: CGFloat,
        on screen: NSScreen,
        excluding excludedID: UUID
    ) -> NSRect {
        let occupiedFrames = shelves
            .filter { $0.id != excludedID && $0.isVisible && $0.dockedEdge == edge && $0.dockedScreen == screen }
            .map { $0.expandedFrame }

        return ShelfLayoutSolver.dockedFrame(
            size: size,
            edge: edge,
            preferredCenterY: preferredCenterY,
            visibleFrame: screen.visibleFrame,
            existingFramesOnSameEdge: occupiedFrames
        )
    }

    private func offscreenStartFrame(from frame: NSRect, edge: ScreenEdge, on screen: NSScreen) -> NSRect {
        let thinWidth: CGFloat = 14
        let x: CGFloat = (edge == .left) ? screen.frame.minX : (screen.frame.maxX - thinWidth)
        return NSRect(x: x, y: frame.origin.y, width: thinWidth, height: frame.height)
    }
}
