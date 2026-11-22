import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum ShelfItemKind: Sendable {
    case file(url: URL, isTemporaryCopy: Bool)
    case folder(url: URL)
    case image(data: Data, fileExtension: String, suggestedName: String)
    case webURL(url: URL, title: String?)
    case text(plain: String, rtfData: Data?, title: String?)
}

struct ShelfItem: Identifiable, Hashable {
    let id: UUID
    let kind: ShelfItemKind
    let displayName: String
    let subtitle: String
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
            let size = (try? FileManager.default.attributesOfItem(atPath: standardized.path)[.size] as? Int64) ?? 0
            self.subtitle = Self.formatByteSize(size)
            self.badgeLabel = ext.isEmpty ? "File" : ext.uppercased()
            self.dedupeKey = "file:\(standardized.path)"

        case .folder(let url):
            let standardized = url.standardizedFileURL
            self.displayName = standardized.lastPathComponent
            self.fileType = .folder
            let count = (try? FileManager.default.contentsOfDirectory(atPath: standardized.path).filter { !$0.hasPrefix(".") }.count)
            if let count {
                self.subtitle = count == 1 ? "1 item" : "\(count) items"
            } else {
                self.subtitle = "Folder"
            }
            self.badgeLabel = "Folder"
            self.dedupeKey = "folder:\(standardized.path)"

        case .image(let data, let fileExtension, let suggestedName):
            let ext = fileExtension.lowercased().isEmpty ? "png" : fileExtension.lowercased()
            let cleanName = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.displayName = cleanName.isEmpty ? "Image.\(ext)" : cleanName
            self.fileType = UTType(filenameExtension: ext) ?? .png
            if let img = thumbnail ?? NSImage(data: data), img.size.width > 0, img.size.height > 0 {
                self.subtitle = "\(Int(img.size.width)) × \(Int(img.size.height))"
            } else {
                self.subtitle = Self.formatByteSize(Int64(data.count))
            }
            self.badgeLabel = "\(ext.uppercased()) Image"
            self.dedupeKey = "image:\(Self.sha256Hex(data))"

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
            self.dedupeKey = "text:\(Self.sha256Hex(Data(plain.utf8)))"
        }
    }

    static func fromFileURL(_ url: URL, isTemporaryCopy: Bool = false) -> ShelfItem {
        let resolved = ((url as NSURL).filePathURL ?? url).standardizedFileURL
        let resourceValues = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isDir = resourceValues?.isDirectory == true
        let isPackage = resourceValues?.isPackage == true
        if isDir && !isPackage {
            return ShelfItem(kind: .folder(url: resolved))
        }
        return ShelfItem(kind: .file(url: resolved, isTemporaryCopy: isTemporaryCopy))
    }

    var fileURL: URL? {
        switch kind {
        case .file(let url, _), .folder(let url):
            return url
        case .image, .webURL, .text:
            return nil
        }
    }

    var temporaryFileURL: URL? {
        if case .file(let url, true) = kind {
            return url
        }
        return nil
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
        case .file(let url, _), .folder(let url):
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
        case .file(let url, _), .folder(let url):
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
    func copyToGeneralPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch kind {
        case .file(let url, _), .folder(let url):
            pb.writeObjects([url as NSURL])
        case .image(let data, let ext, _):
            let type: NSPasteboard.PasteboardType = (ext.lowercased() == "tiff" || ext.lowercased() == "tif") ? .tiff : .png
            pb.setData(data, forType: type)
            if type != .tiff, let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }
        case .webURL(let url, let title):
            pb.writeObjects([url as NSURL])
            pb.setString(url.absoluteString, forType: .string)
            if let title, !title.isEmpty {
                pb.setString(title, forType: NSPasteboard.PasteboardType("public.url-name"))
            }
        case .text(let plain, let rtfData, _):
            if let rtfData {
                pb.setData(rtfData, forType: .rtf)
            }
            pb.setString(plain, forType: .string)
        }
    }

    @MainActor
    func openItem() {
        switch kind {
        case .file(let url, _), .folder(let url):
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
            try? writeExportData(to: destination)
        }
    }

    nonisolated func writeExportData(to destinationURL: URL) throws {
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

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - Helpers

    private static func formatByteSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
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
