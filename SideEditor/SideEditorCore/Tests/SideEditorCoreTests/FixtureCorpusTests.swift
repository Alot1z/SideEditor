import Foundation
import XCTest
@testable import SideEditorCore

/// Case predicates used by the corpus table. Free functions (not methods) so the
/// table can reference them without capturing a test instance.
enum Cases {
    static func pathTraversal(_ error: IPAError) -> Bool {
        if case .pathTraversal = error { return true }
        return false
    }

    static func absolutePath(_ error: IPAError) -> Bool {
        if case .absolutePath = error { return true }
        return false
    }

    static func name(_ error: IPAError, reason: NameViolation) -> Bool {
        if case let .invalidEntryName(_, actual) = error { return actual == reason }
        return false
    }

    static func symlink(_ error: IPAError) -> Bool {
        if case .symlinkEntry = error { return true }
        return false
    }

    static func specialFile(_ error: IPAError) -> Bool {
        if case .specialFileEntry = error { return true }
        return false
    }

    static func duplicate(_ error: IPAError) -> Bool {
        if case .duplicateEntry = error { return true }
        return false
    }

    static func notAnArchive(_ error: IPAError) -> Bool {
        if case .notAnArchive = error { return true }
        return false
    }

    static func zip64(_ error: IPAError) -> Bool {
        if case .zip64Unsupported = error { return true }
        return false
    }

    static func truncated(_ error: IPAError) -> Bool {
        if case .truncatedArchive = error { return true }
        return false
    }

    static func encrypted(_ error: IPAError) -> Bool {
        if case .encryptedEntry = error { return true }
        return false
    }

    static func unsupportedMethod(_ error: IPAError) -> Bool {
        if case .unsupportedCompressionMethod = error { return true }
        return false
    }

    static func noApplicationBundle(_ error: IPAError) -> Bool {
        if case .noApplicationBundle = error { return true }
        return false
    }

    static func multipleApplications(_ error: IPAError) -> Bool {
        if case .multipleApplicationBundles = error { return true }
        return false
    }

    static func missingInfoPlist(_ error: IPAError) -> Bool {
        if case .missingInfoPlist = error { return true }
        return false
    }

    static func missingEntry(_ error: IPAError) -> Bool {
        if case .missingEntry = error { return true }
        return false
    }

    static func nestedTooDeep(_ error: IPAError) -> Bool {
        if case .nestedArchiveDepthExceeded = error { return true }
        return false
    }

    static func entryTooLarge(_ error: IPAError) -> Bool {
        if case .entryTooLarge = error { return true }
        return false
    }

    static func ratioExceeded(_ error: IPAError) -> Bool {
        if case .compressionRatioExceeded = error { return true }
        return false
    }

    static func decompressionLimited(_ error: IPAError) -> Bool {
        if case .decompressionLimitExceeded = error { return true }
        return false
    }

    static func corruptDeflate(_ error: IPAError) -> Bool {
        if case .corruptDeflateStream = error { return true }
        return false
    }

    static func checksumMismatch(_ error: IPAError) -> Bool {
        if case .checksumMismatch = error { return true }
        return false
    }

    static func sizeMismatch(_ error: IPAError) -> Bool {
        if case .declaredSizeMismatch = error { return true }
        return false
    }

    static func malformedPlist(_ error: IPAError) -> Bool {
        if case .malformedInfoPlist = error { return true }
        return false
    }

    static func mistypedBundleIdentifier(_ error: IPAError) -> Bool {
        if case let .mistypedInfoPlist(key, expected) = error {
            return key == "CFBundleIdentifier" && expected == "String"
        }
        return false
    }

    static func plistTooDeep(_ error: IPAError) -> Bool {
        if case .plistTooDeep = error { return true }
        return false
    }
}

/// The corpus itself: every fixture must fail for the reason it was built to
/// fail for, and every valid fixture must inspect cleanly.
///
/// A hostile fixture that starts throwing a *different* error is a regression
/// just as much as one that stops throwing, so each row names the expected case.
final class FixtureCorpusTests: XCTestCase {
    func testCorpusContainsEnoughFixtures() {
        XCTAssertGreaterThanOrEqual(Fixture.hostileNames.count, 12, "hostile fixture count")
        XCTAssertGreaterThanOrEqual(Fixture.validNames.count, 4, "valid fixture count")
        XCTAssertEqual(
            Fixture.allNames.count,
            Fixture.hostileNames.count + Fixture.validNames.count,
            "every fixture is either valid-* or hostile"
        )
    }

    func testEveryHostileFixtureFailsWithItsExpectedError() {
        let expectations: [(String, (IPAError) -> Bool)] = [
            ("traversal-parent.ipa", Cases.pathTraversal),
            ("traversal-absolute.ipa", Cases.absolutePath),
            ("traversal-windows-drive.ipa", Cases.absolutePath),
            ("traversal-backslash.ipa", { Cases.name($0, reason: .backslashSeparator) }),
            ("traversal-nul.ipa", { Cases.name($0, reason: .controlCharacter) }),
            ("symlink-entry.ipa", Cases.symlink),
            ("special-file-entry.ipa", Cases.specialFile),
            ("duplicate-entry.ipa", Cases.duplicate),
            ("not-a-zip.ipa", Cases.notAnArchive),
            ("zip64-eocd.ipa", Cases.zip64),
            ("truncated-archive.ipa", Cases.truncated),
            ("encrypted-entry.ipa", Cases.encrypted),
            ("unsupported-method.ipa", Cases.unsupportedMethod),
            ("no-payload.ipa", Cases.noApplicationBundle),
            ("multiple-apps.ipa", Cases.multipleApplications),
            ("missing-plist.ipa", Cases.missingInfoPlist),
            ("missing-executable.ipa", Cases.missingEntry),
            ("deep-nested-archive.ipa", Cases.nestedTooDeep),
            ("bomb-declared-huge.ipa", Cases.entryTooLarge),
            ("bomb-ratio.ipa", Cases.ratioExceeded),
            ("bomb-inflate.ipa", Cases.decompressionLimited),
            ("corrupt-deflate.ipa", Cases.corruptDeflate),
            ("checksum-mismatch.ipa", Cases.checksumMismatch),
            ("size-mismatch.ipa", Cases.sizeMismatch),
            ("truncated-payload.ipa", Cases.truncated),
            ("malformed-plist.ipa", Cases.malformedPlist),
            ("mistyped-plist.ipa", Cases.mistypedBundleIdentifier),
            ("deep-plist.ipa", Cases.plistTooDeep),
        ]

        // Every hostile fixture must appear in the table, so a new fixture
        // cannot be added without stating what it should produce.
        XCTAssertEqual(
            Set(expectations.map { $0.0 }),
            Set(Fixture.hostileNames),
            "the corpus table must cover every hostile fixture"
        )

        for (name, matcher) in expectations {
            expectIPAError(
                try IPAScanner.inspect(contentsOf: Fixture.url(name)),
                matcher,
                name
            )
        }
    }

    func testEveryValidFixtureInspects() throws {
        for name in Fixture.validNames {
            let inspection = try IPAScanner.inspect(contentsOf: Fixture.url(name))
            XCTAssertNotNil(inspection.primaryApplication, "\(name) has no primary app")
            XCTAssertNotNil(inspection.primaryApplication?.bundleIdentifier, "\(name) has no bundle identifier")
            XCTAssertGreaterThan(inspection.summary.entryCount, 0, "\(name) has no entries")
        }
    }
}
