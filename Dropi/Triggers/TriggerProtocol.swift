import AppKit

enum TriggerEvent {
    case edge(edge: ScreenEdge, location: NSPoint, screen: NSScreen)
    case shake(location: NSPoint)
    case hotkey(location: NSPoint)
}

@MainActor
protocol ShelfTrigger: AnyObject {
    var isEnabled: Bool { get set }
    var onTrigger: ((TriggerEvent) -> Void)? { get set }
    func start()
    func stop()
}
