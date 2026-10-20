import Foundation

/// One central-directory record, as declared by the archive.
///
/// These values are *claims*. `IPAArchive` validates them against limits and
/// against the local header before any byte reaches the decompressor.
public struct ZipEntry: Sendable, Equatable {
    public let name: String
    public let compressionMethod: UInt16
    public let generalPurposeFlags: UInt16
    public let crc32: UInt32
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let localHeaderOffset: Int
    public let externalAttributes: UInt32
    public let versionMadeBy: UInt16

    /// ZIP records directory-ness twice: a trailing slash in the name, and — for
    /// archives written on Unix — the `S_IFDIR` bits in the external attributes.
    /// Either signal is enough. Archivers exist that omit the slash, and treating
    /// such an entry as a file writes a zero-byte file where a directory belongs.
    public var isDirectory: Bool {
        if name.hasSuffix("/") { return true }
        guard let permissions = unixPermissions else { return false }
        return permissions & 0o170000 == 0o040000
    }

    /// The name used for duplicate detection: the trailing slash, when present,
    /// is not part of the identity. Never strips a real character.
    var canonicalName: String {
        name.hasSuffix("/") ? String(name.dropLast()) : name
    }

    /// The host system that created the entry (upper byte of `versionMadeBy`).
    /// 3 is Unix, which is the only value whose external attributes carry a mode.
    public var hostSystem: UInt8 { UInt8(truncatingIfNeeded: versionMadeBy >> 8) }

    public var unixPermissions: UInt16? {
        guard hostSystem == 3 else { return nil }
        return UInt16(truncatingIfNeeded: externalAttributes >> 16)
    }

    public var isEncrypted: Bool { generalPurposeFlags & 0x0001 != 0 }
    public var usesDataDescriptor: Bool { generalPurposeFlags & 0x0008 != 0 }
}

/// Bounds-checked little-endian reads over the mapped archive bytes.
struct ByteCursor {
    let data: Data
    let context: String

    init(data: Data, context: String) {
        self.data = data
        self.context = context
    }

    func require(_ offset: Int, _ count: Int) throws {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
            throw IPAError.truncatedArchive(offset: max(0, offset))
        }
    }

    func uint8(at offset: Int) throws -> UInt8 {
        try require(offset, 1)
        return data[data.startIndex + offset]
    }

    func uint16(at offset: Int) throws -> UInt16 {
        try require(offset, 2)
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    func uint32(at offset: Int) throws -> UInt32 {
        try require(offset, 4)
        let base = data.startIndex + offset
        var value: UInt32 = 0
        for index in (0..<4).reversed() {
            value = (value << 8) | UInt32(data[base + index])
        }
        return value
    }

    func bytes(at offset: Int, count: Int) throws -> Data {
        try require(offset, count)
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }

    func string(at offset: Int, count: Int) throws -> String {
        let raw = try bytes(at: offset, count: count)
        guard let name = String(data: raw, encoding: .utf8) else {
            throw IPAError.invalidEntryName(
                name: String(decoding: raw, as: UTF8.self),
                reason: .invalidUTF8
            )
        }
        return name
    }
}

enum ZipSignature {
    static let endOfCentralDirectory: UInt32 = 0x0605_4b50
    static let centralDirectoryFileHeader: UInt32 = 0x0201_4b50
    static let localFileHeader: UInt32 = 0x0403_4b50
    static let zip64EndOfCentralDirectoryLocator: UInt32 = 0x0706_4b50
    static let zip64EndOfCentralDirectory: UInt32 = 0x0606_4b50

    /// Serialized sizes.
    static let endOfCentralDirectorySize = 22
    static let centralDirectoryHeaderSize = 46
    static let localFileHeaderSize = 30

    /// The largest possible EOCD suffix: 22 bytes plus the 64 KiB comment field.
    static let maximumEndOfCentralDirectorySearchWindow = 22 + 0xFFFF
}

/// A parsed archive directory. `contents` is the same mapped bytes the entries
/// point into; nothing is copied.
struct ZipDirectory {
    let entries: [ZipEntry]
    let centralDirectoryOffset: Int
    let centralDirectorySize: Int
    let endOfCentralDirectoryOffset: Int
}

