import AppKit
import Foundation
import QuickLookUI
import SwiftUI

/// Immutable `QLPreviewItem` wrapper handed to `QLPreviewPanel`.
final class ShelfQuickLookPreviewItem: NSObject, QLPreviewItem, @unchecked Sendable {
    let shelfID: UUID
    let itemID: UUID
    let url: URL
    let title: String
    let transitionImage: NSImage?

    nonisolated init(
        shelfID: UUID,
        itemID: UUID,
        url: URL,
        title: String,
        transitionImage: NSImage? = nil
    ) {
        self.shelfID = shelfID
        self.itemID = itemID
        self.url = url
        self.title = title
        self.transitionImage = transitionImage
        super.init()
    }

    var previewItemURL: URL! { url }
    var previewItemTitle: String! { title }
}

/// Zero-hit-testing NSView anchored directly behind a row's 32×32 icon preview so
/// `QLPreviewPanel` zooms out from and minimizes directly back into the item's icon.
struct ShelfItemIconAnchor: NSViewRepresentable {
    let shelfID: UUID
    let itemID: UUID

    func makeNSView(context: Context) -> ShelfItemIconAnchorNSView {
        let view = ShelfItemIconAnchorNSView()
        view.configure(shelfID: shelfID, itemID: itemID)
        return view
    }

    func updateNSView(_ nsView: ShelfItemIconAnchorNSView, context: Context) {
        nsView.configure(shelfID: shelfID, itemID: itemID)
    }

    static func dismantleNSView(_ nsView: ShelfItemIconAnchorNSView, coordinator: ()) {
        nsView.unregister()
    }
}

final class ShelfItemIconAnchorNSView: NSView {
    private var registeredKey: ShelfQuickLookController.IconAnchorKey?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(shelfID: UUID, itemID: UUID) {
        let newKey = ShelfQuickLookController.IconAnchorKey(shelfID: shelfID, itemID: itemID)
        if registeredKey != newKey {
            unregister()
            registeredKey = newKey
        }
        if window != nil {
            ShelfQuickLookController.shared.registerIconAnchor(self, for: newKey)
        }
    }

    func unregister() {
        guard let key = registeredKey else { return }
        ShelfQuickLookController.shared.unregisterIconAnchor(self, for: key)
        registeredKey = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let key = registeredKey else { return }
        if window != nil {
            ShelfQuickLookController.shared.registerIconAnchor(self, for: key)
        } else {
            ShelfQuickLookController.shared.unregisterIconAnchor(self, for: key)
        }
    }
}

/// Snapshot of a single Quick Look preview session, including any private `0700` temporary
/// directory created solely for in-memory items (`.image`, `.text`, `.webURL`).
struct ShelfQuickLookSession: Sendable {
    let shelfID: UUID
    let items: [ShelfQuickLookPreviewItem]
    let temporarySessionDirectory: URL?

    var itemIDs: Set<UUID> {
        Set(items.map(\.itemID))
    }
}

private struct QuickLookExportInput: @unchecked Sendable {
    let id: UUID
    let kind: ShelfItemKind
    let displayName: String
    let suggestedExportFilename: String
    let precomputedTransitionImage: NSImage?

    @MainActor
    init(item: ShelfItem) {
        self.id = item.id
        self.kind = item.kind
        self.displayName = item.displayName
        self.suggestedExportFilename = item.suggestedExportFilename

        if let thumb = item.thumbnail, thumb.size.width > 0, thumb.size.height > 0 {
            self.precomputedTransitionImage = thumb
        } else if case .image = item.kind {
            // Computed off-main via ImageIO inside `buildSession(from:)`.
            self.precomputedTransitionImage = nil
        } else {
            let fallback = item.fallbackIcon
            self.precomputedTransitionImage = (fallback.size.width > 0 && fallback.size.height > 0) ? fallback : nil
        }
    }
}

