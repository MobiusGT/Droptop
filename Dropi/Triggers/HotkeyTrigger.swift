import AppKit

@MainActor
final class HotkeyTrigger: ShelfTrigger {
    var isEnabled: Bool = true
    var onTrigger: ((TriggerEvent) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    var keyCode: UInt16 = 49
    var modifiers: NSEvent.ModifierFlags = [.command, .shift]

    func start() {
        stop()

        // Local monitor always works (even without Accessibility)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matches(event) else { return event }
            self.onTrigger?(.hotkey(location: NSEvent.mouseLocation))
            return nil
        }

        // Global keyDown monitor works whenever Accessibility is granted
        if Permissions.isAccessibilityGranted {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.matches(event) else { return }
                    self.onTrigger?(.hotkey(location: NSEvent.mouseLocation))
                }
            }
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    func refreshPermissionIfNeeded() {
        if globalMonitor == nil && Permissions.isAccessibilityGranted {
            start()
        }
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let pressed = event.modifierFlags.intersection(relevant)
        return event.keyCode == keyCode && pressed == modifiers.intersection(relevant)
    }
}
