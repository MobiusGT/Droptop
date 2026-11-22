import AppKit
import Foundation
import XCTest
@testable import Droptop

@MainActor
final class StagingSecurityTests: XCTestCase {
    private var tempBaseDir: URL!
    private var stagingRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ShelfStore.clearClipboardRetention()
        tempBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroptopTests-SEC04-\(UUID().uuidString)", isDirectory: true)
        stagingRoot = tempBaseDir
            .appendingPathComponent("Droptop", isDirectory: true)
            .appendingPathComponent("Promises", isDirectory: true)
    }

    override func tearDownWithError() throws {
        ShelfStore.waitForPendingCleanup()
        ShelfStore.clearClipboardRetention()
        try? FileManager.default.removeItem(at: tempBaseDir)
        try super.tearDownWithError()
    }

    func testStagingRootAndShelfDirectoryHave0700Permissions() throws {
        try ShelfStore.ensureStagingRootDirectory(at: stagingRoot)
        let store = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)

        let parentAttrs = try FileManager.default.attributesOfItem(atPath: stagingRoot.deletingLastPathComponent().path)
        let rootAttrs = try FileManager.default.attributesOfItem(atPath: stagingRoot.path)
        let shelfAttrs = try FileManager.default.attributesOfItem(atPath: store.stagingDirectory.path)

        XCTAssertEqual((parentAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((rootAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((shelfAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testPreExistingLooseStagingRootIsTightenedTo0700() throws {
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingRoot.path)

        try ShelfStore.ensureStagingRootDirectory(at: stagingRoot)

        let rootAttrs = try FileManager.default.attributesOfItem(atPath: stagingRoot.path)
        XCTAssertEqual((rootAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testStartupSweepRemovesStaleCrashLeftovers() throws {
        let staleDir = stagingRoot.appendingPathComponent("stale-session-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)
        let staleFile = staleDir.appendingPathComponent("PhotosExport.heic")
        try Data("sensitive-photo".utf8).write(to: staleFile)

        XCTAssertTrue(FileManager.default.fileExists(atPath: staleFile.path))

        ShelfStore.cleanupAllStagingDirectories(at: stagingRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    func testCreateShelfFromClipboardUsesShelfStagingAndClosesWhenEmpty() throws {
        let manager = ShelfManager(stagingRoot: stagingRoot, startTriggers: false)
        defer { manager.shutdown() }

        // 1. Completely empty clipboard -> creates no shelf and no staging directories.
        let emptyPB = NSPasteboard.withUniqueName()
        emptyPB.clearContents()
        manager.createShelfFromClipboard(from: emptyPB)
        XCTAssertTrue(manager.shelves.isEmpty)

        // 2. Whitespace-only string (canAccept is true, but extractItems yields 0 items)
        //    -> shelf closes cleanly without leaving an empty shelf behind.
        let blankPB = NSPasteboard.withUniqueName()
        blankPB.clearContents()
        blankPB.setString("   \n\t  ", forType: .string)
        manager.createShelfFromClipboard(from: blankPB)
        ShelfStore.waitForPendingCleanup()
        XCTAssertTrue(manager.shelves.isEmpty)

        // 3. Valid clipboard payload -> shelf created, tied to its own staging directory (no clipboard-* dir).
        let textPB = NSPasteboard.withUniqueName()
        textPB.clearContents()
        textPB.setString("Hello Droptop", forType: .string)
        manager.createShelfFromClipboard(from: textPB)

        XCTAssertEqual(manager.shelves.count, 1)
        let createdShelf = try XCTUnwrap(manager.shelves.first)
        XCTAssertEqual(createdShelf.store.items.count, 1)

        let rootEntries = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        XCTAssertFalse(rootEntries.contains(where: { $0.hasPrefix("clipboard-") }))
        XCTAssertTrue(rootEntries.contains(createdShelf.id.uuidString))

        // Closing the shelf cleans up its staging directory.
        manager.closeShelf(id: createdShelf.id, animated: false)
        ShelfStore.waitForPendingCleanup()
        XCTAssertTrue(manager.shelves.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdShelf.store.stagingDirectory.path))
    }
}
