import Foundation
import XCTest
@testable import SideEditorCore

/// Each limit is exercised on a *valid* fixture with an artificially tight
/// value, so a failure names the limit rather than the fixture.
final class LimitTests: XCTestCase {
    func testEntryCountLimit() {
        expectIPAError(
            try IPAScanner.inspect(
                contentsOf: Fixture.url("valid-minimal.ipa"),
                limits: InspectionLimits(maxEntryCount: 2)
            )
        ) { error in
            if case let .entryCountExceeded(limit, found) = error {
                return limit == 2 && found == 4
            }
            return false
        }
    }

    func testTotalDeclaredSizeLimit() {
        expectIPAError(
            try IPAScanner.inspect(
                contentsOf: Fixture.url("valid-minimal.ipa"),
                limits: InspectionLimits(maxTotalDeclaredSize: 8)
            )
        ) { error in
            if case .totalSizeExceeded = error { return true }
            return false
        }
    }

    func testCompressionRatioLimit() {
        expectIPAError(
            try IPAScanner.inspect(
                contentsOf: Fixture.url("valid-deflate.ipa"),
                limits: InspectionLimits(maxCompressionRatio: 0.5)
            )
        ) { error in
            if case let .compressionRatioExceeded(_, ratio, limit) = error {
                return ratio > limit && limit == 0.5
            }
            return false
        }
    }

    func testEntryNameLengthLimit() {
        expectIPAError(
            try IPAArchive(
                contentsOf: Fixture.url("valid-minimal.ipa"),
                limits: InspectionLimits(maxEntryNameBytes: 5)
            )
        ) { error in
            if case .entryNameTooLong = error { return true }
            return false
        }
    }

    func testInfoPlistSizeLimit() {
        expectIPAError(
            try IPAScanner.inspect(
                contentsOf: Fixture.url("valid-minimal.ipa"),
                limits: InspectionLimits(maxInfoPlistSize: 10)
            )
        ) { error in
            if case let .infoPlistTooLarge(declared, limit) = error {
                return declared > limit && limit == 10
            }
            return false
        }
    }

    func testNestedArchiveDepthLimit() {
        expectIPAError(
            try IPAScanner.inspect(
                contentsOf: Fixture.url("valid-nested.ipa"),
                limits: InspectionLimits(maxNestedArchiveDepth: 2)
            )
        ) { error in
            if case let .nestedArchiveDepthExceeded(_, depth, limit) = error {
                return depth == 4 && limit == 2
            }
            return false
        }
    }

    func testReadCeilingRejectsAnEntryLargerThanTheCallerAllows() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("valid-minimal.ipa"))
        expectIPAError(
            try archive.readEntry(named: "Payload/Example.app/Example", maxBytes: 4)
        ) { error in
            if case let .entryTooLarge(_, declared, limit) = error {
                return declared == 64 && limit == 4
            }
            return false
        }
    }

    func testDefaultReadCeilingAllowsOrdinaryEntries() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("valid-minimal.ipa"))
        XCTAssertNoThrow(try archive.readEntry(named: "Payload/Example.app/Info.plist"))
        XCTAssertEqual(archive.limits.maxReadableEntrySize, InspectionLimits.default.maxReadableEntrySize)
    }
}
