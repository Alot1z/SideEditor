import Foundation

/// Resource ceilings applied while listing and reading an archive.
///
/// Two kinds of limit are deliberately separate:
///
/// * **Listing** limits refuse an archive that *claims* to be hostile, using only
///   the central directory. They cost no decompression.
/// * **Read** limits bound what the reader is willing to decompress into memory.
///
/// A large, legitimate binary (a 300 MB game) is fine to list but is not read by
/// default; callers that need the bytes pass a larger `maxBytes` explicitly.
/// That is why `maxReadableEntrySize` is much smaller than
/// `maxDeclaredEntrySize` — it is a memory guard, not a validity rule.
public struct InspectionLimits: Sendable, Equatable {
    /// Number of central-directory records.
    public var maxEntryCount: Int
    /// Length of a single entry name, in UTF-8 bytes.
    public var maxEntryNameBytes: Int
    /// Hard ceiling for any single entry's declared uncompressed size.
    public var maxDeclaredEntrySize: Int
    /// Hard ceiling for the sum of all declared uncompressed sizes.
    public var maxTotalDeclaredSize: Int
    /// Declared expansion ratio (uncompressed / compressed) for a non-empty entry.
    public var maxCompressionRatio: Double
    /// Bytes the reader will decompress into memory for one entry by default.
    public var maxReadableEntrySize: Int
    /// Bytes read for a bundle's Info.plist.
    public var maxInfoPlistSize: Int
    /// Maximum number of path components for an entry ending in `.ipa`.
    public var maxNestedArchiveDepth: Int
    /// Maximum nesting of property-list containers while converting to `PlistValue`.
    public var maxPlistDepth: Int

    public init(
        maxEntryCount: Int = 4_096,
        maxEntryNameBytes: Int = 1_024,
        maxDeclaredEntrySize: Int = 2 * 1_024 * 1_024 * 1_024,
        maxTotalDeclaredSize: Int = 4 * 1_024 * 1_024 * 1_024,
        maxCompressionRatio: Double = 200,
        maxReadableEntrySize: Int = 64 * 1_024 * 1_024,
        maxInfoPlistSize: Int = 4 * 1_024 * 1_024,
        maxNestedArchiveDepth: Int = 8,
        maxPlistDepth: Int = 64
    ) {
        self.maxEntryCount = maxEntryCount
        self.maxEntryNameBytes = maxEntryNameBytes
        self.maxDeclaredEntrySize = maxDeclaredEntrySize
        self.maxTotalDeclaredSize = maxTotalDeclaredSize
        self.maxCompressionRatio = maxCompressionRatio
        self.maxReadableEntrySize = maxReadableEntrySize
        self.maxInfoPlistSize = maxInfoPlistSize
        self.maxNestedArchiveDepth = maxNestedArchiveDepth
        self.maxPlistDepth = maxPlistDepth
    }

    public static let `default` = InspectionLimits()
}
