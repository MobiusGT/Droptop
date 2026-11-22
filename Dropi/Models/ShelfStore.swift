import AppKit
import Combine
import Foundation

@MainActor
final class ShelfStore: ObservableObject, Identifiable {
    private struct RetainedEntry {
        let retainedAt: Date
        let shelfStagingDirectory: URL
    }

    private struct PendingMetadataUpdate {
        var thumbnail: NSImage?
        var subtitle: String?
    }

    let id: UUID
    let shelfNumber: Int
    let colorVariation: ShelfColorVariation
    let stagingRoot: URL
    let stagingDirectory: URL

    @Published var items: [ShelfItem] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var assignedRandomTheme: ShelfTheme?

    private var anchorSelectionID: UUID?
    private var metadataTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var pendingMetadataUpdates: [UUID: PendingMetadataUpdate] = [:]
    private var metadataFlushTask: Task<Void, Never>?

    nonisolated static let defaultRetentionTTL: TimeInterval = 60 * 60 // 60 minutes

    private static var retainedGlobal: [URL: RetainedEntry] = [:]
    private static var activeStagingDirectories: Set<URL> = []
    private static var clipboardRetention: (pasteboard: NSPasteboard, changeCount: Int, urls: Set<URL>)?
    private nonisolated static let cleanupQueue = DispatchQueue(
        label: "com.local.Droptop.StagingCleanup",
        qos: .utility
    )

