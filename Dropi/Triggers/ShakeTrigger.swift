import AppKit
import Foundation

@MainActor
final class ShakeTrigger: ShelfTrigger {
    var isEnabled: Bool = false
    var onTrigger: ((TriggerEvent) -> Void)?

    private var observerID: UUID?
    private var directionChanges: [Date] = []
    private var lastDirection: Int = 0
    private var cooldownUntil: Date = .distantPast

    private let requiredChanges = 3
    private let timeWindow: TimeInterval = 0.45
    private let minimumDelta: CGFloat = 6.0
    private let cooldownDuration: TimeInterval = 1.0

    func start() {
        guard observerID == nil else { return }
        observerID = GlobalDragMonitor.shared.addObserver(
            onDragBegan: { [weak self] _ in
                self?.resetState()
            },
            onDragMoved: { [weak self] location, deltaX, _ in
                self?.handleMove(location: location, deltaX: deltaX)
            },
            onDragEnded: { [weak self] _ in
                self?.resetState()
            }
        )
    }

    func stop() {
        if let observerID {
            GlobalDragMonitor.shared.removeObserver(id: observerID)
            self.observerID = nil
        }
        resetState()
    }

    private func resetState() {
        directionChanges.removeAll()
        lastDirection = 0
    }

    private func handleMove(location: NSPoint, deltaX: CGFloat) {
        guard isEnabled, Date() > cooldownUntil else { return }
        guard abs(deltaX) >= minimumDelta else { return }

        let direction = deltaX > 0 ? 1 : -1
        guard direction != lastDirection, lastDirection != 0 else {
            lastDirection = direction
            return
        }
        lastDirection = direction

        let now = Date()
        directionChanges.append(now)
        directionChanges.removeAll { now.timeIntervalSince($0) > timeWindow }

        if directionChanges.count >= requiredChanges {
            cooldownUntil = now.addingTimeInterval(cooldownDuration)
            directionChanges.removeAll()
            onTrigger?(.shake(location: location))
        }
    }
}
