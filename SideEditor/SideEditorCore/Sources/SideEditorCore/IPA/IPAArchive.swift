import Foundation

/// A read-only view of an IPA (or any ZIP archive).
///
/// Opening the archive validates the central directory against
/// `InspectionLimits` and the path policy in `SafePath`; it never writes to the
/// source file, never extracts implicitly, and never decompresses an entry until
/// one is asked for by name.
///
/// The bytes come from a memory-mapped file handle, so opening a 300 MB IPA does
/// not copy it, and reading one small entry does not read the whole archive.
public final class IPAArchive {
    public let sourceURL: URL?
    public let byteCount: Int
    public let entries: [ZipEntry]
    public let limits: InspectionLimits

    private let data: Data
    private let directory: ZipDirectory

    public convenience init(contentsOf url: URL, limits: InspectionLimits = .default) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try self.init(data: data, sourceURL: url, limits: limits)
    }

    /// For callers that already hold the bytes (and for the fixture tests).
    public init(data: Data, sourceURL: URL? = nil, limits: InspectionLimits = .default) throws {
        self.data = data
        self.sourceURL = sourceURL
        self.byteCount = data.count
        self.limits = limits
        self.directory = try ZipDirectoryParser.parse(data: data, byteCount: data.count, limits: limits)
        self.entries = directory.entries
    }

    public var entryNames: [String] { entries.map(\.name) }

    public func entry(named name: String) -> ZipEntry? {
        entries.first { $0.name == name }
    }

    /// Reads and checks one entry.
    ///
    /// `maxBytes` bounds the decompressed size; the default is
    /// `limits.maxReadableEntrySize`. The declared size must already be within
    /// the bound, so a lying central directory cannot talk the reader into a huge
    /// allocation — the decoder also stops at the bound.
    public func readEntry(named name: String, maxBytes: Int? = nil) throws -> Data {
        guard let entry = entry(named: name) else {
            throw IPAError.missingEntry(name)
        }
        return try read(entry: entry, maxBytes: maxBytes ?? limits.maxReadableEntrySize)
    }

    /// Extracts every entry into `destination`, which is created if needed.
    ///
    /// Nothing is written outside `destination`: names were validated when the
    /// directory was parsed, and every target is re-checked for containment
    /// before it is written (defence in depth — a future parser change must not
    /// be able to turn into a write outside the sandbox).
    @discardableResult
    public func extractAll(to destination: URL, maxBytes: Int? = nil) throws -> [String] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL

        var written: [String] = []
        for entry in entries {
            if entry.isDirectory {
                let target = try containedURL(for: entry.canonicalName, under: root)
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let target = try containedURL(for: entry.name, under: root)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let bytes = try read(entry: entry, maxBytes: maxBytes ?? limits.maxReadableEntrySize)
            try bytes.write(to: target, options: .atomic)
            written.append(entry.name)
        }
        return written
    }

    private func containedURL(for relativePath: String, under root: URL) throws -> URL {
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw IPAError.pathTraversal(relativePath)
        }

        // Lexical containment is not enough: if the destination already holds a
        // symlinked directory, writing "through" it lands outside. Resolve the
        // deepest existing ancestor and require that it is still inside the
        // destination. A symlinked *file* is safe because `.atomic` writes replace
        // the link instead of following it.
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedRootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        var ancestor = candidate.deletingLastPathComponent()
        while ancestor.path != root.path, !FileManager.default.fileExists(atPath: ancestor.path) {
            ancestor = ancestor.deletingLastPathComponent()
        }
        let resolvedAncestor = ancestor.resolvingSymlinksInPath()
        guard resolvedAncestor.path == resolvedRoot.path || resolvedAncestor.path.hasPrefix(resolvedRootPath) else {
            throw IPAError.pathTraversal(relativePath)
        }
        return candidate
    }

    private func read(entry: ZipEntry, maxBytes: Int) throws -> Data {
        let cursor = ByteCursor(data: data, context: entry.name)
        guard try cursor.uint32(at: entry.localHeaderOffset) == ZipSignature.localFileHeader else {
            throw IPAError.localHeaderMismatch(name: entry.name)
        }

        let localNameLength = Int(try cursor.uint16(at: entry.localHeaderOffset + 26))
        let localExtraLength = Int(try cursor.uint16(at: entry.localHeaderOffset + 28))
        let localName = try cursor.string(at: entry.localHeaderOffset + 30, count: localNameLength)
        guard localName == entry.name else {
            throw IPAError.localHeaderMismatch(name: entry.name)
        }

        let payloadOffset = entry.localHeaderOffset
            + ZipSignature.localFileHeaderSize
            + localNameLength
            + localExtraLength
        // Payload may not run into the central directory; that is the shape of a
        // overlapping-entry ("zip quine"/mismatch) attack.
        guard payloadOffset <= directory.centralDirectoryOffset,
              entry.compressedSize <= directory.centralDirectoryOffset - payloadOffset else {
            throw IPAError.truncatedArchive(offset: payloadOffset)
        }

        let declared = entry.uncompressedSize
        let limit = min(maxBytes, limits.maxDeclaredEntrySize)
        guard declared <= limit else {
            throw IPAError.entryTooLarge(name: entry.name, declared: declared, limit: limit)
        }

        let compressed = try cursor.bytes(at: payloadOffset, count: entry.compressedSize)
        let output: Data
        switch entry.compressionMethod {
        case 0:
            guard entry.compressedSize == declared else {
                throw IPAError.declaredSizeMismatch(
                    name: entry.name,
                    declared: declared,
                    produced: entry.compressedSize
                )
            }
            output = compressed
        case 8:
            var inflater = Inflater(input: compressed, outputLimit: declared, entryName: entry.name)
            output = try inflater.run()
        default:
            throw IPAError.unsupportedCompressionMethod(name: entry.name, method: entry.compressionMethod)
        }

        guard output.count == declared else {
            throw IPAError.declaredSizeMismatch(name: entry.name, declared: declared, produced: output.count)
        }
        guard CRC32.checksum(output) == entry.crc32 else {
            throw IPAError.checksumMismatch(name: entry.name)
        }
        return output
    }
}

