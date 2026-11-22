import AppKit
import Foundation
import QuickLookUI
import XCTest
@testable import Droptop

@MainActor
final class ShelfQuickLookTests: XCTestCase {
    private var tempBaseDir: URL!
    private var stagingRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ShelfQuickLookController.shared.closeAndCleanup(synchronous: true)
        tempBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroptopTests-QuickLook-\(UUID().uuidString)", isDirectory: true)
        stagingRoot = tempBaseDir
            .appendingPathComponent("Droptop", isDirectory: true)
            .appendingPathComponent("Promises", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ShelfQuickLookController.shared.closeAndCleanup(synchronous: true)
        ShelfQuickLookController.waitForPendingCleanup()
        ShelfStore.waitForPendingCleanup()
        try? FileManager.default.removeItem(at: tempBaseDir)
        try super.tearDownWithError()
    }

    func testFileAndFolderResolveDirectlyWithoutTempDirectory() throws {
        let regularFile = tempBaseDir.appendingPathComponent("Report.txt")
        try Data("Quarterly summary".utf8).write(to: regularFile)

        let regularFolder = tempBaseDir.appendingPathComponent("ProjectDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: regularFolder, withIntermediateDirectories: true)

        let fileItem = ShelfItem.fromFileURL(regularFile, isTemporaryCopy: false)
        let folderItem = ShelfItem.fromFileURL(regularFolder, isTemporaryCopy: false)

        let session = try XCTUnwrap(
            ShelfQuickLookController.buildSession(
                for: [fileItem, folderItem],
                shelfID: UUID(),
                stagingRoot: stagingRoot
            )
        )

        XCTAssertNil(session.temporarySessionDirectory)
        XCTAssertEqual(session.items.count, 2)
        XCTAssertEqual(session.items[0].previewItemURL, regularFile.standardizedFileURL)
        XCTAssertEqual(session.items[1].previewItemURL, regularFolder.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    func testStagedTemporaryFileAndFolderResolveDirectlyAndSurviveCleanup() throws {
        let store = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let batchDir = store.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ShelfStore.ensurePrivateDirectory(at: batchDir)

        let stagedFile = batchDir.appendingPathComponent("Screenshot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: stagedFile)

        let stagedFolder = batchDir.appendingPathComponent("ExportedBundle", isDirectory: true)
        try ShelfStore.ensurePrivateDirectory(at: stagedFolder)

        let fileItem = ShelfItem.fromFileURL(stagedFile, isTemporaryCopy: true)
        let folderItem = ShelfItem.fromFileURL(stagedFolder, isTemporaryCopy: true)

        let session = try XCTUnwrap(
            ShelfQuickLookController.buildSession(
                for: [fileItem, folderItem],
                shelfID: store.id,
                stagingRoot: stagingRoot
            )
        )

        XCTAssertNil(session.temporarySessionDirectory)
        XCTAssertEqual(session.items.map(\.previewItemURL), [stagedFile.standardizedFileURL, stagedFolder.standardizedFileURL])

        ShelfQuickLookController.cleanupTemporaryDirectory(session.temporarySessionDirectory, synchronous: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFolder.path))
    }

    func testInMemoryItemsExportIntoPrivate0700DirectoriesAndCleanUp() throws {
        let textItem = ShelfItem(kind: .text(plain: "Quick Look snippet", rtfData: nil, title: "Notes"))
        let rtfPayload = Data("{\\rtf1\\ansi Hello}".utf8)
        let rtfItem = ShelfItem(kind: .text(plain: "Hello", rtfData: rtfPayload, title: "Styled"))
        let imagePayload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let imageItem = ShelfItem(kind: .image(data: imagePayload, fileExtension: "png", suggestedName: "Clip"))
        let urlItem = ShelfItem(kind: .webURL(url: URL(string: "https://example.com/docs")!, title: "Example Docs"))

        let session = try XCTUnwrap(
            ShelfQuickLookController.buildSession(
                for: [textItem, rtfItem, imageItem, urlItem],
                shelfID: UUID(),
                stagingRoot: stagingRoot
            )
        )

        let sessionDir = try XCTUnwrap(session.temporarySessionDirectory)
        let previewRoot = sessionDir.deletingLastPathComponent()

        let rootAttrs = try FileManager.default.attributesOfItem(atPath: stagingRoot.path)
        let previewRootAttrs = try FileManager.default.attributesOfItem(atPath: previewRoot.path)
        let sessionAttrs = try FileManager.default.attributesOfItem(atPath: sessionDir.path)

        XCTAssertEqual((rootAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((previewRootAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((sessionAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        XCTAssertEqual(session.items.count, 4)

        let txtURL = try XCTUnwrap(session.items[0].previewItemURL)
        let rtfURL = try XCTUnwrap(session.items[1].previewItemURL)
        let pngURL = try XCTUnwrap(session.items[2].previewItemURL)
        let weblocURL = try XCTUnwrap(session.items[3].previewItemURL)

        XCTAssertEqual(txtURL.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: txtURL, encoding: .utf8), "Quick Look snippet")

        XCTAssertEqual(rtfURL.pathExtension, "rtf")
        XCTAssertEqual(try Data(contentsOf: rtfURL), rtfPayload)

        XCTAssertEqual(pngURL.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: pngURL), imagePayload)

        XCTAssertEqual(weblocURL.pathExtension, "webloc")
        let weblocData = try Data(contentsOf: weblocURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: weblocData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["URL"] as? String, "https://example.com/docs")

        // Repeated preview of the same items must succeed without SEC-05 overwrite collisions.
        let secondSession = try XCTUnwrap(
            ShelfQuickLookController.buildSession(
                for: [textItem, imageItem],
                shelfID: UUID(),
                stagingRoot: stagingRoot
            )
        )
        XCTAssertEqual(secondSession.items.count, 2)
        XCTAssertNotEqual(sessionDir, secondSession.temporarySessionDirectory)

        ShelfQuickLookController.cleanupTemporaryDirectory(sessionDir, synchronous: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondSession.temporarySessionDirectory!.path))

        ShelfQuickLookController.cleanupTemporaryDirectory(secondSession.temporarySessionDirectory, synchronous: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewRoot.path))
    }

    func testMissingFileURLsAreSkippedGracefully() {
        let missingURL = tempBaseDir.appendingPathComponent("DoesNotExist.pdf")
        let missingItem = ShelfItem(kind: .file(url: missingURL, isTemporaryCopy: false))

        let session = ShelfQuickLookController.buildSession(
            for: [missingItem],
            shelfID: UUID(),
            stagingRoot: stagingRoot
        )
        XCTAssertNil(session)
    }

    func testShelfStoreQuickLookSelectionAndArrowNavigation() {
        let store = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let first = ShelfItem(kind: .text(plain: "First", rtfData: nil, title: "First"))
        let second = ShelfItem(kind: .text(plain: "Second", rtfData: nil, title: "Second"))
        let third = ShelfItem(kind: .text(plain: "Third", rtfData: nil, title: "Third"))

        // Single-item shelf previews its sole item even without explicit selection.
        store.add(first)
        XCTAssertEqual(store.itemsForQuickLook.map(\.id), [first.id])

        // Multi-item shelf with no selection yields empty quick-look list until user selects.
        store.addMany([second, third])
        XCTAssertTrue(store.itemsForQuickLook.isEmpty)

        // Multi-selection preserves shelf order.
        store.handleRowTap(itemID: third.id, commandPressed: false, shiftPressed: false)
        store.handleRowTap(itemID: first.id, commandPressed: true, shiftPressed: false)
        XCTAssertEqual(store.itemsForQuickLook.map(\.id), [first.id, third.id])

        // Arrow navigation steps single-item selection cleanly and clamps at bounds.
        store.deselectAll()
        XCTAssertEqual(store.moveSelection(by: 1).map(\.id), [first.id])
        XCTAssertEqual(store.moveSelection(by: 1).map(\.id), [second.id])
        XCTAssertEqual(store.moveSelection(by: 1).map(\.id), [third.id])
        XCTAssertEqual(store.moveSelection(by: 1).map(\.id), [third.id])
        XCTAssertEqual(store.moveSelection(by: -1).map(\.id), [second.id])
    }

    func testShelfWindowKeyFocusAndSpacebarDispatch() throws {
        let store = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let panel = ShelfWindow(
            shelfID: store.id,
            stagingDirectory: store.stagingDirectory,
            stagingRoot: stagingRoot,
            contentRect: NSRect(x: 100, y: 100, width: 280, height: 200)
        )
        defer {
            panel.prepareForHide()
            panel.orderOut(nil)
        }

        // Non-activating by default: never becomes key or main until explicitly requested.
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)

        panel.prepareForShow()
        panel.orderFrontRegardless()
        XCTAssertFalse(panel.canBecomeKey)

        // Auto-hidden shelves cannot take key focus.
        panel.dropContainerView.highlightState.isAutoHidden = true
        panel.acquireKeyFocusForKeyboard()
        XCTAssertFalse(panel.canBecomeKey)

        // Visible expanded shelf acquires key focus on selection click.
        panel.dropContainerView.highlightState.isAutoHidden = false
        panel.acquireKeyFocusForKeyboard()
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)

        var quickLookCount = 0
        var lastDelta = 0
        panel.onQuickLookRequested = { quickLookCount += 1 }
        panel.onNavigateSelection = { lastDelta = $0 }

        // Bare Spacebar triggers Quick Look.
        let spaceEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
        )
        panel.keyDown(with: spaceEvent)
        XCTAssertEqual(quickLookCount, 1)

        // Modified Spacebar (e.g. Cmd+Shift+Space hotkey) does NOT trigger Quick Look.
        let modifiedSpaceEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
        )
        panel.keyDown(with: modifiedSpaceEvent)
        XCTAssertEqual(quickLookCount, 1)

        // Down arrow triggers selection navigation.
        let downEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 125
            )
        )
        panel.keyDown(with: downEvent)
        XCTAssertEqual(lastDelta, 1)

