import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import os

private let dragMonitorLogger = Logger(subsystem: "com.local.Droptop", category: "GlobalDragMonitor")

/// Pure, testable state tracker for distinguishing genuine macOS drag-and-drop sessions
/// (including drags started from Dock folder stacks) from Finder marquee multi-select,
/// text selection, or window dragging.
struct DragSessionStateMachine {
    private(set) var isTrackingMouseDown = false
    private(set) var isInternalSession = false
    private(set) var isValidatedExternalDrag = false
    private(set) var mouseDownLocation: NSPoint = .zero
    private(set) var dragChangeCountAtDown: Int = 0
    private(set) var lastObservedDragChangeCount: Int = 0
    private(set) var droppedOnShelf = false

    init(initialDragChangeCount: Int) {
        self.dragChangeCountAtDown = initialDragChangeCount
        self.lastObservedDragChangeCount = initialDragChangeCount
    }

    enum Transition: Equatable {
        case none
        case beganExternalDrag(NSPoint)
        case movedExternalDrag(NSPoint)
        case endedExternalDrag(droppedOnShelf: Bool)
    }

    mutating func mouseDown(
        at location: NSPoint,
        isInternal: Bool,
        currentDragChangeCount: Int
    ) -> Transition {
        let priorTransition: Transition
        if isValidatedExternalDrag {
            priorTransition = .endedExternalDrag(droppedOnShelf: droppedOnShelf)
        } else {
            priorTransition = .none
        }

        isTrackingMouseDown = true
        isInternalSession = isInternal
        isValidatedExternalDrag = false
        droppedOnShelf = false
        mouseDownLocation = location

        // IMPORTANT (Dock.app race fix): If an external app/Dock already bumped the drag pasteboard
        // just BEFORE our async leftMouseDown notification arrived, keep the previous baseline
        // (`lastObservedDragChangeCount`) so we do NOT mask the drag-start transition!
        if !isInternal && currentDragChangeCount != lastObservedDragChangeCount {
            dragChangeCountAtDown = lastObservedDragChangeCount
        } else {
            dragChangeCountAtDown = currentDragChangeCount
            lastObservedDragChangeCount = currentDragChangeCount
        }
        return priorTransition
    }

    mutating func mouseMovedOrPolled(
        at location: NSPoint,
        isLeftButtonPressed: Bool,
        isDraggingFromShelf: Bool,
        currentDragChangeCount: Int,
        pasteboardHasSupportedPayload: () -> Bool,
        hasExternalDraggingWindow: () -> Bool = { false }
    ) -> Transition {
        if !isLeftButtonPressed {
            return mouseUp(currentDragChangeCount: currentDragChangeCount)
        }

        if isDraggingFromShelf || isInternalSession {
            lastObservedDragChangeCount = currentDragChangeCount
            return .none
        }

        if isValidatedExternalDrag {
            lastObservedDragChangeCount = currentDragChangeCount
            return .movedExternalDrag(location)
        }

        // Case A: Standard path after leftMouseDown
        if isTrackingMouseDown {
            let movedDistance = hypot(location.x - mouseDownLocation.x, location.y - mouseDownLocation.y)
            guard movedDistance >= Constants.Trigger.dragMovementThreshold else { return .none }

            let pasteboardChanged = (currentDragChangeCount != dragChangeCountAtDown) && pasteboardHasSupportedPayload()
            guard pasteboardChanged || hasExternalDraggingWindow() else { return .none }

            isValidatedExternalDrag = true
            lastObservedDragChangeCount = currentDragChangeCount
            return .beganExternalDrag(location)
        }

        // Case B: Recovery path when leftMouseDown was swallowed by a privileged system process
        // (such as Dock.app when dragging a file out of a folder stack in the Dock).
        let pasteboardChanged = (currentDragChangeCount != lastObservedDragChangeCount) && pasteboardHasSupportedPayload()
        if pasteboardChanged || hasExternalDraggingWindow() {
            isTrackingMouseDown = true
            isInternalSession = false
            isValidatedExternalDrag = true
            droppedOnShelf = false
            mouseDownLocation = location
            dragChangeCountAtDown = lastObservedDragChangeCount
            lastObservedDragChangeCount = currentDragChangeCount
            return .beganExternalDrag(location)
        }

        return .none
    }

