import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var edgeEnabled: Bool {
        didSet { UserDefaults.standard.set(edgeEnabled, forKey: Keys.edgeEnabled) }
    }
    @Published var leftEdgeEnabled: Bool {
        didSet { UserDefaults.standard.set(leftEdgeEnabled, forKey: Keys.leftEdgeEnabled) }
    }
    @Published var rightEdgeEnabled: Bool {
        didSet { UserDefaults.standard.set(rightEdgeEnabled, forKey: Keys.rightEdgeEnabled) }
    }
    @Published var showEdgeIndicators: Bool {
        didSet { UserDefaults.standard.set(showEdgeIndicators, forKey: Keys.showEdgeIndicators) }
    }
    @Published var shakeEnabled: Bool {
        didSet { UserDefaults.standard.set(shakeEnabled, forKey: Keys.shakeEnabled) }
    }
    @Published var hotkeyEnabled: Bool {
        didSet { UserDefaults.standard.set(hotkeyEnabled, forKey: Keys.hotkeyEnabled) }
    }
    @Published var autoRemoveOnDragOut: Bool {
        didSet { UserDefaults.standard.set(autoRemoveOnDragOut, forKey: Keys.autoRemoveOnDragOut) }
    }
    @Published var autoHideWhenEmpty: Bool {
        didSet { UserDefaults.standard.set(autoHideWhenEmpty, forKey: Keys.autoHideWhenEmpty) }
    }
    /// Auto Hide: tucks inactive shelves 80% off-screen along the docked edge.
    @Published var autoHideEnabled: Bool {
        didSet { UserDefaults.standard.set(autoHideEnabled, forKey: Keys.autoHideEnabled) }
    }
    /// Clean Auto-Hide Tab: replaces the clipped edge preview with a polished minimal tab while auto-hidden.
    @Published var prettyAutoHideTab: Bool {
        didSet { UserDefaults.standard.set(prettyAutoHideTab, forKey: Keys.prettyAutoHideTab) }
    }
    @Published var autoHideTabStyle: AutoHideTabStyle {
        didSet { UserDefaults.standard.set(autoHideTabStyle.rawValue, forKey: Keys.autoHideTabStyle) }
    }
    @Published var shelfTheme: ShelfTheme {
        didSet { UserDefaults.standard.set(shelfTheme.rawValue, forKey: Keys.shelfTheme) }
    }
    @Published var colorVariationLevel: ColorVariationLevel {
        didSet { UserDefaults.standard.set(colorVariationLevel.rawValue, forKey: Keys.colorVariationLevel) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }
    @Published var showMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon)
            onMenuBarChanged?(showMenuBarIcon)
        }
    }
    @Published var hotkeyKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode) }
    }
    @Published var hotkeyModifiers: Int {
        didSet { UserDefaults.standard.set(hotkeyModifiers, forKey: Keys.hotkeyModifiers) }
    }

    var onMenuBarChanged: ((Bool) -> Void)?

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(hotkeyModifiers))
    }

    var hotkeyDisplayString: String {
        var parts: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToString(hotkeyKeyCode))
        return parts.joined()
    }

    func isEdgeAllowed(_ edge: ScreenEdge) -> Bool {
        guard edgeEnabled else { return false }
        switch edge {
        case .left: return leftEdgeEnabled
        case .right: return rightEdgeEnabled
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        Self.migrateLegacyPreferencesIfNeeded(into: defaults)
        let defaultModifiers = NSEvent.ModifierFlags([.command, .shift]).rawValue

        edgeEnabled = defaults.object(forKey: Keys.edgeEnabled) as? Bool ?? true
        leftEdgeEnabled = defaults.object(forKey: Keys.leftEdgeEnabled) as? Bool ?? true
        rightEdgeEnabled = defaults.object(forKey: Keys.rightEdgeEnabled) as? Bool ?? true
        showEdgeIndicators = defaults.object(forKey: Keys.showEdgeIndicators) as? Bool ?? true
        shakeEnabled = defaults.object(forKey: Keys.shakeEnabled) as? Bool ?? false
        hotkeyEnabled = defaults.object(forKey: Keys.hotkeyEnabled) as? Bool ?? true
        autoRemoveOnDragOut = defaults.object(forKey: Keys.autoRemoveOnDragOut) as? Bool ?? true
        autoHideWhenEmpty = defaults.object(forKey: Keys.autoHideWhenEmpty) as? Bool ?? true
        autoHideEnabled = defaults.object(forKey: Keys.autoHideEnabled) as? Bool ?? false
        prettyAutoHideTab = defaults.object(forKey: Keys.prettyAutoHideTab) as? Bool ?? true
        if let rawTabStyle = defaults.string(forKey: Keys.autoHideTabStyle),
           let parsedTabStyle = AutoHideTabStyle(rawValue: rawTabStyle) {
            autoHideTabStyle = parsedTabStyle
        } else {
            autoHideTabStyle = .fileIcons
        }
        if let rawTheme = defaults.string(forKey: Keys.shelfTheme),
           let parsedTheme = ShelfTheme(rawValue: rawTheme) {
            shelfTheme = parsedTheme
        } else {
            shelfTheme = .systemGlass
        }
        if let rawVar = defaults.string(forKey: Keys.colorVariationLevel),
           let parsedVar = ColorVariationLevel(rawValue: rawVar) {
            colorVariationLevel = parsedVar
        } else if let legacyVary = defaults.object(forKey: Keys.legacyVaryColors) as? Bool, legacyVary {
            colorVariationLevel = .low
        } else {
            colorVariationLevel = .off
        }
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        showMenuBarIcon = defaults.object(forKey: Keys.showMenuBarIcon) as? Bool ?? true
        hotkeyKeyCode = UInt16(defaults.object(forKey: Keys.hotkeyKeyCode) as? Int ?? 49)
        hotkeyModifiers = defaults.object(forKey: Keys.hotkeyModifiers) as? Int ?? Int(defaultModifiers)
    }

    func updateHotkey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        hotkeyKeyCode = keyCode
        hotkeyModifiers = Int(modifiers.rawValue)
    }

    private func updateLoginItem() {
        if launchAtLogin {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }

    private func keyCodeToString(_ keyCode: UInt16) -> String {
        let mapping: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M", 49: "Space", 36: "↩", 48: "⇥", 51: "⌫",
            53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return mapping[keyCode] ?? "Key\(keyCode)"
    }

    private static func migrateLegacyPreferencesIfNeeded(into defaults: UserDefaults) {
        let migrationFlag = "didMigrateFromDropshelfReplacement"
        guard !defaults.bool(forKey: migrationFlag) else { return }
        if let legacy = defaults.persistentDomain(forName: "com.local.DropshelfReplacement") {
            for (key, value) in legacy where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationFlag)
    }

    private enum Keys {
        static let edgeEnabled = "edgeEnabled"
        static let leftEdgeEnabled = "leftEdgeEnabled"
        static let rightEdgeEnabled = "rightEdgeEnabled"
        static let showEdgeIndicators = "showEdgeIndicators"
        static let shakeEnabled = "shakeEnabled"
        static let hotkeyEnabled = "hotkeyEnabled"
        static let autoRemoveOnDragOut = "autoRemoveOnDragOut"
        static let autoHideWhenEmpty = "autoHideWhenEmpty"
        static let autoHideEnabled = "peekWhenUnfocused"
        static let prettyAutoHideTab = "prettyAutoHideTab"
        static let autoHideTabStyle = "autoHideTabStyle"
        static let shelfTheme = "shelfTheme"
        static let colorVariationLevel = "colorVariationLevel"
        static let legacyVaryColors = "varyAdditionalShelfColors"
        static let launchAtLogin = "launchAtLogin"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
    }
}
