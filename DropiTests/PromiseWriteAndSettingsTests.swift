import Foundation
import XCTest
@testable import Droptop

@MainActor
final class PromiseWriteAndSettingsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroptopTests-SEC05-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - SEC-05

    func testFileAndFolderExportThrowsUnsupportedWithoutDeletingDestination() throws {
        let sourceFile = tempDir.appendingPathComponent("source.txt")
        let destFile = tempDir.appendingPathComponent("existing.txt")
        let destFolder = tempDir.appendingPathComponent("existing-folder", isDirectory: true)
        let nestedFile = destFolder.appendingPathComponent("precious.txt")

        try Data("source".utf8).write(to: sourceFile)
        try Data("do-not-delete".utf8).write(to: destFile)
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        try Data("keep-me".utf8).write(to: nestedFile)

        let fileItem = ShelfItem(kind: .file(url: sourceFile, isTemporaryCopy: false))
        let folderItem = ShelfItem(kind: .folder(url: tempDir, isTemporaryCopy: false))

        XCTAssertThrowsError(try fileItem.writeExportData(to: destFile, allowOverwrite: false)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .featureUnsupported)
        }
        XCTAssertThrowsError(try fileItem.writeExportData(to: destFile, allowOverwrite: true)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .featureUnsupported)
        }
        XCTAssertThrowsError(try folderItem.writeExportData(to: destFolder, allowOverwrite: true)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .featureUnsupported)
        }

        // Neither existing file nor directory was deleted.
        XCTAssertEqual(try Data(contentsOf: destFile), Data("do-not-delete".utf8))
        XCTAssertEqual(try Data(contentsOf: nestedFile), Data("keep-me".utf8))
    }

    func testPromiseWriteCreatesFreshFileAndPopulatesZeroBytePlaceholder() throws {
        let snippet = ShelfItem(kind: .text(plain: "hello world", rtfData: nil, title: nil))

        // 1. Non-existent destination succeeds.
        let freshURL = tempDir.appendingPathComponent("Fresh.txt")
        try snippet.writeExportData(to: freshURL, allowOverwrite: false)
        XCTAssertEqual(try String(contentsOf: freshURL, encoding: .utf8), "hello world")

        // 2. Finder-style pre-created 0-byte placeholder succeeds.
        let placeholderURL = tempDir.appendingPathComponent("Placeholder.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: placeholderURL.path, contents: Data()))
        try snippet.writeExportData(to: placeholderURL, allowOverwrite: false)
        XCTAssertEqual(try String(contentsOf: placeholderURL, encoding: .utf8), "hello world")
    }

    func testPromiseWriteRefusesNonEmptyExistingFileAndSymlink() throws {
        let snippet = ShelfItem(kind: .text(plain: "new data", rtfData: nil, title: nil))

        // 1. Existing non-empty file is NOT overwritten.
        let existingURL = tempDir.appendingPathComponent("Important.txt")
        try Data("original-contents".utf8).write(to: existingURL)
        XCTAssertThrowsError(try snippet.writeExportData(to: existingURL, allowOverwrite: false)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "original-contents")

        // 2. Symlink pointing to a 0-byte file is NOT followed or overwritten.
        let targetURL = tempDir.appendingPathComponent("Target.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: targetURL.path, contents: Data()))
        let symlinkURL = tempDir.appendingPathComponent("Link.txt")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        XCTAssertThrowsError(try snippet.writeExportData(to: symlinkURL, allowOverwrite: false)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), Data())

        // 3. Explicit user-confirmed overwrite (NSSavePanel path) still works.
        try snippet.writeExportData(to: existingURL, allowOverwrite: true)
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "new data")
    }

    // MARK: - Lower-Severity Cleanup

    func testLegacyPreferenceMigrationAllowlistsKnownKeysOnly() throws {
        let suiteName = "com.local.DroptopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Pre-populate one key to verify existing settings are never overwritten.
        defaults.set(false, forKey: "edgeEnabled")

        let legacyDomain: [String: Any] = [
            "edgeEnabled": true,
            "shakeEnabled": true,
            "shelfTheme": "midnight",
            "hotkeyKeyCode": 36,
            "unexpectedKey": "injected",
            "AppleLanguages": ["zz"],
            "hotkeyModifiers": "wrong-type-should-be-ignored"
        ]

        AppSettings.migrateLegacyPreferences(from: legacyDomain, into: defaults)

        let migratedDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(defaults.object(forKey: "edgeEnabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "shakeEnabled") as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: "shelfTheme"), "midnight")
        XCTAssertEqual(defaults.object(forKey: "hotkeyKeyCode") as? Int, 36)
        XCTAssertNil(migratedDomain["unexpectedKey"])
        XCTAssertNil(migratedDomain["AppleLanguages"])
        XCTAssertNil(migratedDomain["hotkeyModifiers"])
    }

    func testShelfItemInitIsNonBlockingAndAsyncMetadataLoadsFileAndFolderStats() throws {
        let fileURL = tempDir.appendingPathComponent("sample.pdf")
        try Data(repeating: 0x41, count: 2048).write(to: fileURL)

        let folderURL = tempDir.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folderURL.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: folderURL.appendingPathComponent("b.txt"))
        try Data("hidden".utf8).write(to: folderURL.appendingPathComponent(".DS_Store"))

        let fileItem = ShelfItem(kind: .file(url: fileURL, isTemporaryCopy: false))
        let folderItem = ShelfItem(kind: .folder(url: folderURL, isTemporaryCopy: false))

        XCTAssertEqual(fileItem.subtitle, "PDF file")
        XCTAssertEqual(folderItem.subtitle, "Folder")

        let fileMeta = ShelfItem.loadSubtitleMetadata(for: fileItem.kind)
        let folderMeta = ShelfItem.loadSubtitleMetadata(for: folderItem.kind)
        XCTAssertNotNil(fileMeta)
        XCTAssertEqual(folderMeta, "2 items")
    }

    func testShowCopyButtonInShelfPersistsToUserDefaults() {
        let defaults = UserDefaults.standard
        let key = "showCopyButtonInShelf"
        let hadExisting = defaults.object(forKey: key) != nil
        let previousValue = AppSettings.shared.showCopyButtonInShelf
        defer {
            AppSettings.shared.showCopyButtonInShelf = previousValue
            if !hadExisting {
                defaults.removeObject(forKey: key)
            }
        }

        AppSettings.shared.showCopyButtonInShelf = true
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)

        AppSettings.shared.showCopyButtonInShelf = false
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)
    }
}
