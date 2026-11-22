import AppKit
import QuartzCore

@MainActor
final class EdgeIndicatorWindow: NSPanel {
    let edge: ScreenEdge
    private let glowLayer = CAGradientLayer()
    private let barWidth: CGFloat = 6
    private let barHeight: CGFloat = 200

    init(edge: ScreenEdge, screen: NSScreen, centerY: CGFloat) {
        self.edge = edge

        let visible = screen.visibleFrame
        let minY = visible.minY + 16
        let maxY = max(minY, visible.maxY - barHeight - 16)
        let clampedY = min(max(centerY - barHeight / 2, minY), maxY)
        let x: CGFloat = (edge == .left) ? screen.frame.minX : (screen.frame.maxX - barWidth)
        let rect = NSRect(x: x, y: clampedY, width: barWidth, height: barHeight)

        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        alphaValue = 0

        setupGlow(size: rect.size)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func setupGlow(size: NSSize) {
        let hostView = NSView(frame: NSRect(origin: .zero, size: size))
        hostView.wantsLayer = true

        let themeAccent = AppSettings.shared.shelfTheme.nsAccentColor
        glowLayer.frame = hostView.bounds
        let accent = themeAccent.withAlphaComponent(0.90).cgColor
        let transparent = NSColor.clear.cgColor

        glowLayer.cornerRadius = size.width / 2
        glowLayer.colors = [transparent, accent, accent, transparent]
        glowLayer.locations = [0.0, 0.28, 0.72, 1.0]
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0)
        glowLayer.endPoint = CGPoint(x: 0.5, y: 1)

        glowLayer.shadowColor = themeAccent.cgColor
        glowLayer.shadowRadius = 18
        glowLayer.shadowOpacity = 0.95
        glowLayer.shadowOffset = .zero

        hostView.layer?.addSublayer(glowLayer)
        contentView = hostView
    }

    func repositionVertically(around centerY: CGFloat, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let minY = visible.minY + 16
        let maxY = max(minY, visible.maxY - barHeight - 16)
        let clampedY = min(max(centerY - barHeight / 2, minY), maxY)
        let x: CGFloat = (edge == .left) ? screen.frame.minX : (screen.frame.maxX - barWidth)
        setFrameOrigin(NSPoint(x: x, y: clampedY))
    }

    func fadeIn() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0.65
        }
    }

    func fadeOut(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                completion?()
            }
        })
    }

    func updateProximity(_ proximity: CGFloat) {
        let clamped = max(0, min(1, proximity))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.05
            animator().alphaValue = 0.35 + clamped * 0.65
        }
    }
}
