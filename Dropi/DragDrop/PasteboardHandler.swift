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
        // Fallback check for translated file URLs (e.g. Dock folder stack drags),
        // excluding `.URL`-only drags so web links pointing to `file://` are never treated as files.
        if !available.contains(.URL),
           pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
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

    /// If `url` points inside Droptop's staging root (e.g. a staged file dragged or pasted from
    /// another shelf), copies it into a fresh `0700` batch directory inside `stagingDirectory` so
    /// the receiving shelf owns an independent temporary copy.
    static func adoptStagedFileIfNeeded(
        _ url: URL,
        into stagingDirectory: URL,
        stagingRoot: URL = ShelfStore.rootStagingDirectory
    ) -> (url: URL, isTemporaryCopy: Bool, adoptedSourcePath: String?) {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRoot = stagingRoot.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalTarget = stagingDirectory.standardizedFileURL.resolvingSymlinksInPath()

        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard canonicalURL.path.hasPrefix(rootPrefix) else {
            return (canonicalURL, false, nil)
        }

        let targetPrefix = canonicalTarget.path.hasSuffix("/") ? canonicalTarget.path : canonicalTarget.path + "/"
        if canonicalURL.path.hasPrefix(targetPrefix) {
            // Already owned by this exact shelf's staging directory (e.g. same-shelf paste).
            return (canonicalURL, true, nil)
        }

        try? ShelfStore.ensureStagingRootDirectory(at: canonicalRoot)
        try? ShelfStore.ensurePrivateDirectory(at: canonicalTarget)
        let batchDir = canonicalTarget.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try ShelfStore.ensurePrivateDirectory(at: batchDir)
            let destination = batchDir.appendingPathComponent(canonicalURL.lastPathComponent)
            try FileManager.default.copyItem(at: canonicalURL, to: destination)
            return (destination.standardizedFileURL, true, canonicalURL.path)
        } catch {
            try? FileManager.default.removeItem(at: batchDir)
            return (canonicalURL, false, nil)
        }
    }

    private enum RawInMemoryPayload: Sendable {
        case directImage(data: Data, fileExtension: String, suggestedName: String)
        case tiffNeedsPNGConversion(tiffData: Data, suggestedName: String)
        case webURL(url: URL, title: String?)
        case text(plain: String, rtfData: Data?, title: String?)

        var needsOffMainProcessing: Bool {
            if case .tiffNeedsPNGConversion = self { return true }
            return false
        }
    }

    private static let imageNameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    /// Extracts supported items from a pasteboard (drag pasteboard, Dock stack drag, or general clipboard).
    /// Always reads all raw pasteboard URLs/data synchronously on the main thread before returning.
    /// Returns true if at least one synchronous or asynchronous extraction was started.
    @discardableResult
    static func extractItems(
        from pasteboard: NSPasteboard,
        stagingDirectory: URL,
        stagingRoot: URL = ShelfStore.rootStagingDirectory,
        completion: @escaping @MainActor ([ShelfItem]) -> Void
    ) -> Bool {
        // 1. Direct file & folder URLs (Finder, Dock folder stacks, desktop, open panels, etc.)
        //    Staged file adoption stays synchronous for airtight SEC-01 shelf-to-shelf ownership
        //    handoff (O(1) APFS clonefile inside ~/Library/Caches/Droptop/Promises).
        if let fileURLs = readDirectFileURLs(from: pasteboard), !fileURLs.isEmpty {
            let items = fileURLs.map { url -> ShelfItem in
                let adopted = adoptStagedFileIfNeeded(url, into: stagingDirectory, stagingRoot: stagingRoot)
                if SelfDragState.isDraggingFromShelf, let adoptedPath = adopted.adoptedSourcePath {
                    SelfDragState.recordAdoptedStagedSourcePath(adoptedPath)
                }
                return ShelfItem.fromFileURL(adopted.url, isTemporaryCopy: adopted.isTemporaryCopy)
            }
            completion(items)
            return true
        }

        // 2. Promised files (Photos, Mail attachments, Safari dragged files/images, etc.)
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            // Snapshot only lightweight raw bytes synchronously; never decode/encode fallback
            // images unless the file promises actually fail.
            let fallbackPayloads = snapshotInMemoryPayloads(from: pasteboard)
            receiveFilePromises(
                receivers,
                stagingDirectory: stagingDirectory,
                stagingRoot: stagingRoot,
                fallbackPayloads: fallbackPayloads,
                completion: completion
            )
            return true
        }

        // 3. In-memory images, web URLs, and text snippets
        let payloads = snapshotInMemoryPayloads(from: pasteboard)
        if !payloads.isEmpty {
            deliverInMemoryPayloads(payloads, completion: completion)
            return true
        }

        return false
    }

    // MARK: - File URL & Promise Readers

    static func readDirectFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let availableTypes = Set(pasteboard.types ?? [])
        let hasDirectFileType = availableTypes.contains(.fileURL)
            || availableTypes.contains(filenamesType)
            || availableTypes.contains(coreDragFurlType)
            || availableTypes.contains(coreDragHfsType)
        guard hasDirectFileType else {
            return nil
        }

        var resolvedURLs: [URL] = []
        var seenPaths = Set<String>()

        func appendResolved(_ url: URL) {
            guard let resolved = resolveFileURL(url) else { return }
            if seenPaths.insert(resolved.path).inserted {
                resolvedURLs.append(resolved)
            }
        }

        // 1a. Per-item public.file-url ONLY (never .URL / public.url).
        // Handles Finder, modern drags, Dock file-reference URLs (`file:///.file/id=...`),
        // and prevents mixed pasteboards from smuggling a `.URL`-only `file://` link as a file.
        if let pbItems = pasteboard.pasteboardItems {
            for pbItem in pbItems {
                if let str = pbItem.string(forType: .fileURL)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty,
                   let url = URL(string: str),
                   url.isFileURL {
                    appendResolved(url)
                } else if let data = pbItem.data(forType: .fileURL),
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.isFileURL {
                    appendResolved(url)
                } else if let plist = pbItem.propertyList(forType: .fileURL),
                          let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
                          url.isFileURL {
                    appendResolved(url)
                }
            }
        }

        // 1b. Legacy NSFilenamesPboardType (used by Dock folder stacks & some Carbon/AppKit apps)
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            for path in paths where !path.isEmpty {
                appendResolved(URL(fileURLWithPath: path))
            }
        }

        // 1c. Guarded fallback for translated CoreDrag/Carbon file flavors ONLY when `.URL` is absent
        if resolvedURLs.isEmpty && !availableTypes.contains(.URL) {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
                for url in urls {
                    appendResolved(url)
                }
            }
        }

        return resolvedURLs.isEmpty ? nil : resolvedURLs
    }

    private static func receiveFilePromises(
        _ receivers: [NSFilePromiseReceiver],
        stagingDirectory: URL,
        stagingRoot: URL,
        fallbackPayloads: [RawInMemoryPayload],
        completion: @escaping @MainActor ([ShelfItem]) -> Void
    ) {
        try? ShelfStore.ensureStagingRootDirectory(at: stagingRoot)
        try? ShelfStore.ensurePrivateDirectory(at: stagingDirectory)
        let batchDir = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? ShelfStore.ensurePrivateDirectory(at: batchDir)

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
            } else {
                try? FileManager.default.removeItem(at: batchDir)
                if !fallbackPayloads.isEmpty {
                    deliverInMemoryPayloads(fallbackPayloads, completion: completion)
                } else {
                    completion([])
                }
            }
        }
    }

    private static func deliverInMemoryPayloads(
        _ payloads: [RawInMemoryPayload],
        completion: @escaping @MainActor ([ShelfItem]) -> Void
    ) {
        if !payloads.contains(where: \.needsOffMainProcessing) {
            let kinds = resolveInMemoryKinds(payloads)
            completion(kinds.map { ShelfItem(kind: $0, thumbnail: nil) })
            return
        }

        Task.detached(priority: .userInitiated) {
            let kinds = resolveInMemoryKinds(payloads)
            await MainActor.run {
                completion(kinds.map { ShelfItem(kind: $0, thumbnail: nil) })
            }
        }
    }

    private nonisolated static func resolveInMemoryKinds(_ payloads: [RawInMemoryPayload]) -> [ShelfItemKind] {
        payloads.map { payload in
            switch payload {
            case .directImage(let data, let fileExtension, let suggestedName):
                return .image(data: data, fileExtension: fileExtension, suggestedName: suggestedName)
            case .tiffNeedsPNGConversion(let tiffData, let suggestedName):
                if let convertedPNG = ThumbnailGenerator.transcodeImageData(tiffData, to: .png) {
                    return .image(data: convertedPNG, fileExtension: "png", suggestedName: suggestedName)
                }
                return .image(data: tiffData, fileExtension: "tiff", suggestedName: suggestedName)
            case .webURL(let url, let title):
                return .webURL(url: url, title: title)
            case .text(let plain, let rtfData, let title):
                return .text(plain: plain, rtfData: rtfData, title: title)
            }
        }
    }

    private static func snapshotInMemoryPayloads(from pasteboard: NSPasteboard) -> [RawInMemoryPayload] {
        var results: [RawInMemoryPayload] = []

        let webTitlesMap = extractWebTitlesMap(from: pasteboard)

        if let pbItems = pasteboard.pasteboardItems, !pbItems.isEmpty {
            for pbItem in pbItems {
                if let imagePayload = snapshotImagePayload(from: pbItem) {
                    results.append(imagePayload)
                    continue
                }
                if let urlPayload = snapshotWebURLPayload(from: pbItem, titlesMap: webTitlesMap) {
                    results.append(urlPayload)
                    continue
                }
                if let textPayload = snapshotTextPayload(from: pbItem) {
                    results.append(textPayload)
                    continue
                }
            }
        }

        if !results.isEmpty {
            return results
        }

        if let fallbackImage = snapshotPasteboardLevelImage(from: pasteboard) {
            results.append(fallbackImage)
            return results
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls where !url.isFileURL && isSupportedWebURL(url) {
                let title = webTitlesMap[url.absoluteString] ?? pasteboard.string(forType: urlNameType)
                results.append(.webURL(url: url, title: title))
            }
            if !results.isEmpty {
                return results
            }
        }

        if let rtfData = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            let plain = attributed.string
            if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(.text(plain: plain, rtfData: rtfData, title: nil))
                return results
            }
        }

        if let plain = pasteboard.string(forType: .string) {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let url = singleWebURL(from: trimmed) {
                    results.append(.webURL(url: url, title: webTitlesMap[url.absoluteString]))
                } else {
                    results.append(.text(plain: plain, rtfData: nil, title: nil))
                }
            }
        }

        return results
    }

    private static let imagePasteboardCandidates: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "png"),
        (jpegType, "jpg"),
        (heicType, "heic"),
        (gifType, "gif"),
        (webpType, "webp"),
        (.tiff, "tiff")
    ]

    private static func snapshotImagePayload(from pbItem: NSPasteboardItem) -> RawInMemoryPayload? {
        for (type, ext) in imagePasteboardCandidates {
            guard let rawData = pbItem.data(forType: type), !rawData.isEmpty,
                  ThumbnailGenerator.imagePixelDimensions(from: rawData) != nil else {
                continue
            }

            let name = pbItem.string(forType: urlNameType) ?? timestampedImageName()
            if ext == "tiff" {
                return .tiffNeedsPNGConversion(tiffData: rawData, suggestedName: name)
            }
            return .directImage(data: rawData, fileExtension: ext, suggestedName: name)
        }
        return nil
    }

    private static func snapshotPasteboardLevelImage(from pasteboard: NSPasteboard) -> RawInMemoryPayload? {
        for (type, ext) in imagePasteboardCandidates {
            guard let rawData = pasteboard.data(forType: type), !rawData.isEmpty,
                  ThumbnailGenerator.imagePixelDimensions(from: rawData) != nil else {
                continue
            }
            let name = pasteboard.string(forType: urlNameType) ?? timestampedImageName()
            if ext == "tiff" {
                return .tiffNeedsPNGConversion(tiffData: rawData, suggestedName: name)
            }
            return .directImage(data: rawData, fileExtension: ext, suggestedName: name)
        }

        // Legacy fallback for custom non-standard NSImage pasteboard types (e.g. PDF/PICT)
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
           let image = NSImage(pasteboard: pasteboard),
           let tiffData = image.tiffRepresentation, !tiffData.isEmpty {
            return .tiffNeedsPNGConversion(tiffData: tiffData, suggestedName: timestampedImageName())
        }
        return nil
    }

    private static func snapshotWebURLPayload(
        from pbItem: NSPasteboardItem,
        titlesMap: [String: String]
    ) -> RawInMemoryPayload? {
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
        return .webURL(url: url, title: title)
    }

    private static func snapshotTextPayload(from pbItem: NSPasteboardItem) -> RawInMemoryPayload? {
        if let rtfData = pbItem.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            let plain = pbItem.string(forType: .string) ?? attributed.string
            if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .text(plain: plain, rtfData: rtfData, title: nil)
            }
        }

        if let plain = pbItem.string(forType: .string) {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let url = singleWebURL(from: trimmed) {
                return .webURL(url: url, title: nil)
            }
            return .text(plain: plain, rtfData: nil, title: nil)
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

    private static func timestampedImageName() -> String {
        "Image \(imageNameDateFormatter.string(from: Date()))"
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
