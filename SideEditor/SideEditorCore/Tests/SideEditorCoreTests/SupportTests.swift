import Foundation
import XCTest
@testable import SideEditorCore

/// Known-answer tests. The package computes its own digests (no CryptoKit on
/// Linux), so they are checked against the published FIPS vectors rather than
/// against themselves.
final class SupportTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(
            SHA256.hexDigest(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256.hexDigest(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            SHA256.hexDigest(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testSHA256HandlesMessagesSpanningManyBlocks() {
        let data = Data.repeated(0x61, count: 1_000_000)
        XCTAssertEqual(
            SHA256.hexDigest(of: data),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    func testCRC32KnownVector() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testReaderCRC32AcceptsAStoredFixture() throws {
        let archive = try IPAArchive(contentsOf: Fixture.url("valid-minimal.ipa"))
        let entry = try XCTUnwrap(archive.entry(named: "Payload/Example.app/Info.plist"))
        let bytes = try archive.readEntry(named: entry.name)
        XCTAssertEqual(CRC32.checksum(bytes), entry.crc32)
    }
}
