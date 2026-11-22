import AppKit
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum ShelfItemKind: Sendable {
    case file(url: URL, isTemporaryCopy: Bool)
    case folder(url: URL, isTemporaryCopy: Bool = false)
    case image(data: Data, fileExtension: String, suggestedName: String)
    case webURL(url: URL, title: String?)
    case text(plain: String, rtfData: Data?, title: String?)
}

struct ShelfItem: Identifiable, Hashable {
    let id: UUID
    let kind: ShelfItemKind
    let displayName: String
    var subtitle: String
    let badgeLabel: String
    let fileType: UTType
    let dedupeKey: String
    var thumbnail: NSImage?
    let addedAt: Date

    init(
        id: UUID = UUID(),
        kind: ShelfItemKind,
        thumbnail: NSImage? = nil
    ) {
        self.id = id
        self.kind = kind
        self.addedAt = Date()
        self.thumbnail = thumbnail

        switch kind {
        case .file(let url, _):
            let standardized = url.standardizedFileURL
            self.displayName = standardized.lastPathComponent
            let ext = standardized.pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            self.fileType = type
            self.subtitle = ext.isEmpty ? "File" : "\(ext.uppercased()) file"
            self.badgeLabel = ext.isEmpty ? "File" : ext.uppercased()
            self.dedupeKey = "file:\(standardized.path)"

        case .folder(let url, _):
            let standardized = url.standardizedFileURL
            self.displayName = standardized.lastPathComponent
            self.fileType = .folder
            self.subtitle = "Folder"
            self.badgeLabel = "Folder"
            self.dedupeKey = "folder:\(standardized.path)"

        case .image(let data, let fileExtension, let suggestedName):
            let ext = fileExtension.lowercased().isEmpty ? "png" : fileExtension.lowercased()
            let cleanName = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.displayName = cleanName.isEmpty ? "Image.\(ext)" : cleanName
            self.fileType = UTType(filenameExtension: ext) ?? .png
            if let img = thumbnail, img.size.width > 0, img.size.height > 0 {
                self.subtitle = "\(Int(img.size.width)) × \(Int(img.size.height))"
            } else {
                self.subtitle = Self.formatByteSize(Int64(data.count))
            }
            self.badgeLabel = "\(ext.uppercased()) Image"
            self.dedupeKey = "image:\(data.count):\(Self.boundedHashHex(data))"

        case .webURL(let url, let title):
            let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleanTitle, !cleanTitle.isEmpty {
                self.displayName = cleanTitle
            } else {
                self.displayName = url.host ?? url.absoluteString
            }
            self.subtitle = url.host ?? url.scheme?.uppercased() ?? "URL"
            self.badgeLabel = "URL"
            self.fileType = .url
            self.dedupeKey = "url:\(url.absoluteString)"

        case .text(let plain, let rtfData, let title):
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = trimmed.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Text Snippet"
            let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleanTitle, !cleanTitle.isEmpty {
                self.displayName = cleanTitle
            } else {
                self.displayName = String(firstLine.prefix(48))
            }
            let charCount = plain.count
            self.subtitle = charCount == 1 ? "1 char" : "\(charCount) chars"
            self.badgeLabel = rtfData != nil ? "RTF" : "Text"
            self.fileType = rtfData != nil ? .rtf : .plainText
            let utf8 = Data(plain.utf8)
            self.dedupeKey = "text:\(utf8.count):\(Self.boundedHashHex(utf8))"
        }
    }

    static func fromFileURL(_ url: URL, isTemporaryCopy: Bool = false) -> ShelfItem {
        let resolved = ((url as NSURL).filePathURL ?? url).standardizedFileURL
        let resourceValues = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isDir = resourceValues?.isDirectory == true
        let isPackage = resourceValues?.isPackage == true
        if isDir && !isPackage {
            return ShelfItem(kind: .folder(url: resolved, isTemporaryCopy: isTemporaryCopy))
        }
        return ShelfItem(kind: .file(url: resolved, isTemporaryCopy: isTemporaryCopy))
    }

