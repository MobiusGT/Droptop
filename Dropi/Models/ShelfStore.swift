import AppKit
import Combine
import Foundation

@MainActor
final class ShelfStore: ObservableObject, Identifiable {
    let id: UUID
    let shelfNumber: Int
    let colorVariation: ShelfColorVariation
    let stagingDirectory: URL

    @Published var items: [ShelfItem] = []
    @Published var selectedIDs: Set<UUID> = []

    private var anchorSelectionID: UUID?

    static var rootStagingDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("Droptop", isDirectory: true)
            .appendingPathComponent("Promises", isDirectory: true)
    }

    init(
        id: UUID = UUID(),
        shelfNumber: Int,
        colorVariation: ShelfColorVariation = .identity
    ) {
        self.id = id
        self.shelfNumber = shelfNumber
        self.colorVariation = (shelfNumber == 1) ? .identity : colorVariation
        let dir = Self.rootStagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        self.stagingDirectory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        scheduleThumbnailGeneration(for: item)
        return true
    }

    func addMany(_ newItems: [ShelfItem]) {
        for item in newItems {
            _ = add(item)
        }
    }

    func remove(_ item: ShelfItem) {
        removeByIDs([item.id])
    }

    func removeSelected() {
        removeByIDs(selectedIDs)
    }

    func removeByIDs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
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

    func clearAll() {
        let removed = items
        items.removeAll()
        selectedIDs.removeAll()
        anchorSelectionID = nil
        for item in removed {
            cleanupTemporaryFile(for: item)
        }
    }

    func cleanupStagingDirectory() {
        let dir = stagingDirectory
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static func cleanupAllStagingDirectories() {
        try? FileManager.default.removeItem(at: rootStagingDirectory)
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
    func addFromClipboard() -> Bool {
        PasteboardHandler.extractItems(
            from: NSPasteboard.general,
            stagingDirectory: stagingDirectory
        ) { [weak self] extracted in
            guard !extracted.isEmpty else { return }
            self?.addMany(extracted)
        }
    }

    func copySelectionOrAllToClipboard() {
        let targets = selectedIDs.isEmpty ? items : selectedItems
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            targets[0].copyToGeneralPasteboard()
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        let fileURLs = targets.compactMap(\.fileURL)
        if fileURLs.count == targets.count {
            pb.writeObjects(fileURLs.map { $0 as NSURL })
            return
        }

        let writers: [any NSPasteboardWriting] = targets.map { item in
            switch item.kind {
            case .file(let url, _), .folder(let url):
                return url as NSURL
            case .image, .webURL, .text:
                return ShelfFilePromiseProvider(kind: item.kind, suggestedFilename: item.suggestedExportFilename)
            }
        }
        pb.writeObjects(writers)
    }

    // MARK: - Thumbnails & Cleanup

    private func scheduleThumbnailGeneration(for item: ShelfItem) {
        let itemID = item.id
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let image = await ThumbnailGenerator.generate(for: item) else { return }
            await MainActor.run { [weak self] in
                self?.updateThumbnail(id: itemID, image: image)
            }
        }
    }

    private func cleanupTemporaryFile(for item: ShelfItem) {
        guard let tempURL = item.temporaryFileURL else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}
