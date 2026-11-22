import AppKit
import Combine
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Droptop

@MainActor
final class PerformanceReliabilityTests: XCTestCase {
    private var tempBaseDir: URL!
    private var stagingRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ShelfQuickLookController.shared.closeAndCleanup(synchronous: true)
        ShelfStore.clearClipboardRetention()
        ShelfStore.clearRetainedTemporaryFiles()

        tempBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroptopTests-PERF-\(UUID().uuidString)", isDirectory: true)
        stagingRoot = tempBaseDir
            .appendingPathComponent("Droptop", isDirectory: true)
            .appendingPathComponent("Promises", isDirectory: true)
        try ShelfStore.ensureStagingRootDirectory(at: stagingRoot)
    }

    override func tearDownWithError() throws {
        ShelfQuickLookController.shared.closeAndCleanup(synchronous: true)
        ShelfQuickLookController.waitForPendingCleanup()
        ShelfStore.waitForPendingCleanup()
        ShelfStore.clearClipboardRetention()
        ShelfStore.clearRetainedTemporaryFiles()
        GlobalDragMonitor.shared.stop()
        try? FileManager.default.removeItem(at: tempBaseDir)
        try super.tearDownWithError()
    }

    private func makeValidPNGData(width: Int = 64, height: Int = 32) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try XCTUnwrap(ctx.makeImage())
        let mutable = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            mutable as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return mutable as Data
    }

    // MARK: - PERF-01 & PERF-09

    func testDragSessionStateMachineShortCircuitsWindowProbeWhenPasteboardChanged() {
        var machine = DragSessionStateMachine(initialDragChangeCount: 10)
        _ = machine.mouseDown(at: NSPoint(x: 100, y: 100), isInternal: false, currentDragChangeCount: 10)

        var windowProbeCalls = 0
        let transitionA = machine.mouseMovedOrPolled(
            at: NSPoint(x: 120, y: 100),
            isLeftButtonPressed: true,
            isDraggingFromShelf: false,
            currentDragChangeCount: 11,
            pasteboardHasSupportedPayload: { true },
            hasExternalDraggingWindow: {
                windowProbeCalls += 1
                return false
            }
        )
        XCTAssertEqual(transitionA, .beganExternalDrag(NSPoint(x: 120, y: 100)))
        XCTAssertEqual(windowProbeCalls, 0, "Window probe must be short-circuited when pasteboard already changed")

        // Case B (Dock recovery without mouseDown): also short-circuits when pasteboard changed.
        var machineB = DragSessionStateMachine(initialDragChangeCount: 20)
        let transitionB = machineB.mouseMovedOrPolled(
            at: NSPoint(x: 50, y: 50),
            isLeftButtonPressed: true,
            isDraggingFromShelf: false,
            currentDragChangeCount: 21,
            pasteboardHasSupportedPayload: { true },
            hasExternalDraggingWindow: {
                windowProbeCalls += 1
                return false
            }
        )
        XCTAssertEqual(transitionB, .beganExternalDrag(NSPoint(x: 50, y: 50)))
        XCTAssertEqual(windowProbeCalls, 0)

        // When pasteboard did NOT change (e.g. Dock layer-500 drag), probe is invoked and begins drag.
        var machineDock = DragSessionStateMachine(initialDragChangeCount: 30)
        let transitionDock = machineDock.mouseMovedOrPolled(
            at: NSPoint(x: 50, y: 50),
            isLeftButtonPressed: true,
            isDraggingFromShelf: false,
            currentDragChangeCount: 30,
            pasteboardHasSupportedPayload: { false },
            hasExternalDraggingWindow: {
                windowProbeCalls += 1
                return true
            }
        )
        XCTAssertEqual(transitionDock, .beganExternalDrag(NSPoint(x: 50, y: 50)))
        XCTAssertEqual(windowProbeCalls, 1)
    }

    func testGlobalDragMonitorIgnoresTapEventsAfterStop() {
        let monitor = GlobalDragMonitor.shared
        monitor.stop()
        XCTAssertFalse(monitor.isMonitoringActive)
        XCTAssertFalse(monitor.hasActiveWatchdog)

        monitor.handleTapEvent(.leftMouseDown)
        XCTAssertFalse(monitor.hasActiveWatchdog, "Stopped monitor must ignore tap events and never start watchdog")
    }

    // MARK: - PERF-02

    func testRetainedTemporaryFilesPruneByTTLWhileProtectingClipboardAndBatchSiblings() throws {
        let shelf = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let sharedBatch = shelf.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let clipBatch = shelf.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let freshBatch = shelf.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ShelfStore.ensurePrivateDirectory(at: sharedBatch)
        try ShelfStore.ensurePrivateDirectory(at: clipBatch)
        try ShelfStore.ensurePrivateDirectory(at: freshBatch)

        let expiredFile = sharedBatch.appendingPathComponent("expired.png")
        let siblingFile = sharedBatch.appendingPathComponent("sibling.png")
        let clipboardFile = clipBatch.appendingPathComponent("clipboard.png")
        let freshFile = freshBatch.appendingPathComponent("fresh.png")

        try Data("expired".utf8).write(to: expiredFile)
        try Data("sibling".utf8).write(to: siblingFile)
        try Data("clip".utf8).write(to: clipboardFile)
        try Data("fresh".utf8).write(to: freshFile)

        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        ShelfStore.retainTemporaryURL(expiredFile, shelfStagingDirectory: shelf.stagingDirectory, at: baseTime)
        ShelfStore.retainTemporaryURL(clipboardFile, shelfStagingDirectory: shelf.stagingDirectory, at: baseTime)
        ShelfStore.retainTemporaryURL(freshFile, shelfStagingDirectory: shelf.stagingDirectory, at: baseTime.addingTimeInterval(45 * 60))

        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([clipboardFile as NSURL])
        ShelfStore.recordClipboardRetainedTemporaryURLs([clipboardFile], pasteboard: pb)

        // At baseTime + 61 minutes:
        // - expiredFile is > 60 min old -> deleted, but sharedBatch + siblingFile MUST remain intact!
        // - clipboardFile is > 60 min old -> protected by active clipboard retention!
        // - freshFile is only 16 min old -> preserved!
        ShelfStore.pruneRetained(
            olderThan: ShelfStore.defaultRetentionTTL,
            now: baseTime.addingTimeInterval(61 * 60),
            synchronous: true
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingFile.path), "Sibling file in shared batch must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedBatch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipboardFile.path), "Active clipboard file must survive TTL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshFile.path), "Unexpired file must survive TTL")

        // Once clipboard changes and TTL passes for freshFile too, both are pruned cleanly.
        pb.clearContents()
        pb.setString("replaced", forType: .string)
        ShelfStore.pruneRetained(
            olderThan: ShelfStore.defaultRetentionTTL,
            now: baseTime.addingTimeInterval(120 * 60),
            synchronous: true
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: clipboardFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clipBatch.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshBatch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingFile.path))
    }

    func testAdoptedSourceFileCleanedImmediatelyInRemoveDraggedOutOnOpenShelf() throws {
        let shelf = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let batch1 = shelf.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let batch2 = shelf.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ShelfStore.ensurePrivateDirectory(at: batch1)
        try ShelfStore.ensurePrivateDirectory(at: batch2)

        let adoptedFile = batch1.appendingPathComponent("MovedToOtherShelf.png")
        let keptFile = batch2.appendingPathComponent("StaysOnShelf.png")
        try Data("moved".utf8).write(to: adoptedFile)
        try Data("kept".utf8).write(to: keptFile)

        let item1 = ShelfItem.fromFileURL(adoptedFile, isTemporaryCopy: true)
        let item2 = ShelfItem.fromFileURL(keptFile, isTemporaryCopy: true)
        shelf.addMany([item1, item2])

        let canonicalAdopted = adoptedFile.standardizedFileURL.resolvingSymlinksInPath().path
        shelf.removeDraggedOut([item1.id], adoptedSourcePaths: [canonicalAdopted])
        ShelfStore.waitForPendingCleanup()

        // Shelf remains open with item2, while adopted source file + batch1 are cleaned up immediately.
        XCTAssertEqual(shelf.items.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: adoptedFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFile.path))
    }

    func testOrphanedDropFilesPurgedCleanly() throws {
        let shelf = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let batch = shelf.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ShelfStore.ensurePrivateDirectory(at: batch)

        let orphanFile = batch.appendingPathComponent("LatePromise.png")
        try Data("late".utf8).write(to: orphanFile)
        let orphanItem = ShelfItem.fromFileURL(orphanFile, isTemporaryCopy: true)

        ShelfStore.purgeOrphanedTemporaryFiles(in: [orphanItem], synchronous: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.path))
    }

    // MARK: - PERF-03

    func testImageIODownsamplingAndPixelDimensionHeaderParsing() throws {
        let pngData = try makeValidPNGData(width: 120, height: 60)

        let dims = try XCTUnwrap(ThumbnailGenerator.imagePixelDimensions(from: pngData))
        XCTAssertEqual(dims.width, 120)
        XCTAssertEqual(dims.height, 60)

        let thumb = try XCTUnwrap(ThumbnailGenerator.downsampledImage(from: pngData, maxPixelSize: 40))
        XCTAssertLessThanOrEqual(max(thumb.size.width, thumb.size.height), 40.5)
        XCTAssertGreaterThan(thumb.size.width, 0)
        XCTAssertGreaterThan(thumb.size.height, 0)

        let item = ShelfItem(kind: .image(data: pngData, fileExtension: "png", suggestedName: "Shot"))
        XCTAssertNil(item.thumbnail)
        XCTAssertEqual(ShelfItem.loadSubtitleMetadata(for: item.kind), "120 × 60")
    }

    func testThumbnailConcurrencyLimiterCancellationSafety() async {
        let limiter = ThumbnailConcurrencyLimiter(limit: 1)

        // Hold the sole permit.
        let firstAcquired = await limiter.acquire()
        XCTAssertTrue(firstAcquired)

        // Launch a queued waiter and cancel it while waiting.
        let waiterTask = Task {
            await limiter.acquire()
        }
        try? await Task.sleep(for: .milliseconds(25))
        waiterTask.cancel()
        let cancelledResult = await waiterTask.value
        XCTAssertFalse(cancelledResult)

        // Release the permit and verify a fresh acquire succeeds cleanly (no permit leak).
        limiter.release()
        let nextAcquired = await limiter.acquire()
        XCTAssertTrue(nextAcquired)
        limiter.release()
    }

    func testCancelAllMetadataTasksCancelsFlushTaskAndPendingUpdates() {
        let shelf = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let item = ShelfItem(kind: .text(plain: "Snippet", rtfData: nil, title: "Title"))
        shelf.add(item)
        shelf.enqueueMetadataUpdate(id: item.id, subtitle: "Updated")
        XCTAssertTrue(shelf.hasPendingMetadataFlush)

        shelf.cancelAllMetadataTasks()
        XCTAssertEqual(shelf.activeMetadataTaskCount, 0)
        XCTAssertFalse(shelf.hasPendingMetadataFlush)
    }

    // MARK: - PERF-04

    func testImageDedupeKeyBoundedHashDistinguishesHeadTailAndLength() {
        let base = Data(repeating: 0xAA, count: 200_000)
        var diffHead = base
        diffHead[10] = 0xBB
        var diffTail = base
        diffTail[199_990] = 0xCC
        let diffLength = Data(repeating: 0xAA, count: 200_001)

        let itemBase1 = ShelfItem(kind: .image(data: base, fileExtension: "png", suggestedName: "A"))
        let itemBase2 = ShelfItem(kind: .image(data: base, fileExtension: "png", suggestedName: "B"))
        let itemHead = ShelfItem(kind: .image(data: diffHead, fileExtension: "png", suggestedName: "C"))
        let itemTail = ShelfItem(kind: .image(data: diffTail, fileExtension: "png", suggestedName: "D"))
        let itemLen = ShelfItem(kind: .image(data: diffLength, fileExtension: "png", suggestedName: "E"))

        XCTAssertEqual(itemBase1.dedupeKey, itemBase2.dedupeKey)
        XCTAssertNotEqual(itemBase1.dedupeKey, itemHead.dedupeKey)
        XCTAssertNotEqual(itemBase1.dedupeKey, itemTail.dedupeKey)
        XCTAssertNotEqual(itemBase1.dedupeKey, itemLen.dedupeKey)
    }

    func testCopyToGeneralPasteboardProvidesEagerPNGAndLazyTIFFWithoutEvictingMultiItems() throws {
        let png1 = try makeValidPNGData(width: 32, height: 32)
        let png2 = try makeValidPNGData(width: 48, height: 24)

        let pb = NSPasteboard.withUniqueName()
        let item1 = ShelfItem(kind: .image(data: png1, fileExtension: "png", suggestedName: "One"))
        item1.copyToGeneralPasteboard(pasteboard: pb)

        XCTAssertEqual(pb.data(forType: .png), png1)
        XCTAssertEqual(LazyImagePasteboardDataProvider.activeProviderCount(for: pb), 1)

        // Requesting TIFF materializes it on demand via the lazy data provider.
        let lazyTiff = try XCTUnwrap(pb.data(forType: .tiff))
        XCTAssertFalse(lazyTiff.isEmpty)
        XCTAssertEqual(ThumbnailGenerator.imagePixelDimensions(from: lazyTiff)?.width, 32)

        // Multi-item copy on the same pasteboard generation keeps both providers alive.
        let multiPB = NSPasteboard.withUniqueName()
        multiPB.clearContents()
        let pair1 = ShelfItem.makeLazyImagePasteboardItem(data: png1, fileExtension: "png", pasteboard: multiPB)
        let pair2 = ShelfItem.makeLazyImagePasteboardItem(data: png2, fileExtension: "png", pasteboard: multiPB)
        multiPB.writeObjects([pair1.item, pair2.item])
        if let p1 = pair1.provider { LazyImagePasteboardDataProvider.register(p1, on: multiPB) }
        if let p2 = pair2.provider { LazyImagePasteboardDataProvider.register(p2, on: multiPB) }

        XCTAssertEqual(LazyImagePasteboardDataProvider.activeProviderCount(for: multiPB), 2)
        let items = try XCTUnwrap(multiPB.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertNotNil(items[0].data(forType: .tiff))
        XCTAssertNotNil(items[1].data(forType: .tiff))
    }

    func testQuickLookRapidSelectionSyncCancelsStaleExportsAndLeaksNoTempDirs() throws {
        let store = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let shelfWindow = ShelfWindow(
            shelfID: store.id,
            stagingDirectory: store.stagingDirectory,
            stagingRoot: stagingRoot,
            contentRect: NSRect(x: 120, y: 120, width: 280, height: 200)
        )
        defer {
            ShelfQuickLookController.shared.closeAndCleanup(synchronous: true)
            shelfWindow.teardown()
        }

        shelfWindow.prepareForShow()
        shelfWindow.orderFrontRegardless()

        let items = (1...5).map { idx in
            ShelfItem(kind: .text(plain: "Rapid Quick Look Item \(idx)", rtfData: nil, title: "Item \(idx)"))
        }

        ShelfQuickLookController.shared.showPreview(
            items: [items[0]],
            forShelfID: store.id,
            stagingRoot: stagingRoot,
            sourceWindow: shelfWindow
        )
        ShelfQuickLookController.shared.waitForPendingExport()

        // Simulate rapid arrow-key stepping across items 1 -> 2 -> 3 -> 4 without waiting.
        for idx in 1..<items.count {
            ShelfQuickLookController.shared.syncSelectionIfPreviewing(items: [items[idx]], forShelfID: store.id)
        }
        ShelfQuickLookController.shared.waitForPendingExport()
        ShelfQuickLookController.waitForPendingCleanup()

        let active = try XCTUnwrap(ShelfQuickLookController.shared.activeSession)
        XCTAssertEqual(active.items.map(\.itemID), [items[4].id])

        let previewRoot = stagingRoot.appendingPathComponent(
            ShelfQuickLookController.previewSubdirectoryName,
            isDirectory: true
        )
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: previewRoot.path)) ?? []
        XCTAssertEqual(dirs.count, 1, "Only the active Quick Look session directory should remain on disk")
    }

    // MARK: - PERF-05

    func testShowForEdgeDragCancelsInFlightHideGenerationRace() throws {
        let manager = ShelfManager(stagingRoot: stagingRoot, startTriggers: false)
        defer { manager.shutdown() }

        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let shelf = try XCTUnwrap(manager.createManualShelf(edge: .right))
        let shelfID = shelf.id
        let center = NSPoint(x: shelf.panel.frame.midX, y: shelf.panel.frame.midY)

        // Start animated close (0.16s animation, removeAfterHide: true).
        manager.closeShelf(id: shelfID, animated: true)

        // Immediately re-enter via edge drag before the 0.16s animation finishes.
        manager.showForEdgeDrag(edge: .right, cursorLocation: center, screen: screen)

        // Pump main runloop past the 0.16s animation duration so any stale finalize() would have fired.
        RunLoop.main.run(until: Date().addingTimeInterval(0.30))
        ShelfStore.waitForPendingCleanup()

        XCTAssertTrue(manager.shelves.contains(where: { $0.id == shelfID }), "Shelf must not be removed mid-drop by stale hide finalize")
        XCTAssertTrue(shelf.isVisible)
        XCTAssertEqual(shelf.panel.alphaValue, 1.0, accuracy: 0.01)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shelf.store.stagingDirectory.path))
    }

    // MARK: - PERF-06

    func testShelfStoreCoalescesMetadataUpdatesIntoSingleEmission() throws {
        let store = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let items = (1...3).map { i in
            ShelfItem(kind: .text(plain: "Item \(i)", rtfData: nil, title: "T\(i)"))
        }
        store.addMany(items)

        var emissions = 0
        let cancellable = store.$items
            .dropFirst()
            .sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        let img = NSImage(size: NSSize(width: 16, height: 16))
        for (idx, item) in items.enumerated() {
            store.enqueueMetadataUpdate(id: item.id, subtitle: "Sub \(idx)")
            store.enqueueMetadataUpdate(id: item.id, thumbnail: img)
        }
        XCTAssertEqual(emissions, 0, "Pending updates should be buffered until batch flush")

        store.flushPendingMetadataUpdates()
        XCTAssertEqual(emissions, 1, "All 6 metadata updates should coalesce into 1 @Published emission")
        XCTAssertEqual(store.items.map(\.subtitle), ["Sub 0", "Sub 1", "Sub 2"])
        XCTAssertTrue(store.items.allSatisfy { $0.thumbnail != nil })
    }

    // MARK: - PERF-07

    func testTriggerEngineDynamicallyGatesHotkeyAndDragMonitors() {
        let settings = AppSettings.shared
        let prevEdge = settings.edgeEnabled
        let prevShake = settings.shakeEnabled
        let prevHotkey = settings.hotkeyEnabled
        defer {
            settings.edgeEnabled = prevEdge
            settings.shakeEnabled = prevShake
            settings.hotkeyEnabled = prevHotkey
        }

        settings.edgeEnabled = false
        settings.shakeEnabled = false
        settings.hotkeyEnabled = false

        let engine = TriggerEngine()
        engine.start()
        defer { engine.stop() }

        XCTAssertFalse(engine.isDragMonitoringActive)
        XCTAssertFalse(engine.isHotkeyMonitoringActive)

        // Toggle hotkey on/off independently.
        settings.hotkeyEnabled = true
        XCTAssertTrue(engine.isHotkeyMonitoringActive)
        XCTAssertFalse(engine.isDragMonitoringActive)

        settings.hotkeyEnabled = false
        XCTAssertFalse(engine.isHotkeyMonitoringActive)

        // Toggle shake on/off -> activates/deactivates GlobalDragMonitor.
        settings.shakeEnabled = true
        XCTAssertTrue(engine.isDragMonitoringActive)

        settings.shakeEnabled = false
        XCTAssertFalse(engine.isDragMonitoringActive)

        // Toggle edge on/off -> activates/deactivates GlobalDragMonitor.
        settings.edgeEnabled = true
        XCTAssertTrue(engine.isDragMonitoringActive)

        settings.edgeEnabled = false
        XCTAssertFalse(engine.isDragMonitoringActive)
    }

    // MARK: - PERF-10

    func testShelfCloseTeardownClearsClosuresContentViewAndPurgesQuickLookAnchors() throws {
        let manager = ShelfManager(stagingRoot: stagingRoot, startTriggers: false)
        defer { manager.shutdown() }

        let shelf1 = try XCTUnwrap(manager.createManualShelf(edge: .right))
        let shelf2 = try XCTUnwrap(manager.createManualShelf(edge: .left))

        let anchor1 = ShelfItemIconAnchorNSView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        let anchor2 = ShelfItemIconAnchorNSView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        let item1ID = UUID()
        let item2ID = UUID()
        ShelfQuickLookController.shared.registerIconAnchor(
            anchor1,
            for: .init(shelfID: shelf1.id, itemID: item1ID)
        )
        ShelfQuickLookController.shared.registerIconAnchor(
            anchor2,
            for: .init(shelfID: shelf2.id, itemID: item2ID)
        )
        defer {
            ShelfQuickLookController.shared.purgeAnchors(forShelfID: shelf1.id)
            ShelfQuickLookController.shared.purgeAnchors(forShelfID: shelf2.id)
        }

        XCTAssertEqual(ShelfQuickLookController.shared.registeredAnchorCount(forShelfID: shelf1.id), 1)
        XCTAssertEqual(ShelfQuickLookController.shared.registeredAnchorCount(forShelfID: shelf2.id), 1)

        manager.closeShelf(id: shelf1.id, animated: false)
        ShelfStore.waitForPendingCleanup()

        XCTAssertNil(shelf1.panel.contentView)
        XCTAssertNil(shelf1.panel.onQuickLookRequested)
        XCTAssertNil(shelf1.panel.dropContainerView.onItemsDropped)
        XCTAssertTrue(shelf1.cancellables.isEmpty)
        XCTAssertFalse(shelf1.panel.isReleasedWhenClosed)
        XCTAssertEqual(ShelfQuickLookController.shared.registeredAnchorCount(forShelfID: shelf1.id), 0)
        XCTAssertEqual(ShelfQuickLookController.shared.registeredAnchorCount(forShelfID: shelf2.id), 1)
    }

    // MARK: - Scroll Hover & App Version

    func testRowHoverCoordinatorEnforcesSingleRowAndReconcilesAfterScroll() throws {
        let store = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let shelfWindow = ShelfWindow(
            shelfID: store.id,
            stagingDirectory: store.stagingDirectory,
            stagingRoot: stagingRoot,
            contentRect: NSRect(x: 200, y: 200, width: 282, height: 260)
        )
        defer { shelfWindow.teardown() }

        shelfWindow.prepareForShow()
        shelfWindow.orderFrontRegardless()

        let coordinator = ShelfRowHoverCoordinator()
        let rowIDs = [UUID(), UUID(), UUID()]
        var views: [ShelfRowHoverTrackerNSView] = []
        for (idx, rowID) in rowIDs.enumerated() {
            let rowView = ShelfRowHoverTrackerNSView(
                frame: NSRect(x: 8, y: CGFloat(10 + idx * 56), width: 266, height: 48)
            )
            rowView.configure(itemID: rowID, coordinator: coordinator)
            shelfWindow.dropContainerView.addSubview(rowView)
            views.append(rowView)
        }

        // Entering row 1 then row 2 without mouseExited on row 1 leaves ONLY row 2 hovered.
        coordinator.setHovered(itemID: rowIDs[0], isHovered: true)
        XCTAssertEqual(coordinator.hoveredItemID, rowIDs[0])

        coordinator.setHovered(itemID: rowIDs[1], isHovered: true)
        XCTAssertEqual(coordinator.hoveredItemID, rowIDs[1])

        // Reconciling with live pointer over row 3 switches hover exclusively to row 3.
        let row3CenterInWindow = views[2].convert(NSPoint(x: 100, y: 24), to: nil)
        let row3CenterScreen = shelfWindow.convertToScreen(NSRect(origin: row3CenterInWindow, size: .zero)).origin
        coordinator.reconcileWithLivePointer(at: row3CenterScreen)
        XCTAssertEqual(coordinator.hoveredItemID, rowIDs[2])

        // Moving pointer outside the shelf clears hover cleanly.
        let outsidePoint = NSPoint(x: shelfWindow.frame.minX - 50, y: shelfWindow.frame.minY - 50)
        coordinator.reconcileWithLivePointer(at: outsidePoint)
        XCTAssertNil(coordinator.hoveredItemID)

        // Auto-hidden shelves never report hovered rows.
        shelfWindow.dropContainerView.highlightState.isAutoHidden = true
        coordinator.reconcileWithLivePointer(at: row3CenterScreen)
        XCTAssertNil(coordinator.hoveredItemID)
    }

    func testHostAppMarketingVersionIs101() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertEqual(version, "1.0.1")
    }

    func testEdgeCreationSensitivityZonesAndPersistence() {
        // Low matches original constants exactly.
        XCTAssertEqual(EdgeCreationSensitivity.low.outerEdgeZone, 20.0)
        XCTAssertEqual(EdgeCreationSensitivity.low.sharedEdgeZone, 8.0)
        XCTAssertEqual(EdgeCreationSensitivity.low.rearmDistance, 70.0)

        // Medium (~10% of shelf width / Color Only tab) & High (~20% of shelf width / Shelf Number tab).
        XCTAssertEqual(EdgeCreationSensitivity.medium.outerEdgeZone, 28.0)
        XCTAssertEqual(EdgeCreationSensitivity.high.outerEdgeZone, 56.0)
        XCTAssertGreaterThan(EdgeCreationSensitivity.high.rearmDistance, EdgeCreationSensitivity.high.outerEdgeZone)

        // At 26 pt from right outer edge: Low does not trigger, Medium & High do trigger.
        XCTAssertNil(EdgeTrigger.evaluateMatchedEdge(
            distToLeft: 800,
            distToRight: 26,
            hasLeftAdjacent: false,
            hasRightAdjacent: false,
            leftAllowed: true,
            rightAllowed: true,
            sensitivity: .low
        ))
        XCTAssertEqual(EdgeTrigger.evaluateMatchedEdge(
            distToLeft: 800,
            distToRight: 26,
            hasLeftAdjacent: false,
            hasRightAdjacent: false,
            leftAllowed: true,
            rightAllowed: true,
            sensitivity: .medium
        )?.0, .right)
        XCTAssertEqual(EdgeTrigger.evaluateMatchedEdge(
            distToLeft: 800,
            distToRight: 26,
            hasLeftAdjacent: false,
            hasRightAdjacent: false,
            leftAllowed: true,
            rightAllowed: true,
            sensitivity: .high
        )?.0, .right)

        // At 54 pt from left outer edge: Low & Medium do not trigger, High does trigger.
        XCTAssertNil(EdgeTrigger.evaluateMatchedEdge(
            distToLeft: 54,
            distToRight: 800,
            hasLeftAdjacent: false,
            hasRightAdjacent: false,
            leftAllowed: true,
            rightAllowed: true,
            sensitivity: .medium
        ))
        XCTAssertEqual(EdgeTrigger.evaluateMatchedEdge(
            distToLeft: 54,
            distToRight: 800,
            hasLeftAdjacent: false,
            hasRightAdjacent: false,
            leftAllowed: true,
            rightAllowed: true,
            sensitivity: .high
        )?.0, .left)

        // Verify persistence in UserDefaults via AppSettings.shared.
        let defaults = UserDefaults.standard
        let key = "edgeCreationSensitivity"
        let hadExisting = defaults.object(forKey: key) != nil
        let previous = AppSettings.shared.edgeCreationSensitivity
        defer {
            AppSettings.shared.edgeCreationSensitivity = previous
            if !hadExisting {
                defaults.removeObject(forKey: key)
            }
        }

        AppSettings.shared.edgeCreationSensitivity = .high
        XCTAssertEqual(defaults.string(forKey: key), "high")
        AppSettings.shared.edgeCreationSensitivity = .medium
        XCTAssertEqual(defaults.string(forKey: key), "medium")
        AppSettings.shared.edgeCreationSensitivity = .low
        XCTAssertEqual(defaults.string(forKey: key), "low")
    }

    func testUnifiedAutoHideStylesAndUpdatedDefaults() {
        XCTAssertEqual(
            AutoHideTabStyle.allCases.map(\.displayName),
            ["Standard", "Icons", "Shelf Number", "Handle Bar"]
        )
        XCTAssertFalse(AutoHideTabStyle.standard.usesCustomTabOverlay)
        XCTAssertTrue(AutoHideTabStyle.fileIcons.usesCustomTabOverlay)
        XCTAssertTrue(AutoHideTabStyle.shelfNumber.usesCustomTabOverlay)
        XCTAssertTrue(AutoHideTabStyle.minimalColor.usesCustomTabOverlay)

        XCTAssertEqual(Constants.Shelf.autoHideVisibleWidth(style: .standard), 56)
        XCTAssertEqual(Constants.Shelf.autoHideVisibleWidth(style: .fileIcons), 54)
        XCTAssertEqual(Constants.Shelf.autoHideVisibleWidth(style: .shelfNumber), 54)
        XCTAssertEqual(Constants.Shelf.autoHideVisibleWidth(style: .minimalColor), 26)

        // Fresh UserDefaults resolves to the new defaults:
        // Auto Hide ON, Handle Bar (.minimalColor), Shelf Color Variation Low.
        let suiteName = "com.local.Droptop.DefaultsTest.\(UUID().uuidString)"
        let freshDefaults = UserDefaults(suiteName: suiteName)!
        defer { freshDefaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(AppSettings.resolveAutoHideEnabled(in: freshDefaults))
        XCTAssertEqual(AppSettings.resolveAutoHideTabStyle(in: freshDefaults), .minimalColor)
        XCTAssertEqual(AppSettings.resolveColorVariationLevel(in: freshDefaults), .low)

        // Legacy preference migration: users who previously had Clean Auto hide disabled
        // map seamlessly to the new "Standard" option.
        freshDefaults.set(false, forKey: "prettyAutoHideTab")
        freshDefaults.set("fileIcons", forKey: "autoHideTabStyle")
        XCTAssertEqual(AppSettings.resolveAutoHideTabStyle(in: freshDefaults), .standard)

        // Once prettyAutoHideTab is true, the chosen custom style is respected.
        freshDefaults.set(true, forKey: "prettyAutoHideTab")
        XCTAssertEqual(AppSettings.resolveAutoHideTabStyle(in: freshDefaults), .fileIcons)

        // Explicitly saved "standard" always resolves to .standard.
        freshDefaults.set("standard", forKey: "autoHideTabStyle")
        XCTAssertEqual(AppSettings.resolveAutoHideTabStyle(in: freshDefaults), .standard)

        // Explicit color variation level overrides default.
        freshDefaults.set("off", forKey: "colorVariationLevel")
        XCTAssertEqual(AppSettings.resolveColorVariationLevel(in: freshDefaults), .off)
    }

    func testRandomThemePoolsRespectModeAndSystemAppearance() {
        XCTAssertEqual(
            ShelfTheme.adaptiveThemes,
            [.systemGlass, .random, .randomLight, .randomDark, .randomSystem]
        )
        XCTAssertEqual(ShelfTheme.darkThemes.count, 50)
        XCTAssertEqual(ShelfTheme.lightThemes.count, 50)
        XCTAssertEqual(ShelfTheme.concreteThemes.count, 101)

        let randomModes: Set<ShelfTheme> = [.random, .randomLight, .randomDark, .randomSystem]

        // Random: all concrete themes (System Glass + 50 Dark + 50 Light), never random modes.
        let randomDarkMode = ShelfTheme.random.eligibleRandomThemes(isSystemDarkMode: true)
        let randomLightMode = ShelfTheme.random.eligibleRandomThemes(isSystemDarkMode: false)
        XCTAssertEqual(Set(randomDarkMode), Set(ShelfTheme.concreteThemes))
        XCTAssertEqual(Set(randomLightMode), Set(ShelfTheme.concreteThemes))
        XCTAssertTrue(Set(randomDarkMode).isDisjoint(with: randomModes))

        // Random Dark: all dark themes + System Glass ONLY when macOS is in Dark Mode.
        let randDarkInDark = Set(ShelfTheme.randomDark.eligibleRandomThemes(isSystemDarkMode: true))
        let randDarkInLight = Set(ShelfTheme.randomDark.eligibleRandomThemes(isSystemDarkMode: false))
        XCTAssertEqual(randDarkInDark, Set(ShelfTheme.darkThemes).union([.systemGlass]))
        XCTAssertEqual(randDarkInLight, Set(ShelfTheme.darkThemes))
        XCTAssertFalse(randDarkInLight.contains(.systemGlass))
        XCTAssertTrue(randDarkInDark.isDisjoint(with: randomModes))

        // Random Light: all light themes + System Glass ONLY when macOS is in Light Mode.
        let randLightInDark = Set(ShelfTheme.randomLight.eligibleRandomThemes(isSystemDarkMode: true))
        let randLightInLight = Set(ShelfTheme.randomLight.eligibleRandomThemes(isSystemDarkMode: false))
        XCTAssertEqual(randLightInDark, Set(ShelfTheme.lightThemes))
        XCTAssertFalse(randLightInDark.contains(.systemGlass))
        XCTAssertEqual(randLightInLight, Set(ShelfTheme.lightThemes).union([.systemGlass]))
        XCTAssertTrue(randLightInLight.isDisjoint(with: randomModes))

        // Random System: Dark themes in Dark Mode, Light themes in Light Mode, ALWAYS includes System Glass.
        let randSystemInDark = Set(ShelfTheme.randomSystem.eligibleRandomThemes(isSystemDarkMode: true))
        let randSystemInLight = Set(ShelfTheme.randomSystem.eligibleRandomThemes(isSystemDarkMode: false))
        XCTAssertEqual(randSystemInDark, Set(ShelfTheme.darkThemes).union([.systemGlass]))
        XCTAssertEqual(randSystemInLight, Set(ShelfTheme.lightThemes).union([.systemGlass]))
        XCTAssertTrue(randSystemInDark.isDisjoint(with: randomModes))
        XCTAssertTrue(randSystemInLight.isDisjoint(with: randomModes))
    }

    func testRandomThemePickerAvoidsSameColorFamilyAndNeverRunsOut() {
        let picker = ShelfThemeRandomPicker()

        // 1. Concurrent open shelves: opening 10 shelves in `.random` uses all 10 distinct color families.
        var openThemes: [ShelfTheme] = []
        for _ in 0..<10 {
            let picked = picker.pickTheme(for: .random, activeThemes: openThemes, isSystemDarkMode: true)
            XCTAssertFalse(picked.isRandomTheme)
            openThemes.append(picked)
        }
        XCTAssertEqual(Set(openThemes.map(\.colorFamily)).count, ThemeColorFamily.allCases.count)

        // 2. Opening 15 MORE shelves (25 total > 10 families) never runs out and keeps families balanced.
        for _ in 0..<15 {
            let previousFamily = openThemes.last?.colorFamily
            let picked = picker.pickTheme(for: .random, activeThemes: openThemes, isSystemDarkMode: true)
            XCTAssertFalse(picked.isRandomTheme)
            XCTAssertNotEqual(picked.colorFamily, previousFamily)
            openThemes.append(picked)
        }
        let familyCounts = Dictionary(grouping: openThemes, by: \.colorFamily).mapValues(\.count)
        let minCount = familyCounts.values.min() ?? 0
        let maxCount = familyCounts.values.max() ?? 0
        XCTAssertLessThanOrEqual(maxCount - minCount, 1)

        // 3. Sequential single-shelf opens (empty activeThemes) cycle through all available families
        //    without repeating until wrap-around, and never repeat back-to-back across wrap-around.
        picker.reset()
        let darkLightModeFamilies = Set(
            ShelfTheme.randomDark.eligibleRandomThemes(isSystemDarkMode: false).map(\.colorFamily)
        )
        XCTAssertEqual(darkLightModeFamilies.count, 9) // All 9 non-glass families

        var firstCycle: [ShelfTheme] = []
        for _ in 0..<darkLightModeFamilies.count {
            let picked = picker.pickTheme(for: .randomDark, activeThemes: [], isSystemDarkMode: false)
            XCTAssertNotEqual(picked, .systemGlass)
            XCTAssertFalse(picked.isLightTheme)
            firstCycle.append(picked)
        }
        XCTAssertEqual(Set(firstCycle.map(\.colorFamily)).count, darkLightModeFamilies.count)

        let wrappedPick = picker.pickTheme(for: .randomDark, activeThemes: [], isSystemDarkMode: false)
        XCTAssertNotEqual(wrappedPick.colorFamily, firstCycle.last?.colorFamily)
    }

    func testShelfManagerAssignsDistinctRandomThemesAndClearsOnFixedTheme() {
        let defaults = UserDefaults.standard
        let themeKey = "shelfTheme"
        let hadExistingTheme = defaults.object(forKey: themeKey) != nil
        let previousTheme = AppSettings.shared.shelfTheme
        defer {
            AppSettings.shared.shelfTheme = previousTheme
            if !hadExistingTheme {
                defaults.removeObject(forKey: themeKey)
            }
        }

        let manager = ShelfManager(stagingRoot: stagingRoot, startTriggers: false)
        defer { manager.shutdown() }

        AppSettings.shared.shelfTheme = .random
        let shelf1 = manager.createManualShelf(edge: .right)
        let shelf2 = manager.createManualShelf(edge: .right)
        let shelf3 = manager.createManualShelf(edge: .right)

        guard let t1 = shelf1?.store.assignedRandomTheme,
              let t2 = shelf2?.store.assignedRandomTheme,
              let t3 = shelf3?.store.assignedRandomTheme else {
            return XCTFail("Expected each shelf opened in Random mode to receive a concrete assigned theme")
        }
        XCTAssertFalse(t1.isRandomTheme)
        XCTAssertFalse(t2.isRandomTheme)
        XCTAssertFalse(t3.isRandomTheme)
        XCTAssertEqual(Set([t1.colorFamily, t2.colorFamily, t3.colorFamily]).count, 3)

        // Switching to a fixed theme clears assignedRandomTheme on open shelves.
        AppSettings.shared.shelfTheme = .midnight
        XCTAssertNil(shelf1?.store.assignedRandomTheme)
        XCTAssertNil(shelf2?.store.assignedRandomTheme)
        XCTAssertNil(shelf3?.store.assignedRandomTheme)
        XCTAssertEqual(shelf1?.store.effectiveTheme(for: .midnight), .midnight)

        // Switching back to a random mode assigns fresh distinct-family random themes to already-open shelves.
        AppSettings.shared.shelfTheme = .randomLight
        let r1 = shelf1?.store.assignedRandomTheme
        let r2 = shelf2?.store.assignedRandomTheme
        let r3 = shelf3?.store.assignedRandomTheme
        XCTAssertNotNil(r1)
        XCTAssertNotNil(r2)
        XCTAssertNotNil(r3)
        if let r1, let r2, let r3 {
            XCTAssertEqual(Set([r1.colorFamily, r2.colorFamily, r3.colorFamily]).count, 3)
            let eligible = Set(ShelfTheme.randomLight.eligibleRandomThemes(isSystemDarkMode: ShelfTheme.isSystemDarkMode))
            XCTAssertTrue(eligible.contains(r1))
            XCTAssertTrue(eligible.contains(r2))
            XCTAssertTrue(eligible.contains(r3))
        }
    }
}