    mutating func markDroppedOnShelf(currentDragChangeCount: Int) -> Transition {
        droppedOnShelf = true
        return mouseUp(currentDragChangeCount: currentDragChangeCount)
    }

    mutating func mouseUp(currentDragChangeCount: Int) -> Transition {
        let wasDrag = isValidatedExternalDrag
        let didDrop = droppedOnShelf

        isTrackingMouseDown = false
        isInternalSession = false
        isValidatedExternalDrag = false
        droppedOnShelf = false
        dragChangeCountAtDown = currentDragChangeCount
        lastObservedDragChangeCount = currentDragChangeCount

        return wasDrag ? .endedExternalDrag(droppedOnShelf: didDrop) : .none
    }

    mutating func syncAfterInternalDrag(currentDragChangeCount: Int) {
        isTrackingMouseDown = false
        isInternalSession = false
        isValidatedExternalDrag = false
        droppedOnShelf = false
        dragChangeCountAtDown = currentDragChangeCount
        lastObservedDragChangeCount = currentDragChangeCount
    }
}

private final class EventTapBox: @unchecked Sendable {
    var tap: CFMachPort?
    var onMouseEvent: (@Sendable (CGEventType, CGFloat, CGFloat) -> Void)?
    var onTapPermanentlyDisabled: (@Sendable () -> Void)?
}

/// Passive, zero-interference global drag monitor.
/// - Never intercepts or blocks mouse events (safe for Finder marquee multi-select).
/// - Uses a single event source: a synchronous `.listenOnly` CGEventTap on the main run loop
///   when permitted (with timeout auto-recovery), falling back cleanly to passive NSEvent monitors
///   whenever the tap is unavailable or disabled.
/// - Detects drags originating from Dock folder stacks via BOTH drag-pasteboard delta
///   AND rate-limited macOS layer-500 (`CGWindowLevelForKey(.draggingWindow)`) window detection.
/// - Uses an active-session watchdog checking `NSEvent.pressedMouseButtons`
///   so drag state ALWAYS resets cleanly even if macOS suppresses a global `leftMouseUp`.
@MainActor
final class GlobalDragMonitor {
    static let shared = GlobalDragMonitor()

    struct Observer {
        let id: UUID
        let onDragBegan: (NSPoint) -> Void
        let onDragMoved: (NSPoint, CGFloat, CGFloat) -> Void
        let onDragEnded: (Bool) -> Void
    }

    private var observers: [Observer] = []
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var stateMachine: DragSessionStateMachine

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var watchdogTimer: Timer?
    private var dockRecoveryTimer: Timer?
    private var lastEventLocation: NSPoint = .zero
    private var isStarted = false

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let draggingWindowLayer = Int(CGWindowLevelForKey(.draggingWindow))
    private let windowProbeCacheTTL: CFTimeInterval = 0.15
    private var lastWindowProbe: (timestamp: CFTimeInterval, result: Bool) = (0, false)

    private var eventTapBox: EventTapBox?
    private var eventTapRunLoopSource: CFRunLoopSource?

    var isMonitoringActive: Bool {
        isStarted
    }

    var hasActiveWatchdog: Bool {
        watchdogTimer != nil
    }

    private init() {
        self.stateMachine = DragSessionStateMachine(initialDragChangeCount: dragPasteboard.changeCount)
    }

    @discardableResult
    func addObserver(
        onDragBegan: @escaping (NSPoint) -> Void,
        onDragMoved: @escaping (NSPoint, CGFloat, CGFloat) -> Void,
        onDragEnded: @escaping (Bool) -> Void
    ) -> UUID {
        let id = UUID()
        observers.append(Observer(
            id: id,
            onDragBegan: onDragBegan,
            onDragMoved: onDragMoved,
            onDragEnded: onDragEnded
        ))
        return id
    }

