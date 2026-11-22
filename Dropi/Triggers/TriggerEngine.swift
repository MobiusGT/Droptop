import AppKit
import Combine

@MainActor
final class TriggerEngine {
    private let hotkey = HotkeyTrigger()
    private let edge = EdgeTrigger()
    private let shake = ShakeTrigger()

    private var triggers: [ShelfTrigger] { [edge, shake, hotkey] }
    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    var isHotkeyMonitoringActive: Bool {
        hotkey.hasInstalledMonitors
    }

    var isDragMonitoringActive: Bool {
        GlobalDragMonitor.shared.isMonitoringActive
    }

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
        guard !isStarted else { return }
        isStarted = true
        applySettings()
        triggers.forEach { $0.start() }
        syncDragMonitorState(edgeEnabled: edge.isEnabled, shakeEnabled: shake.isEnabled)
        observeSettings()
    }

    func stop() {
        isStarted = false
        triggers.forEach { $0.stop() }
        GlobalDragMonitor.shared.stop()
        cancellables.removeAll()
    }

    func refreshPermissionsIfNeeded() {
        guard isStarted, Permissions.isAccessibilityGranted else { return }
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

    private func syncDragMonitorState(edgeEnabled: Bool, shakeEnabled: Bool) {
        guard isStarted else { return }
        if edgeEnabled || shakeEnabled {
            GlobalDragMonitor.shared.start()
        } else {
            GlobalDragMonitor.shared.stop()
        }
    }

    private func observeSettings() {
        let settings = AppSettings.shared

        // Combine `@Published` emits in `willSet` (before the property updates), so pass
        // the emitted values directly into `syncDragMonitorState`.
        settings.$edgeEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.edge.isEnabled = enabled
                if !enabled {
                    self.edge.cancelActiveEdgeSession()
                }
                self.syncDragMonitorState(edgeEnabled: enabled, shakeEnabled: self.shake.isEnabled)
            }
            .store(in: &cancellables)

        settings.$shakeEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.shake.isEnabled = enabled
                self.syncDragMonitorState(edgeEnabled: self.edge.isEnabled, shakeEnabled: enabled)
            }
            .store(in: &cancellables)

        settings.$hotkeyEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.hotkey.isEnabled = enabled
            }
            .store(in: &cancellables)

        settings.$hotkeyKeyCode
            .dropFirst()
            .sink { [weak self] keyCode in
                self?.hotkey.keyCode = keyCode
            }
            .store(in: &cancellables)

        settings.$hotkeyModifiers
            .dropFirst()
            .sink { [weak self] modifiers in
                self?.hotkey.modifiers = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
            }
            .store(in: &cancellables)
    }
}
