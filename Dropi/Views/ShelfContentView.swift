import AppKit
import SwiftUI

struct ShelfContentView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var dropHighlight: ShelfDropHighlightState
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var rowHover = ShelfRowHoverCoordinator()

    let onRequestClose: () -> Void
    let onRequestResize: (CGFloat) -> Void
    let onRequestQuickLook: (ShelfItem) -> Void
    let onSelectionInteraction: () -> Void

    private var activeTheme: ShelfTheme {
        store.effectiveTheme(for: settings.shelfTheme)
    }

    private var effectiveColorVariation: ShelfColorVariation {
        settings.shelfTheme.isRandomTheme ? .identity : store.colorVariation
    }

    private var resolvedPalette: ResolvedShelfPalette {
        activeTheme.palette(
            variation: effectiveColorVariation,
            level: settings.colorVariationLevel
        )
    }

    private var showCleanAutoHideTab: Bool {
        dropHighlight.isAutoHidden && settings.autoHideTabStyle.usesCustomTabOverlay
    }

    private var growthAnchor: UnitPoint {
        dropHighlight.dockedEdge == .left ? .leading : .trailing
    }

    private var contentAlignment: Alignment {
        dropHighlight.dockedEdge == .left ? .trailing : .leading
    }

    var body: some View {
        let palette = resolvedPalette
        GeometryReader { geo in
            ZStack {
                // Layer 1: Full shelf content lives inside a zero-min-width overlay so SwiftUI
                // NEVER enforces a 282pt minimum width on NSWindow during Auto Hide (preventing
                // any overflow onto adjacent Virtual Desktops), while staying anchored at fixed
                // full width so growing out from the edge strip blooms smoothly with zero reflow!
                Color.clear
                    .frame(width: geo.size.width, height: geo.size.height)
                    .overlay(alignment: contentAlignment) {
                        fullShelfContent(palette: palette)
                            .frame(width: Constants.Shelf.width, height: geo.size.height)
                            .scaleEffect(x: showCleanAutoHideTab ? 0.94 : 1.0, y: 1.0, anchor: growthAnchor)
                            .opacity(showCleanAutoHideTab ? 0.0 : 1.0)
                            .allowsHitTesting(!showCleanAutoHideTab)
                    }
                    .clipped()

                // Layer 2: Auto-Hide edge tab fills the exact live collapsed window bounds
                // (26pt for Handle Bar, 54pt for Icons / Shelf Number) and dissolves
                // smoothly as the shelf grows out from behind it.
                if settings.autoHideTabStyle.usesCustomTabOverlay {
                    AutoHideTabView(
                        store: store,
                        style: settings.autoHideTabStyle,
                        palette: palette
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(showCleanAutoHideTab ? 1.0 : 0.0)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                palette.backgroundTint
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Constants.Shelf.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Constants.Shelf.cornerRadius)
                .strokeBorder(
                    dropHighlight.isDropTargeted ? palette.accentColor.opacity(0.95) : palette.borderColor,
                    lineWidth: dropHighlight.isDropTargeted ? 2.5 : 1.0
                )
        )
        .preferredColorScheme(palette.preferredColorScheme)
        .animation(.easeInOut(duration: 0.16), value: dropHighlight.isDropTargeted)
        .animation(.easeOut(duration: 0.24), value: showCleanAutoHideTab)
        .animation(.easeInOut(duration: 0.22), value: activeTheme)
        .animation(.easeInOut(duration: 0.22), value: settings.colorVariationLevel)
        .onChange(of: store.items.count) { _, newCount in
            rowHover.pruneHover(validItemIDs: Set(store.items.map(\.id)))
            rowHover.scheduleReconcile()
            onRequestResize(Constants.Shelf.preferredHeight(forItemCount: newCount))
        }
        .onChange(of: dropHighlight.isPointerInsideShelf) { _, inside in
            if !inside {
                rowHover.clearHover()
            }
        }
        .onChange(of: dropHighlight.isAutoHidden) { _, hidden in
            if hidden {
                rowHover.clearHover()
            }
        }
        .onChange(of: dropHighlight.isDropTargeted) { _, targeted in
            if targeted {
                rowHover.clearHover()
            }
        }
    }

    // MARK: - Full Shelf Body

    private func fullShelfContent(palette: ResolvedShelfPalette) -> some View {
        VStack(spacing: 0) {
            headerBar(palette: palette)

            if store.items.isEmpty {
                VStack(spacing: 4) {
                    DropZoneView(isDropTargeted: dropHighlight.isDropTargeted, palette: palette)
                    HStack {
                        Spacer()
                        Button {
                            _ = store.addFromClipboard()
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(palette.secondaryTextColor)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(palette.controlFill, in: Capsule())
                                .hoverDarken(in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                themeDivider(palette: palette)
                selectionToolbar(palette: palette)
                themeDivider(palette: palette)
                itemListView(palette: palette)
                themeDivider(palette: palette)
                bottomDragBar(palette: palette)
            }
        }
    }

    private func themeDivider(palette: ResolvedShelfPalette) -> some View {
        Rectangle()
            .fill(palette.dividerColor)
            .frame(height: 0.75)
    }

    // MARK: - Header (Custom Drag Handle — Never Triggers macOS Half-Screen Tiling!)

    private func headerBar(palette: ResolvedShelfPalette) -> some View {
        HStack(spacing: 6) {
            Button(action: onRequestClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(palette.primaryTextColor.opacity(0.85), palette.controlFill)
                    .frame(width: 20, height: 20)
                    .hoverDarken(in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close this shelf")

            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(palette.tertiaryTextColor)

                Text(store.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.primaryTextColor)

                if !store.items.isEmpty {
                    Text(store.items.count == 1 ? "1 Item" : store.items.dropshelfSummaryLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.secondaryTextColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(palette.controlFill, in: Capsule())
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(WindowDragGesture())
            .help("Drag up/down to reposition, or past the center of the screen to switch sides")
        }
        .padding(.horizontal, Constants.Shelf.padding)
        .padding(.vertical, 7)
    }

    // MARK: - Selection Toolbar

    private func selectionToolbar(palette: ResolvedShelfPalette) -> some View {
        HStack(spacing: 6) {
            Button {
                store.toggleSelectAll()
                onSelectionInteraction()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.isAllSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11.5))
                    Text(store.isAllSelected ? "None" : "All")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(store.isAllSelected ? palette.accentColor : palette.secondaryTextColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(palette.controlFill, in: Capsule())
                .hoverDarken(in: Capsule())
            }
            .buttonStyle(.plain)
            .help(store.isAllSelected ? "Deselect all items" : "Select all items in this shelf")

            if !store.selectedIDs.isEmpty {
                Text("\(store.selectedIDs.count) of \(store.items.count) selected")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.accentColor)
                    .lineLimit(1)
            } else {
                Text("Click to select · Drag any row")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.tertiaryTextColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if settings.showCopyButtonInShelf {
                Button {
                    store.copySelectionOrAllToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondaryTextColor)
                        .frame(width: 22, height: 22)
                        .background(palette.controlFill, in: Circle())
                        .hoverDarken(in: Circle())
                }
                .buttonStyle(.plain)
                .help(store.selectedIDs.isEmpty ? "Copy all items" : "Copy selected items")
            }

            Button {
                if store.selectedIDs.isEmpty {
                    store.clearAll()
                } else {
                    store.removeSelected()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryTextColor)
                    .frame(width: 22, height: 22)
                    .background(palette.controlFill, in: Circle())
                    .hoverDarken(in: Circle())
            }
            .buttonStyle(.plain)
            .help(store.selectedIDs.isEmpty ? "Clear this shelf" : "Remove selected items")
        }
        .padding(.horizontal, Constants.Shelf.padding)
        .padding(.vertical, 6)
    }

    // MARK: - Listed Selectable Items

    private func itemListView(palette: ResolvedShelfPalette) -> some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(store.items) { item in
                    ShelfItemRowView(
                        shelfID: store.id,
                        item: item,
                        theme: activeTheme,
                        palette: palette,
                        colorVariation: effectiveColorVariation,
                        hoverCoordinator: rowHover,
                        isHovered: rowHover.hoveredItemID == item.id,
                        isAutoHidden: dropHighlight.isAutoHidden,
                        isSelected: store.selectedIDs.contains(item.id),
                        hasAnySelection: !store.selectedIDs.isEmpty,
                        resolveDragItems: {
                            store.itemsForRowDrag(initiatedOn: item)
                        },
                        onToggleCheckbox: {
                            store.toggleSelection(itemID: item.id)
                            onSelectionInteraction()
                        },
                        onTapRow: { cmdPressed, shiftPressed in
                            store.handleRowTap(
                                itemID: item.id,
                                commandPressed: cmdPressed,
                                shiftPressed: shiftPressed
                            )
                        },
                        onDragCompleted: { draggedIDs, adoptedPaths in
                            store.removeDraggedOut(draggedIDs, adoptedSourcePaths: adoptedPaths)
                        },
                        onQuickLook: {
                            onRequestQuickLook(item)
                        },
                        onRemove: {
                            store.remove(item)
                        },
                        onSelectAll: {
                            store.selectAll()
                        },
                        onCopySelection: {
                            store.copySelectionOrAllToClipboard()
                        },
                        onClearShelf: {
                            store.clearAll()
                        }
                    )
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, _ in
            FilenameTooltipController.shared.hide()
            rowHover.reconcileWithLivePointer()
        }
    }

    // MARK: - Bottom Drag-Out Bar

    private func bottomDragBar(palette: ResolvedShelfPalette) -> some View {
        HStack(spacing: 6) {
            if store.hasPartialSelection {
                dragPill(
                    palette: palette,
                    title: "Drag \(store.selectedIDs.count) Selected",
                    symbol: "hand.draw.fill",
                    isProminent: true,
                    resolveItems: { store.selectedItems }
                )

                dragPill(
                    palette: palette,
                    title: "All (\(store.items.count))",
                    symbol: "square.stack.3d.up.fill",
                    isProminent: false,
                    resolveItems: { store.items }
                )
                .frame(width: 82)
            } else {
                let count = store.items.count
                dragPill(
                    palette: palette,
                    title: count == 1 ? "Drag Item" : "Drag All (\(count))",
                    symbol: count == 1 ? "hand.draw.fill" : "square.stack.3d.up.fill",
                    isProminent: true,
                    resolveItems: { store.items }
                )
            }
        }
        .padding(.horizontal, Constants.Shelf.padding)
        .padding(.vertical, 8)
    }

    private func dragPill(
        palette: ResolvedShelfPalette,
        title: String,
        symbol: String,
        isProminent: Bool,
        resolveItems: @escaping () -> [ShelfItem]
    ) -> some View {
        ShelfDragPillView(
            store: store,
            palette: palette,
            title: title,
            symbol: symbol,
            isProminent: isProminent,
            resolveItems: resolveItems
        )
    }
}

private struct ShelfDragPillView: View {
    @ObservedObject var store: ShelfStore
    let palette: ResolvedShelfPalette
    let title: String
    let symbol: String
    let isProminent: Bool
    let resolveItems: () -> [ShelfItem]

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let isLight = (colorScheme == .light)
        let shape = RoundedRectangle(cornerRadius: 9)
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(isProminent ? palette.accentForegroundColor : palette.primaryTextColor)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6.5)
        .padding(.horizontal, 10)
        .background(
            shape
                .fill(isProminent ? palette.accentColor.opacity(0.92) : palette.controlFill)
        )
        .overlay(
            shape
                .fill(Color.black.opacity(isHovered ? (isLight ? 0.16 : 0.28) : 0.0))
                .allowsHitTesting(false)
        )
        .overlay(
            ShelfDragSource(
                shelfID: store.id,
                resolveDragItems: resolveItems,
                contextMenuItem: nil,
                onDragCompleted: { draggedIDs, adoptedPaths in
                    store.removeDraggedOut(draggedIDs, adoptedSourcePaths: adoptedPaths)
                },
                onSelectAll: {
                    store.selectAll()
                },
                onCopySelection: {
                    store.copySelectionOrAllToClipboard()
                },
                onClearShelf: {
                    store.clearAll()
                },
                onHoverChanged: { hovering, _, _ in
                    isHovered = hovering
                }
            )
        )
        .clipShape(shape)
        .animation(.easeOut(duration: 0.10), value: isHovered)
    }
}

// MARK: - Custom Window Drag Handle (Zero macOS Half-Screen Window Tiling!)

struct WindowDragGesture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Manually tracks mouseDragged and updates `window.setFrameOrigin` directly instead of calling
/// `window.performDrag(with:)`. This completely prevents macOS's native half-screen tiling
/// overlay from ever activating when dragging shelves near screen edges, and guarantees 100%
/// consistent cross-screen side switching when crossing the horizontal halfway line.
private final class WindowDragView: NSView {
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var didBeginDrag = false
    private var didPushCursor = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        FilenameTooltipController.shared.hide()
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window.frame.origin
        didBeginDrag = false
        if !didPushCursor {
            NSCursor.closedHand.push()
            didPushCursor = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - startMouse.x
        let dy = currentMouse.y - startMouse.y

        if !didBeginDrag {
            guard hypot(dx, dy) >= 2.0 else { return }
            didBeginDrag = true
            (window as? ShelfWindow)?.onManualMoveBegan?()
        }

        let newOrigin = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
        window.setFrameOrigin(newOrigin)
        (window as? ShelfWindow)?.onManualMoveUpdated?(window.frame, currentMouse)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = didBeginDrag
        dragStartMouse = nil
        dragStartOrigin = nil
        didBeginDrag = false
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }

        if wasDragging, let shelfWindow = window as? ShelfWindow {
            shelfWindow.onManualMoveEnded?(shelfWindow.frame)
        }
    }
}
