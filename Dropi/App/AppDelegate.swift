import AppKit
import QuickLookUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private(set) var shelfManager: ShelfManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        #endif
        ProcessInfo.processInfo.disableAutomaticTermination("Active background drag shelf")
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApp.setActivationPolicy(.accessory)
        ShelfStore.cleanupAllStagingDirectories()
        shelfManager = ShelfManager()
        setupMenuBar()
        bindSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shelfManager?.shutdown()
    }

    private func setupMenuBar() {
        if AppSettings.shared.showMenuBarIcon {
            showMenuBarIcon()
        }
    }

    private func bindSettings() {
        AppSettings.shared.onMenuBarChanged = { [weak self] show in
            if show {
                self?.showMenuBarIcon()
            } else {
                self?.hideMenuBarIcon()
            }
        }
    }

    private func showMenuBarIcon() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let icon = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Droptop")
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = true
            button.image = icon
            button.toolTip = "Droptop"
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        self.statusMenu = menu
        self.statusItem = item
    }

    private func hideMenuBarIcon() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        statusMenu = nil
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        shelfManager?.refreshPermissionsIfNeeded()
        menu.removeAllItems()

        let settings = AppSettings.shared
        let shelves = shelfManager?.shelves ?? []

        let newShelfItem = NSMenuItem(title: "New Shelf", action: #selector(newShelf), keyEquivalent: "n")
        newShelfItem.target = self
        menu.addItem(newShelfItem)

        let pasteItem = NSMenuItem(title: "New Shelf from Clipboard", action: #selector(newShelfFromClipboard), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        if !shelves.isEmpty {
            menu.addItem(.separator())

            for shelf in shelves {
                let summary = shelf.store.items.isEmpty ? "Empty" : shelf.store.items.dropshelfSummaryLabel
                let edgeText = shelf.dockedEdge == .left ? "Left" : "Right"
                let shelfItem = NSMenuItem(
                    title: "\(shelf.store.title) — \(summary) (\(edgeText))",
                    action: #selector(focusShelf(_:)),
                    keyEquivalent: ""
                )
                shelfItem.target = self
                shelfItem.representedObject = shelf.id
                shelfItem.state = shelf.isVisible ? .on : .off
                menu.addItem(shelfItem)
            }

            menu.addItem(.separator())

            if shelfManager?.hasVisibleShelves == true {
                let hideAll = NSMenuItem(title: "Hide All Shelves", action: #selector(hideAllShelves), keyEquivalent: "")
                hideAll.target = self
                menu.addItem(hideAll)
            } else {
                let showAll = NSMenuItem(title: "Show All Shelves", action: #selector(showAllShelves), keyEquivalent: "")
                showAll.target = self
                menu.addItem(showAll)
            }

            let closeAll = NSMenuItem(title: "Clear & Close All Shelves", action: #selector(clearAndCloseAllShelves), keyEquivalent: "")
            closeAll.target = self
            menu.addItem(closeAll)
        }

        menu.addItem(.separator())

        let autoHideToggle = NSMenuItem(title: "Auto Hide", action: #selector(toggleAutoHide), keyEquivalent: "")
        autoHideToggle.target = self
        autoHideToggle.state = settings.autoHideEnabled ? .on : .off
        menu.addItem(autoHideToggle)

        let autoHideStyleMenuItem = NSMenuItem(title: "Auto Hide Style", action: nil, keyEquivalent: "")
        let autoHideStyleSubmenu = NSMenu()

        for style in AutoHideTabStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: #selector(selectAutoHideTabStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = (settings.autoHideTabStyle == style) ? .on : .off
            autoHideStyleSubmenu.addItem(item)
        }
        autoHideStyleMenuItem.submenu = autoHideStyleSubmenu
        menu.addItem(autoHideStyleMenuItem)

        let themeMenuItem = NSMenuItem(title: "Theme (\(settings.shelfTheme.displayName))", action: nil, keyEquivalent: "")
        let themeSubmenu = NSMenu()

        let variationMenuItem = NSMenuItem(
            title: "Shelf Color Variation (\(settings.colorVariationLevel.displayName))",
            action: nil,
            keyEquivalent: ""
        )
        let variationSubmenu = NSMenu()
        for level in ColorVariationLevel.allCases {
            let item = NSMenuItem(
                title: level.displayName,
                action: #selector(selectColorVariationLevel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = level.rawValue
            item.state = (settings.colorVariationLevel == level) ? .on : .off
            variationSubmenu.addItem(item)
        }
        variationMenuItem.submenu = variationSubmenu
        themeSubmenu.addItem(variationMenuItem)
        themeSubmenu.addItem(.separator())

        for candidate in ShelfTheme.adaptiveThemes {
            let item = NSMenuItem(title: candidate.displayName, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.rawValue
            item.state = (settings.shelfTheme == candidate) ? .on : .off
            themeSubmenu.addItem(item)
        }
        themeSubmenu.addItem(.separator())

        let darkGroupItem = NSMenuItem(title: "Dark Themes (\(ShelfTheme.darkThemes.count))", action: nil, keyEquivalent: "")
        let darkSubmenu = NSMenu()
        for candidate in ShelfTheme.darkThemes {
            let item = NSMenuItem(title: candidate.displayName, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.rawValue
            item.state = (settings.shelfTheme == candidate) ? .on : .off
            darkSubmenu.addItem(item)
        }
        darkGroupItem.submenu = darkSubmenu
        themeSubmenu.addItem(darkGroupItem)

        let lightGroupItem = NSMenuItem(title: "Light Themes (\(ShelfTheme.lightThemes.count))", action: nil, keyEquivalent: "")
        let lightSubmenu = NSMenu()
        for candidate in ShelfTheme.lightThemes {
            let item = NSMenuItem(title: candidate.displayName, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.rawValue
            item.state = (settings.shelfTheme == candidate) ? .on : .off
            lightSubmenu.addItem(item)
        }
        lightGroupItem.submenu = lightSubmenu
        themeSubmenu.addItem(lightGroupItem)

        themeMenuItem.submenu = themeSubmenu
        menu.addItem(themeMenuItem)

        menu.addItem(.separator())

        let edgeToggle = NSMenuItem(title: "Enable Screen-Edge Trigger", action: #selector(toggleEdgeTrigger), keyEquivalent: "")
        edgeToggle.target = self
        edgeToggle.state = settings.edgeEnabled ? .on : .off
        menu.addItem(edgeToggle)

        let leftEdgeToggle = NSMenuItem(title: "Left Screen Edge", action: #selector(toggleLeftEdge), keyEquivalent: "")
        leftEdgeToggle.target = self
        leftEdgeToggle.state = settings.leftEdgeEnabled ? .on : .off
        leftEdgeToggle.isEnabled = settings.edgeEnabled
        menu.addItem(leftEdgeToggle)

        let rightEdgeToggle = NSMenuItem(title: "Right Screen Edge", action: #selector(toggleRightEdge), keyEquivalent: "")
        rightEdgeToggle.target = self
        rightEdgeToggle.state = settings.rightEdgeEnabled ? .on : .off
        rightEdgeToggle.isEnabled = settings.edgeEnabled
        menu.addItem(rightEdgeToggle)

        let sensitivityMenuItem = NSMenuItem(
            title: "Window Creation Sensitivity (\(settings.edgeCreationSensitivity.displayName))",
            action: nil,
            keyEquivalent: ""
        )
        sensitivityMenuItem.isEnabled = settings.edgeEnabled
        let sensitivitySubmenu = NSMenu()
        for candidate in EdgeCreationSensitivity.allCases {
            let item = NSMenuItem(
                title: candidate.displayName,
                action: #selector(selectEdgeCreationSensitivity(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = candidate.rawValue
            item.state = (settings.edgeCreationSensitivity == candidate) ? .on : .off
            sensitivitySubmenu.addItem(item)
        }
        sensitivityMenuItem.submenu = sensitivitySubmenu
        menu.addItem(sensitivityMenuItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Droptop", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func newShelf() {
        _ = shelfManager?.createManualShelf()
    }

    @objc private func newShelfFromClipboard() {
        shelfManager?.createShelfFromClipboard()
    }

    @objc private func focusShelf(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        shelfManager?.focusOrToggleShelf(id: id)
    }

    @objc private func hideAllShelves() {
        shelfManager?.hideAllShelves()
    }

    @objc private func showAllShelves() {
        shelfManager?.showAllShelves()
    }

    @objc private func clearAndCloseAllShelves() {
        shelfManager?.clearAndCloseAllShelves()
    }

    @objc private func toggleAutoHide() {
        AppSettings.shared.autoHideEnabled.toggle()
    }

    @objc private func selectAutoHideTabStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = AutoHideTabStyle(rawValue: raw) else { return }
        AppSettings.shared.autoHideTabStyle = style
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let chosen = ShelfTheme(rawValue: raw) else { return }
        AppSettings.shared.shelfTheme = chosen
    }

    @objc private func selectColorVariationLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let chosen = ColorVariationLevel(rawValue: raw) else { return }
        AppSettings.shared.colorVariationLevel = chosen
    }

    @objc private func toggleEdgeTrigger() {
        AppSettings.shared.edgeEnabled.toggle()
    }

    @objc private func toggleLeftEdge() {
        AppSettings.shared.leftEdgeEnabled.toggle()
    }

    @objc private func toggleRightEdge() {
        AppSettings.shared.rightEdgeEnabled.toggle()
    }

    @objc private func selectEdgeCreationSensitivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let chosen = EdgeCreationSensitivity(rawValue: raw) else { return }
        AppSettings.shared.edgeCreationSensitivity = chosen
    }

    @objc private func openSettings() {
        shelfManager?.openSettings()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - QLPreviewPanelController

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        ShelfQuickLookController.shared.acceptsPreviewPanelControl(panel)
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        ShelfQuickLookController.shared.beginPreviewPanelControl(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        ShelfQuickLookController.shared.endPreviewPanelControl(panel)
    }
}
