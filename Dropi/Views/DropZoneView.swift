import SwiftUI

struct DropZoneView: View {
    let isDropTargeted: Bool
    let palette: ResolvedShelfPalette

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isDropTargeted ? palette.accentColor.opacity(0.22) : palette.controlFill)
                    .frame(width: 54, height: 54)

                Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(isDropTargeted ? palette.accentColor : palette.secondaryTextColor)
                    .scaleEffect(isDropTargeted ? 1.08 : 1.0)
                    .animation(.spring(duration: 0.2), value: isDropTargeted)
            }

            VStack(spacing: 4) {
                Text(isDropTargeted ? "Release to Hold" : "Drop Here")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(isDropTargeted ? palette.accentColor : palette.primaryTextColor)

                Text("Files, folders, images,\nURLs, or text snippets")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryTextColor)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? palette.accentColor.opacity(0.88) : palette.borderColor,
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: [6, 5])
                )
                .padding(10)
        )
    }
}
