import AppKit
import QuartzCore
import SwiftUI

/// Pure, testable positioning math for anchoring the full-filename tooltip directly beside
/// the shelf at the exact hovered row's vertical position — immune to NSHostingView coordinate flipping.
enum FilenameTooltipLayout {
    static func frame(
        textSize: NSSize,
        cursorScreenPoint: NSPoint,
        shelfScreenFrame: NSRect,
        visibleScreenFrame: NSRect
    ) -> NSRect {
        let width = min(max(ceil(textSize.width) + 22, 90), 340)
        let height = max(ceil(textSize.height) + 14, 28)
        let gap: CGFloat = 6

        let placeOnLeft = shelfScreenFrame.midX > visibleScreenFrame.midX
        var x: CGFloat
        if placeOnLeft {
            x = shelfScreenFrame.minX - width - gap
            if x < visibleScreenFrame.minX + 6 {
                x = shelfScreenFrame.maxX + gap
            }
        } else {
            x = shelfScreenFrame.maxX + gap
            if x + width > visibleScreenFrame.maxX - 6 {
                x = shelfScreenFrame.minX - width - gap
            }
        }
        x = min(max(x, visibleScreenFrame.minX + 6), visibleScreenFrame.maxX - width - 6)

        let minShelfY = shelfScreenFrame.minY + 4
        let maxShelfY = max(minShelfY, shelfScreenFrame.maxY - height - 4)
        var y = min(max(cursorScreenPoint.y - height / 2, minShelfY), maxShelfY)
        y = min(max(y, visibleScreenFrame.minY + 6), visibleScreenFrame.maxY - height - 6)

        return NSRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
final class FilenameTooltipController {
    static let shared = FilenameTooltipController()

    private var panel: FilenameTooltipPanel?
    private var showWorkItem: DispatchWorkItem?
    private var activeToken: UUID?

    private init() {}

    func scheduleShow(
        text: String,
        token: UUID,
        shelfScreenRect: NSRect,
        colorVariation: ShelfColorVariation = .identity
    ) {
        cancelPending()
        activeToken = token

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.activeToken == token else { return }
                guard NSEvent.pressedMouseButtons == 0 else { return }
                let cursor = NSEvent.mouseLocation
                guard shelfScreenRect.insetBy(dx: -4, dy: -4).contains(cursor) else { return }
                self.present(
                    text: text,
                    cursorPoint: cursor,
                    shelfScreenRect: shelfScreenRect,
                    colorVariation: colorVariation
                )
            }
        }
        showWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    func hide(forToken token: UUID? = nil) {
        if let token, let activeToken, activeToken != token {
            return
        }
        cancelPending()
        activeToken = nil
        panel?.orderOut(nil)
    }

    private func cancelPending() {
        showWorkItem?.cancel()
        showWorkItem = nil
    }

    private func present(
        text: String,
        cursorPoint: NSPoint,
        shelfScreenRect: NSRect,
        colorVariation: ShelfColorVariation
    ) {
        let settings = AppSettings.shared
        let palette = settings.shelfTheme.palette(
            variation: colorVariation,
            level: settings.colorVariationLevel
        )
        let tooltipPanel = panel ?? FilenameTooltipPanel()
        self.panel = tooltipPanel

        tooltipPanel.appearance = palette.nsAppearance

        let maxTextWidth: CGFloat = 316
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let measured = NSString(string: text).boundingRect(
            with: NSSize(width: maxTextWidth, height: 180),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let textSize = NSSize(width: ceil(measured.width) + 2, height: ceil(measured.height) + 2)

        let screen = ScreenGeometry.screen(containing: cursorPoint) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetFrame = FilenameTooltipLayout.frame(
            textSize: textSize,
            cursorScreenPoint: cursorPoint,
            shelfScreenFrame: shelfScreenRect,
            visibleScreenFrame: visible
        )

        let contentView = FilenameTooltipContentView(
            text: text,
            palette: palette,
            width: targetFrame.width,
            height: targetFrame.height
        )
        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = NSRect(origin: .zero, size: targetFrame.size)
        tooltipPanel.contentView = hosting

        tooltipPanel.setFrame(targetFrame, display: true)
        tooltipPanel.alphaValue = 0
        tooltipPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tooltipPanel.animator().alphaValue = 1.0
        }
    }
}

private final class FilenameTooltipPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct FilenameTooltipContentView: View {
    let text: String
    let palette: ResolvedShelfPalette
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.primaryTextColor)
            .multilineTextAlignment(.leading)
            .frame(width: width - 20, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width, height: height)
            .background(
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    palette.backgroundTint
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(palette.borderColor, lineWidth: 1)
            )
            .preferredColorScheme(palette.preferredColorScheme)
    }
}