/// Parses the central directory and applies every *listing* rule.
enum ZipDirectoryParser {
    static func parse(
        data: Data,
        byteCount: Int,
        limits: InspectionLimits
    ) throws -> ZipDirectory {
        let cursor = ByteCursor(data: data, context: "centralDirectory")
        let eocdOffset = try locateEndOfCentralDirectory(cursor: cursor, byteCount: byteCount)

        let diskNumber = try cursor.uint16(at: eocdOffset + 4)
        let centralDirectoryDisk = try cursor.uint16(at: eocdOffset + 6)
        let entriesOnDisk = Int(try cursor.uint16(at: eocdOffset + 8))
        let totalEntries = Int(try cursor.uint16(at: eocdOffset + 10))
        let centralDirectorySize = Int(try cursor.uint32(at: eocdOffset + 12))
        let centralDirectoryOffset = Int(try cursor.uint32(at: eocdOffset + 16))
        let commentLength = Int(try cursor.uint16(at: eocdOffset + 20))

        guard commentLength == byteCount - (eocdOffset + ZipSignature.endOfCentralDirectorySize) else {
            // The comment length is the one EOCD field whose value is checkable
            // against the file length for free. Anything else means either a
            // corrupt tail or a second, conflicting EOCD record.
            throw IPAError.multipleCentralDirectories
        }

        if diskNumber == 0xFFFF || centralDirectoryDisk == 0xFFFF
            || entriesOnDisk == 0xFFFF || totalEntries == 0xFFFF
            || centralDirectorySize == 0xFFFF_FFFF || centralDirectoryOffset == 0xFFFF_FFFF {
            throw IPAError.zip64Unsupported
        }

        if eocdOffset >= 20 {
            let locator = try? cursor.uint32(at: eocdOffset - 20)
            if locator == ZipSignature.zip64EndOfCentralDirectoryLocator {
                throw IPAError.zip64Unsupported
            }
        }

        guard diskNumber == 0, centralDirectoryDisk == 0, entriesOnDisk == totalEntries else {
            throw IPAError.multipleCentralDirectories
        }

        guard centralDirectoryOffset >= 0, centralDirectorySize >= 0,
              centralDirectoryOffset <= eocdOffset,
              centralDirectorySize <= eocdOffset - centralDirectoryOffset else {
            throw IPAError.truncatedArchive(offset: centralDirectoryOffset)
        }

        guard totalEntries <= limits.maxEntryCount else {
            throw IPAError.entryCountExceeded(limit: limits.maxEntryCount, found: totalEntries)
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(totalEntries)
        var seenNames = Set<String>()
        var declaredTotal = 0
        var offset = centralDirectoryOffset

        for _ in 0..<totalEntries {
            guard offset + ZipSignature.centralDirectoryHeaderSize <= centralDirectoryOffset + centralDirectorySize else {
                throw IPAError.truncatedArchive(offset: offset)
            }
            guard try cursor.uint32(at: offset) == ZipSignature.centralDirectoryFileHeader else {
                throw IPAError.truncatedArchive(offset: offset)
            }

            let versionMadeBy = try cursor.uint16(at: offset + 4)
            let flags = try cursor.uint16(at: offset + 8)
            let method = try cursor.uint16(at: offset + 10)
            let crc = try cursor.uint32(at: offset + 16)
            let compressedSize = Int(try cursor.uint32(at: offset + 20))
            let uncompressedSize = Int(try cursor.uint32(at: offset + 24))
            let nameLength = Int(try cursor.uint16(at: offset + 28))
            let extraLength = Int(try cursor.uint16(at: offset + 30))
            let entryCommentLength = Int(try cursor.uint16(at: offset + 32))
            let externalAttributes = try cursor.uint32(at: offset + 38)
            let localHeaderOffset = Int(try cursor.uint32(at: offset + 42))

            let nameOffset = offset + ZipSignature.centralDirectoryHeaderSize
            guard nameLength > 0,
                  nameOffset + nameLength + extraLength + entryCommentLength <= centralDirectoryOffset + centralDirectorySize else {
                throw IPAError.truncatedArchive(offset: offset)
            }

            let rawName = try cursor.string(at: nameOffset, count: nameLength)
            let name = try SafePath.validated(rawName, maxBytes: limits.maxEntryNameBytes)

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
                throw IPAError.zip64Unsupported
            }

            let entry = ZipEntry(
                name: name,
                compressionMethod: method,
                generalPurposeFlags: flags,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                externalAttributes: externalAttributes,
                versionMadeBy: versionMadeBy
            )

            try validatePolicy(for: entry, seenNames: seenNames)

            // Every record must actually point at a local header inside the file,
            // and it must be before the central directory: that rules out an
            // offset that lands in the directory itself or past EOF, which is the
            // shape used to make two readers disagree about an entry's contents.
            guard entry.localHeaderOffset + ZipSignature.localFileHeaderSize <= centralDirectoryOffset,
                  try cursor.uint32(at: entry.localHeaderOffset) == ZipSignature.localFileHeader else {
                throw IPAError.localHeaderMismatch(name: entry.name)
            }

            seenNames.insert(entry.canonicalName)

            if entry.uncompressedSize > 0, !entry.isDirectory {
                guard entry.uncompressedSize <= limits.maxDeclaredEntrySize else {
                    throw IPAError.entryTooLarge(
                        name: entry.name,
                        declared: entry.uncompressedSize,
                        limit: limits.maxDeclaredEntrySize
                    )
                }
                let compressed = max(entry.compressedSize, 1)
                let ratio = Double(entry.uncompressedSize) / Double(compressed)
                if ratio > limits.maxCompressionRatio {
                    throw IPAError.compressionRatioExceeded(
                        name: entry.name,
                        ratio: ratio,
                        limit: limits.maxCompressionRatio
                    )
                }
                declaredTotal += entry.uncompressedSize
                guard declaredTotal <= limits.maxTotalDeclaredSize else {
                    throw IPAError.totalSizeExceeded(
                        limit: limits.maxTotalDeclaredSize,
                        declared: declaredTotal
                    )
                }
            }

            entries.append(entry)
            offset = nameOffset + nameLength + extraLength + entryCommentLength
        }

        return ZipDirectory(
            entries: entries,
            centralDirectoryOffset: centralDirectoryOffset,
            centralDirectorySize: centralDirectorySize,
            endOfCentralDirectoryOffset: eocdOffset
        )
    }

