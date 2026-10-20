import Foundation
import XCTest
@testable import SideEditorCore

/// Invariant 1 from the target architecture: the input is never modified, and
/// nothing is written outside the directory the caller names.
final class SafetyTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = try makeSandbox()
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
    }

    func testInputBytesAndModificationDateAreUnchanged() throws {
        let input = try copyFixture("valid-stored.ipa")
        let before = try fingerprint(input)

        let inspection = try IPAScanner.inspect(contentsOf: input)
        let archive = try IPAArchive(contentsOf: input)
        _ = try archive.readEntry(named: "Payload/Example.app/Info.plist")
        _ = try archive.extractAll(to: sandbox.appendingPathComponent("out", isDirectory: true))

        let after = try fingerprint(input)
        XCTAssertEqual(before.sha256, after.sha256, "input bytes changed")
        XCTAssertEqual(before.modificationDate, after.modificationDate, "input mtime changed")
        XCTAssertEqual(inspection.summary.byteCount, before.size)
    }

    func testInspectionAndExtractionWriteOnlyInsideTheDestination() throws {
        let input = try copyFixture("valid-stored.ipa")
        let destination = sandbox.appendingPathComponent("out", isDirectory: true)
        let before = Set(Snapshot.paths(under: sandbox))

        let archive = try IPAArchive(contentsOf: input)
        let written = try archive.extractAll(to: destination)

        let added = Set(Snapshot.paths(under: sandbox)).subtracting(before)
        XCTAssertFalse(added.isEmpty, "extraction wrote nothing")
        XCTAssertTrue(
            added.allSatisfy { $0 == "out" || $0.hasPrefix("out/") },
            "extraction wrote outside the destination: \(added.sorted())"
        )
        XCTAssertEqual(written.count, archive.entries.filter { !$0.isDirectory }.count)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sandbox.deletingLastPathComponent().appendingPathComponent("evil.txt").path
            ),
            "extraction escaped the sandbox"
        )
    }

    func testExtractionRefusesToWriteThroughASymlinkedDirectory() throws {
        let input = try copyFixture("valid-stored.ipa")
        let destination = sandbox.appendingPathComponent("out", isDirectory: true)
        let escape = sandbox.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: escape, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("Payload"),
            withDestinationURL: escape
        )

        let archive = try IPAArchive(contentsOf: input)
        expectIPAError(try archive.extractAll(to: destination)) { error in
            if case .pathTraversal = error { return true }
            return false
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: escape.path),
            [],
            "extraction wrote through a symlink"
        )
    }

    func testRejectedArchiveWritesNothing() throws {
        let input = try copyFixture("traversal-parent.ipa")
        let before = Snapshot.paths(under: sandbox)

        expectIPAError(try IPAArchive(contentsOf: input)) { error in
            if case .pathTraversal = error { return true }
            return false
        }

        XCTAssertEqual(Snapshot.paths(under: sandbox), before)
    }

    func testExtractedBytesMatchTheArchiveEntries() throws {
        let input = try copyFixture("valid-stored.ipa")
        let destination = sandbox.appendingPathComponent("out", isDirectory: true)

        let archive = try IPAArchive(contentsOf: input)
        try archive.extractAll(to: destination)

        let plistPath = destination.appendingPathComponent("Payload/Example.app/Info.plist")
        XCTAssertEqual(
            try Data(contentsOf: plistPath),
            try archive.readEntry(named: "Payload/Example.app/Info.plist")
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Payload/Example.app/Frameworks/CoreKit.framework").path
            ),
            "directory entries were not created"
        )
    }

    // MARK: Helpers

    private struct Fingerprint {
        let sha256: String
        let modificationDate: Date
        let size: Int
    }

    private func copyFixture(_ name: String) throws -> URL {
        let destination = sandbox.appendingPathComponent("input.ipa")
        try FileManager.default.copyItem(at: Fixture.url(name), to: destination)
        return destination
    }

    private func fingerprint(_ url: URL) throws -> Fingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let date = try XCTUnwrap(attributes[.modificationDate] as? Date, "no modification date")
        let size = try XCTUnwrap(attributes[.size] as? NSNumber, "no size").intValue
        return Fingerprint(
            sha256: try SHA256.hexDigest(of: url),
            modificationDate: date,
            size: size
        )
    }
}
