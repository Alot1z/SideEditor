import Foundation
import XCTest
@testable import SideEditorCore

final class ArchiveTests: XCTestCase {
    func testValidMinimalListsEntriesInDirectoryOrder() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("valid-minimal.ipa"))

        XCTAssertEqual(
            archive.entryNames,
            [
                "Payload/",
                "Payload/Example.app/",
                "Payload/Example.app/Info.plist",
                "Payload/Example.app/Example",
            ]
        )
        XCTAssertTrue(archive.entries[0].isDirectory)
        XCTAssertFalse(archive.entries[2].isDirectory)
        XCTAssertEqual(archive.entries.filter(\.isDirectory).count, 2)
        XCTAssertFalse(archive.entry(named: "Payload/Example.app/Info.plist")?.isEncrypted ?? true)
    }

    func testStoredEntryRoundTripsByteForByte() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("valid-stored.ipa"))
        let executable = try archive.readEntry(named: "Payload/Example.app/Example")

        XCTAssertEqual(executable, Data([0xcf, 0xfa, 0xed, 0xfe]) + Data.repeated(0x00, count: 60))
    }

    func testDeflatedEntryRoundTripsByteForByte() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("valid-deflate.ipa"))
        let executable = try archive.readEntry(named: "Payload/Example.app/Example")

        XCTAssertEqual(executable, Data([0xcf, 0xfa, 0xed, 0xfe]) + Data.repeated(0x00, count: 60))
        XCTAssertEqual(archive.entry(named: "Payload/Example.app/Example")?.compressionMethod, 8)
    }

    func testDeflatedPlistParsesAfterDecompression() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("valid-deflate.ipa"))
        let data = try archive.readEntry(named: "Payload/Example.app/Info.plist")
        let model = try InfoPlistModel.parse(data)

        XCTAssertEqual(try model.string(for: "CFBundleIdentifier"), "com.example.deflated")
        XCTAssertEqual(try model.integer(for: "BuildNumber"), 7)
        XCTAssertEqual(try model.boolean(for: "UIFileSharingEnabled"), true)
    }

    func testReadingAMissingEntryNamesIt() {
        let archive = try? IPAArchive(contentsOf: Fixture.url("valid-minimal.ipa"))
        expectIPAError(try archive?.readEntry(named: "Payload/Example.app/Nope")) { error in
            if case let .missingEntry(path) = error {
                return path == "Payload/Example.app/Nope"
            }
            return false
        }
    }

    func testCorruptDeflateStreamIsReported() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("corrupt-deflate.ipa"))
        expectIPAError(try archive.readEntry(named: "Payload/Example.app/Info.plist")) { error in
            if case .corruptDeflateStream = error { return true }
            return false
        }
    }

    func testChecksumMismatchIsReported() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("checksum-mismatch.ipa"))
        expectIPAError(try archive.readEntry(named: "Payload/Example.app/Info.plist")) { error in
            if case .checksumMismatch = error { return true }
            return false
        }
    }

    func testDeclaredSizeMismatchIsReported() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("size-mismatch.ipa"))
        expectIPAError(try archive.readEntry(named: "Payload/Example.app/Info.plist")) { error in
            if case .declaredSizeMismatch = error { return true }
            return false
        }
    }

    func testTruncatedPayloadIsReported() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("truncated-payload.ipa"))
        expectIPAError(try archive.readEntry(named: "Payload/Example.app/Info.plist")) { error in
            if case .truncatedArchive = error { return true }
            return false
        }
    }

    func testZip64EndOfCentralDirectoryIsRejected() {
        expectIPAError(try IPAArchive(contentsOf: Fixture.url("zip64-eocd.ipa"))) { error in
            if case .zip64Unsupported = error { return true }
            return false
        }
    }

    func testArchiveWithAnImpossibleDirectorySizeIsTruncated() {
        expectIPAError(try IPAArchive(contentsOf: Fixture.url("truncated-archive.ipa"))) { error in
            if case .truncatedArchive = error { return true }
            return false
        }
    }

    func testBytesThatAreNotAZipAreRejected() {
        expectIPAError(try IPAArchive(contentsOf: Fixture.url("not-a-zip.ipa"))) { error in
            if case .notAnArchive = error { return true }
            return false
        }
    }

    func testLocalHeaderNameMustMatchTheCentralDirectory() throws {
        var bytes = try Fixture.data("valid-minimal.ipa")
        let name = "Payload/Example.app/Info.plist"
        let entry = try XCTUnwrap(try IPAArchive(data: bytes).entry(named: name))

        // Rename the first byte of the local header's copy of the name. The
        // central directory still says "Payload/...", so the two disagree.
        bytes[entry.localHeaderOffset + ZipSignature.localFileHeaderSize] = UInt8(ascii: "X")

        let tampered = try IPAArchive(data: bytes)
        expectIPAError(try tampered.readEntry(named: name)) { error in
            if case .localHeaderMismatch = error { return true }
            return false
        }
    }

    func testDirectoryDetectionUsesTheUnixModeWhenTheNameHasNoSlash() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("valid-directory-modes.ipa"))

        XCTAssertEqual(archive.entry(named: "Payload")?.isDirectory, true)
        XCTAssertEqual(archive.entry(named: "Payload/Example.app")?.isDirectory, true)
        XCTAssertEqual(archive.entry(named: "Payload/Example.app/Resources")?.isDirectory, true)
        XCTAssertEqual(archive.entry(named: "Payload/Example.app/Info.plist")?.isDirectory, false)

        let inspection = try IPAScanner.inspect(archive: archive)
        XCTAssertEqual(inspection.summary.entryCount, 5)
        XCTAssertEqual(inspection.summary.directoryEntryCount, 3)
    }

    func testModeOnlyDirectoriesExtractAsDirectories() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let archive = try IPAArchive(contentsOf: Fixture.url("valid-directory-modes.ipa"))
        try archive.extractAll(to: sandbox)

        for path in ["Payload", "Payload/Example.app", "Payload/Example.app/Resources"] {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: sandbox.appendingPathComponent(path).path,
                isDirectory: &isDirectory
            )
            XCTAssertTrue(exists, "missing \(path)")
            XCTAssertTrue(isDirectory.boolValue, "\(path) was written as a file")
        }

        XCTAssertEqual(
            try Data(contentsOf: sandbox.appendingPathComponent("Payload/Example.app/Info.plist")),
            try archive.readEntry(named: "Payload/Example.app/Info.plist")
        )
    }

    func testSummaryCountsMatchTheDirectory() throws {
        let inspection = try IPAScanner.inspect(contentsOf: Fixture.url("valid-minimal.ipa"))

        XCTAssertEqual(inspection.summary.entryCount, 4)
        XCTAssertEqual(inspection.summary.directoryEntryCount, 2)
        XCTAssertEqual(inspection.summary.compressedEntryCount, 0)
        XCTAssertEqual(inspection.summary.byteCount, try Fixture.data("valid-minimal.ipa").count)
        XCTAssertGreaterThan(inspection.summary.totalUncompressedSize, 0)
    }

    func testDeflateSummaryCountsCompressedEntries() throws {
        let inspection = try IPAScanner.inspect(contentsOf: Fixture.url("valid-deflate.ipa"))
        XCTAssertEqual(inspection.summary.compressedEntryCount, 3)
    }
}
