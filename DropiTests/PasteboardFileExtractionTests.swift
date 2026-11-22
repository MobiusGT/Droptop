import AppKit
import Foundation
import XCTest
@testable import Droptop

@MainActor
final class PasteboardFileExtractionTests: XCTestCase {
    private var tempBaseDir: URL!
    private var stagingDir: URL!
    private var secretFile: URL!
    private var benignFile: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroptopTests-SEC03-\(UUID().uuidString)", isDirectory: true)
        stagingDir = tempBaseDir.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        secretFile = tempBaseDir.appendingPathComponent("id_rsa")
        benignFile = tempBaseDir.appendingPathComponent("report.txt")
        try Data("PRIVATE KEY".utf8).write(to: secretFile)
        try Data("benign report".utf8).write(to: benignFile)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempBaseDir)
        try super.tearDownWithError()
    }

    func testFileURLInsidePublicURLIsRejectedFromDirectFileExtraction() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(secretFile.absoluteString, forType: .URL)
        pb.writeObjects([item])

        XCTAssertNil(PasteboardHandler.readDirectFileURLs(from: pb))

        var extracted: [ShelfItem] = []
        let accepted = PasteboardHandler.extractItems(
            from: pb,
            stagingDirectory: stagingDir,
            stagingRoot: tempBaseDir
        ) { items in
            extracted = items
        }

        XCTAssertFalse(accepted)
        XCTAssertTrue(extracted.isEmpty)
    }

    func testFileURLInsidePublicURLWithPlainTextDegradesToTextNeverFile() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(secretFile.absoluteString, forType: .URL)
        item.setString(secretFile.absoluteString, forType: .string)
        pb.writeObjects([item])

        XCTAssertNil(PasteboardHandler.readDirectFileURLs(from: pb))

        var extracted: [ShelfItem] = []
        _ = PasteboardHandler.extractItems(
            from: pb,
            stagingDirectory: stagingDir,
            stagingRoot: tempBaseDir
        ) { items in
            extracted = items
        }

        XCTAssertEqual(extracted.count, 1)
        if case .text = extracted[0].kind {
            // Expected harmless plain text, never a live file reference.
        } else {
            XCTFail("Expected harmless .text item, got \(extracted[0].kind)")
        }
    }

    func testGenuineFileURLPasteboardIsAccepted() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([benignFile as NSURL])

        let urls = PasteboardHandler.readDirectFileURLs(from: pb)
        XCTAssertEqual(
            urls?.map { $0.standardizedFileURL.resolvingSymlinksInPath() },
            [benignFile.standardizedFileURL.resolvingSymlinksInPath()]
        )
    }

    func testLegacyFilenamesPasteboardIsAccepted() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pb.declareTypes([filenamesType], owner: nil)
        pb.setPropertyList([benignFile.path], forType: filenamesType)

        let urls = PasteboardHandler.readDirectFileURLs(from: pb)
        XCTAssertEqual(
            urls?.map { $0.standardizedFileURL.resolvingSymlinksInPath() },
            [benignFile.standardizedFileURL.resolvingSymlinksInPath()]
        )
    }

    func testMixedPasteboardDoesNotSmugglePublicURLFileEntry() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()

        let legitItem = NSPasteboardItem()
        legitItem.setString(benignFile.absoluteString, forType: .fileURL)

        let smuggledItem = NSPasteboardItem()
        smuggledItem.setString(secretFile.absoluteString, forType: .URL)

        pb.writeObjects([legitItem, smuggledItem])

        let urls = PasteboardHandler.readDirectFileURLs(from: pb)
        XCTAssertEqual(
            urls?.map { $0.standardizedFileURL.resolvingSymlinksInPath() },
            [benignFile.standardizedFileURL.resolvingSymlinksInPath()]
        )
    }

    func testLegitimateHTTPSWebLinkStillExtractsAsWebURL() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("https://example.com/docs", forType: .URL)
        item.setString("Example Docs", forType: NSPasteboard.PasteboardType("public.url-name"))
        pb.writeObjects([item])

        XCTAssertNil(PasteboardHandler.readDirectFileURLs(from: pb))

        var extracted: [ShelfItem] = []
        let accepted = PasteboardHandler.extractItems(
            from: pb,
            stagingDirectory: stagingDir,
            stagingRoot: tempBaseDir
        ) { items in
            extracted = items
        }

        XCTAssertTrue(accepted)
        XCTAssertEqual(extracted.count, 1)
        XCTAssertEqual(extracted.first?.webURL?.absoluteString, "https://example.com/docs")
    }
}
