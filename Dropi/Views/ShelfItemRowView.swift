import AppKit
import Combine
import SwiftUI

/// Single mutually-exclusive hover coordinator for all rows in a shelf.
/// Guarantees at most ONE row can ever display hovered chrome (highlight + Eye/X buttons),
/// and reconciles hover against live clipped screen rects on every scroll offset change
/// so scrolling rapidly past many rows never leaves stale hovered rows behind.
@MainActor
final class ShelfRowHoverCoordinator: ObservableObject {
    @Published private(set) var hoveredItemID: UUID?

    private struct WeakRowView {
        weak var view: ShelfRowHoverTrackerNSView?
    }

    private var rowViews: [UUID: WeakRowView] = [:]
    private var hasScheduledReconcile = false

    func register(_ view: ShelfRowHoverTrackerNSView, for itemID: UUID) {
        rowViews[itemID] = WeakRowView(view: view)
    }

    func unregister(_ view: ShelfRowHoverTrackerNSView, for itemID: UUID) {
        if let existing = rowViews[itemID], existing.view == nil || existing.view === view {
            rowViews.removeValue(forKey: itemID)
        }
        if hoveredItemID == itemID {
            scheduleReconcile()
        }
    }

    func setHovered(itemID: UUID, isHovered: Bool) {
        if isHovered {
            if hoveredItemID != itemID {
                hoveredItemID = itemID
            }
        } else if hoveredItemID == itemID {
            hoveredItemID = nil
        }
    }

    func clearHover() {
        if hoveredItemID != nil {
            hoveredItemID = nil
        }
    }

    func scheduleReconcile() {
        guard !hasScheduledReconcile else { return }
        hasScheduledReconcile = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledReconcile = false
            self.reconcileWithLivePointer()
        }
    }

    func reconcileWithLivePointer(at screenPoint: NSPoint = NSEvent.mouseLocation) {
        var matchedID: UUID?
        var staleIDs: [UUID] = []

        for (itemID, entry) in rowViews {
            guard let view = entry.view else {
                staleIDs.append(itemID)
                continue
            }
            if matchedID == nil, view.containsScreenPointInVisibleBounds(screenPoint) {
                matchedID = itemID
            }
        }

        for id in staleIDs {
            rowViews.removeValue(forKey: id)
        }

        if hoveredItemID != matchedID {
            hoveredItemID = matchedID
        }
    }

    func pruneHover(validItemIDs: Set<UUID>) {
        if let current = hoveredItemID, !validItemIDs.contains(current) {
            hoveredItemID = nil
        }
    }
}

/// Zero-hit-testing AppKit view spanning a full row (`[Checkbox | Body | Eye + X]`)
/// so moving smoothly across row controls never flickers hover, while `updateTrackingAreas`
/// and scroll reconciliation prevent macOS from leaving stale hover behind on scrolled rows.
struct ShelfRowHoverTracker: NSViewRepresentable {
    let itemID: UUID
    let coordinator: ShelfRowHoverCoordinator

    func makeNSView(context: Context) -> ShelfRowHoverTrackerNSView {
        let view = ShelfRowHoverTrackerNSView()
        view.configure(itemID: itemID, coordinator: coordinator)
        return view
    }

    func updateNSView(_ nsView: ShelfRowHoverTrackerNSView, context: Context) {
        nsView.configure(itemID: itemID, coordinator: coordinator)
    }

    static func dismantleNSView(_ nsView: ShelfRowHoverTrackerNSView, coordinator: ()) {
        nsView.unregister()
    }
}

final class ShelfRowHoverTrackerNSView: NSView {
    private weak var coordinator: ShelfRowHoverCoordinator?
    private var itemID: UUID?
    private var trackingAreaRef: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(itemID: UUID, coordinator: ShelfRowHoverCoordinator) {
        if self.itemID != itemID || self.coordinator !== coordinator {
            unregister()
            self.itemID = itemID
            self.coordinator = coordinator
        }
        if window != nil {
            coordinator.register(self, for: itemID)
        }
    }

    func unregister() {
        if let itemID, let coordinator {
            coordinator.unregister(self, for: itemID)
        }
        itemID = nil
        coordinator = nil
    }

