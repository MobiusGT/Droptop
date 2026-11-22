import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum SelfDragState {
    static var isDraggingFromShelf: Bool = false
    static var sourceShelfID: UUID?
    static var activeSessionCount: Int = 0

    static func begin(fromShelf shelfID: UUID) {
        activeSessionCount += 1
        isDraggingFromShelf = true
        sourceShelfID = shelfID
    }

    static func end() {
        activeSessionCount = max(0, activeSessionCount - 1)
        isDraggingFromShelf = activeSessionCount > 0
        if !isDraggingFromShelf {
            sourceShelfID = nil
        }
    }
}

/// Holds an immutable export payload so async NSFilePromise writes succeed even after
/// the item is removed from the shelf upon drag completion.
final class ShelfItemPromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    nonisolated private static let writeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.local.Droptop.FilePromiseWriteQueue"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    let kind: ShelfItemKind
    let suggestedFilename: String

    nonisolated init(kind: ShelfItemKind, suggestedFilename: String) {
        self.kind = kind
        self.suggestedFilename = suggestedFilename
        super.init()
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        suggestedFilename
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.writeQueue
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        do {
            try Self.write(kind: kind, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    private nonisolated static func write(kind: ShelfItemKind, to destinationURL: URL) throws {
        switch kind {
        case .file(let sourceURL, _), .folder(let sourceURL):
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        case .image(let data, _, _):
            try data.write(to: destinationURL, options: .atomic)
        case .webURL(let url, _):
            let plist: [String: Any] = ["URL": url.absoluteString]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: destinationURL, options: .atomic)
        case .text(let plain, let rtfData, _):
            if let rtfData {
                try rtfData.write(to: destinationURL, options: .atomic)
            } else {
                try Data(plain.utf8).write(to: destinationURL, options: .atomic)
            }
        }
    }
}

/// Dual-purpose pasteboard writer: supplies both native in-memory pasteboard representations
/// (for apps like Notes, Safari, Slack, Preview, Terminal) AND an NSFilePromiseProvider
/// (so dropping onto Finder or Desktop writes a real .png / .webloc / .txt / .rtf file).
final class ShelfFilePromiseProvider: NSFilePromiseProvider, @unchecked Sendable {
    nonisolated private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    nonisolated(unsafe) private var payloadKind: ShelfItemKind?
    nonisolated(unsafe) private var retainedDelegate: ShelfItemPromiseDelegate?

    /// Required because AppKit's `init(fileType:delegate:)` internally calls `self.init()`.
    nonisolated override init() {
        super.init()
    }

    nonisolated convenience init(kind: ShelfItemKind, suggestedFilename: String) {
        let promiseFileType: String
        switch kind {
        case .file, .folder:
            promiseFileType = UTType.data.identifier
        case .image(_, let ext, _):
            promiseFileType = (UTType(filenameExtension: ext) ?? .png).identifier
        case .webURL:
            promiseFileType = "com.apple.web-internet-location"
        case .text(_, let rtfData, _):
            promiseFileType = rtfData != nil ? UTType.rtf.identifier : UTType.plainText.identifier
        }

        let promiseDelegate = ShelfItemPromiseDelegate(
            kind: kind,
            suggestedFilename: suggestedFilename
        )
        self.init(fileType: promiseFileType, delegate: promiseDelegate)
        self.payloadKind = kind
        self.retainedDelegate = promiseDelegate
    }

    nonisolated override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        guard let payloadKind else { return types }
        switch payloadKind {
        case .image(_, let ext, _):
            let primary: NSPasteboard.PasteboardType = (ext.lowercased() == "tiff" || ext.lowercased() == "tif") ? .tiff : .png
            if !types.contains(primary) { types.append(primary) }
            if !types.contains(.tiff) { types.append(.tiff) }
        case .webURL:
            let urlTypes: [NSPasteboard.PasteboardType] = [.URL, Self.urlNameType, .string]
            types = urlTypes + types.filter { !urlTypes.contains($0) }
        case .text(_, let rtfData, _):
            var textTypes: [NSPasteboard.PasteboardType] = []
            if rtfData != nil { textTypes.append(.rtf) }
            textTypes.append(.string)
            types = textTypes + types.filter { !textTypes.contains($0) }
        case .file, .folder:
            break
        }
        return types
    }

    nonisolated override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if let payloadKind {
            switch payloadKind {
            case .image(let data, let ext, _):
                if type == .png {
                    if ext.lowercased() == "png" { return data }
                    if let img = NSImage(data: data),
                       let tiff = img.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff) {
                        return rep.representation(using: .png, properties: [:])
                    }
                }
                if type == .tiff {
                    if ext.lowercased() == "tiff" || ext.lowercased() == "tif" { return data }
                    return NSImage(data: data)?.tiffRepresentation
                }
            case .webURL(let url, let title):
                if type == .URL {
                    return (url as NSURL).pasteboardPropertyList(forType: type)
                }
                if type == Self.urlNameType {
                    return title ?? url.host ?? url.absoluteString
                }
                if type == .string {
                    return url.absoluteString
                }
            case .text(let plain, let rtfData, _):
                if type == .rtf, let rtfData {
                    return rtfData
                }
                if type == .string {
                    return plain
                }
            case .file, .folder:
                break
            }
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

@MainActor
enum ShelfItemDragWriter {
    static func draggingItems(for items: [ShelfItem], anchorPoint: NSPoint) -> [NSDraggingItem] {
        var draggingItems: [NSDraggingItem] = []

        for (index, item) in items.enumerated() {
            let writer: any NSPasteboardWriting
            switch item.kind {
            case .file(let url, _), .folder(let url):
                writer = url as NSURL
            case .image, .webURL, .text:
                writer = ShelfFilePromiseProvider(kind: item.kind, suggestedFilename: item.suggestedExportFilename)
            }

            let dragItem = NSDraggingItem(pasteboardWriter: writer)
            let image = dragPreviewImage(for: item)
            let size = image.size
            let stackOffset = CGFloat(min(index, 4)) * 5.0
            let frame = NSRect(
                x: anchorPoint.x - size.width / 2 + stackOffset,
                y: anchorPoint.y - size.height / 2 - stackOffset,
                width: size.width,
                height: size.height
            )
            dragItem.setDraggingFrame(frame, contents: image)
            draggingItems.append(dragItem)
        }

        return draggingItems
    }

    private static func dragPreviewImage(for item: ShelfItem) -> NSImage {
        let targetSize = NSSize(width: 52, height: 52)

        if let thumb = item.thumbnail {
            return renderBadgeImage(size: targetSize) { rect in
                NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).addClip()
                thumb.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        }

        switch item.kind {
        case .file, .folder:
            let icon = item.fallbackIcon
            icon.size = targetSize
            return icon

        case .image(let data, _, _):
            if let img = NSImage(data: data) {
                return renderBadgeImage(size: targetSize) { rect in
                    NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).addClip()
                    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                }
            }
            return symbolBadge(symbol: "photo.fill", tint: .systemBlue, size: targetSize)

        case .webURL:
            return symbolBadge(symbol: "globe", tint: .systemTeal, size: targetSize)

        case .text(let plain, _, _):
            return renderBadgeImage(size: NSSize(width: 72, height: 52)) { rect in
                let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
                NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.lineWidth = 1
                path.stroke()

                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph
                ]
                let snippet = String(plain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                NSString(string: snippet).draw(in: rect.insetBy(dx: 7, dy: 7), withAttributes: attrs)
            }
        }
    }

    private static func symbolBadge(symbol: String, tint: NSColor, size: NSSize) -> NSImage {
        renderBadgeImage(size: size) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
            tint.withAlphaComponent(0.22).setFill()
            path.fill()
            tint.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1.2
            path.stroke()

            if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .medium)) {
                let drawRect = NSRect(
                    x: (rect.width - 26) / 2,
                    y: (rect.height - 26) / 2,
                    width: 26,
                    height: 26
                )
                icon.draw(in: drawRect)
            }
        }
    }

    private static func renderBadgeImage(size: NSSize, draw: (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        draw(NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }
}
