import AppKit
import Combine
import CoreFoundation
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
    @Published var edgeCreationSensitivity: EdgeCreationSensitivity {
        didSet { UserDefaults.standard.set(edgeCreationSensitivity.rawValue, forKey: Keys.edgeCreationSensitivity) }
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
    @Published var showCopyButtonInShelf: Bool {
        didSet { UserDefaults.standard.set(showCopyButtonInShelf, forKey: Keys.showCopyButtonInShelf) }
    }
    /// Auto Hide: tucks inactive shelves away into the docked screen edge.
    @Published var autoHideEnabled: Bool {
        didSet { UserDefaults.standard.set(autoHideEnabled, forKey: Keys.autoHideEnabled) }
    }
    /// Controls how auto-hidden shelves appear while tucked at the screen edge.
    @Published var autoHideTabStyle: AutoHideTabStyle {
        didSet {
            UserDefaults.standard.set(autoHideTabStyle.rawValue, forKey: Keys.autoHideTabStyle)
            UserDefaults.standard.set(autoHideTabStyle.usesCustomTabOverlay, forKey: Keys.prettyAutoHideTab)
        }
    }
    /// Convenience mirror for whether the selected Auto Hide style uses a custom edge tab overlay.
    var prettyAutoHideTab: Bool {
        autoHideTabStyle.usesCustomTabOverlay
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
        if let rawSensitivity = defaults.string(forKey: Keys.edgeCreationSensitivity),
           let parsedSensitivity = EdgeCreationSensitivity(rawValue: rawSensitivity) {
            edgeCreationSensitivity = parsedSensitivity
        } else {
            edgeCreationSensitivity = .low
        }
        shakeEnabled = defaults.object(forKey: Keys.shakeEnabled) as? Bool ?? false
        hotkeyEnabled = defaults.object(forKey: Keys.hotkeyEnabled) as? Bool ?? true
        autoRemoveOnDragOut = defaults.object(forKey: Keys.autoRemoveOnDragOut) as? Bool ?? true
        autoHideWhenEmpty = defaults.object(forKey: Keys.autoHideWhenEmpty) as? Bool ?? true
        showCopyButtonInShelf = defaults.object(forKey: Keys.showCopyButtonInShelf) as? Bool ?? false
        autoHideEnabled = Self.resolveAutoHideEnabled(in: defaults)
        autoHideTabStyle = Self.resolveAutoHideTabStyle(in: defaults)
        if let rawTheme = defaults.string(forKey: Keys.shelfTheme),
           let parsedTheme = ShelfTheme(rawValue: rawTheme) {
            shelfTheme = parsedTheme
        } else {
            shelfTheme = .systemGlass
        }
        colorVariationLevel = Self.resolveColorVariationLevel(in: defaults)
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

    static func resolveAutoHideEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Keys.autoHideEnabled) as? Bool ?? true
    }

    static func resolveAutoHideTabStyle(in defaults: UserDefaults) -> AutoHideTabStyle {
        if let rawTabStyle = defaults.string(forKey: Keys.autoHideTabStyle),
           rawTabStyle == AutoHideTabStyle.standard.rawValue {
            return .standard
        }
        if let legacyPretty = defaults.object(forKey: Keys.prettyAutoHideTab) as? Bool,
           !legacyPretty {
            return .standard
        }
        if let rawTabStyle = defaults.string(forKey: Keys.autoHideTabStyle),
           let parsedTabStyle = AutoHideTabStyle(rawValue: rawTabStyle) {
            return parsedTabStyle
        }
        return .minimalColor
    }

    static func resolveColorVariationLevel(in defaults: UserDefaults) -> ColorVariationLevel {
        if let rawVar = defaults.string(forKey: Keys.colorVariationLevel),
           let parsedVar = ColorVariationLevel(rawValue: rawVar) {
            return parsedVar
        }
        if let legacyVary = defaults.object(forKey: Keys.legacyVaryColors) as? Bool {
            return legacyVary ? .low : .off
        }
        return .low
    }

    private static func migrateLegacyPreferencesIfNeeded(into defaults: UserDefaults) {
        let migrationFlag = "didMigrateFromDropshelfReplacement"
        guard !defaults.bool(forKey: migrationFlag) else { return }
        if let legacy = defaults.persistentDomain(forName: "com.local.DropshelfReplacement") {
            migrateLegacyPreferences(from: legacy, into: defaults)
        }
        defaults.set(true, forKey: migrationFlag)
    }

    static func migrateLegacyPreferences(from legacy: [String: Any], into defaults: UserDefaults) {
        for (key, expectedType) in Keys.migratableKeys {
            guard defaults.object(forKey: key) == nil, let rawValue = legacy[key] else {
                continue
            }
            switch expectedType {
            case .bool:
                if let number = rawValue as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    defaults.set(number.boolValue, forKey: key)
                }
            case .int:
                if let number = rawValue as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                   let intValue = rawValue as? Int {
                    defaults.set(intValue, forKey: key)
                }
            case .string:
                if let stringValue = rawValue as? String {
                    defaults.set(stringValue, forKey: key)
                }
            }
        }
    }

    private enum LegacyValueType {
        case bool
        case int
        case string
    }

    private enum Keys {
        static let edgeEnabled = "edgeEnabled"
        static let leftEdgeEnabled = "leftEdgeEnabled"
        static let rightEdgeEnabled = "rightEdgeEnabled"
        static let showEdgeIndicators = "showEdgeIndicators"
        static let edgeCreationSensitivity = "edgeCreationSensitivity"
        static let shakeEnabled = "shakeEnabled"
        static let hotkeyEnabled = "hotkeyEnabled"
        static let autoRemoveOnDragOut = "autoRemoveOnDragOut"
        static let autoHideWhenEmpty = "autoHideWhenEmpty"
        static let showCopyButtonInShelf = "showCopyButtonInShelf"
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

        static let migratableKeys: [String: LegacyValueType] = [
            edgeEnabled: .bool,
            leftEdgeEnabled: .bool,
            rightEdgeEnabled: .bool,
            showEdgeIndicators: .bool,
            shakeEnabled: .bool,
            hotkeyEnabled: .bool,
            autoRemoveOnDragOut: .bool,
            autoHideWhenEmpty: .bool,
            autoHideEnabled: .bool,
            prettyAutoHideTab: .bool,
            autoHideTabStyle: .string,
            shelfTheme: .string,
            colorVariationLevel: .string,
            legacyVaryColors: .bool,
            launchAtLogin: .bool,
            showMenuBarIcon: .bool,
            hotkeyKeyCode: .int,
            hotkeyModifiers: .int
        ]
    }
}
