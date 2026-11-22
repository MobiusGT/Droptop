import AppKit
import Foundation

@MainActor
final class EdgeTrigger: ShelfTrigger {
    var isEnabled: Bool = true
    var onTrigger: ((TriggerEvent) -> Void)?
    var onDragEnded: ((Bool) -> Void)?

    private var observerID: UUID?
    private var dwellTimer: Timer?
    private var pendingEdge: ScreenEdge?
    private var pendingScreen: NSScreen?
    private var triggeredEdgeForCurrentVisit: ScreenEdge?

    private var leftIndicator: EdgeIndicatorWindow?
    private var rightIndicator: EdgeIndicatorWindow?
    private var indicatorScreen: NSScreen?
    private var indicatorsVisible = false

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
    }

    func stop() {
        if let observerID {
            GlobalDragMonitor.shared.removeObserver(id: observerID)
            self.observerID = nil
        }
        cancelDwell()
        hideIndicators()
        triggeredEdgeForCurrentVisit = nil
    }

    // MARK: - Drag Lifecycle

    private func handleDragBegan(at location: NSPoint) {
        triggeredEdgeForCurrentVisit = nil
        cancelDwell()

        guard isEnabled, AppSettings.shared.edgeEnabled else { return }
        if AppSettings.shared.showEdgeIndicators,
           let screen = ScreenGeometry.screen(containing: location) {
            showIndicators(on: screen, nearY: location.y)
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
        triggeredEdgeForCurrentVisit = nil
        onDragEnded?(droppedOnShelf)
    }

    // MARK: - Edge Detection

    private func evaluateEdge(at location: NSPoint) {
        guard let screen = ScreenGeometry.screen(containing: location) else { return }

        if AppSettings.shared.showEdgeIndicators && triggeredEdgeForCurrentVisit == nil {
            if !indicatorsVisible || indicatorScreen != screen {
                showIndicators(on: screen, nearY: location.y)
            }
            updateIndicatorProximity(location: location, screen: screen)
        }

        let distToLeft = location.x - screen.frame.minX
        let distToRight = screen.frame.maxX - location.x

        // Rearm if cursor moved far enough away from previously triggered edge
        if let triggered = triggeredEdgeForCurrentVisit {
            let awayDistance = triggered == .left ? distToLeft : distToRight
            if awayDistance > Constants.Trigger.rearmDistance {
                triggeredEdgeForCurrentVisit = nil
            } else {
                cancelDwell()
                return
            }
        }

        if let (edge, dwellDuration) = matchedEdge(
            distToLeft: distToLeft,
            distToRight: distToRight,
            screen: screen
        ) {
            scheduleDwell(edge: edge, screen: screen, duration: dwellDuration)
        } else {
            cancelDwell()
        }
    }

    private func matchedEdge(
        distToLeft: CGFloat,
        distToRight: CGFloat,
        screen: NSScreen
    ) -> (ScreenEdge, TimeInterval)? {
        let settings = AppSettings.shared

        if settings.isEdgeAllowed(.left) {
            let isShared = ScreenGeometry.hasAdjacentScreen(to: screen, on: .left)
            if isShared {
                if distToLeft <= Constants.Trigger.sharedEdgeZone {
                    return (.left, Constants.Trigger.sharedEdgeDwell)
                }
            } else if distToLeft <= Constants.Trigger.outerEdgeImmediateZone {
                return (.left, Constants.Trigger.outerImmediateDwell)
            } else if distToLeft <= Constants.Trigger.outerEdgeZone {
                return (.left, Constants.Trigger.outerNormalDwell)
            }
        }

        if settings.isEdgeAllowed(.right) {
            let isShared = ScreenGeometry.hasAdjacentScreen(to: screen, on: .right)
            if isShared {
                if distToRight <= Constants.Trigger.sharedEdgeZone {
                    return (.right, Constants.Trigger.sharedEdgeDwell)
                }
            } else if distToRight <= Constants.Trigger.outerEdgeImmediateZone {
                return (.right, Constants.Trigger.outerImmediateDwell)
            } else if distToRight <= Constants.Trigger.outerEdgeZone {
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                let fallbackScreen = self.pendingScreen
                self.dwellTimer = nil
                self.pendingEdge = nil
                self.pendingScreen = nil

                // Verify mouse is still pressed and still near the screen edge
                guard (NSEvent.pressedMouseButtons & 1) != 0 else { return }
                let currentLocation = NSEvent.mouseLocation
                guard let currentScreen = ScreenGeometry.screen(containing: currentLocation) ?? fallbackScreen else {
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

    // MARK: - Edge Glow Indicators

    private func showIndicators(on screen: NSScreen, nearY y: CGFloat) {
        hideIndicators()
        let settings = AppSettings.shared
        guard settings.showEdgeIndicators else { return }

        indicatorScreen = screen
        indicatorsVisible = true

        if settings.isEdgeAllowed(.left) {
            let left = EdgeIndicatorWindow(edge: .left, screen: screen, centerY: y)
            left.fadeIn()
            leftIndicator = left
        }
        if settings.isEdgeAllowed(.right) {
            let right = EdgeIndicatorWindow(edge: .right, screen: screen, centerY: y)
            right.fadeIn()
            rightIndicator = right
        }
    }

    private func hideIndicators() {
        indicatorsVisible = false
        indicatorScreen = nil

        let oldLeft = leftIndicator
        let oldRight = rightIndicator
        leftIndicator = nil
        rightIndicator = nil

        oldLeft?.fadeOut()
        oldRight?.fadeOut()
    }

    private func updateIndicatorProximity(location: NSPoint, screen: NSScreen) {
        let zone = Constants.Trigger.indicatorProximityZone
        let distToLeft = location.x - screen.frame.minX
        let distToRight = screen.frame.maxX - location.x

        if let leftIndicator {
            leftIndicator.repositionVertically(around: location.y, on: screen)
            let proximity = distToLeft < zone ? (1.0 - distToLeft / zone) : 0
            leftIndicator.updateProximity(proximity)
        }

        if let rightIndicator {
            rightIndicator.repositionVertically(around: location.y, on: screen)
            let proximity = distToRight < zone ? (1.0 - distToRight / zone) : 0
            rightIndicator.updateProximity(proximity)
        }
    }
}