/// Counts that describe an archive without exposing its bytes.
public struct IPAArchiveSummary: Sendable, Equatable {
    public let byteCount: Int
    public let entryCount: Int
    public let totalUncompressedSize: Int
    public let compressedEntryCount: Int
    public let directoryEntryCount: Int

    public init(
        byteCount: Int,
        entryCount: Int,
        totalUncompressedSize: Int,
        compressedEntryCount: Int,
        directoryEntryCount: Int
    ) {
        self.byteCount = byteCount
        self.entryCount = entryCount
        self.totalUncompressedSize = totalUncompressedSize
        self.compressedEntryCount = compressedEntryCount
        self.directoryEntryCount = directoryEntryCount
    }
}

/// One inspection pass: summary, bundle graph, and the primary app's Info.plist.
public struct IPAInspection: Sendable, Equatable {
    public let summary: IPAArchiveSummary
    public let graph: BundleGraph

    public var primaryApplication: BundleGraph.Application? { graph.primaryApplication }
    public var infoPlist: InfoPlistModel? { graph.primaryApplication?.infoPlist }

    public init(summary: IPAArchiveSummary, graph: BundleGraph) {
        self.summary = summary
        self.graph = graph
    }
}

/// The single entry point Phase 3 and later should build on.
public enum IPAScanner {
    public static func inspect(
        contentsOf url: URL,
        limits: InspectionLimits = .default
    ) throws -> IPAInspection {
        let archive = try IPAArchive(contentsOf: url, limits: limits)
        return try inspect(archive: archive, limits: limits)
    }

    public static func inspect(
        archive: IPAArchive,
        limits: InspectionLimits? = nil
    ) throws -> IPAInspection {
        let effectiveLimits = limits ?? archive.limits
        let graph = try BundleGraph.build(archive: archive, limits: effectiveLimits)
        let summary = IPAArchiveSummary(
            byteCount: archive.byteCount,
            entryCount: archive.entries.count,
            totalUncompressedSize: archive.entries.reduce(0) { $0 + $1.uncompressedSize },
            compressedEntryCount: archive.entries.filter {
                !$0.isDirectory && $0.compressionMethod == 8
            }.count,
            directoryEntryCount: archive.entries.filter(\.isDirectory).count
        )
        return IPAInspection(summary: summary, graph: graph)
    }
}
