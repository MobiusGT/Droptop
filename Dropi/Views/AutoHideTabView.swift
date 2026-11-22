import AppKit
import SwiftUI

struct AutoHideTabView: View {
    @ObservedObject var store: ShelfStore
    let style: AutoHideTabStyle
    let palette: ResolvedShelfPalette

    var body: some View {
        Group {
            switch style {
            case .minimalColor:
                minimalColorStrip
            case .shelfNumber:
                shelfNumberStrip
            case .fileIcons:
                fileIconsStrip
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var minimalColorStrip: some View {
        VStack(spacing: 0) {
            Spacer()
            Capsule()
                .fill(palette.accentColor.opacity(0.92))
                .frame(width: 4, height: 40)
                .shadow(color: palette.accentColor.opacity(0.35), radius: 3)
            Spacer()
        }
    }

    private var shelfNumberStrip: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 8)

            VStack(spacing: 3) {
                Text("SHELF")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(palette.secondaryTextColor)

                Text("\(store.shelfNumber)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryTextColor)
            }

            if !store.items.isEmpty {
                Text("\(store.items.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.accentForegroundColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.accentColor, in: Capsule())
            }

            Spacer(minLength: 8)
        }
    }

    private var fileIconsStrip: some View {
        let maxIcons = 5
        let shownItems = Array(store.items.prefix(maxIcons))
        let remainingCount = max(0, store.items.count - maxIcons)

        return VStack(spacing: 6) {
            Spacer(minLength: 8)

            if shownItems.isEmpty {
                Image(systemName: "tray")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.secondaryTextColor)
            } else {
                ForEach(shownItems) { item in
                    miniIcon(for: item)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(palette.borderColor, lineWidth: 0.75)
                        )
                        .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
                }

                if remainingCount > 0 {
                    Text("+\(remainingCount)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.accentForegroundColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.accentColor, in: Capsule())
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func miniIcon(for item: ShelfItem) -> some View {
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
                        .frame(width: 20, height: 20)
                }
            }

        case .folder:
            ZStack {
                palette.controlFill
                Image(nsImage: item.thumbnail ?? item.fallbackIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
            }

        case .image(let data, _, _):
            if let img = item.thumbnail ?? NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                symbolMini("photo.fill", tint: .blue)
            }

        case .webURL:
            symbolMini("globe", tint: .teal)

        case .text:
            symbolMini("doc.text.fill", tint: .orange)
        }
    }

    private func symbolMini(_ symbol: String, tint: Color) -> some View {
        ZStack {
            tint.opacity(0.20)
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}
