import Foundation
import XCTest
@testable import SideEditorCore

final class InfoPlistTests: XCTestCase {
    func testTypedAccessorsKeepStringsIntegersAndBooleansApart() throws {
        let data = try Fixture.data("valid-minimal.ipa")
        let archive = try IPAArchive(data: data)
        let plistData = try archive.readEntry(named: "Payload/Example.app/Info.plist")
        let model = try InfoPlistModel.parse(plistData)

        XCTAssertEqual(try model.string(for: "CFBundleName"), "Example")
        XCTAssertEqual(try model.integer(for: "BuildNumber"), 7)
        XCTAssertEqual(try model.boolean(for: "UIFileSharingEnabled"), true)

        // The value is a string, so asking for a number must fail rather than
        // coerce.
        expectIPAError(try model.integer(for: "CFBundleName")) { error in
            if case let .mistypedInfoPlist(key, expected) = error {
                return key == "CFBundleName" && expected == "Integer"
            }
            return false
        }
    }

    func testBinaryPlistKeepsBooleansAndIntegersDistinct() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("valid-deflate.ipa"))
        let model = try InfoPlistModel.parse(
            try archive.readEntry(named: "Payload/Example.app/Info.plist")
        )

        guard case let .boolean(flag)? = model["UIFileSharingEnabled"] else {
            return XCTFail("UIFileSharingEnabled is not a boolean")
        }
        XCTAssertTrue(flag)

        guard case let .integer(build)? = model["BuildNumber"] else {
            return XCTFail("BuildNumber is not an integer")
        }
        XCTAssertEqual(build, 7)
    }

    func testNestedContainersAreConverted() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("valid-deflate.ipa"))
        let model = try InfoPlistModel.parse(
            try archive.readEntry(named: "Payload/Example.app/PlugIns/Share.appex/Info.plist")
        )
        let extensionKeys = try model.dictionary(for: "NSExtension")

        XCTAssertEqual(
            extensionKeys?["NSExtensionPointIdentifier"],
            PlistValue.string("com.apple.share-services")
        )
    }

    func testMissingKeyReturnsNil() throws {
        let model = try InfoPlistModel.parse(try plistData("valid-minimal.ipa"))
        XCTAssertNil(try model.string(for: "NotAKey"))
    }

    func testRootThatIsNotADictionaryIsRejected() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["one", "two"],
            format: .xml,
            options: 0
        )
        expectIPAError(try InfoPlistModel.parse(data)) { error in
            if case .malformedInfoPlist = error { return true }
            return false
        }
    }

    func testMalformedPlistIsRejected() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("malformed-plist.ipa"))
        expectIPAError(
            try InfoPlistModel.parse(try archive.readEntry(named: "Payload/Example.app/Info.plist"))
        ) { error in
            if case .malformedInfoPlist = error { return true }
            return false
        }
    }

    func testMistypedBundleIdentifierIsReportedByTheGraph() {
        expectIPAError(try IPAScanner.inspect(contentsOf: Fixture.url("mistyped-plist.ipa"))) { error in
            if case let .mistypedInfoPlist(key, expected) = error {
                return key == "CFBundleIdentifier" && expected == "String"
            }
            return false
        }
    }

    func testDeeplyNestedPlistIsRejected() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("deep-plist.ipa"))
        // The file parses; the *model* refuses to recurse without a ceiling.
        let entry = try XCTUnwrap(archive.entry(named: "Payload/Example.app/Info.plist"))
        XCTAssertGreaterThan(entry.uncompressedSize, 1000)

        expectIPAError(
            try InfoPlistModel.parse(try archive.readEntry(named: "Payload/Example.app/Info.plist"))
        ) { error in
            if case .plistTooDeep = error { return true }
            return false
        }
    }

    func testFlatPlistFitsUnderAShallowNestingLimit() throws {
        let limits = InspectionLimits(maxPlistDepth: 1)
        let model = try InfoPlistModel.parse(try plistData("valid-minimal.ipa"), limits: limits)
        XCTAssertEqual(try model.string(for: "CFBundleName"), "Example")
    }

    /// The ceiling is documented as counting container edges from the root, so
    /// 63 nested arrays put the innermost value at depth 64 (allowed) and 64 put
    /// it at 65 (rejected). Both sides of the boundary are pinned here, and the
    /// `deep-plist.ipa` fixture repeats the rejected case end to end.
    func testPlistNestingAtTheLimitParses() throws {
        let model = try InfoPlistModel.parse(try nestedArrayPlist(depth: 63))
        XCTAssertNotNil(model["Deep"])
        XCTAssertEqual(InspectionLimits.default.maxPlistDepth, 64)
    }

    func testPlistNestingPastTheLimitIsRejected() throws {
        let data = try nestedArrayPlist(depth: 64)
        expectIPAError(try InfoPlistModel.parse(data)) { error in
            if case let .plistTooDeep(limit) = error { return limit == 64 }
            return false
        }
    }

    private func nestedArrayPlist(depth: Int) throws -> Data {
        var value: Any = "leaf"
        for _ in 0..<depth {
            value = [value]
        }
        return try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.deep", "Deep": value],
            format: .xml,
            options: 0
        )
    }

    private func plistData(_ fixture: String) throws -> Data {
        let archive = try IPAArchive(contentsOf: Fixture.url(fixture))
        return try archive.readEntry(named: "Payload/Example.app/Info.plist")
    }
}