    func removeObserver(id: UUID) {
        observers.removeAll { $0.id == id }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        resetWindowProbeCache()
        stateMachine.syncAfterInternalDrag(currentDragChangeCount: dragPasteboard.changeCount)

        // Prefer the listen-only CGEventTap (covers the exact same leftMouseDown/Dragged/Up
        // mask as NSEvent monitors with zero duplicate processing). Fall back to passive
        // NSEvent global + local monitors whenever the tap is unavailable or disabled.
        if !installListenOnlyEventTapIfPermitted() {
            installCocoaMonitorsIfNeeded()
        }
        startDockRecoveryProbe()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        resetWindowProbeCache()

        removeCocoaMonitors()
        removeEventTap()
        stopWatchdog()
        stopDockRecoveryProbe()

        let transition = stateMachine.mouseUp(currentDragChangeCount: dragPasteboard.changeCount)
        dispatch(transition, deltaX: 0, deltaY: 0)
    }

    func notifyDropCompletedOnShelf() {
        stopWatchdog()
        resetWindowProbeCache()
        let transition = stateMachine.markDroppedOnShelf(currentDragChangeCount: dragPasteboard.changeCount)
        dispatch(transition, deltaX: 0, deltaY: 0)
    }

    func syncAfterInternalDragEnded() {
        stopWatchdog()
        resetWindowProbeCache()
        stateMachine.syncAfterInternalDrag(currentDragChangeCount: dragPasteboard.changeCount)
    }

    func refreshEventTapIfNeeded() {
        guard isStarted, eventTapBox == nil else { return }
        if installListenOnlyEventTapIfPermitted() {
            removeCocoaMonitors()
        }
    }

    // MARK: - Passive NSEvent Fallback Monitors

