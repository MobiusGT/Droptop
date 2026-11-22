import AppKit
import QuartzCore

@MainActor
final class EdgeIndicatorWindow: NSPanel {
    let edge: ScreenEdge
    private let glowLayer = CAGradientLayer()
    private let barWidth: CGFloat = 6
    private let barHeight: CGFloat = 200
    private let verticalHysteresis: CGFloat = 4.0

    private var appliedTheme: ShelfTheme?
    private var visibilityGeneration: UInt64 = 0
    private var isFadingIn = false
    private var lastAppliedOrigin: NSPoint?
    private var lastQuantizedProximity: Int = -1

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
        lastAppliedOrigin = rect.origin

        setupGlow(size: rect.size)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func setupGlow(size: NSSize) {
        let hostView = NSView(frame: NSRect(origin: .zero, size: size))
        hostView.wantsLayer = true

        glowLayer.frame = hostView.bounds
        glowLayer.cornerRadius = size.width / 2
        glowLayer.locations = [0.0, 0.28, 0.72, 1.0]
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0)
        glowLayer.endPoint = CGPoint(x: 0.5, y: 1)

        glowLayer.shadowRadius = 18
        glowLayer.shadowOpacity = 0.95
        glowLayer.shadowOffset = .zero
        glowLayer.shadowPath = CGPath(
            roundedRect: hostView.bounds,
            cornerWidth: size.width / 2,
            cornerHeight: size.width / 2,
            transform: nil
        )

        refreshThemeColorIfNeeded()

        hostView.layer?.addSublayer(glowLayer)
        contentView = hostView
    }

    func refreshThemeColorIfNeeded() {
        let currentTheme = AppSettings.shared.shelfTheme
        guard appliedTheme != currentTheme || currentTheme == .systemGlass else { return }
        appliedTheme = currentTheme

        let themeAccent = currentTheme.nsAccentColor
        let accent = themeAccent.withAlphaComponent(0.90).cgColor
        let transparent = NSColor.clear.cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.colors = [transparent, accent, accent, transparent]
        glowLayer.shadowColor = themeAccent.cgColor
        CATransaction.commit()
    }

    func repositionVertically(around centerY: CGFloat, on screen: NSScreen, force: Bool = false) {
        repositionVertically(
            around: centerY,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            force: force
        )
    }

    func repositionVertically(
        around centerY: CGFloat,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        force: Bool = false
    ) {
        let minY = visibleFrame.minY + 16
        let maxY = max(minY, visibleFrame.maxY - barHeight - 16)
        let clampedY = min(max(centerY - barHeight / 2, minY), maxY)
        let x: CGFloat = (edge == .left) ? screenFrame.minX : (screenFrame.maxX - barWidth)
        let targetOrigin = NSPoint(x: x, y: clampedY)

        if !force, let last = lastAppliedOrigin,
           abs(last.x - targetOrigin.x) < 0.5,
           abs(last.y - targetOrigin.y) < verticalHysteresis {
            return
        }

        lastAppliedOrigin = targetOrigin
        setFrameOrigin(targetOrigin)
    }

    func fadeIn(initialProximity: CGFloat? = nil) {
        refreshThemeColorIfNeeded()
        visibilityGeneration &+= 1
        let expectedGen = visibilityGeneration
        isFadingIn = true

        let targetAlpha: CGFloat
        if let initialProximity {
            let clamped = max(0, min(1, initialProximity))
            let bucket = Int((clamped * 50).rounded())
            lastQuantizedProximity = bucket
            targetAlpha = 0.35 + (CGFloat(bucket) / 50.0) * 0.65
        } else {
            lastQuantizedProximity = -1
            targetAlpha = 0.65
        }

        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = targetAlpha
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == expectedGen else { return }
                self.isFadingIn = false
            }
        })
    }

    func fadeOut(completion: (() -> Void)? = nil) {
        visibilityGeneration &+= 1
        let expectedGen = visibilityGeneration
        isFadingIn = false
        lastQuantizedProximity = -1

        guard isVisible else {
            alphaValue = 0
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == expectedGen else { return }
                self.orderOut(nil)
                completion?()
            }
        })
    }

    func updateProximity(_ proximity: CGFloat) {
        let clamped = max(0, min(1, proximity))
        let bucket = Int((clamped * 50).rounded())
        guard bucket != lastQuantizedProximity else { return }
        lastQuantizedProximity = bucket

        let targetAlpha = 0.35 + (CGFloat(bucket) / 50.0) * 0.65
        if isFadingIn && clamped <= 0.25 {
            return
        }
        isFadingIn = false
        alphaValue = targetAlpha
    }
}
