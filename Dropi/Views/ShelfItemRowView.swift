import AppKit
import SwiftUI

struct ShelfItemRowView: View {
    let shelfID: UUID
    let item: ShelfItem
    let palette: ResolvedShelfPalette
    let colorVariation: ShelfColorVariation
    let isAutoHidden: Bool
    let isSelected: Bool
    let hasAnySelection: Bool
    let resolveDragItems: () -> [ShelfItem]
    let onToggleCheckbox: () -> Void
    let onTapRow: (Bool, Bool) -> Void
    let onDragCompleted: (Set<UUID>) -> Void
    let onRemove: () -> Void
    let onSelectAll: () -> Void
    let onCopySelection: () -> Void
    let onClearShelf: () -> Void

    @State private var isBodyHovered = false
    @State private var isRemoveHovered = false
    @State private var nameAvailableWidth: CGFloat = 0

    private var isRowHovered: Bool {
        isBodyHovered || isRemoveHovered
    }

    private var isNameTruncated: Bool {
        guard nameAvailableWidth > 10 else { return false }
        let naturalWidth = NSString(string: item.displayName)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            .width
        return naturalWidth > (nameAvailableWidth - 4)
    }

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onToggleCheckbox) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        isSelected
                            ? palette.accentColor
                            : palette.secondaryTextColor.opacity(isRowHovered || hasAnySelection ? 0.90 : 0.42)
                    )
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
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
                    onRemoveItem: { _ in onRemove() },
                    onSelectAll: onSelectAll,
                    onCopySelection: onCopySelection,
                    onClearShelf: onClearShelf,
                    onHoverChanged: { hovering, _, shelfRect in
                        handleBodyHover(hovering, shelfScreenRect: shelfRect)
                    }
                )
            )

            // Permanently reserved 20pt width eliminates hover text spasm completely
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(palette.secondaryTextColor)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isRowHovered ? 1.0 : 0.0)
            .allowsHitTesting(isRowHovered)
            .onHover { hovering in
                isRemoveHovered = hovering
                if hovering {
                    FilenameTooltipController.shared.hide(forToken: item.id)
                }
            }
            .help("Remove from shelf")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(rowBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? palette.accentColor.opacity(0.60) : Color.clear, lineWidth: 1)
        )
        .onDisappear {
            FilenameTooltipController.shared.hide(forToken: item.id)
        }
    }

    private func handleBodyHover(_ hovering: Bool, shelfScreenRect: NSRect) {
        isBodyHovered = hovering
        if hovering && !isAutoHidden && isNameTruncated && shelfScreenRect != .zero {
            FilenameTooltipController.shared.scheduleShow(
                text: item.displayName,
                token: item.id,
                shelfScreenRect: shelfScreenRect,
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

        case .image(let data, _, _):
            if let img = item.thumbnail ?? NSImage(data: data) {
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
