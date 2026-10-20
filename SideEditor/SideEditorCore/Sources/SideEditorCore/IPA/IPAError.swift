import Foundation

/// Why an entry name is not a safe relative path.
///
/// ZIP has no universal name encoding rule beyond "use `/`", so every reader
/// that also runs on Windows has to pick a policy. This package's policy is the
/// strict one: a name is either a plain relative path made of `/`-separated
/// segments, or it is rejected. Nothing is silently rewritten.
public enum NameViolation: String, Sendable, Equatable {
    case empty
    case invalidUTF8
    case controlCharacter
    /// Backslash is a path separator on Windows and a literal on POSIX. Two
    /// extractors disagreeing about it is exactly how `..\..\x` escapes.
    case backslashSeparator
    case emptyComponent
    case dotComponent
}

/// Every failure the reader can report, as a value the caller can switch on.
///
/// No case carries user data other than identifiers, offsets and sizes, so the
/// type is suitable for both tests and log records (report 10, T-13: nothing
/// that could contain a secret is interpolated).
public enum IPAError: Error, Sendable, Equatable {
    // Archive structure
    case notAnArchive
    case truncatedArchive(offset: Int)
    case zip64Unsupported
    case localHeaderMismatch(name: String)
    case multipleCentralDirectories

    // Entry policy
    case entryCountExceeded(limit: Int, found: Int)
    case entryNameTooLong(name: String, limit: Int)
    case invalidEntryName(name: String, reason: NameViolation)
    case pathTraversal(String)
    case absolutePath(String)
    case duplicateEntry(String)
    case symlinkEntry(String)
    case specialFileEntry(String)
    case encryptedEntry(String)
    case unsupportedCompressionMethod(name: String, method: UInt16)

    // Size and decompression limits
    case entryTooLarge(name: String, declared: Int, limit: Int)
    case totalSizeExceeded(limit: Int, declared: Int)
    case compressionRatioExceeded(name: String, ratio: Double, limit: Double)
    case decompressionLimitExceeded(name: String, limit: Int)
    case declaredSizeMismatch(name: String, declared: Int, produced: Int)
    case corruptDeflateStream(name: String)
    case checksumMismatch(name: String)
    case missingEntry(String)

    // Bundle graph
    case noApplicationBundle
    case multipleApplicationBundles([String])
    case nestedArchiveDepthExceeded(path: String, depth: Int, limit: Int)

    // Property lists
    case infoPlistTooLarge(declared: Int, limit: Int)
    case missingInfoPlist(String)
    case malformedInfoPlist(String)
    case mistypedInfoPlist(key: String, expected: String)
    case plistTooDeep(limit: Int)
}

extension IPAError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "The file is not a ZIP archive."
        case let .truncatedArchive(offset):
            return "The archive is truncated at byte \(offset)."
        case .zip64Unsupported:
            return "ZIP64 archives are not supported."
        case let .localHeaderMismatch(name):
            return "The local header for \(name) disagrees with the central directory."
        case .multipleCentralDirectories:
            return "The archive declares more than one central directory."
        case let .entryCountExceeded(limit, found):
            return "The archive declares \(found) entries, above the limit of \(limit)."
        case let .entryNameTooLong(name, limit):
            return "An entry name of \(name.utf8.count) bytes exceeds the limit of \(limit)."
        case let .invalidEntryName(name, reason):
            return "The entry name \"\(name)\" is not a safe relative path (\(reason.rawValue))."
        case let .pathTraversal(name):
            return "The entry name \"\(name)\" escapes the archive root."
        case let .absolutePath(name):
            return "The entry name \"\(name)\" is an absolute path."
        case let .duplicateEntry(name):
            return "The archive contains more than one entry named \"\(name)\"."
        case let .symlinkEntry(name):
            return "The entry \"\(name)\" is a symbolic link."
        case let .specialFileEntry(name):
            return "The entry \"\(name)\" is not a regular file or directory."
        case let .encryptedEntry(name):
            return "The entry \"\(name)\" is encrypted."
        case let .unsupportedCompressionMethod(name, method):
            return "The entry \"\(name)\" uses unsupported compression method \(method)."
        case let .entryTooLarge(name, declared, limit):
            return "The entry \"\(name)\" declares \(declared) bytes, above the limit of \(limit)."
        case let .totalSizeExceeded(limit, declared):
            return "The archive declares \(declared) uncompressed bytes, above the limit of \(limit)."
        case let .compressionRatioExceeded(name, ratio, limit):
            return "The entry \"\(name)\" expands \(ratio)x, above the limit of \(limit)x."
        case let .decompressionLimitExceeded(name, limit):
            return "The entry \"\(name)\" expands past the \(limit) byte read limit."
        case let .declaredSizeMismatch(name, declared, produced):
            return "The entry \"\(name)\" declares \(declared) bytes but produced \(produced)."
        case let .corruptDeflateStream(name):
            return "The entry \"\(name)\" contains a corrupt DEFLATE stream."
        case let .checksumMismatch(name):
            return "The entry \"\(name)\" does not match its recorded CRC-32."
        case let .missingEntry(name):
            return "The archive does not contain \"\(name)\"."
        case .noApplicationBundle:
            return "The archive does not contain a Payload/*.app bundle."
        case let .multipleApplicationBundles(paths):
            return "The archive contains more than one application bundle: \(paths.joined(separator: ", "))."
        case let .nestedArchiveDepthExceeded(path, depth, limit):
            return "The nested archive \"\(path)\" is \(depth) levels deep, above the limit of \(limit)."
        case let .infoPlistTooLarge(declared, limit):
            return "The Info.plist declares \(declared) bytes, above the limit of \(limit)."
        case let .missingInfoPlist(path):
            return "The bundle at \"\(path)\" has no Info.plist."
        case let .malformedInfoPlist(reason):
            return "The Info.plist is malformed: \(reason)"
        case let .mistypedInfoPlist(key, expected):
            return "The Info.plist key \(key) is not a \(expected)."
        case let .plistTooDeep(limit):
            return "The property list nests deeper than \(limit) levels."
        }
    }
}