    func containsScreenPointInVisibleBounds(_ screenPoint: NSPoint) -> Bool {
        guard let window, window.isVisible, !window.ignoresMouseEvents else { return false }
        if let shelfWindow = window as? ShelfWindow,
           shelfWindow.dropContainerView.highlightState.isAutoHidden {
            return false
        }
        let visibleBounds = bounds.intersection(visibleRect)
        guard !visibleBounds.isNull, !visibleBounds.isEmpty,
              visibleBounds.width >= 2, visibleBounds.height >= 2 else {
            return false
        }
        let rectInWindow = convert(visibleBounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow).intersection(window.frame)
        guard !screenRect.isNull, !screenRect.isEmpty else { return false }
        return screenRect.contains(screenPoint)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let itemID, let coordinator else { return }
        if window != nil {
            coordinator.register(self, for: itemID)
        } else {
            coordinator.unregister(self, for: itemID)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let isCurrentlyInside = containsScreenPointInVisibleBounds(NSEvent.mouseLocation)
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if isCurrentlyInside {
            options.insert(.assumeInside)
        }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area

        if let itemID, let coordinator {
            let currentlyMarkedHovered = (coordinator.hoveredItemID == itemID)
            if isCurrentlyInside != currentlyMarkedHovered {
                coordinator.scheduleReconcile()
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let itemID else { return }
        coordinator?.setHovered(itemID: itemID, isHovered: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard let itemID else { return }
        coordinator?.setHovered(itemID: itemID, isHovered: false)
    }
}

struct ShelfItemRowView: View {
    let shelfID: UUID
    let item: ShelfItem
    let theme: ShelfTheme
    let palette: ResolvedShelfPalette
    let colorVariation: ShelfColorVariation
    let hoverCoordinator: ShelfRowHoverCoordinator
    let isHovered: Bool
    let isAutoHidden: Bool
    let isSelected: Bool
    let hasAnySelection: Bool
    let resolveDragItems: () -> [ShelfItem]
    let onToggleCheckbox: () -> Void
    let onTapRow: (Bool, Bool) -> Void
    let onDragCompleted: (Set<UUID>, Set<String>) -> Void
    let onQuickLook: () -> Void
    let onRemove: () -> Void
    let onSelectAll: () -> Void
    let onCopySelection: () -> Void
    let onClearShelf: () -> Void

    @State private var nameAvailableWidth: CGFloat = 0

    private var isRowHovered: Bool {
        isHovered && !isAutoHidden
    }

    private var isNameTruncated: Bool {
        guard nameAvailableWidth > 10 else { return false }
        let naturalWidth = NSString(string: item.displayName)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            .width
        return naturalWidth > (nameAvailableWidth - 4)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleCheckbox) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        isSelected
                            ? palette.accentColor
                            : palette.secondaryTextColor.opacity(isRowHovered || hasAnySelection ? 0.90 : 0.42)
                    )
                    .frame(width: 22, height: 22)
                    .hoverDarken(in: Circle(), isActive: isRowHovered) { hovering in
                        if hovering {
                            FilenameTooltipController.shared.hide(forToken: item.id)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Deselect item" : "Select item")

            HStack(spacing: 8) {
                itemThumbnail
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(palette.borderColor, lineWidth: 0.75)
                    )
                    .background(
                        ShelfItemIconAnchor(shelfID: shelfID, itemID: item.id)
                            .allowsHitTesting(false)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.primaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { nameAvailableWidth = geo.size.width }
                                    .onChange(of: geo.size.width) { _, newWidth in
                                        nameAvailableWidth = newWidth
                                    }
                            }
                        )

                    HStack(spacing: 5) {
                        Text(item.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(palette.secondaryTextColor)
                            .lineLimit(1)

                        if shouldShowTypeTag {
                            Text(item.badgeLabel)
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(palette.secondaryTextColor)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(palette.controlFill, in: Capsule())
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(
                ShelfDragSource(
                    shelfID: shelfID,
                    resolveDragItems: resolveDragItems,
                    contextMenuItem: item,
                    onDragCompleted: onDragCompleted,
                    onTap: onTapRow,
                    onDoubleClick: { item.openItem() },
                    onQuickLookItem: { _ in onQuickLook() },
                    onRemoveItem: { _ in onRemove() },
                    onSelectAll: onSelectAll,
                    onCopySelection: onCopySelection,
                    onClearShelf: onClearShelf,
                    onHoverChanged: { hovering, _, shelfRect in
                        handleBodyHover(hovering, shelfScreenRect: shelfRect)
                    }
                )
            )

            // Permanently reserved width for Quick Look + Remove eliminates hover text spasm completely
            HStack(spacing: 2) {
                Button(action: onQuickLook) {
                    Image(systemName: "eye")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondaryTextColor)
                        .frame(width: 22, height: 22)
                        .background(palette.controlFill, in: Circle())
                        .hoverDarken(in: Circle(), isActive: isRowHovered) { hovering in
                            if hovering {
                                FilenameTooltipController.shared.hide(forToken: item.id)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help("Quick Look")

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(palette.secondaryTextColor)
                        .frame(width: 22, height: 22)
                        .background(palette.controlFill, in: Circle())
                        .hoverDarken(in: Circle(), isActive: isRowHovered) { hovering in
                            if hovering {
                                FilenameTooltipController.shared.hide(forToken: item.id)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help("Remove from shelf")
            }
            .opacity(isRowHovered ? 1.0 : 0.0)
            .allowsHitTesting(isRowHovered)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(rowBackgroundColor)
                ShelfRowHoverTracker(itemID: item.id, coordinator: hoverCoordinator)
                    .allowsHitTesting(false)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? palette.accentColor.opacity(0.60) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onDisappear {
            FilenameTooltipController.shared.hide(forToken: item.id)
        }
    }

    private func handleBodyHover(_ hovering: Bool, shelfScreenRect: NSRect) {
        if hovering && !isAutoHidden && isNameTruncated && shelfScreenRect != .zero {
            FilenameTooltipController.shared.scheduleShow(
                text: item.displayName,
                token: item.id,
                shelfScreenRect: shelfScreenRect,
                theme: theme,
                colorVariation: colorVariation
            )
        } else {
            FilenameTooltipController.shared.hide(forToken: item.id)
        }
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            return palette.accentColor.opacity(palette.isLightTheme ? 0.16 : 0.22)
        }
        if isRowHovered {
            return palette.rowHoverFill
        }
        return palette.rowFill
    }

    private var shouldShowTypeTag: Bool {
        switch item.kind {
        case .webURL, .text, .image:
            return true
        case .file, .folder:
            return false
        }
    }

    @ViewBuilder
    private var itemThumbnail: some View {
        switch item.kind {
        case .file:
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    palette.controlFill
                    Image(nsImage: item.fallbackIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                }
            }

        case .folder:
            ZStack {
                palette.controlFill
                Image(nsImage: item.thumbnail ?? item.fallbackIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
            }

        case .image:
            if let img = item.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                symbolThumb("photo.fill", tint: .blue)
            }

        case .webURL:
            symbolThumb("globe", tint: .teal)

        case .text:
            symbolThumb("doc.text.fill", tint: .orange)
        }
    }

    private func symbolThumb(_ symbol: String, tint: Color) -> some View {
        ZStack {
            tint.opacity(0.18)
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}