@MainActor
final class ShelfQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfQuickLookController()

    nonisolated static let previewSubdirectoryName = "QuickLookPreview"

    struct IconAnchorKey: Hashable {
        let shelfID: UUID
        let itemID: UUID
    }

    private struct WeakAnchorView {
        weak var view: NSView?
    }

    private nonisolated static let cleanupQueue = DispatchQueue(
        label: "com.local.Droptop.QuickLookCleanup",
        qos: .utility
    )

    private(set) var activeSession: ShelfQuickLookSession?
    private weak var activeSourceWindow: ShelfWindow?
    private var iconAnchors: [IconAnchorKey: WeakAnchorView] = [:]
    private var onNavigateSelection: ((UUID, Int) -> [ShelfItem]?)?
    private var onSessionEnded: ((UUID) -> Void)?
    private var activeStagingRoot: URL = ShelfStore.rootStagingDirectory
    private var isControllingPanel = false
    private var delayedCleanupWorkItem: DispatchWorkItem?
    private var pendingCleanupDirectory: URL?
    private var resignActiveObserver: NSObjectProtocol?
    private var exportGeneration: UInt64 = 0
    private var pendingExportTask: Task<Void, Never>?
    private var pendingExportKey: (shelfID: UUID, itemIDs: [UUID])?

    override init() {
        super.init()
    }

    var hasActiveSession: Bool {
        activeSession != nil
    }

    var hasPendingExport: Bool {
        pendingExportTask != nil
    }

    var isPanelVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    func isPreviewing(shelfID: UUID) -> Bool {
        activeSession?.shelfID == shelfID && isPanelVisible
    }

    func isPreviewingOrExporting(shelfID: UUID, itemIDs: [UUID]) -> Bool {
        if let pending = pendingExportKey, pending.shelfID == shelfID, pending.itemIDs == itemIDs {
            return true
        }
        return isPreviewing(shelfID: shelfID) && activeSession?.items.map(\.itemID) == itemIDs
    }

    // MARK: - Icon Preview Anchor Registry

    func registerIconAnchor(_ view: NSView, for key: IconAnchorKey) {
        iconAnchors[key] = WeakAnchorView(view: view)
    }

    func unregisterIconAnchor(_ view: NSView, for key: IconAnchorKey) {
        guard let existing = iconAnchors[key] else { return }
        if existing.view == nil || existing.view === view {
            iconAnchors.removeValue(forKey: key)
        }
    }

    func purgeAnchors(forShelfID shelfID: UUID) {
        iconAnchors = iconAnchors.filter { key, entry in
            key.shelfID != shelfID && entry.view != nil
        }
    }

    func registeredAnchorCount(forShelfID shelfID: UUID) -> Int {
        iconAnchors.reduce(into: 0) { count, pair in
            if pair.key.shelfID == shelfID && pair.value.view != nil {
                count += 1
            }
        }
    }

    func iconScreenFrame(shelfID: UUID, itemID: UUID) -> NSRect {
        let key = IconAnchorKey(shelfID: shelfID, itemID: itemID)
        guard let anchorView = iconAnchors[key]?.view else {
            iconAnchors.removeValue(forKey: key)
            return .zero
        }
        guard let window = anchorView.window, window.isVisible else {
            return .zero
        }
        if let shelfWindow = window as? ShelfWindow,
           shelfWindow.dropContainerView.highlightState.isAutoHidden {
            return .zero
        }

        // On macOS 14+, `NSView.clipsToBounds` defaults to `false`, so `visibleRect` expands to
        // the enclosing clipping ancestor (e.g. the shelf/scroll viewport). Intersect with `bounds`
        // to isolate the exact visible 32×32 icon rect while still respecting ScrollView clipping.
        let visibleBounds = anchorView.bounds.intersection(anchorView.visibleRect)
        guard !visibleBounds.isNull, !visibleBounds.isEmpty, visibleBounds.width >= 4, visibleBounds.height >= 4 else {
            return .zero
        }

        let rectInWindow = anchorView.convert(visibleBounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        let clamped = screenRect.intersection(window.frame)
        guard !clamped.isNull, clamped.width >= 4, clamped.height >= 4 else {
            return .zero
        }
        return clamped
    }

    // MARK: - Session Materialization (SEC-01 / SEC-04 / SEC-05 Compliant)

    /// Resolves `ShelfItem` values into `QLPreviewItem` URLs:
    /// - `.file` and `.folder` (both regular and staged temporary copies) are passed directly by URL
    ///   without calling `writeExportData` (preserving SEC-05).
    /// - `.image`, `.text`, and `.webURL` are exported into a fresh `0700` per-session/per-item
    ///   subdirectory under `<stagingRoot>/QuickLookPreview` using `allowOverwrite: false` (SEC-04 / SEC-05).
    static func buildSession(
        for items: [ShelfItem],
        shelfID: UUID,
        stagingRoot: URL = ShelfStore.rootStagingDirectory
    ) -> ShelfQuickLookSession? {
        guard !items.isEmpty else { return nil }
        let inputs = items.map { QuickLookExportInput(item: $0) }
        return buildSession(from: inputs, shelfID: shelfID, stagingRoot: stagingRoot)
    }

    private nonisolated static func buildSession(
        from inputs: [QuickLookExportInput],
        shelfID: UUID,
        stagingRoot: URL
    ) -> ShelfQuickLookSession? {
        guard !inputs.isEmpty else { return nil }

        let fm = FileManager.default
        var previewItems: [ShelfQuickLookPreviewItem] = []
        var sessionDir: URL?

        func ensureSessionDirectory() throws -> URL {
            if let existing = sessionDir {
                return existing
            }
            let canonicalRoot = stagingRoot.standardizedFileURL
            try ShelfStore.ensureStagingRootDirectory(at: canonicalRoot)
            let previewRoot = canonicalRoot.appendingPathComponent(previewSubdirectoryName, isDirectory: true)
            try ShelfStore.ensurePrivateDirectory(at: previewRoot)
            let created = previewRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try ShelfStore.ensurePrivateDirectory(at: created)
            sessionDir = created
            return created
        }

        for input in inputs {
            if Task.isCancelled {
                if let sessionDir {
                    cleanupTemporaryDirectory(sessionDir, synchronous: true)
                }
                return nil
            }

            let transitionImage = resolveTransitionImage(for: input)
            switch input.kind {
            case .file(let url, _), .folder(let url, _):
                let standardized = url.standardizedFileURL
                guard fm.fileExists(atPath: standardized.path) else { continue }
                previewItems.append(
                    ShelfQuickLookPreviewItem(
                        shelfID: shelfID,
                        itemID: input.id,
                        url: standardized,
                        title: input.displayName,
                        transitionImage: transitionImage
                    )
                )

            case .image, .text, .webURL:
                do {
                    let rootSessionDir = try ensureSessionDirectory()
                    let itemDir = rootSessionDir.appendingPathComponent(input.id.uuidString, isDirectory: true)
                    try ShelfStore.ensurePrivateDirectory(at: itemDir)
                    let rawName = input.suggestedExportFilename
                    let safeName = (rawName.isEmpty || rawName == "." || rawName == "..") ? "Preview" : rawName
                    let destination = itemDir.appendingPathComponent(safeName)
                    try ShelfItem.writeExportData(kind: input.kind, to: destination, allowOverwrite: false)
                    previewItems.append(
                        ShelfQuickLookPreviewItem(
                            shelfID: shelfID,
                            itemID: input.id,
                            url: destination.standardizedFileURL,
                            title: input.displayName,
                            transitionImage: transitionImage
                        )
                    )
                } catch {
                    continue
                }
            }
        }

        guard !previewItems.isEmpty, !Task.isCancelled else {
            if let sessionDir {
                cleanupTemporaryDirectory(sessionDir, synchronous: true)
            }
            return nil
        }

        return ShelfQuickLookSession(
            shelfID: shelfID,
            items: previewItems,
            temporarySessionDirectory: sessionDir
        )
    }

    private nonisolated static func resolveTransitionImage(for input: QuickLookExportInput) -> NSImage? {
        if let precomputed = input.precomputedTransitionImage,
           precomputed.size.width > 0,
           precomputed.size.height > 0 {
            return precomputed
        }
        if case .image(let data, _, _) = input.kind,
           let downsampled = ThumbnailGenerator.downsampledImage(from: data, maxPixelSize: 280),
           downsampled.size.width > 0,
           downsampled.size.height > 0 {
            return downsampled
        }
        return nil
    }

    private static func requiresTemporaryExport(_ items: [ShelfItem]) -> Bool {
        items.contains { item in
            switch item.kind {
            case .file, .folder:
                return false
            case .image, .text, .webURL:
                return true
            }
        }
    }

    nonisolated static func cleanupTemporaryDirectory(_ directory: URL?, synchronous: Bool = false) {
        guard let directory else { return }
        let target = directory.standardizedFileURL
        let work: @Sendable () -> Void = {
            let fm = FileManager.default
            try? fm.removeItem(at: target)

            let parent = target.deletingLastPathComponent()
            if parent.lastPathComponent == previewSubdirectoryName,
               let remaining = try? fm.contentsOfDirectory(atPath: parent.path),
               remaining.isEmpty {
                try? fm.removeItem(at: parent)
            }
        }

        if synchronous {
            work()
        } else {
            cleanupQueue.async(execute: work)
        }
    }

    nonisolated static func waitForPendingCleanup() {
        cleanupQueue.sync {}
    }

    func waitForPendingExport(timeout: TimeInterval = 5.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while pendingExportTask != nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Presentation & Lifecycle

    func togglePreview(
        items: [ShelfItem],
        forShelfID shelfID: UUID,
        stagingRoot: URL = ShelfStore.rootStagingDirectory,
        sourceWindow: ShelfWindow?,
        onNavigateSelection: ((UUID, Int) -> [ShelfItem]?)? = nil,
        onSessionEnded: ((UUID) -> Void)? = nil
    ) {
        if isPanelVisible || pendingExportTask != nil {
            closePanel(restoreShelfFocus: true)
            return
        }
        showPreview(
            items: items,
            forShelfID: shelfID,
            stagingRoot: stagingRoot,
            sourceWindow: sourceWindow,
            onNavigateSelection: onNavigateSelection,
            onSessionEnded: onSessionEnded
        )
    }

    func showPreview(
        items: [ShelfItem],
        forShelfID shelfID: UUID,
        stagingRoot: URL = ShelfStore.rootStagingDirectory,
        sourceWindow: ShelfWindow?,
        onNavigateSelection: ((UUID, Int) -> [ShelfItem]?)? = nil,
        onSessionEnded: ((UUID) -> Void)? = nil
    ) {
        guard !items.isEmpty else { return }

        cancelPendingExport()
        FilenameTooltipController.shared.hide()

        // Fast synchronous path for direct file/folder previews (zero temporary file export).
        if !Self.requiresTemporaryExport(items) {
            guard let newSession = Self.buildSession(for: items, shelfID: shelfID, stagingRoot: stagingRoot) else {
                return
            }
            presentBuiltSession(
                newSession,
                forShelfID: shelfID,
                stagingRoot: stagingRoot,
                sourceWindow: sourceWindow,
                onNavigateSelection: onNavigateSelection,
                onSessionEnded: onSessionEnded
            )
            return
        }

        // Off-main export for in-memory items (.image, .text, .webURL) with generation guard.
        let inputs = items.map { QuickLookExportInput(item: $0) }
        exportGeneration &+= 1
        let expectedGen = exportGeneration
        pendingExportKey = (shelfID: shelfID, itemIDs: items.map(\.id))

        pendingExportTask = Task.detached(priority: .userInitiated) { [weak self, weak sourceWindow] in
            let builtSession = Self.buildSession(
                from: inputs,
                shelfID: shelfID,
                stagingRoot: stagingRoot
            )

            await MainActor.run { [weak self, weak sourceWindow] in
                guard let self else {
                    Self.cleanupTemporaryDirectory(builtSession?.temporarySessionDirectory, synchronous: false)
                    return
                }
                guard expectedGen == self.exportGeneration else {
                    Self.cleanupTemporaryDirectory(builtSession?.temporarySessionDirectory, synchronous: false)
                    return
                }
                self.pendingExportTask = nil
                self.pendingExportKey = nil

                if let sourceWindow,
                   !sourceWindow.isVisible || sourceWindow.dropContainerView.highlightState.isAutoHidden {
                    Self.cleanupTemporaryDirectory(builtSession?.temporarySessionDirectory, synchronous: false)
                    return
                }

                guard let builtSession else { return }
                self.presentBuiltSession(
                    builtSession,
                    forShelfID: shelfID,
                    stagingRoot: stagingRoot,
                    sourceWindow: sourceWindow,
                    onNavigateSelection: onNavigateSelection,
                    onSessionEnded: onSessionEnded
                )
            }
        }
    }

    private func presentBuiltSession(
        _ newSession: ShelfQuickLookSession,
        forShelfID shelfID: UUID,
        stagingRoot: URL,
        sourceWindow: ShelfWindow?,
        onNavigateSelection: ((UUID, Int) -> [ShelfItem]?)?,
        onSessionEnded: ((UUID) -> Void)?
    ) {
        let previousDir = activeSession?.temporarySessionDirectory
        let previousShelfID = activeSession?.shelfID
        let previousWindow = activeSourceWindow
        flushPendingDelayedCleanup(synchronous: false)

        activeSession = newSession
        activeSourceWindow = sourceWindow
        activeStagingRoot = stagingRoot
        self.onNavigateSelection = onNavigateSelection
        self.onSessionEnded = onSessionEnded

        if let previousWindow, previousWindow !== sourceWindow {
            previousWindow.endQuickLookControlFocus()
        }
        if let previousShelfID, previousShelfID != shelfID {
            onSessionEnded?(previousShelfID)
        }
        Self.cleanupTemporaryDirectory(previousDir, synchronous: false)

        installObserversIfNeeded()

        guard let panel = QLPreviewPanel.shared() else { return }
        configurePanel(panel)

        // Ensure Droptop is active (required for `.accessory` apps so `QLPreviewPanel` stays visible)
        // and ensure the shelf window is in the key/main responder chain when `QLPreviewPanel` looks
        // for a controller.
        NSApp.activate(ignoringOtherApps: true)
        sourceWindow?.beginQuickLookControlFocus()

        if panel.isVisible {
            panel.updateController()
            if isControllingPanel {
                panel.currentPreviewItemIndex = 0
                panel.reloadData()
            }
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.updateController()
            if isControllingPanel {
                panel.currentPreviewItemIndex = 0
                panel.reloadData()
            }
        }
    }

    func updatePreviewIfActive(
        forShelfID shelfID: UUID,
        remainingItems: [ShelfItem]
    ) {
        guard let session = activeSession, session.shelfID == shelfID else { return }
        let remainingByID = Dictionary(uniqueKeysWithValues: remainingItems.map { ($0.id, $0) })
        let stillPresent = session.items.compactMap { remainingByID[$0.itemID] }

        guard !stillPresent.isEmpty else {
            closePanel(restoreShelfFocus: false)
            return
        }

        if stillPresent.count == session.items.count {
            return
        }

        replaceActiveSession(with: stillPresent, forShelfID: shelfID)
    }

    func syncSelectionIfPreviewing(
        items: [ShelfItem],
        forShelfID shelfID: UUID
    ) {
        guard isPreviewing(shelfID: shelfID), !items.isEmpty else { return }
        let requestedIDs = items.map(\.id)
        if let pending = pendingExportKey, pending.shelfID == shelfID, pending.itemIDs == requestedIDs {
            return
        }
        if pendingExportTask == nil, let current = activeSession, current.items.map(\.itemID) == requestedIDs {
            return
        }
        replaceActiveSession(with: items, forShelfID: shelfID)
    }

    func closeIfShowing(forShelfID shelfID: UUID) {
        guard activeSession?.shelfID == shelfID || pendingExportKey?.shelfID == shelfID else { return }
        closePanel(restoreShelfFocus: false)
    }

    func closePanel(restoreShelfFocus: Bool, delayTemporaryCleanup: Bool = false) {
        cancelPendingExport()
        let shouldOrderOut = QLPreviewPanel.sharedPreviewPanelExists()
        if shouldOrderOut, let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        finishActiveSession(
            restoreShelfFocus: restoreShelfFocus,
            delayTemporaryCleanup: delayTemporaryCleanup,
            synchronousCleanup: false
        )
    }

    func closeAndCleanup(synchronous: Bool = true) {
        cancelPendingExport()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        flushPendingDelayedCleanup(synchronous: synchronous)
        finishActiveSession(
            restoreShelfFocus: false,
            delayTemporaryCleanup: false,
            synchronousCleanup: synchronous
        )
        if let observer = resignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            resignActiveObserver = nil
        }
    }

    private func cancelPendingExport() {
        exportGeneration &+= 1
        pendingExportTask?.cancel()
        pendingExportTask = nil
        pendingExportKey = nil
    }

    // MARK: - QLPreviewPanelController Forwarding

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        activeSession != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard let panel else { return }
        isControllingPanel = true
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        isControllingPanel = false
        if let panel {
            if panel.dataSource === self {
                panel.dataSource = nil
            }
            if panel.delegate === self {
                panel.delegate = nil
            }
        }
        // If the panel was dismissed externally (e.g. system orderOut without windowWillClose),
        // finish the session on the next runloop turn without racing a controller handoff.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isControllingPanel, !self.isPanelVisible, self.hasActiveSession else {
                return
            }
            self.finishActiveSession(
                restoreShelfFocus: NSApp.isActive,
                delayTemporaryCleanup: false,
                synchronousCleanup: false
            )
        }
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        activeSession?.items.count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard let items = activeSession?.items, index >= 0, index < items.count else {
            return nil
        }
        return items[index]
    }

    // MARK: - QLPreviewPanelDelegate & NSWindowDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let modifiers = event.modifierFlags.intersection(relevant)
        guard modifiers.isEmpty else { return false }

        switch event.keyCode {
        case 49: // Spacebar closes Quick Look just like Finder
            if !event.isARepeat {
                closePanel(restoreShelfFocus: true)
            }
            return true

        case 53: // Escape
            closePanel(restoreShelfFocus: true)
            return true

        case 125, 126: // Down / Up arrows
            let delta = (event.keyCode == 125) ? 1 : -1
            return handleArrowNavigation(delta: delta, panel: panel)

        default:
            return false
        }
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let previewItem = item as? ShelfQuickLookPreviewItem else {
            return .zero
        }
        return iconScreenFrame(shelfID: previewItem.shelfID, itemID: previewItem.itemID)
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        transitionImageFor item: (any QLPreviewItem)!,
        contentRect: UnsafeMutablePointer<NSRect>!
    ) -> Any! {
        guard let previewItem = item as? ShelfQuickLookPreviewItem,
              let image = previewItem.transitionImage,
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }
        if let contentRect {
            contentRect.pointee = NSRect(origin: .zero, size: image.size)
        }
        return image
    }

    func windowWillClose(_ notification: Notification) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              (notification.object as AnyObject?) === panel else {
            return
        }
        finishActiveSession(
            restoreShelfFocus: NSApp.isActive,
            delayTemporaryCleanup: false,
            synchronousCleanup: false
        )
    }

    // MARK: - Internals

    private func configurePanel(_ panel: QLPreviewPanel) {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        var behavior = panel.collectionBehavior
        behavior.remove(.moveToActiveSpace)
        behavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        panel.collectionBehavior = behavior
    }

    private func installObserversIfNeeded() {
        guard resignActiveObserver == nil else { return }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hasActiveSession || self.hasPendingExport else { return }
                // Close Quick Look cleanly when switching apps so it never ghosts back later,
                // while giving any "Open with <App>" handoff a short window to read temp previews.
                self.closePanel(restoreShelfFocus: false, delayTemporaryCleanup: true)
            }
        }
    }

    private func handleArrowNavigation(delta: Int, panel: QLPreviewPanel?) -> Bool {
        guard let session = activeSession else { return false }

        if session.items.count > 1, let panel {
            let current = panel.currentPreviewItemIndex
            let base = (current == NSNotFound) ? 0 : current
            let next = min(max(base + delta, 0), session.items.count - 1)
            if next != current {
                panel.currentPreviewItemIndex = next
            }
            return true
        }

        guard let nextItems = onNavigateSelection?(session.shelfID, delta), !nextItems.isEmpty else {
            return false
        }
        replaceActiveSession(with: nextItems, forShelfID: session.shelfID)
        return true
    }

    private func replaceActiveSession(with items: [ShelfItem], forShelfID shelfID: UUID) {
        let requestedIDs = items.map(\.id)
        if let pending = pendingExportKey, pending.shelfID == shelfID, pending.itemIDs == requestedIDs {
            return
        }
        if pendingExportTask == nil,
           let current = activeSession,
           current.shelfID == shelfID,
           current.items.map(\.itemID) == requestedIDs {
            return
        }

        cancelPendingExport()

        if !Self.requiresTemporaryExport(items) {
            guard let newSession = Self.buildSession(
                for: items,
                shelfID: shelfID,
                stagingRoot: activeStagingRoot
            ) else {
                closePanel(restoreShelfFocus: true)
                return
            }
            applyReplacedSession(newSession)
            return
        }

        let inputs = items.map { QuickLookExportInput(item: $0) }
        let stagingRoot = activeStagingRoot
        exportGeneration &+= 1
        let expectedGen = exportGeneration
        pendingExportKey = (shelfID: shelfID, itemIDs: requestedIDs)

        pendingExportTask = Task.detached(priority: .userInitiated) { [weak self] in
            let builtSession = Self.buildSession(
                from: inputs,
                shelfID: shelfID,
                stagingRoot: stagingRoot
            )

            await MainActor.run { [weak self] in
                guard let self else {
                    Self.cleanupTemporaryDirectory(builtSession?.temporarySessionDirectory, synchronous: false)
                    return
                }
                guard expectedGen == self.exportGeneration,
                      self.activeSession?.shelfID == shelfID else {
                    Self.cleanupTemporaryDirectory(builtSession?.temporarySessionDirectory, synchronous: false)
                    return
                }
                self.pendingExportTask = nil
                self.pendingExportKey = nil

                guard let builtSession else {
                    self.closePanel(restoreShelfFocus: true)
                    return
                }
                self.applyReplacedSession(builtSession)
            }
        }
    }

    private func applyReplacedSession(_ newSession: ShelfQuickLookSession) {
        let previousDir = activeSession?.temporarySessionDirectory
        activeSession = newSession
        Self.cleanupTemporaryDirectory(previousDir, synchronous: false)

        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.currentPreviewItemIndex = 0
            panel.reloadData()
        }
    }

    private func finishActiveSession(
        restoreShelfFocus: Bool,
        delayTemporaryCleanup: Bool,
        synchronousCleanup: Bool
    ) {
        cancelPendingExport()
        guard let endedSession = activeSession else { return }
        let sourceWindow = activeSourceWindow
        let endedCallback = onSessionEnded

        activeSession = nil
        activeSourceWindow = nil
        onNavigateSelection = nil
        onSessionEnded = nil

        sourceWindow?.endQuickLookControlFocus()
        if restoreShelfFocus,
           let sourceWindow,
           sourceWindow.isVisible,
           !sourceWindow.dropContainerView.highlightState.isAutoHidden {
            sourceWindow.acquireKeyFocusForKeyboard()
        } else {
            sourceWindow?.releaseKeyFocus()
        }

        if let tempDir = endedSession.temporarySessionDirectory {
            if delayTemporaryCleanup && !synchronousCleanup {
                scheduleDelayedCleanup(for: tempDir)
            } else {
                Self.cleanupTemporaryDirectory(tempDir, synchronous: synchronousCleanup)
            }
        }

        endedCallback?(endedSession.shelfID)
    }

    private func scheduleDelayedCleanup(for directory: URL) {
        flushPendingDelayedCleanup(synchronous: false)
        pendingCleanupDirectory = directory
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let dir = self.pendingCleanupDirectory
                self.pendingCleanupDirectory = nil
                self.delayedCleanupWorkItem = nil
                Self.cleanupTemporaryDirectory(dir, synchronous: false)
            }
        }
        delayedCleanupWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func flushPendingDelayedCleanup(synchronous: Bool) {
        delayedCleanupWorkItem?.cancel()
        delayedCleanupWorkItem = nil
        if let dir = pendingCleanupDirectory {
            pendingCleanupDirectory = nil
            Self.cleanupTemporaryDirectory(dir, synchronous: synchronous)
        }
    }
}
