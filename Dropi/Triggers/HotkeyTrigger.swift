import AppKit

@MainActor
final class HotkeyTrigger: ShelfTrigger {
    var isEnabled: Bool = true {
        didSet {
            guard isStarted, oldValue != isEnabled else { return }
            if isEnabled {
                installMonitors()
            } else {
                removeMonitors()
            }
        }
    }
    var onTrigger: ((TriggerEvent) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isStarted = false

    var keyCode: UInt16 = 49
    var modifiers: NSEvent.ModifierFlags = [.command, .shift]

    var hasInstalledMonitors: Bool {
        localMonitor != nil || globalMonitor != nil
    }

    func start() {
        isStarted = true
        if isEnabled {
            installMonitors()
        } else {
            removeMonitors()
        }
    }

    func stop() {
        isStarted = false
        removeMonitors()
    }

    func refreshPermissionIfNeeded() {
        guard isStarted, isEnabled, globalMonitor == nil, Permissions.isAccessibilityGranted else {
            return
        }
        installMonitors()
    }

    private func installMonitors() {
        removeMonitors()

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

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let pressed = event.modifierFlags.intersection(relevant)
        return event.keyCode == keyCode && pressed == modifiers.intersection(relevant)
    }
}