    private nonisolated static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    nonisolated static var rootStagingDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("Droptop", isDirectory: true)
            .appendingPathComponent("Promises", isDirectory: true)
    }

    nonisolated static func ensurePrivateDirectory(at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    nonisolated static func ensureStagingRootDirectory(at root: URL = rootStagingDirectory) throws {
        let parent = root.deletingLastPathComponent()
        if parent.lastPathComponent == "Droptop" {
            try ensurePrivateDirectory(at: parent)
        }
        try ensurePrivateDirectory(at: root)
    }

    static func recordClipboardRetainedTemporaryURLs(_ urls: [URL], pasteboard: NSPasteboard = .general) {
        let normalized = Set(urls.map { canonicalURL($0) })
        guard !normalized.isEmpty else { return }
        clipboardRetention = (pasteboard, pasteboard.changeCount, normalized)
    }

    static func activeClipboardRetainedURLs() -> Set<URL> {
        guard let entry = clipboardRetention else { return [] }
        guard entry.pasteboard.changeCount == entry.changeCount else {
            clipboardRetention = nil
            return []
        }
        return entry.urls
    }

    static func isClipboardRetained(_ url: URL) -> Bool {
        activeClipboardRetainedURLs().contains(canonicalURL(url))
    }

    static func clearClipboardRetention() {
        clipboardRetention = nil
    }

    static func retainTemporaryURL(
        _ url: URL,
        shelfStagingDirectory: URL,
        at date: Date = Date()
    ) {
        let canonicalFile = canonicalURL(url)
        let canonicalShelfDir = canonicalURL(shelfStagingDirectory)
        retainedGlobal[canonicalFile] = RetainedEntry(
            retainedAt: date,
            shelfStagingDirectory: canonicalShelfDir
        )
    }

    static func isRetainedTemporaryURL(_ url: URL) -> Bool {
        retainedGlobal[canonicalURL(url)] != nil
    }

    static func clearRetainedTemporaryFiles() {
        retainedGlobal.removeAll()
    }

    private static func purgeRetainedEntries(under root: URL) {
        let canonicalRoot = canonicalURL(root)
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        retainedGlobal = retainedGlobal.filter { url, _ in
            !url.path.hasPrefix(rootPrefix)
        }
        activeStagingDirectories = activeStagingDirectories.filter { dir in
            !dir.path.hasPrefix(rootPrefix)
        }
    }

    /// Prunes expired dragged-out staged files older than `age` (default 60 minutes),
    /// respecting active clipboard retention and preserving sibling files inside multi-file batches.
    static func pruneRetained(
        olderThan age: TimeInterval = defaultRetentionTTL,
        now: Date = Date(),
        synchronous: Bool = false
    ) {
        guard !retainedGlobal.isEmpty else { return }
        let clipboardURLs = activeClipboardRetainedURLs()

        struct RemovalTarget: Sendable {
            let fileURL: URL
            let shelfDir: URL
            let canRemoveEmptyShelfDir: Bool
        }

        var targets: [RemovalTarget] = []
        for (url, entry) in retainedGlobal {
            guard now.timeIntervalSince(entry.retainedAt) >= age,
                  !clipboardURLs.contains(url) else {
                continue
            }
            targets.append(RemovalTarget(
                fileURL: url,
                shelfDir: entry.shelfStagingDirectory,
                canRemoveEmptyShelfDir: !activeStagingDirectories.contains(entry.shelfStagingDirectory)
            ))
        }

        guard !targets.isEmpty else { return }
        for target in targets {
            retainedGlobal.removeValue(forKey: target.fileURL)
        }

        let removalTargets = targets
        let work: @Sendable () -> Void = {
            let fm = FileManager.default
            for target in removalTargets {
                try? fm.removeItem(at: target.fileURL)

                let shelfPath = target.shelfDir.path
                let shelfPrefix = shelfPath.hasSuffix("/") ? shelfPath : shelfPath + "/"
                let batchDir = canonicalURL(target.fileURL.deletingLastPathComponent())
                if batchDir.path.hasPrefix(shelfPrefix),
                   batchDir.path != shelfPath,
                   let remaining = try? fm.contentsOfDirectory(atPath: batchDir.path),
                   remaining.isEmpty {
                    try? fm.removeItem(at: batchDir)
                }

                if target.canRemoveEmptyShelfDir,
                   let remainingShelfEntries = try? fm.contentsOfDirectory(atPath: shelfPath),
                   remainingShelfEntries.isEmpty {
                    try? fm.removeItem(at: target.shelfDir)
                }
            }
        }

        if synchronous {
            work()
        } else {
            cleanupQueue.async(execute: work)
        }
    }

    /// Deletes temporary staged copies from an async drop/clipboard extraction whose shelf
    /// was already closed before the extraction completed.
    static func purgeOrphanedTemporaryFiles(in items: [ShelfItem], synchronous: Bool = false) {
        let clipboardURLs = activeClipboardRetainedURLs()
        let urls = items.compactMap(\.temporaryFileURL)
            .map { canonicalURL($0) }
            .filter { retainedGlobal[$0] == nil && !clipboardURLs.contains($0) }
        guard !urls.isEmpty else { return }

        let rootCanonical = canonicalURL(rootStagingDirectory)
        let work: @Sendable () -> Void = {
            let fm = FileManager.default
            for url in urls {
                try? fm.removeItem(at: url)
                let parent = canonicalURL(url.deletingLastPathComponent())
                if parent.path != rootCanonical.path,
                   let remaining = try? fm.contentsOfDirectory(atPath: parent.path),
                   remaining.isEmpty {
                    try? fm.removeItem(at: parent)
                }
            }
        }

        if synchronous {
            work()
        } else {
            cleanupQueue.async(execute: work)
        }
    }

    init(
        id: UUID = UUID(),
        shelfNumber: Int,
        colorVariation: ShelfColorVariation = .identity,
        assignedRandomTheme: ShelfTheme? = nil,
        stagingRoot: URL = ShelfStore.rootStagingDirectory
    ) {
        self.id = id
        self.shelfNumber = shelfNumber
        self.colorVariation = (shelfNumber == 1) ? .identity : colorVariation
        self.assignedRandomTheme = assignedRandomTheme
        self.stagingRoot = stagingRoot
        let dir = stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        self.stagingDirectory = dir
        try? Self.ensureStagingRootDirectory(at: stagingRoot)
        try? Self.ensurePrivateDirectory(at: dir)
        Self.activeStagingDirectories.insert(Self.canonicalURL(dir))
    }

    func effectiveTheme(for selectedTheme: ShelfTheme) -> ShelfTheme {
        if selectedTheme.isRandomTheme {
            return assignedRandomTheme ?? .systemGlass
        }
        return selectedTheme
    }

    var activeMetadataTaskCount: Int {
        metadataTasks.count
    }

    var hasPendingMetadataFlush: Bool {
        metadataFlushTask != nil || !pendingMetadataUpdates.isEmpty
    }

    var title: String {
        "Shelf \(shelfNumber)"
    }

    var selectedItems: [ShelfItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    var isAllSelected: Bool {
        !items.isEmpty && selectedIDs.count == items.count
    }

    var hasPartialSelection: Bool {
        !selectedIDs.isEmpty && selectedIDs.count < items.count
    }

    // MARK: - Item Management

    @discardableResult
    func add(_ item: ShelfItem) -> Bool {
        guard !items.contains(where: { $0.dedupeKey == item.dedupeKey }) else {
            return false
        }
        items.append(item)
        scheduleThumbnailAndMetadata(for: item)
        return true
    }

    func addMany(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var seenKeys = Set(items.map(\.dedupeKey))
        var toAppend: [ShelfItem] = []
        toAppend.reserveCapacity(newItems.count)
        for item in newItems where seenKeys.insert(item.dedupeKey).inserted {
            toAppend.append(item)
        }
        guard !toAppend.isEmpty else { return }
        items.append(contentsOf: toAppend)
        for item in toAppend {
            scheduleThumbnailAndMetadata(for: item)
        }
    }

    func remove(_ item: ShelfItem) {
        removeByIDs([item.id], cleanupTemporaryFiles: true)
    }

    func removeSelected() {
        removeByIDs(selectedIDs, cleanupTemporaryFiles: true)
    }

    /// Removes items after a completed drag-out.
    /// - Temporary copies confirmed adopted by another Droptop shelf are cleaned up immediately
    ///   (respecting active clipboard retention).
    /// - Any temporary copy dragged to an external app is registered in `retainedGlobal` with a
    ///   conservative 60-minute TTL so the target app can read it after shelf auto-close.
    func removeDraggedOut(_ ids: Set<UUID>, adoptedSourcePaths: Set<String> = []) {
        guard !ids.isEmpty else { return }
        cancelMetadataTasks(for: ids)
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        if let anchor = anchorSelectionID, ids.contains(anchor) {
            anchorSelectionID = nil
        }

        for item in removed {
            guard let tempURL = item.temporaryFileURL else { continue }
            let canonical = Self.canonicalURL(tempURL)
            if adoptedSourcePaths.contains(canonical.path) {
                cleanupTemporaryFile(for: item)
            } else {
                Self.retainTemporaryURL(canonical, shelfStagingDirectory: stagingDirectory)
            }
        }
    }

    func removeByIDs(_ ids: Set<UUID>, cleanupTemporaryFiles: Bool = true) {
        if !cleanupTemporaryFiles {
            removeDraggedOut(ids)
            return
        }
        guard !ids.isEmpty else { return }
        cancelMetadataTasks(for: ids)
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        if let anchor = anchorSelectionID, ids.contains(anchor) {
            anchorSelectionID = nil
        }
        for item in removed {
            cleanupTemporaryFile(for: item)
        }
    }

    func updateThumbnail(id: UUID, image: NSImage) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].thumbnail = image
    }

    func updateSubtitle(id: UUID, subtitle: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].subtitle = subtitle
    }

    func enqueueMetadataUpdate(id: UUID, thumbnail: NSImage? = nil, subtitle: String? = nil) {
        guard items.contains(where: { $0.id == id }) else { return }
        var pending = pendingMetadataUpdates[id] ?? PendingMetadataUpdate()
        if let thumbnail { pending.thumbnail = thumbnail }
        if let subtitle { pending.subtitle = subtitle }
        pendingMetadataUpdates[id] = pending

        if metadataFlushTask == nil {
            metadataFlushTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                self?.flushPendingMetadataUpdates()
            }
        }
    }

    func flushPendingMetadataUpdates() {
        metadataFlushTask?.cancel()
        metadataFlushTask = nil

        guard !pendingMetadataUpdates.isEmpty else { return }
        let updates = pendingMetadataUpdates
        pendingMetadataUpdates.removeAll()

        var updated = items
        var didMutate = false
        for index in updated.indices {
            let itemID = updated[index].id
            guard let pending = updates[itemID] else { continue }
            if let thumbnail = pending.thumbnail {
                updated[index].thumbnail = thumbnail
                didMutate = true
            }
            if let subtitle = pending.subtitle, updated[index].subtitle != subtitle {
                updated[index].subtitle = subtitle
                didMutate = true
            }
        }
        if didMutate {
            items = updated
        }
    }

    func clearAll() {
        cancelAllMetadataTasks()
        let removed = items
        items.removeAll()
        selectedIDs.removeAll()
        anchorSelectionID = nil
        for item in removed {
            cleanupTemporaryFile(for: item)
        }
    }

    func cleanupStagingDirectory(synchronous: Bool = false) {
        cancelAllMetadataTasks()
        let dir = stagingDirectory
        let canonicalDir = Self.canonicalURL(dir)
        Self.activeStagingDirectories.remove(canonicalDir)
        let dirPrefix = canonicalDir.path.hasSuffix("/") ? canonicalDir.path : canonicalDir.path + "/"

        let allRetained = Set(Self.retainedGlobal.keys).union(Self.activeClipboardRetainedURLs())
        var preservedTopLevelNames = Set<String>()
        for retainedURL in allRetained {
            let canonical = Self.canonicalURL(retainedURL)
            if canonical.path.hasPrefix(dirPrefix) {
                let relative = String(canonical.path.dropFirst(dirPrefix.count))
                if let firstComponent = relative.split(separator: "/").first {
                    preservedTopLevelNames.insert(String(firstComponent))
                }
            }
        }

        let preserved = preservedTopLevelNames
        let work: @Sendable () -> Void = {
            let fm = FileManager.default
            if preserved.isEmpty {
                try? fm.removeItem(at: dir)
            } else if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for entry in entries where !preserved.contains(entry.lastPathComponent) {
                    try? fm.removeItem(at: entry)
                }
            }
        }

        if synchronous {
            work()
        } else {
            Self.cleanupQueue.async(execute: work)
        }
    }

    nonisolated static func cleanupAllStagingDirectories(at root: URL = rootStagingDirectory) {
        let canonicalRoot = canonicalURL(root)
        try? FileManager.default.removeItem(at: root)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                Self.purgeRetainedEntries(under: canonicalRoot)
            }
        } else {
            Task { @MainActor in
                Self.purgeRetainedEntries(under: canonicalRoot)
            }
        }
    }

    // MARK: - Selection Logic (One, Multiple, Range, or All)

    func handleRowTap(itemID: UUID, commandPressed: Bool, shiftPressed: Bool) {
        if shiftPressed, let anchorID = anchorSelectionID,
           let anchorIndex = items.firstIndex(where: { $0.id == anchorID }),
           let targetIndex = items.firstIndex(where: { $0.id == itemID }) {
            let lower = min(anchorIndex, targetIndex)
            let upper = max(anchorIndex, targetIndex)
            let rangeIDs = Set(items[lower...upper].map(\.id))
            if commandPressed {
                selectedIDs.formUnion(rangeIDs)
            } else {
                selectedIDs = rangeIDs
            }
            return
        }

        if commandPressed {
            toggleSelection(itemID: itemID)
            return
        }

        if selectedIDs == [itemID] {
            selectedIDs.removeAll()
            anchorSelectionID = nil
        } else {
            selectedIDs = [itemID]
            anchorSelectionID = itemID
        }
    }

    func toggleSelection(itemID: UUID) {
        if selectedIDs.contains(itemID) {
            selectedIDs.remove(itemID)
        } else {
            selectedIDs.insert(itemID)
            anchorSelectionID = itemID
        }
    }

    func selectAll() {
        selectedIDs = Set(items.map(\.id))
        anchorSelectionID = items.first?.id
    }

    func deselectAll() {
        selectedIDs.removeAll()
        anchorSelectionID = nil
    }

    func toggleSelectAll() {
        if isAllSelected {
            deselectAll()
        } else {
            selectAll()
        }
    }

    /// Items to preview when pressing Spacebar on this shelf:
    /// - Selected items (in shelf order) if any are selected.
    /// - Otherwise the sole item when the shelf contains exactly one item.
    var itemsForQuickLook: [ShelfItem] {
        if !selectedIDs.isEmpty {
            return selectedItems
        }
        return items.count == 1 ? items : []
    }

    /// Moves single-item selection up (`delta < 0`) or down (`delta > 0`) through `items`.
    @discardableResult
    func moveSelection(by delta: Int) -> [ShelfItem] {
        guard !items.isEmpty, delta != 0 else { return selectedItems }

        let currentIndex: Int?
        if let anchorID = anchorSelectionID,
           selectedIDs.contains(anchorID),
           let idx = items.firstIndex(where: { $0.id == anchorID }) {
            currentIndex = idx
        } else if let firstSelectedIdx = items.firstIndex(where: { selectedIDs.contains($0.id) }) {
            currentIndex = firstSelectedIdx
        } else {
            currentIndex = nil
        }

        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(max(currentIndex + delta, 0), items.count - 1)
        } else {
            nextIndex = delta > 0 ? 0 : items.count - 1
        }

        let target = items[nextIndex]
        selectedIDs = [target.id]
        anchorSelectionID = target.id
        return [target]
    }

    /// Resolves which items should be dragged when a drag starts on a specific row:
    /// - If the row is part of a multi-selection, drags ALL selected items together.
    /// - Otherwise, drags just that single row (even without selecting it first!).
    func itemsForRowDrag(initiatedOn item: ShelfItem) -> [ShelfItem] {
        if selectedIDs.contains(item.id) && selectedIDs.count > 1 {
            return selectedItems
        }
        return [item]
    }

    @discardableResult
    func addFromClipboard(from pasteboard: NSPasteboard = .general) -> Bool {
        PasteboardHandler.extractItems(
            from: pasteboard,
            stagingDirectory: stagingDirectory,
            stagingRoot: stagingRoot
        ) { [weak self] extracted in
            guard !extracted.isEmpty else { return }
            guard let self else {
                Self.purgeOrphanedTemporaryFiles(in: extracted)
                return
            }
            self.addMany(extracted)
        }
    }

    func copySelectionOrAllToClipboard(pasteboard: NSPasteboard = .general) {
        let targets = selectedIDs.isEmpty ? items : selectedItems
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            targets[0].copyToGeneralPasteboard(pasteboard: pasteboard)
            return
        }

        pasteboard.clearContents()
        let tempURLs = targets.compactMap(\.temporaryFileURL)
        let fileURLs = targets.compactMap(\.fileURL)
        if fileURLs.count == targets.count {
            pasteboard.writeObjects(fileURLs.map { $0 as NSURL })
            if !tempURLs.isEmpty {
                Self.recordClipboardRetainedTemporaryURLs(tempURLs, pasteboard: pasteboard)
            }
            return
        }

        let writers: [any NSPasteboardWriting] = targets.map { item in
            switch item.kind {
            case .file(let url, _), .folder(let url, _):
                return url as NSURL
            case .image, .webURL, .text:
                return ShelfFilePromiseProvider(kind: item.kind, suggestedFilename: item.suggestedExportFilename)
            }
        }
        pasteboard.writeObjects(writers)
        if !tempURLs.isEmpty {
            Self.recordClipboardRetainedTemporaryURLs(tempURLs, pasteboard: pasteboard)
        }
    }

    nonisolated static func waitForPendingCleanup() {
        cleanupQueue.sync {}
    }

    // MARK: - Thumbnails, Metadata & Cleanup

    func cancelMetadataTasks(for ids: Set<UUID>) {
        for id in ids {
            metadataTasks.removeValue(forKey: id)?.task.cancel()
            pendingMetadataUpdates.removeValue(forKey: id)
        }
    }

    func cancelAllMetadataTasks() {
        for (_, entry) in metadataTasks {
            entry.task.cancel()
        }
        metadataTasks.removeAll()
        metadataFlushTask?.cancel()
        metadataFlushTask = nil
        pendingMetadataUpdates.removeAll()
    }

    private func finishMetadataTask(for itemID: UUID, token: UUID) {
        if metadataTasks[itemID]?.token == token {
            metadataTasks.removeValue(forKey: itemID)
        }
    }

    private func scheduleThumbnailAndMetadata(for item: ShelfItem) {
        let itemID = item.id
        let kind = item.kind
        let token = UUID()
        metadataTasks.removeValue(forKey: itemID)?.task.cancel()

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let acquired = await ThumbnailConcurrencyLimiter.shared.acquire()
            guard acquired else {
                await MainActor.run { [weak self] in
                    self?.finishMetadataTask(for: itemID, token: token)
                }
                return
            }
            defer { ThumbnailConcurrencyLimiter.shared.release() }

            if !Task.isCancelled, let subtitle = ShelfItem.loadSubtitleMetadata(for: kind) {
                await MainActor.run { [weak self] in
                    self?.enqueueMetadataUpdate(id: itemID, subtitle: subtitle)
                }
            }

            if !Task.isCancelled, let image = await ThumbnailGenerator.generate(for: kind) {
                await MainActor.run { [weak self] in
                    self?.enqueueMetadataUpdate(id: itemID, thumbnail: image)
                }
            }

            await MainActor.run { [weak self] in
                self?.finishMetadataTask(for: itemID, token: token)
            }
        }
        metadataTasks[itemID] = (token: token, task: task)
    }

    private func cleanupTemporaryFile(for item: ShelfItem) {
        guard let tempURL = item.temporaryFileURL else { return }
        let canonical = Self.canonicalURL(tempURL)
        guard !Self.isRetainedTemporaryURL(canonical),
              !Self.isClipboardRetained(canonical) else {
            return
        }

        let stagingCanonical = Self.canonicalURL(stagingDirectory)
        let stagingPrefix = stagingCanonical.path.hasSuffix("/") ? stagingCanonical.path : stagingCanonical.path + "/"

        Self.cleanupQueue.async {
            let fm = FileManager.default
            try? fm.removeItem(at: canonical)

            let parent = Self.canonicalURL(canonical.deletingLastPathComponent())
            if parent.path.hasPrefix(stagingPrefix),
               parent.path != stagingCanonical.path,
               let remaining = try? fm.contentsOfDirectory(atPath: parent.path),
               remaining.isEmpty {
                try? fm.removeItem(at: parent)
            }
        }
    }
}
