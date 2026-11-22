import AppKit
import Foundation

@MainActor
final class EdgeTrigger: ShelfTrigger {
    private struct CachedScreenMetrics {
        let screen: NSScreen
        let frame: NSRect
        let visibleFrame: NSRect
        let hasLeftAdjacent: Bool
        let hasRightAdjacent: Bool
    }

    var isEnabled: Bool = true
    var onTrigger: ((TriggerEvent) -> Void)?
    var onDragEnded: ((Bool) -> Void)?

    private var observerID: UUID?
    private var screenParamsObserver: NSObjectProtocol?
    private var dwellTimer: Timer?
    private var pendingEdge: ScreenEdge?
    private var pendingScreen: NSScreen?
    private var triggeredEdgeForCurrentVisit: ScreenEdge?

    // Pooled indicator windows reused across drags (released on stop()).
    private var leftIndicator: EdgeIndicatorWindow?
    private var rightIndicator: EdgeIndicatorWindow?
    private var indicatorScreen: NSScreen?
    private var indicatorsVisible = false

    // Per-drag display geometry cache (invalidated on drag end & screen parameter changes).
    private var cachedScreens: [CachedScreenMetrics] = []
    private var lastMatchedScreenIndex: Int?

    func start() {
        guard observerID == nil else { return }
        observerID = GlobalDragMonitor.shared.addObserver(
            onDragBegan: { [weak self] location in
                self?.handleDragBegan(at: location)
            },
            onDragMoved: { [weak self] location, _, _ in
                self?.handleDragMoved(at: location)
            },
            onDragEnded: { [weak self] droppedOnShelf in
                self?.handleDragEnded(droppedOnShelf: droppedOnShelf)
            }
        )
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateScreenCache()
            }
        }
    }

    func stop() {
        if let observerID {
            GlobalDragMonitor.shared.removeObserver(id: observerID)
            self.observerID = nil
        }
        if let screenParamsObserver {
            NotificationCenter.default.removeObserver(screenParamsObserver)
            self.screenParamsObserver = nil
        }
        cancelDwell()
        hideIndicators()
        leftIndicator?.orderOut(nil)
        leftIndicator?.close()
        leftIndicator = nil
        rightIndicator?.orderOut(nil)
        rightIndicator?.close()
        rightIndicator = nil
        invalidateScreenCache()
        triggeredEdgeForCurrentVisit = nil
    }

    func cancelActiveEdgeSession() {
        cancelDwell()
        hideIndicators()
        triggeredEdgeForCurrentVisit = nil
    }

    // MARK: - Drag Lifecycle

    private func handleDragBegan(at location: NSPoint) {
        triggeredEdgeForCurrentVisit = nil
        cancelDwell()
        refreshScreenCache()

        guard isEnabled, AppSettings.shared.edgeEnabled else { return }
        if AppSettings.shared.showEdgeIndicators,
           let metrics = cachedMetrics(containing: location) {
            showIndicators(on: metrics, at: location)
        }
        evaluateEdge(at: location)
    }

    private func handleDragMoved(at location: NSPoint) {
        guard isEnabled, AppSettings.shared.edgeEnabled else {
            cancelDwell()
            hideIndicators()
            return
        }
        evaluateEdge(at: location)
    }

    private func handleDragEnded(droppedOnShelf: Bool) {
        cancelDwell()
        hideIndicators()
        invalidateScreenCache()
        triggeredEdgeForCurrentVisit = nil
        onDragEnded?(droppedOnShelf)
    }

    // MARK: - Per-Drag Screen Geometry Cache

    private func refreshScreenCache() {
        let screens = NSScreen.screens
        cachedScreens = screens.map { screen in
            CachedScreenMetrics(
                screen: screen,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                hasLeftAdjacent: ScreenGeometry.hasAdjacentScreen(to: screen, on: .left),
                hasRightAdjacent: ScreenGeometry.hasAdjacentScreen(to: screen, on: .right)
            )
        }
        lastMatchedScreenIndex = nil
    }

    private func invalidateScreenCache() {
        cachedScreens.removeAll()
        lastMatchedScreenIndex = nil
    }

    private func cachedMetrics(containing point: NSPoint) -> CachedScreenMetrics? {
        if cachedScreens.isEmpty {
            refreshScreenCache()
        }
        guard !cachedScreens.isEmpty else { return nil }

        if let lastIndex = lastMatchedScreenIndex,
           lastIndex < cachedScreens.count,
           NSMouseInRect(point, cachedScreens[lastIndex].frame, false) {
            return cachedScreens[lastIndex]
        }

        if let exactIndex = cachedScreens.firstIndex(where: { NSMouseInRect(point, $0.frame, false) }) {
            lastMatchedScreenIndex = exactIndex
            return cachedScreens[exactIndex]
        }

        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, metrics) in cachedScreens.enumerated() {
            let rect = metrics.frame
            let clampedX = min(max(point.x, rect.minX), rect.maxX)
            let clampedY = min(max(point.y, rect.minY), rect.maxY)
            let dx = point.x - clampedX
            let dy = point.y - clampedY
            let distSq = dx * dx + dy * dy
            if distSq < bestDistance {
                bestDistance = distSq
                bestIndex = index
            }
        }
        lastMatchedScreenIndex = bestIndex
        return cachedScreens[bestIndex]
    }

    // MARK: - Edge Detection

    private func evaluateEdge(at location: NSPoint) {
        guard let metrics = cachedMetrics(containing: location) else { return }

        if AppSettings.shared.showEdgeIndicators && triggeredEdgeForCurrentVisit == nil {
            if !indicatorsVisible || indicatorScreen != metrics.screen {
                showIndicators(on: metrics, at: location)
            } else {
                updateIndicatorProximity(location: location, metrics: metrics)
            }
        }

        let distToLeft = location.x - metrics.frame.minX
        let distToRight = metrics.frame.maxX - location.x

        // Rearm if cursor moved far enough away from previously triggered edge
        let sensitivity = AppSettings.shared.edgeCreationSensitivity
        if let triggered = triggeredEdgeForCurrentVisit {
            let awayDistance = triggered == .left ? distToLeft : distToRight
            if awayDistance > sensitivity.rearmDistance {
                triggeredEdgeForCurrentVisit = nil
            } else {
                cancelDwell()
                return
            }
        }

        if let (edge, dwellDuration) = Self.evaluateMatchedEdge(
            distToLeft: distToLeft,
            distToRight: distToRight,
            hasLeftAdjacent: metrics.hasLeftAdjacent,
            hasRightAdjacent: metrics.hasRightAdjacent,
            leftAllowed: AppSettings.shared.isEdgeAllowed(.left),
            rightAllowed: AppSettings.shared.isEdgeAllowed(.right),
            sensitivity: sensitivity
        ) {
            scheduleDwell(edge: edge, screen: metrics.screen, duration: dwellDuration)
        } else {
            cancelDwell()
        }
    }

    static func evaluateMatchedEdge(
        distToLeft: CGFloat,
        distToRight: CGFloat,
        hasLeftAdjacent: Bool,
        hasRightAdjacent: Bool,
        leftAllowed: Bool,
        rightAllowed: Bool,
        sensitivity: EdgeCreationSensitivity
    ) -> (ScreenEdge, TimeInterval)? {
        let outerZone = sensitivity.outerEdgeZone
        let sharedZone = sensitivity.sharedEdgeZone

        if leftAllowed {
            if hasLeftAdjacent {
                if distToLeft <= sharedZone {
                    return (.left, Constants.Trigger.sharedEdgeDwell)
                }
            } else if distToLeft <= Constants.Trigger.outerEdgeImmediateZone {
                return (.left, Constants.Trigger.outerImmediateDwell)
            } else if distToLeft <= outerZone {
                return (.left, Constants.Trigger.outerNormalDwell)
            }
        }

        if rightAllowed {
            if hasRightAdjacent {
                if distToRight <= sharedZone {
                    return (.right, Constants.Trigger.sharedEdgeDwell)
                }
            } else if distToRight <= Constants.Trigger.outerEdgeImmediateZone {
                return (.right, Constants.Trigger.outerImmediateDwell)
            } else if distToRight <= outerZone {
                return (.right, Constants.Trigger.outerNormalDwell)
            }
        }

        return nil
    }

    private func scheduleDwell(edge: ScreenEdge, screen: NSScreen, duration: TimeInterval) {
        if pendingEdge == edge, pendingScreen == screen, dwellTimer != nil {
            return
        }

        cancelDwell()
        pendingEdge = edge
        pendingScreen = screen

        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let fallbackScreen = self.pendingScreen
                self.dwellTimer = nil
                self.pendingEdge = nil
                self.pendingScreen = nil

                // Verify mouse is still pressed and still near the screen edge
                guard (NSEvent.pressedMouseButtons & 1) != 0 else { return }
                let currentLocation = NSEvent.mouseLocation
                guard let currentScreen = self.cachedMetrics(containing: currentLocation)?.screen
                    ?? ScreenGeometry.screen(containing: currentLocation)
                    ?? fallbackScreen else {
                    return
                }

                self.triggeredEdgeForCurrentVisit = edge
                self.hideIndicators()
                self.onTrigger?(.edge(edge: edge, location: currentLocation, screen: currentScreen))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        pendingEdge = nil
        pendingScreen = nil
    }

    // MARK: - Pooled Edge Glow Indicators

    private func showIndicators(on metrics: CachedScreenMetrics, at location: NSPoint) {
        let settings = AppSettings.shared
        guard settings.showEdgeIndicators else {
            hideIndicators()
            return
        }

        indicatorScreen = metrics.screen
        indicatorsVisible = true

        let zone = Constants.Trigger.indicatorProximityZone
        let distToLeft = location.x - metrics.frame.minX
        let distToRight = metrics.frame.maxX - location.x

        if settings.isEdgeAllowed(.left) {
            let left: EdgeIndicatorWindow
            if let existing = leftIndicator {
                left = existing
            } else {
                left = EdgeIndicatorWindow(edge: .left, screen: metrics.screen, centerY: location.y)
                leftIndicator = left
            }
            left.repositionVertically(
                around: location.y,
                screenFrame: metrics.frame,
                visibleFrame: metrics.visibleFrame,
                force: true
            )
            let proximity = distToLeft < zone ? (1.0 - distToLeft / zone) : 0
            left.fadeIn(initialProximity: proximity)
        } else {
            leftIndicator?.fadeOut()
        }

        if settings.isEdgeAllowed(.right) {
            let right: EdgeIndicatorWindow
            if let existing = rightIndicator {
                right = existing
            } else {
                right = EdgeIndicatorWindow(edge: .right, screen: metrics.screen, centerY: location.y)
                rightIndicator = right
            }
            right.repositionVertically(
                around: location.y,
                screenFrame: metrics.frame,
                visibleFrame: metrics.visibleFrame,
                force: true
            )
            let proximity = distToRight < zone ? (1.0 - distToRight / zone) : 0
            right.fadeIn(initialProximity: proximity)
        } else {
            rightIndicator?.fadeOut()
        }
    }

    private func hideIndicators() {
        indicatorsVisible = false
        indicatorScreen = nil
        leftIndicator?.fadeOut()
        rightIndicator?.fadeOut()
    }

    private func updateIndicatorProximity(location: NSPoint, metrics: CachedScreenMetrics) {
        let settings = AppSettings.shared
        let zone = Constants.Trigger.indicatorProximityZone
        let distToLeft = location.x - metrics.frame.minX
        let distToRight = metrics.frame.maxX - location.x

        if settings.isEdgeAllowed(.left), let leftIndicator {
            leftIndicator.repositionVertically(
                around: location.y,
                screenFrame: metrics.frame,
                visibleFrame: metrics.visibleFrame
            )
            let proximity = distToLeft < zone ? (1.0 - distToLeft / zone) : 0
            leftIndicator.updateProximity(proximity)
        }

        if settings.isEdgeAllowed(.right), let rightIndicator {
            rightIndicator.repositionVertically(
                around: location.y,
                screenFrame: metrics.frame,
                visibleFrame: metrics.visibleFrame
            )
            let proximity = distToRight < zone ? (1.0 - distToRight / zone) : 0
            rightIndicator.updateProximity(proximity)
        }
    }
}
