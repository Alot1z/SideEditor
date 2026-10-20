import Foundation
import XCTest
@testable import SideEditorCore

final class BundleGraphTests: XCTestCase {
    func testMinimalGraphHasOneAppWithItsExecutable() throws {
        let graph = try IPAScanner.inspect(contentsOf: Fixture.url("valid-minimal.ipa")).graph
        let app = try XCTUnwrap(graph.primaryApplication)

        XCTAssertEqual(graph.applications.count, 1)
        XCTAssertEqual(app.path, "Payload/Example.app")
        XCTAssertEqual(app.bundleIdentifier, "com.example.app")
        XCTAssertEqual(app.shortVersion, "1.0")
        XCTAssertEqual(app.minimumOSVersion, "15.0")
        XCTAssertEqual(app.executablePath, "Payload/Example.app/Example")
        XCTAssertTrue(app.extensions.isEmpty)
        XCTAssertTrue(app.frameworks.isEmpty)
        XCTAssertTrue(graph.nestedArchives.isEmpty)
    }

    func testExtensionsAndFrameworksAreDiscoveredWithIdentifiers() throws {
        let graph = try IPAScanner.inspect(contentsOf: Fixture.url("valid-stored.ipa")).graph
        let app = try XCTUnwrap(graph.primaryApplication)

        XCTAssertEqual(
            app.extensions.map(\.path),
            [
                "Payload/Example.app/PlugIns/Bare.appex",
                "Payload/Example.app/PlugIns/Widget.appex",
            ]
        )
        XCTAssertEqual(app.extensions[0].bundleIdentifier, nil)
        XCTAssertNil(app.extensions[0].infoPlistPath)
        XCTAssertEqual(app.extensions[1].bundleIdentifier, "com.example.app.widget")
        XCTAssertEqual(app.extensions[1].infoPlistPath, "Payload/Example.app/PlugIns/Widget.appex/Info.plist")

        XCTAssertEqual(
            app.frameworks.map(\.path),
            [
                "Payload/Example.app/Frameworks/CoreKit.framework",
                "Payload/Example.app/Frameworks/Raw.framework",
            ]
        )
        XCTAssertEqual(app.frameworks[0].bundleIdentifier, "com.example.corekit")
        XCTAssertNil(app.frameworks[1].bundleIdentifier)
    }

    func testNestedArchiveIsListedWithoutBeingOpened() throws {
        let graph = try IPAScanner.inspect(contentsOf: Fixture.url("valid-nested.ipa")).graph

        XCTAssertEqual(
            graph.nestedArchives,
            [BundleGraph.NestedArchive(path: "Payload/Example.app/PlugIns/Helper.ipa", depth: 4)]
        )
    }

    func testZipWithoutPayloadIsRejected() {
        expectIPAError(try IPAScanner.inspect(contentsOf: Fixture.url("no-payload.ipa"))) { error in
            if case .noApplicationBundle = error { return true }
            return false
        }
    }

    func testTwoApplicationBundlesAreRejected() {
        expectIPAError(try IPAScanner.inspect(contentsOf: Fixture.url("multiple-apps.ipa"))) { error in
            if case let .multipleApplicationBundles(paths) = error {
                return paths == ["Payload/One.app", "Payload/Two.app"]
            }
            return false
        }
    }

    func testAppWithoutInfoPlistIsRejected() {
        expectIPAError(try IPAScanner.inspect(contentsOf: Fixture.url("missing-plist.ipa"))) { error in
            if case let .missingInfoPlist(path) = error {
                return path == "Payload/Example.app"
            }
            return false
        }
    }

    func testExecutableNamedInThePlistMustExist() {
        expectIPAError(try IPAScanner.inspect(contentsOf: Fixture.url("missing-executable.ipa"))) { error in
            if case let .missingEntry(path) = error {
                return path == "Payload/Example.app/Ghost"
            }
            return false
        }
    }

    func testDeepNestedArchiveExceedsTheDepthCeiling() {
        expectIPAError(try IPAScanner.inspect(contentsOf: Fixture.url("deep-nested-archive.ipa"))) { error in
            if case let .nestedArchiveDepthExceeded(_, depth, limit) = error {
                return depth > limit
            }
            return false
        }
    }

    func testBundleGraphIsDeterministic() throws {
        let first = try IPAScanner.inspect(contentsOf: Fixture.url("valid-stored.ipa")).graph
        let second = try IPAScanner.inspect(contentsOf: Fixture.url("valid-stored.ipa")).graph
        XCTAssertEqual(first, second)
    }
}