    nonisolated static func loadSubtitleMetadata(for kind: ShelfItemKind) -> String? {
        switch kind {
        case .file(let url, _):
            let standardized = url.standardizedFileURL
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: standardized.path),
                  let size = attrs[.size] as? Int64 else {
                return nil
            }
            return formatByteSize(size)
        case .folder(let url, _):
            let standardized = url.standardizedFileURL
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: standardized.path) else {
                return "Folder"
            }
            let count = entries.filter { !$0.hasPrefix(".") }.count
            return count == 1 ? "1 item" : "\(count) items"
        case .image(let data, _, _):
            guard let dims = ThumbnailGenerator.imagePixelDimensions(from: data) else {
                return nil
            }
            return "\(dims.width) × \(dims.height)"
        case .webURL, .text:
            return nil
        }
    }

    var fileURL: URL? {
        switch kind {
        case .file(let url, _), .folder(let url, _):
            return url
        case .image, .webURL, .text:
            return nil
        }
    }

    var isTemporaryCopy: Bool {
        switch kind {
        case .file(_, let isTemp), .folder(_, let isTemp):
            return isTemp
        case .image, .webURL, .text:
            return false
        }
    }

    var temporaryFileURL: URL? {
        switch kind {
        case .file(let url, true), .folder(let url, true):
            return url
        default:
            return nil
        }
    }

    var webURL: URL? {
        if case .webURL(let url, _) = kind { return url }
        return nil
    }

    var textPreview: String? {
        if case .text(let plain, _, _) = kind { return plain }
        return nil
    }

    var canOpen: Bool {
        switch kind {
        case .file, .folder, .webURL:
            return true
        case .image, .text:
            return false
        }
    }

    var canRevealInFinder: Bool {
        fileURL != nil
    }

    var canSaveAsFile: Bool {
        switch kind {
        case .image, .webURL, .text:
            return true
        case .file, .folder:
            return false
        }
    }

    var suggestedExportFilename: String {
        switch kind {
        case .file(let url, _), .folder(let url, _):
            return url.lastPathComponent
        case .image(_, let ext, let suggestedName):
            let base = Self.sanitizeFilename(suggestedName)
            let cleanExt = ext.isEmpty ? "png" : ext
            if base.lowercased().hasSuffix(".\(cleanExt.lowercased())") {
                return base
            }
            return "\(base).\(cleanExt)"
        case .webURL(let url, let title):
            let raw = (title?.isEmpty == false ? title! : (url.host ?? "Link"))
            return "\(Self.sanitizeFilename(raw)).webloc"
        case .text(let plain, let rtfData, let title):
            let ext = rtfData != nil ? "rtf" : "txt"
            let raw = (title?.isEmpty == false ? title! : String(plain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(36)))
            return "\(Self.sanitizeFilename(raw.isEmpty ? "Snippet" : raw)).\(ext)"
        }
    }

    var fallbackIcon: NSImage {
        switch kind {
        case .file(let url, _), .folder(let url, _):
            return NSWorkspace.shared.icon(forFile: url.path)
        case .image:
            return NSImage(systemSymbolName: "photo.fill", accessibilityDescription: "Image") ?? NSImage()
        case .webURL:
            return NSImage(systemSymbolName: "globe", accessibilityDescription: "URL") ?? NSImage()
        case .text:
            return NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: "Text") ?? NSImage()
        }
    }

    var systemSymbolName: String {
        switch kind {
        case .file: return "doc.fill"
        case .folder: return "folder.fill"
        case .image: return "photo.fill"
        case .webURL: return "link"
        case .text: return "text.alignleft"
        }
    }

    // MARK: - Actions

    @MainActor
    func copyToGeneralPasteboard(pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        switch kind {
        case .file(let url, let isTemp), .folder(let url, let isTemp):
            pasteboard.writeObjects([url as NSURL])
            if isTemp {
                ShelfStore.recordClipboardRetainedTemporaryURLs([url], pasteboard: pasteboard)
            }
        case .image(let data, let ext, _):
            let normalizedExt = ext.lowercased()
            if normalizedExt == "tiff" || normalizedExt == "tif" {
                pasteboard.setData(data, forType: .tiff)
            } else {
                let (pbItem, provider) = Self.makeLazyImagePasteboardItem(
                    data: data,
                    fileExtension: normalizedExt,
                    pasteboard: pasteboard
                )
                pasteboard.writeObjects([pbItem])
                if let provider {
                    LazyImagePasteboardDataProvider.register(provider, on: pasteboard)
                }
            }
        case .webURL(let url, let title):
            pasteboard.writeObjects([url as NSURL])
            pasteboard.setString(url.absoluteString, forType: .string)
            if let title, !title.isEmpty {
                pasteboard.setString(title, forType: NSPasteboard.PasteboardType("public.url-name"))
            }
        case .text(let plain, let rtfData, _):
            if let rtfData {
                pasteboard.setData(rtfData, forType: .rtf)
            }
            pasteboard.setString(plain, forType: .string)
        }
    }

    @MainActor
    func openItem() {
        switch kind {
        case .file(let url, _), .folder(let url, _):
            NSWorkspace.shared.open(url)
        case .webURL(let url, _):
            NSWorkspace.shared.open(url)
        case .image, .text:
            break
        }
    }

    @MainActor
    func revealInFinder() {
        guard let url = fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    func saveAsFile() {
        guard canSaveAsFile else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedExportFilename
        panel.canCreateDirectories = true
        panel.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let destination = panel.url {
            try? writeExportData(to: destination, allowOverwrite: true)
        }
    }

    nonisolated func writeExportData(to destinationURL: URL, allowOverwrite: Bool = false) throws {
        try Self.writeExportData(kind: kind, to: destinationURL, allowOverwrite: allowOverwrite)
    }

    nonisolated static func exportPayloadData(for kind: ShelfItemKind) throws -> Data {
        switch kind {
        case .file, .folder:
            throw CocoaError(.featureUnsupported)
        case .image(let data, _, _):
            return data
        case .webURL(let url, _):
            let plist: [String: Any] = ["URL": url.absoluteString]
            return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        case .text(let plain, let rtfData, _):
            return rtfData ?? Data(plain.utf8)
        }
    }

    nonisolated static func writeExportData(
        kind: ShelfItemKind,
        to destinationURL: URL,
        allowOverwrite: Bool = false
    ) throws {
        let data = try exportPayloadData(for: kind)
        if allowOverwrite {
            try data.write(to: destinationURL, options: .atomic)
        } else {
            try writePromiseData(data, to: destinationURL)
        }
    }

    /// Writes promised file data without ever replacing an existing non-empty file, directory, or symlink.
    /// Allows populating a pre-created 0-byte regular file (e.g., Finder's file-promise placeholder)
    /// verified atomically on the opened file descriptor via `fstat`.
    nonisolated static func writePromiseData(_ data: Data, to destinationURL: URL) throws {
        try destinationURL.withUnsafeFileSystemRepresentation { fsPath in
            guard let fsPath else {
                throw CocoaError(.fileWriteInvalidFileName)
            }

            let createdFD = Darwin.open(fsPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            if createdFD >= 0 {
                defer { Darwin.close(createdFD) }
                try writeAllBytes(data, to: createdFD)
                return
            }

            let createErrno = errno
            guard createErrno == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: createErrno) ?? .EIO)
            }

            let existingFD = Darwin.open(fsPath, O_WRONLY | O_NOFOLLOW)
            if existingFD < 0 {
                let openErrno = errno
                if openErrno == ELOOP || openErrno == EISDIR || openErrno == EEXIST {
                    throw CocoaError(.fileWriteFileExists)
                }
                throw POSIXError(POSIXErrorCode(rawValue: openErrno) ?? .EIO)
            }
            defer { Darwin.close(existingFD) }

            var st = stat()
            guard Darwin.fstat(existingFD, &st) == 0 else {
                let statErrno = errno
                throw POSIXError(POSIXErrorCode(rawValue: statErrno) ?? .EIO)
            }

            let isRegularFile = (st.st_mode & S_IFMT) == S_IFREG
            guard isRegularFile, st.st_size == 0 else {
                throw CocoaError(.fileWriteFileExists)
            }

            try writeAllBytes(data, to: existingFD)
        }
    }

    private nonisolated static func writeAllBytes(_ data: Data, to fd: Int32) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < rawBuffer.count {
                let pointer = baseAddress.advanced(by: totalWritten)
                let written = Darwin.write(fd, pointer, rawBuffer.count - totalWritten)
                if written > 0 {
                    totalWritten += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    let writeErrno = written < 0 ? errno : EIO
                    throw POSIXError(POSIXErrorCode(rawValue: writeErrno) ?? .EIO)
                }
            }
        }
    }

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - Helpers

    @MainActor
    static func makeLazyImagePasteboardItem(
        data: Data,
        fileExtension: String,
        pasteboard: NSPasteboard
    ) -> (item: NSPasteboardItem, provider: LazyImagePasteboardDataProvider?) {
        let pbItem = NSPasteboardItem()
        let ext = fileExtension.lowercased()

        if ext == "tiff" || ext == "tif" {
            pbItem.setData(data, forType: .tiff)
            return (pbItem, nil)
        }

        let nativeType: NSPasteboard.PasteboardType
        var lazyTypes: [NSPasteboard.PasteboardType]
        if ext == "png" {
            nativeType = .png
            lazyTypes = [.tiff]
        } else if let utType = UTType(filenameExtension: ext) {
            nativeType = NSPasteboard.PasteboardType(utType.identifier)
            lazyTypes = [.png, .tiff]
        } else {
            nativeType = .png
            lazyTypes = [.tiff]
        }

        pbItem.setData(data, forType: nativeType)
        let provider = LazyImagePasteboardDataProvider(
            data: data,
            sourceExtension: ext,
            pasteboard: pasteboard
        )
        pbItem.setDataProvider(provider, forTypes: lazyTypes)
        return (pbItem, provider)
    }

    private nonisolated static func formatByteSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    /// Bounded O(1) content fingerprint: hashes exact byte count plus up to 64 KB head + 64 KB tail
    /// so multi-megabyte screenshots and snippets never stall the main thread during drop/init.
    private nonisolated static func boundedHashHex(_ data: Data) -> String {
        let sliceSize = 65_536
        var hasher = SHA256()
        var countLE = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &countLE) { hasher.update(bufferPointer: $0) }
        if data.count <= sliceSize * 2 {
            hasher.update(data: data)
        } else {
            hasher.update(data: data.prefix(sliceSize))
            hasher.update(data: data.suffix(sliceSize))
        }
        let digest = hasher.finalize()
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func sanitizeFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let limited = String(collapsed.prefix(64))
        return limited.isEmpty ? "Item" : limited
    }
}

