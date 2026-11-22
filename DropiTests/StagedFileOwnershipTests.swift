import AppKit
import Foundation
import XCTest
@testable import Droptop

@MainActor
final class StagedFileOwnershipTests: XCTestCase {
    private var tempBaseDir: URL!
    private var stagingRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ShelfStore.clearClipboardRetention()
        tempBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroptopTests-SEC01-\(UUID().uuidString)", isDirectory: true)
        stagingRoot = tempBaseDir
            .appendingPathComponent("Droptop", isDirectory: true)
            .appendingPathComponent("Promises", isDirectory: true)
        try ShelfStore.ensureStagingRootDirectory(at: stagingRoot)
    }

    override func tearDownWithError() throws {
        ShelfStore.waitForPendingCleanup()
        ShelfStore.clearClipboardRetention()
        SelfDragState.end()
        try? FileManager.default.removeItem(at: tempBaseDir)
        try super.tearDownWithError()
    }

    func testShelfToShelfDragTransfersOwnershipAndSurvivesSourceShelfClose() throws {
        let shelfA = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let shelfB = ShelfStore(shelfNumber: 2, stagingRoot: stagingRoot)

        // Stage a simulated screenshot promise inside Shelf A.
        let batchA = shelfA.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ShelfStore.ensurePrivateDirectory(at: batchA)
        let stagedFileA = batchA.appendingPathComponent("Screenshot.png")
        let payload = Data("fake-png-bytes".utf8)
        try payload.write(to: stagedFileA)

        let itemA = ShelfItem.fromFileURL(stagedFileA, isTemporaryCopy: true)
        XCTAssertTrue(itemA.isTemporaryCopy)
        XCTAssertTrue(shelfA.add(itemA))

        // Simulate Shelf A -> Shelf B drag via a unique pasteboard.
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([stagedFileA as NSURL])

        SelfDragState.begin(fromShelf: shelfA.id)
        var extractedForB: [ShelfItem] = []
        let accepted = PasteboardHandler.extractItems(
            from: pb,
            stagingDirectory: shelfB.stagingDirectory,
            stagingRoot: stagingRoot
        ) { items in
            extractedForB = items
        }
        let adoptedPaths = SelfDragState.consumeAdoptedStagedSourcePaths()
        SelfDragState.end()

        XCTAssertTrue(accepted)
        XCTAssertEqual(extractedForB.count, 1)
        let itemB = try XCTUnwrap(extractedForB.first)
        XCTAssertTrue(itemB.isTemporaryCopy)
        let stagedFileB = try XCTUnwrap(itemB.temporaryFileURL)
        XCTAssertNotEqual(
            stagedFileB.standardizedFileURL.resolvingSymlinksInPath(),
            stagedFileA.standardizedFileURL.resolvingSymlinksInPath()
        )
        XCTAssertTrue(
            stagedFileB.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(
                shelfB.stagingDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            )
        )
        XCTAssertEqual(adoptedPaths, [stagedFileA.standardizedFileURL.resolvingSymlinksInPath().path])

        // Shelf A removes dragged-out item and closes (autoHideWhenEmpty).
        shelfA.removeDraggedOut([itemA.id], adoptedSourcePaths: adoptedPaths)
        shelfA.cleanupStagingDirectory(synchronous: true)

        // Shelf A's directory is cleaned up while Shelf B's copy stays intact.
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelfA.stagingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFileB.path))
        XCTAssertEqual(try Data(contentsOf: stagedFileB), payload)
    }

    func testSameShelfPasteDoesNotDuplicateStagedFile() throws {
        let shelfA = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let batchA = shelfA.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ShelfStore.ensurePrivateDirectory(at: batchA)
        let stagedFileA = batchA.appendingPathComponent("Clip.png")
        try Data("clip".utf8).write(to: stagedFileA)

        let adopted = PasteboardHandler.adoptStagedFileIfNeeded(
            stagedFileA,
            into: shelfA.stagingDirectory,
            stagingRoot: stagingRoot
        )
        XCTAssertTrue(adopted.isTemporaryCopy)
        XCTAssertNil(adopted.adoptedSourcePath)
        XCTAssertEqual(
            adopted.url.standardizedFileURL.resolvingSymlinksInPath(),
            stagedFileA.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testExternalAndSiblingPrefixFilesAreNotTreatedAsStaged() throws {
        let shelf = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)

        // Sibling directory whose path starts with `<stagingRoot.path>` without a trailing `/`.
        let evilSibling = stagingRoot.deletingLastPathComponent()
            .appendingPathComponent("PromisesEvil", isDirectory: true)
        try FileManager.default.createDirectory(at: evilSibling, withIntermediateDirectories: true)
        let externalFile = evilSibling.appendingPathComponent("notes.txt")
        try Data("user-file".utf8).write(to: externalFile)

        let adopted = PasteboardHandler.adoptStagedFileIfNeeded(
            externalFile,
            into: shelf.stagingDirectory,
            stagingRoot: stagingRoot
        )
        XCTAssertFalse(adopted.isTemporaryCopy)
        XCTAssertNil(adopted.adoptedSourcePath)
        XCTAssertEqual(
            adopted.url.standardizedFileURL.resolvingSymlinksInPath(),
            externalFile.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testExternalDragOutRetainsTemporaryCopyAcrossAutoCloseUntilFullSweep() throws {
        let shelf = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)

        let batchDragged = shelf.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let batchDiscarded = shelf.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ShelfStore.ensurePrivateDirectory(at: batchDragged)
        try ShelfStore.ensurePrivateDirectory(at: batchDiscarded)

        let draggedFile = batchDragged.appendingPathComponent("MailAttachment.png")
        let discardedFile = batchDiscarded.appendingPathComponent("Unused.png")
        try Data("important".utf8).write(to: draggedFile)
        try Data("discard".utf8).write(to: discardedFile)

        let draggedItem = ShelfItem.fromFileURL(draggedFile, isTemporaryCopy: true)
        let discardedItem = ShelfItem.fromFileURL(discardedFile, isTemporaryCopy: true)
        shelf.addMany([draggedItem, discardedItem])

        // Dragged out to an external app (no internal shelf adoption).
        shelf.removeDraggedOut([draggedItem.id], adoptedSourcePaths: [])
        XCTAssertEqual(shelf.items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draggedFile.path))

        // Explicitly remove the second item -> deleted immediately.
        shelf.remove(discardedItem)
        ShelfStore.waitForPendingCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: discardedFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: batchDiscarded.path))

        // Shelf closes (e.g. autoHideWhenEmpty) -> dragged-out file MUST survive for external app.
        shelf.cleanupStagingDirectory(synchronous: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draggedFile.path))

        // App quit / next launch sweep removes everything.
        ShelfStore.cleanupAllStagingDirectories(at: stagingRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draggedFile.path))
    }

    func testClipboardCopiedTemporaryFileSurvivesClearAndCloseUntilClipboardChanges() throws {
        let shelf = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let batch = shelf.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ShelfStore.ensurePrivateDirectory(at: batch)
        let tempFile = batch.appendingPathComponent("CopiedShot.png")
        try Data("copied".utf8).write(to: tempFile)

        let item = ShelfItem.fromFileURL(tempFile, isTemporaryCopy: true)
        shelf.add(item)

        let pb = NSPasteboard.withUniqueName()
        item.copyToGeneralPasteboard(pasteboard: pb)

        // Clearing and closing while clipboard still points to tempFile keeps it alive.
        shelf.clearAll()
        ShelfStore.waitForPendingCleanup()
        shelf.cleanupStagingDirectory(synchronous: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path))

        // Once clipboard changes to something else, cleanup removes the staged directory.
        pb.clearContents()
        pb.setString("something else", forType: .string)
        shelf.cleanupStagingDirectory(synchronous: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
    }

    func testOutsideApplicationDragMaskDropsLinkAndMoveForTemporaryCopies() {
        let tempMask = ShelfDragSourceNSView.outsideApplicationOperationMask(containsTemporaryCopy: true)
        XCTAssertEqual(tempMask, [.copy, .generic])
        XCTAssertFalse(tempMask.contains(.link))
        XCTAssertFalse(tempMask.contains(.move))

        let normalMask = ShelfDragSourceNSView.outsideApplicationOperationMask(containsTemporaryCopy: false)
        XCTAssertEqual(normalMask, [.copy, .move, .link, .generic])
    }
}