    private static func locateEndOfCentralDirectory(cursor: ByteCursor, byteCount: Int) throws -> Int {
        guard byteCount >= ZipSignature.endOfCentralDirectorySize else {
            throw IPAError.notAnArchive
        }
        let windowLength = min(byteCount, ZipSignature.maximumEndOfCentralDirectorySearchWindow)
        let windowStart = byteCount - windowLength
        let lastPossible = windowStart + windowLength - ZipSignature.endOfCentralDirectorySize

        var candidate = lastPossible
        while candidate >= windowStart {
            if (try? cursor.uint32(at: candidate)) == ZipSignature.endOfCentralDirectory {
                // Prefer the *last* signature whose comment length reaches the
                // end of the file; the first match can be archive payload that
                // happens to contain the magic.
                let commentLength = Int(try cursor.uint16(at: candidate + 20))
                if candidate + ZipSignature.endOfCentralDirectorySize + commentLength == byteCount {
                    return candidate
                }
            }
            candidate -= 1
        }
        throw IPAError.notAnArchive
    }

    /// Listing rules that depend only on one entry (plus the names seen so far).
    private static func validatePolicy(for entry: ZipEntry, seenNames: Set<String>) throws {
        guard !seenNames.contains(entry.canonicalName) else {
            throw IPAError.duplicateEntry(entry.name)
        }

        guard !entry.isEncrypted else {
            throw IPAError.encryptedEntry(entry.name)
        }

        switch entry.compressionMethod {
        case 0, 8:
            break
        default:
            throw IPAError.unsupportedCompressionMethod(name: entry.name, method: entry.compressionMethod)
        }

        if let permissions = entry.unixPermissions, permissions != 0 {
            switch permissions & 0o170000 {
            case 0o100000, 0o040000:
                break
            case 0o120000:
                throw IPAError.symlinkEntry(entry.name)
            default:
                // FIFOs, sockets, and device nodes. ZIP cannot express a hard
                // link either: the format has one record per name stream, so the
                // hard-link threat is duplicate names plus non-regular modes,
                // both of which are refused here.
                throw IPAError.specialFileEntry(entry.name)
            }
        }
    }
}

/// Path policy for entry names.
enum SafePath {
    static func validated(_ name: String, maxBytes: Int) throws -> String {
        guard !name.isEmpty else {
            throw IPAError.invalidEntryName(name: name, reason: .empty)
        }
        guard name.utf8.count <= maxBytes else {
            throw IPAError.entryNameTooLong(name: name, limit: maxBytes)
        }
        if name.hasPrefix("/") {
            throw IPAError.absolutePath(name)
        }
        if name.contains("\\") {
            throw IPAError.invalidEntryName(name: name, reason: .backslashSeparator)
        }
        for scalar in name.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            throw IPAError.invalidEntryName(name: name, reason: .controlCharacter)
        }
        if hasDriveLetterPrefix(name) {
            throw IPAError.absolutePath(name)
        }

        let isDirectory = name.hasSuffix("/")
        let body = isDirectory ? String(name.dropLast()) : name
        guard !body.isEmpty else {
            throw IPAError.invalidEntryName(name: name, reason: .emptyComponent)
        }

        for component in body.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty {
                throw IPAError.invalidEntryName(name: name, reason: .emptyComponent)
            }
            if component == "." {
                throw IPAError.invalidEntryName(name: name, reason: .dotComponent)
            }
            if component == ".." {
                throw IPAError.pathTraversal(name)
            }
        }
        return name
    }

    /// `C:evil` and `C:\evil` are absolute on Windows. The backslash form is
    /// already refused; this catches the slash form.
    private static func hasDriveLetterPrefix(_ name: String) -> Bool {
        let prefix = name.prefix(2)
        guard prefix.count == 2, prefix.last == ":" else { return false }
        guard let first = prefix.first, first.isLetter else { return false }
        return first.isASCII
    }
}

/// CRC-32 (IEEE 802.3), the checksum ZIP records per entry.
enum CRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }
        return table
    }()

    static func checksum(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        checksum(Data(bytes))
    }
}