/// Lazily materializes `.tiff` (and `.png` for non-PNG sources) on `NSPasteboard` only if
/// a receiving app explicitly requests those types, avoiding eager full-size TIFF duplication
/// on Copy while keeping multi-item providers alive for the duration of the pasteboard generation.
final class LazyImagePasteboardDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private struct RegistryBucket {
        var changeCount: Int
        var providers: [LazyImagePasteboardDataProvider]
    }

    @MainActor private static var activeBuckets: [ObjectIdentifier: RegistryBucket] = [:]

    let data: Data
    let sourceExtension: String
    let pasteboardKey: ObjectIdentifier

    nonisolated init(data: Data, sourceExtension: String, pasteboard: NSPasteboard) {
        self.data = data
        self.sourceExtension = sourceExtension.lowercased()
        self.pasteboardKey = ObjectIdentifier(pasteboard)
        super.init()
    }

    @MainActor
    static func register(_ provider: LazyImagePasteboardDataProvider, on pasteboard: NSPasteboard) {
        let key = ObjectIdentifier(pasteboard)
        let currentCount = pasteboard.changeCount
        if var bucket = activeBuckets[key], bucket.changeCount == currentCount {
            bucket.providers.append(provider)
            activeBuckets[key] = bucket
        } else {
            activeBuckets[key] = RegistryBucket(changeCount: currentCount, providers: [provider])
        }
    }

    @MainActor
    static func activeProviderCount(for pasteboard: NSPasteboard) -> Int {
        guard let bucket = activeBuckets[ObjectIdentifier(pasteboard)],
              bucket.changeCount == pasteboard.changeCount else {
            return 0
        }
        return bucket.providers.count
    }

    @MainActor
    private static func unregister(providerID: ObjectIdentifier, forKey key: ObjectIdentifier) {
        guard var bucket = activeBuckets[key] else { return }
        bucket.providers.removeAll { ObjectIdentifier($0) == providerID }
        if bucket.providers.isEmpty {
            activeBuckets.removeValue(forKey: key)
        } else {
            activeBuckets[key] = bucket
        }
    }

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        if type == .tiff {
            if sourceExtension == "tiff" || sourceExtension == "tif" {
                item.setData(data, forType: .tiff)
                return
            }
            if let tiffData = ThumbnailGenerator.transcodeImageData(data, to: .tiff)
                ?? NSImage(data: data)?.tiffRepresentation {
                item.setData(tiffData, forType: .tiff)
            }
            return
        }

        if type == .png {
            if sourceExtension == "png" {
                item.setData(data, forType: .png)
                return
            }
            if let pngData = ThumbnailGenerator.transcodeImageData(data, to: .png) {
                item.setData(pngData, forType: .png)
            }
        }
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        let key = pasteboardKey
        let providerID = ObjectIdentifier(self)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                Self.unregister(providerID: providerID, forKey: key)
            }
        } else {
            DispatchQueue.main.async {
                Self.unregister(providerID: providerID, forKey: key)
            }
        }
    }
}

extension Array where Element == ShelfItem {
    var dropshelfSummaryLabel: String {
        guard !isEmpty else { return "Empty" }
        if count == 1, let first = first {
            return first.displayName
        }

        var allFiles = true
        var allFolders = true
        var allImages = true
        var allURLs = true
        var allTexts = true

        for item in self {
            switch item.kind {
            case .file:
                allFolders = false; allImages = false; allURLs = false; allTexts = false
            case .folder:
                allFiles = false; allImages = false; allURLs = false; allTexts = false
            case .image:
                allFiles = false; allFolders = false; allURLs = false; allTexts = false
            case .webURL:
                allFiles = false; allFolders = false; allImages = false; allTexts = false
            case .text:
                allFiles = false; allFolders = false; allImages = false; allURLs = false
            }
        }

        if allFiles { return "\(count) Files" }
        if allFolders { return "\(count) Folders" }
        if allImages { return "\(count) Images" }
        if allURLs { return "\(count) Links" }
        if allTexts { return "\(count) Snippets" }
        return "\(count) Items"
    }
}
