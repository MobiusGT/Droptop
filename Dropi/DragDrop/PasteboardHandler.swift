import AppKit
import Foundation
import UniformTypeIdentifiers

enum PasteboardHandler {
    private static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let promisedFileURLType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")
    private static let legacyFilesPromiseType = NSPasteboard.PasteboardType("Apple files promise pasteboard type")
    private static let coreDragFurlType = NSPasteboard.PasteboardType("CorePasteboardFlavorType 0x6675726C")
    private static let coreDragHfsType = NSPasteboard.PasteboardType("CorePasteboardFlavorType 0x68667320")
    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")
    private static let webURLsWithTitlesType = NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")
    private static let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
    private static let heicType = NSPasteboard.PasteboardType(UTType.heic.identifier)
    private static let gifType = NSPasteboard.PasteboardType(UTType.gif.identifier)
    private static let webpType = NSPasteboard.PasteboardType(UTType.webP.identifier)

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.local.Droptop.FilePromiseReceiveQueue"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    static var registeredDraggedTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL,
            filenamesType,
            .URL,
            urlNameType,
            webURLsWithTitlesType,
            .png,
            jpegType,
            heicType,
            gifType,
            webpType,
            .tiff,
            .rtf,
            .rtfd,
            .string
        ]
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        for type in promiseTypes where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        guard let available = pasteboard.types, !available.isEmpty else { return false }
        var accepted = Set(registeredDraggedTypes)
        accepted.insert(promisedFileURLType)
        accepted.insert(legacyFilesPromiseType)
        accepted.insert(coreDragFurlType)
        accepted.insert(coreDragHfsType)
        for type in available where accepted.contains(type) {
            return true
        }
        // Fallback check for translated file URLs (e.g. Dock folder stack drags)
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        return false
    }

    /// Resolves any macOS file URL — including Dock stack file-reference URLs (`file:///.file/id=...`) —
    /// to a standardized filesystem path URL and verifies it exists on disk.
    static func resolveFileURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let resolved = ((url as NSURL).filePathURL ?? url).standardizedFileURL
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return nil
        }
        return resolved
    }

    /// Extracts supported items from a pasteboard (drag pasteboard, Dock stack drag, or general clipboard).
    /// Returns true if at least one synchronous or asynchronous extraction was started.
    @discardableResult
    static func extractItems(
        from pasteboard: NSPasteboard,
        stagingDirectory: URL,
        completion: @escaping @MainActor ([ShelfItem]) -> Void
    ) -> Bool {
        // 1. Direct file & folder URLs (Finder, Dock folder stacks, desktop, open panels, etc.)
        if let fileURLs = readDirectFileURLs(from: pasteboard), !fileURLs.isEmpty {
            let items = fileURLs.map { ShelfItem.fromFileURL($0, isTemporaryCopy: false) }
            completion(items)
            return true
        }

        // 2. Promised files (Photos, Mail attachments, Safari dragged files/images, etc.)
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let fallbackItems = extractInMemoryItems(from: pasteboard)
            receiveFilePromises(
                receivers,
                stagingDirectory: stagingDirectory,
                fallbackItems: fallbackItems,
                completion: completion
            )
            return true
        }

        // 3. In-memory images, web URLs, and text snippets
        let items = extractInMemoryItems(from: pasteboard)
        if !items.isEmpty {
            completion(items)
            return true
        }

        return false
    }

    // MARK: - Private Readers

    private static func readDirectFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        var resolvedURLs: [URL] = []
        var seenPaths = Set<String>()

        func appendResolved(_ url: URL) {
            guard let resolved = resolveFileURL(url) else { return }
            if seenPaths.insert(resolved.path).inserted {
                resolvedURLs.append(resolved)
            }
        }

        // 1a. Standard NSURL reading (handles Finder & modern drags, including file:///.file/id=... references)
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            for url in urls {
                appendResolved(url)
            }
        }

        // 1b. Legacy NSFilenamesPboardType (used by Dock folder stacks & some Carbon/AppKit apps)
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            for path in paths where !path.isEmpty {
                appendResolved(URL(fileURLWithPath: path))
            }
        }

        // 1c. Per-item raw public.file-url or file:// public.url (covers Dock file-reference strings & custom sources)
        if resolvedURLs.isEmpty, let pbItems = pasteboard.pasteboardItems {
            for pbItem in pbItems {
                for type in [NSPasteboard.PasteboardType.fileURL, NSPasteboard.PasteboardType.URL] {
                    if let str = pbItem.string(forType: type)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let url = URL(string: str),
                       url.isFileURL {
                        appendResolved(url)
                    } else if let data = pbItem.data(forType: type),
                              let url = URL(dataRepresentation: data, relativeTo: nil),
                              url.isFileURL {
                        appendResolved(url)
                    }
                }
            }
        }

        return resolvedURLs.isEmpty ? nil : resolvedURLs
    }

    private static func receiveFilePromises(
        _ receivers: [NSFilePromiseReceiver],
        stagingDirectory: URL,
        fallbackItems: [ShelfItem],
        completion: @escaping @MainActor ([ShelfItem]) -> Void
    ) {
        let batchDir = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)

        let group = DispatchGroup()
        let collector = PromiseURLCollector()

        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: batchDir, options: [:], operationQueue: promiseQueue) { fileURL, error in
                if error == nil, FileManager.default.fileExists(atPath: fileURL.path) {
                    collector.append(fileURL.standardizedFileURL)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let urls = collector.allURLs()
            if !urls.isEmpty {
                let items = urls.map { ShelfItem.fromFileURL($0, isTemporaryCopy: true) }
                completion(items)
            } else if !fallbackItems.isEmpty {
                completion(fallbackItems)
            } else {
                completion([])
            }
        }
    }

    private static func extractInMemoryItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        var results: [ShelfItem] = []

        let webTitlesMap = extractWebTitlesMap(from: pasteboard)

        if let pbItems = pasteboard.pasteboardItems, !pbItems.isEmpty {
            for pbItem in pbItems {
                if let imageItem = extractImageItem(from: pbItem) {
                    results.append(imageItem)
                    continue
                }
                if let urlItem = extractWebURLItem(from: pbItem, titlesMap: webTitlesMap) {
                    results.append(urlItem)
                    continue
                }
                if let textItem = extractTextItem(from: pbItem) {
                    results.append(textItem)
                    continue
                }
            }
        }

        if !results.isEmpty {
            return results
        }

        if let image = NSImage(pasteboard: pasteboard),
           let pngData = pngData(from: image) {
            results.append(ShelfItem(
                kind: .image(data: pngData, fileExtension: "png", suggestedName: timestampedImageName()),
                thumbnail: image
            ))
            return results
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls where !url.isFileURL && isSupportedWebURL(url) {
                let title = webTitlesMap[url.absoluteString] ?? pasteboard.string(forType: urlNameType)
                results.append(ShelfItem(kind: .webURL(url: url, title: title)))
            }
            if !results.isEmpty {
                return results
            }
        }

        if let rtfData = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            let plain = attributed.string
            if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(ShelfItem(kind: .text(plain: plain, rtfData: rtfData, title: nil)))
                return results
            }
        }

        if let plain = pasteboard.string(forType: .string) {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let url = singleWebURL(from: trimmed) {
                    results.append(ShelfItem(kind: .webURL(url: url, title: webTitlesMap[url.absoluteString])))
                } else {
                    results.append(ShelfItem(kind: .text(plain: plain, rtfData: nil, title: nil)))
                }
            }
        }

        return results
    }

    private static func extractImageItem(from pbItem: NSPasteboardItem) -> ShelfItem? {
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"),
            (jpegType, "jpg"),
            (heicType, "heic"),
            (gifType, "gif"),
            (webpType, "webp"),
            (.tiff, "tiff")
        ]

        for (type, ext) in candidates {
            guard let rawData = pbItem.data(forType: type), !rawData.isEmpty,
                  let image = NSImage(data: rawData),
                  image.size.width > 0, image.size.height > 0 else {
                continue
            }

            let name = pbItem.string(forType: urlNameType) ?? timestampedImageName()

            if ext == "tiff", let convertedPNG = pngData(from: image) {
                return ShelfItem(
                    kind: .image(data: convertedPNG, fileExtension: "png", suggestedName: name),
                    thumbnail: image
                )
            }

            return ShelfItem(
                kind: .image(data: rawData, fileExtension: ext, suggestedName: name),
                thumbnail: image
            )
        }
        return nil
    }

    private static func extractWebURLItem(
        from pbItem: NSPasteboardItem,
        titlesMap: [String: String]
    ) -> ShelfItem? {
        guard let urlString = pbItem.string(forType: .URL)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty,
              let url = URL(string: urlString),
              !url.isFileURL,
              isSupportedWebURL(url) else {
            return nil
        }

        let title = pbItem.string(forType: urlNameType)
            ?? titlesMap[url.absoluteString]
            ?? titlesMap[urlString]
        return ShelfItem(kind: .webURL(url: url, title: title))
    }

    private static func extractTextItem(from pbItem: NSPasteboardItem) -> ShelfItem? {
        if let rtfData = pbItem.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            let plain = pbItem.string(forType: .string) ?? attributed.string
            if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ShelfItem(kind: .text(plain: plain, rtfData: rtfData, title: nil))
            }
        }

        if let plain = pbItem.string(forType: .string) {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let url = singleWebURL(from: trimmed) {
                return ShelfItem(kind: .webURL(url: url, title: nil))
            }
            return ShelfItem(kind: .text(plain: plain, rtfData: nil, title: nil))
        }

        return nil
    }

    private static func extractWebTitlesMap(from pasteboard: NSPasteboard) -> [String: String] {
        guard let plist = pasteboard.propertyList(forType: webURLsWithTitlesType) as? [[String]],
              plist.count >= 2 else {
            return [:]
        }
        let urls = plist[0]
        let titles = plist[1]
        var map: [String: String] = [:]
        for idx in 0..<min(urls.count, titles.count) {
            let title = titles[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                map[urls[idx]] = title
            }
        }
        return map
    }

    private static func isSupportedWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "ftp", "ftps"].contains(scheme)
    }

    private static func singleWebURL(from trimmed: String) -> URL? {
        guard !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func timestampedImageName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Image \(formatter.string(from: Date()))"
    }
}

private final class PromiseURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var urls: [URL] = []

    nonisolated func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    nonisolated func allURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}
