import AppKit
import SwiftUI

final class SettingsWindow: NSPanel {
    var allowsKeyStatus: Bool = false

    init() {
        let rect = NSRect(
            x: 0,
            y: 0,
            width: Constants.Shelf.settingsWidth,
            height: Constants.Shelf.settingsHeight
        )
        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        appearance = AppSettings.shared.shelfTheme.nsAppearance

        let rootView = SettingsView(
            settings: AppSettings.shared,
            onClose: { [weak self] in
                self?.allowsKeyStatus = false
                self?.orderOut(nil)
            },
            onKeyFocusChange: { [weak self] allowKey in
                guard let self else { return }
                self.allowsKeyStatus = allowKey
                if allowKey {
                    self.makeKey()
                } else if self.isKeyWindow {
                    self.resignKey()
                }
            }
        )

        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = Constants.Shelf.cornerRadius
        hosting.layer?.masksToBounds = true
        contentView = hosting
    }

    override var canBecomeKey: Bool { allowsKeyStatus }
    override var canBecomeMain: Bool { false }

    func showCentered(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        setFrameOrigin(origin)
        orderFrontRegardless()
    }
}