    private func installCocoaMonitorsIfNeeded() {
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]

        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.processCocoaEvent(event, isLocal: false)
                }
            }
        }

        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
                self?.processCocoaEvent(event, isLocal: true)
                return event
            }
        }
    }

    private func removeCocoaMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    // MARK: - System Dragging Window Detection (Layer 500 — Catches Dock Folder Stack Drags!)

    private func resetWindowProbeCache() {
        lastWindowProbe = (0, false)
    }

    /// Detects active macOS CoreDrag dragging-image windows (`kCGDraggingWindowLevel` = 500)
    /// owned by external processes (such as `Dock.app` when dragging from a Dock folder stack).
    /// Finder marquee multi-select and normal window dragging NEVER create a layer-500 window.
    private func hasActiveExternalDraggingWindow() -> Bool {
        let now = CACurrentMediaTime()
        if lastWindowProbe.timestamp > 0, (now - lastWindowProbe.timestamp) < windowProbeCacheTTL {
            return lastWindowProbe.result
        }

        var found = false
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for info in list {
                guard let layer = info[kCGWindowLayer as String] as? Int,
                      layer == draggingWindowLayer else {
                    continue
                }
                let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
                if pid != ownPID {
                    found = true
                    break
                }
            }
        }

        lastWindowProbe = (now, found)
        return found
    }

    // MARK: - Event Processing

    private func processCocoaEvent(_ event: NSEvent, isLocal: Bool) {
        guard isStarted else { return }
        let location = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            FilenameTooltipController.shared.hide()
            handleMouseDown(at: location, isLocal: isLocal)
        case .leftMouseDragged:
            let dx = event.deltaX
            let dy = event.deltaY
            lastEventLocation = location
            handleMouseMoved(at: location, deltaX: dx, deltaY: dy)
        case .leftMouseUp:
            handleMouseUp()
        default:
            break
        }
    }

    func handleTapEvent(_ type: CGEventType, deltaX: CGFloat = 0, deltaY: CGFloat = 0) {
        guard isStarted else { return }
        let location = NSEvent.mouseLocation
        switch type {
        case .leftMouseDown:
            FilenameTooltipController.shared.hide()
            let isInsideOwnWindow = isPointInInteractiveOwnWindow(location)
            handleMouseDown(at: location, isLocal: isInsideOwnWindow)
        case .leftMouseDragged:
            let resolvedDX = (deltaX != 0 || deltaY != 0) ? deltaX : (location.x - lastEventLocation.x)
            let resolvedDY = (deltaX != 0 || deltaY != 0) ? deltaY : (location.y - lastEventLocation.y)
            lastEventLocation = location
            handleMouseMoved(at: location, deltaX: resolvedDX, deltaY: resolvedDY)
        case .leftMouseUp:
            handleMouseUp()
        default:
            break
        }
    }

    private func handleTapPermanentlyDisabled() {
        removeEventTap()
        guard isStarted else { return }
        dragMonitorLogger.info("Listen-only CGEventTap disabled; falling back to passive NSEvent monitors.")
        installCocoaMonitorsIfNeeded()
    }

    private func handleMouseDown(at location: NSPoint, isLocal: Bool) {
        resetWindowProbeCache()
        lastEventLocation = location
        let isInternal = isLocal || SelfDragState.isDraggingFromShelf || isPointInInteractiveOwnWindow(location)
        let priorTransition = stateMachine.mouseDown(
            at: location,
            isInternal: isInternal,
            currentDragChangeCount: dragPasteboard.changeCount
        )
        dispatch(priorTransition, deltaX: 0, deltaY: 0)

        if !isInternal {
            startWatchdog()
        } else {
            stopWatchdog()
        }
    }

    private func handleMouseMoved(at location: NSPoint, deltaX: CGFloat, deltaY: CGFloat) {
        let leftPressed = (NSEvent.pressedMouseButtons & 1) != 0
        let transition = stateMachine.mouseMovedOrPolled(
            at: location,
            isLeftButtonPressed: leftPressed,
            isDraggingFromShelf: SelfDragState.isDraggingFromShelf,
            currentDragChangeCount: dragPasteboard.changeCount,
            pasteboardHasSupportedPayload: { [dragPasteboard] in
                PasteboardHandler.canAccept(dragPasteboard)
            },
            hasExternalDraggingWindow: { [weak self] in
                self?.hasActiveExternalDraggingWindow() ?? false
            }
        )

        if case .beganExternalDrag = transition {
            startWatchdog()
        } else if case .endedExternalDrag = transition {
            stopWatchdog()
        }

        dispatch(transition, deltaX: deltaX, deltaY: deltaY)
    }

    private func handleMouseUp() {
        stopWatchdog()
        resetWindowProbeCache()
        let transition = stateMachine.mouseUp(currentDragChangeCount: dragPasteboard.changeCount)
        dispatch(transition, deltaX: 0, deltaY: 0)
    }

    private func dispatch(_ transition: DragSessionStateMachine.Transition, deltaX: CGFloat, deltaY: CGFloat) {
        switch transition {
        case .none:
            break
        case .beganExternalDrag(let location):
            for observer in observers {
                observer.onDragBegan(location)
            }
        case .movedExternalDrag(let location):
            for observer in observers {
                observer.onDragMoved(location, deltaX, deltaY)
            }
        case .endedExternalDrag(let droppedOnShelf):
            for observer in observers {
                observer.onDragEnded(droppedOnShelf)
            }
        }
    }

    private func isPointInInteractiveOwnWindow(_ point: NSPoint) -> Bool {
        NSApp.windows.contains { window in
            window.isVisible && !window.ignoresMouseEvents && window.frame.contains(point)
        }
    }

    // MARK: - Dock Drag Recovery Probe (Zero IPC When Idle)

    private func startDockRecoveryProbe() {
        guard dockRecoveryTimer == nil else { return }
        let timer = Timer(timeInterval: Constants.Trigger.dockDragRecoveryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dockRecoveryTick()
            }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        dockRecoveryTimer = timer
    }

    private func stopDockRecoveryProbe() {
        dockRecoveryTimer?.invalidate()
        dockRecoveryTimer = nil
    }

    private func dockRecoveryTick() {
        // Fast path when idle or already tracking: zero pasteboard/WindowServer IPC
        guard watchdogTimer == nil,
              !SelfDragState.isDraggingFromShelf,
              (NSEvent.pressedMouseButtons & 1) != 0 else {
            return
        }

        let location = NSEvent.mouseLocation
        guard !isPointInInteractiveOwnWindow(location) else { return }

        let currentCount = dragPasteboard.changeCount
        let countChanged = currentCount != stateMachine.lastObservedDragChangeCount
        guard countChanged || hasActiveExternalDraggingWindow() else { return }

        lastEventLocation = location
        handleMouseMoved(at: location, deltaX: 0, deltaY: 0)
    }

    // MARK: - Active-Session Watchdog

    private func startWatchdog() {
        guard watchdogTimer == nil else { return }
        let timer = Timer(timeInterval: Constants.Trigger.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.watchdogTick()
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func watchdogTick() {
        let leftPressed = (NSEvent.pressedMouseButtons & 1) != 0
        if !leftPressed {
            handleMouseUp()
            return
        }

        let location = NSEvent.mouseLocation
        let dx = location.x - lastEventLocation.x
        let dy = location.y - lastEventLocation.y
        lastEventLocation = location
        handleMouseMoved(at: location, deltaX: dx, deltaY: dy)
    }

    // MARK: - Optional Listen-Only CGEventTap

    @discardableResult
    private func installListenOnlyEventTapIfPermitted() -> Bool {
        if eventTapBox != nil { return true }

        // Exact 1:1 match with NSEvent mouseMask (.leftMouseDown, .leftMouseDragged, .leftMouseUp)
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)

        let box = EventTapBox()
        // Source is added to CFRunLoopGetMain(), so callbacks execute synchronously on the main thread.
        box.onMouseEvent = { eventType, dx, dy in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    GlobalDragMonitor.shared.handleTapEvent(eventType, deltaX: dx, deltaY: dy)
                }
            } else {
                DispatchQueue.main.async {
                    GlobalDragMonitor.shared.handleTapEvent(eventType, deltaX: dx, deltaY: dy)
                }
            }
        }
        box.onTapPermanentlyDisabled = {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    GlobalDragMonitor.shared.handleTapPermanentlyDisabled()
                }
            } else {
                DispatchQueue.main.async {
                    GlobalDragMonitor.shared.handleTapPermanentlyDisabled()
                }
            }
        }

        let userInfo = Unmanaged.passUnretained(box).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let box = Unmanaged<EventTapBox>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = box.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    if !CGEvent.tapIsEnabled(tap: tap) {
                        box.onTapPermanentlyDisabled?()
                    }
                }
                return Unmanaged.passUnretained(event)
            }

            if type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp {
                let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
                let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
                box.onMouseEvent?(type, dx, dy)
            }

            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            dragMonitorLogger.info("Listen-only CGEventTap unavailable; using passive NSEvent monitors + Dock drag detector.")
            return false
        }

        box.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        guard CGEvent.tapIsEnabled(tap: tap) else {
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
            box.onMouseEvent = nil
            box.onTapPermanentlyDisabled = nil
            box.tap = nil
            dragMonitorLogger.info("Listen-only CGEventTap could not be enabled; using passive NSEvent monitors.")
            return false
        }

        eventTapBox = box
        eventTapRunLoopSource = source
        dragMonitorLogger.info("Installed listen-only CGEventTap on main run loop with automatic fallback.")
        return true
    }

    private func removeEventTap() {
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapRunLoopSource = nil
        }
        if let tap = eventTapBox?.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        eventTapBox?.onMouseEvent = nil
        eventTapBox?.onTapPermanentlyDisabled = nil
        eventTapBox?.tap = nil
        eventTapBox = nil
    }
}
