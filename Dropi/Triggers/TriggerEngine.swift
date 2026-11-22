import AppKit
import Combine

@MainActor
final class TriggerEngine {
    private let hotkey = HotkeyTrigger()
    private let edge = EdgeTrigger()
    private let shake = ShakeTrigger()

    private var triggers: [ShelfTrigger] { [edge, shake, hotkey] }
    private var cancellables = Set<AnyCancellable>()

    var onTrigger: ((TriggerEvent) -> Void)? {
        didSet {
            triggers.forEach { $0.onTrigger = onTrigger }
        }
    }

    var onExternalDragEnded: ((Bool) -> Void)? {
        didSet {
            edge.onDragEnded = onExternalDragEnded
        }
    }

    func start() {
        // Start mouse/screen-edge triggers IMMEDIATELY without blocking on Accessibility!
        // Passive NSEvent mouse monitors work out-of-the-box on macOS.
        GlobalDragMonitor.shared.start()
        applySettings()
        observeSettings()
        triggers.forEach { $0.start() }
    }

    func stop() {
        triggers.forEach { $0.stop() }
        GlobalDragMonitor.shared.stop()
        cancellables.removeAll()
    }

    func refreshPermissionsIfNeeded() {
        guard Permissions.isAccessibilityGranted else { return }
        hotkey.refreshPermissionIfNeeded()
        GlobalDragMonitor.shared.refreshEventTapIfNeeded()
    }

    private func applySettings() {
        let settings = AppSettings.shared
        edge.isEnabled = settings.edgeEnabled
        shake.isEnabled = settings.shakeEnabled
        hotkey.isEnabled = settings.hotkeyEnabled
        hotkey.keyCode = settings.hotkeyKeyCode
        hotkey.modifiers = settings.modifierFlags
    }

    private func observeSettings() {
        let settings = AppSettings.shared

        settings.$edgeEnabled
            .sink { [weak self] in self?.edge.isEnabled = $0 }
            .store(in: &cancellables)

        settings.$shakeEnabled
            .sink { [weak self] in self?.shake.isEnabled = $0 }
            .store(in: &cancellables)

        settings.$hotkeyEnabled
            .sink { [weak self] in self?.hotkey.isEnabled = $0 }
            .store(in: &cancellables)

        settings.$hotkeyKeyCode
            .sink { [weak self] in self?.hotkey.keyCode = $0 }
            .store(in: &cancellables)

        settings.$hotkeyModifiers
            .sink { [weak self] modifiers in
                self?.hotkey.modifiers = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
            }
            .store(in: &cancellables)
    }
}