        // Escape releases key focus when no Quick Look panel is active.
        let escEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )
        panel.keyDown(with: escEvent)
        XCTAssertFalse(panel.canBecomeKey)
    }

    func testQLPreviewPanelControllerAttachmentAndSpacebarDismissal() throws {
        let store = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let shelfWindow = ShelfWindow(
            shelfID: store.id,
            stagingDirectory: store.stagingDirectory,
            stagingRoot: stagingRoot,
            contentRect: NSRect(x: 100, y: 100, width: 280, height: 200)
        )
        defer {
            ShelfQuickLookController.shared.closeAndCleanup(synchronous: true)
            shelfWindow.prepareForHide()
            shelfWindow.orderOut(nil)
        }

        shelfWindow.prepareForShow()
        shelfWindow.orderFrontRegardless()

        let snippet = ShelfItem(kind: .text(plain: "Live Quick Look Test", rtfData: nil, title: "Live"))
        var didEndForShelf: UUID?

        ShelfQuickLookController.shared.showPreview(
            items: [snippet],
            forShelfID: store.id,
            stagingRoot: stagingRoot,
            sourceWindow: shelfWindow,
            onSessionEnded: { endedID in
                didEndForShelf = endedID
            }
        )
        ShelfQuickLookController.shared.waitForPendingExport()

        let activeSession = try XCTUnwrap(ShelfQuickLookController.shared.activeSession)
        let sessionDir = try XCTUnwrap(activeSession.temporarySessionDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.path))
        XCTAssertTrue(shelfWindow.acceptsPreviewPanelControl(QLPreviewPanel.shared()))

        let qlPanel = try XCTUnwrap(QLPreviewPanel.shared())
        let controller = try XCTUnwrap(qlPanel.currentController as AnyObject?)
        XCTAssertTrue(
            controller === shelfWindow || controller is AppDelegate || String(describing: type(of: controller)).contains("AppDelegate"),
            "Unexpected QLPreviewPanel controller: \(type(of: controller))"
        )
        XCTAssertTrue(qlPanel.dataSource === ShelfQuickLookController.shared)
        XCTAssertTrue(qlPanel.delegate === ShelfQuickLookController.shared)
        XCTAssertEqual(ShelfQuickLookController.shared.numberOfPreviewItems(in: qlPanel), 1)
        XCTAssertEqual(
            ShelfQuickLookController.shared.previewPanel(qlPanel, previewItemAt: 0)?.previewItemURL,
            activeSession.items[0].previewItemURL
        )

        // Spin the runloop so async activation / focus notifications settle and confirm controller stays attached.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotNil(qlPanel.currentController)
        XCTAssertTrue(qlPanel.dataSource === ShelfQuickLookController.shared)
        XCTAssertTrue(qlPanel.delegate === ShelfQuickLookController.shared)

        // Switching selection while Quick Look is open replaces the preview and cleans up the old temp session.
        let secondSnippet = ShelfItem(kind: .text(plain: "Updated Quick Look", rtfData: nil, title: "Updated"))
        ShelfQuickLookController.shared.syncSelectionIfPreviewing(items: [secondSnippet], forShelfID: store.id)
        ShelfQuickLookController.shared.waitForPendingExport()
        ShelfQuickLookController.waitForPendingCleanup()
        let updatedSession = try XCTUnwrap(ShelfQuickLookController.shared.activeSession)
        let updatedSessionDir = try XCTUnwrap(updatedSession.temporarySessionDirectory)
        XCTAssertEqual(updatedSession.items.map(\.itemID), [secondSnippet.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: updatedSessionDir.path))

        // Pressing Spacebar while Quick Look is open closes the panel and cleans up temp files.
        let spaceEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: qlPanel.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
        )
        XCTAssertTrue(ShelfQuickLookController.shared.previewPanel(qlPanel, handle: spaceEvent))
        ShelfQuickLookController.waitForPendingCleanup()

        XCTAssertNil(ShelfQuickLookController.shared.activeSession)
        XCTAssertEqual(didEndForShelf, store.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: updatedSessionDir.path))
    }

    func testQuickLookSourceFrameTargetsIconPreviewInsteadOfEntireShelf() throws {
        let store = ShelfStore(shelfNumber: 1, stagingRoot: stagingRoot)
        let shelfWindow = ShelfWindow(
            shelfID: store.id,
            stagingDirectory: store.stagingDirectory,
            stagingRoot: stagingRoot,
            contentRect: NSRect(x: 200, y: 300, width: 282, height: 220)
        )
        defer {
            shelfWindow.prepareForHide()
            shelfWindow.orderOut(nil)
        }

        let item = ShelfItem(kind: .text(plain: "Icon zoom test", rtfData: nil, title: "Zoom"))
        let iconAnchor = ShelfItemIconAnchorNSView(frame: NSRect(x: 34, y: 120, width: 32, height: 32))
        iconAnchor.configure(shelfID: store.id, itemID: item.id)
        shelfWindow.dropContainerView.addSubview(iconAnchor)
        defer {
            iconAnchor.unregister()
            iconAnchor.removeFromSuperview()
        }

        // Anchor must never intercept pointer events.
        XCTAssertNil(iconAnchor.hitTest(NSPoint(x: 16, y: 16)))

        shelfWindow.prepareForShow()
        shelfWindow.orderFrontRegardless()

        let session = try XCTUnwrap(
            ShelfQuickLookController.buildSession(
                for: [item],
                shelfID: store.id,
                stagingRoot: stagingRoot
            )
        )
        defer {
            ShelfQuickLookController.cleanupTemporaryDirectory(session.temporarySessionDirectory, synchronous: true)
        }
        let previewItem = try XCTUnwrap(session.items.first)

        let qlPanel = QLPreviewPanel.shared()
        let iconScreenFrame = ShelfQuickLookController.shared.previewPanel(
            qlPanel,
            sourceFrameOnScreenFor: previewItem
        )
        let expectedScreenFrame = shelfWindow.convertToScreen(
            iconAnchor.convert(iconAnchor.bounds, to: nil)
        )
        XCTAssertEqual(iconScreenFrame, expectedScreenFrame)
        XCTAssertEqual(iconScreenFrame.size, NSSize(width: 32, height: 32))
        XCTAssertNotEqual(iconScreenFrame, shelfWindow.frame)

        // Transition image & contentRect should resolve cleanly for crossfade zoom.
        var contentRect = NSRect.zero
        let transitionImage = ShelfQuickLookController.shared.previewPanel(
            qlPanel,
            transitionImageFor: previewItem,
            contentRect: &contentRect
        ) as? NSImage
        XCTAssertNotNil(transitionImage)
        XCTAssertGreaterThan(contentRect.width, 0)
        XCTAssertGreaterThan(contentRect.height, 0)

        // Auto-hidden shelf must return .zero (fade instead of zooming into collapsed strip).
        shelfWindow.dropContainerView.highlightState.isAutoHidden = true
        XCTAssertEqual(
            ShelfQuickLookController.shared.previewPanel(qlPanel, sourceFrameOnScreenFor: previewItem),
            .zero
        )

        // Unregistering anchor returns .zero (never falls back to entire shelf frame).
        shelfWindow.dropContainerView.highlightState.isAutoHidden = false
        iconAnchor.unregister()
        XCTAssertEqual(
            ShelfQuickLookController.shared.previewPanel(qlPanel, sourceFrameOnScreenFor: previewItem),
            .zero
        )
    }
}
