import AppKit
import QuickLookThumbnailing

enum ThumbnailGenerator {
    private static let size = Constants.Thumbnail.size

    static func generate(for item: ShelfItem) async -> NSImage? {
        switch item.kind {
        case .file(let url, _):
            return await generateForFile(url: url)
        case .folder(let url):
            return await MainActor.run {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 96, height: 96)
                return icon
            }
        case .image(let data, _, _):
            return await Task.detached(priority: .userInitiated) {
                Self.downsampledImage(from: data, maxDimension: 280)
            }.value
        case .webURL, .text:
            return nil
        }
    }

    static func generateForFile(url: URL) async -> NSImage {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                if let thumbnail {
                    continuation.resume(returning: thumbnail.nsImage)
                } else {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    icon.size = NSSize(width: 96, height: 96)
                    continuation.resume(returning: icon)
                }
            }
        }
    }

    private nonisolated static func downsampledImage(from data: Data, maxDimension: CGFloat) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return image }
        let longest = max(originalSize.width, originalSize.height)
        guard longest > maxDimension else { return image }

        let ratio = maxDimension / longest
        let targetSize = NSSize(
            width: max(1, (originalSize.width * ratio).rounded()),
            height: max(1, (originalSize.height * ratio).rounded())
        )
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()
        return resized
    }
}
