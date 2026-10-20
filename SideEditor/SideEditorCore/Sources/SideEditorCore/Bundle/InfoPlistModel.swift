import Foundation

/// A typed property-list value.
///
/// `boolean` and `integer` are separate cases on purpose: `UIFileSharingEnabled`
/// is a flag, `CFBundleVersion` is often numeric, and a reader that collapses
/// them cannot round-trip or report a mistyped key.
public indirect enum PlistValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case real(Double)
    case boolean(Bool)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])
}

/// A read-only, typed view of a bundle's `Info.plist`.
///
/// Scope note (Phase 2): values are read through `PropertyListSerialization`, so
/// the *set* of keys is complete but dictionary order is not preserved — that is
/// a property of Foundation's plist objects, not a parsing shortcut. An
/// order-preserving model belongs to the Phase 3 editor model, which needs to
/// rewrite the document instead of only reading it.
public struct InfoPlistModel: Sendable, Equatable {
    public let values: [String: PlistValue]

    public init(values: [String: PlistValue]) {
        self.values = values
    }

    public subscript(key: String) -> PlistValue? {
        values[key]
    }

    public var keys: [String] {
        values.keys.sorted()
    }

    /// Parses XML, binary, or OpenStep property lists.
    ///
    /// Throws `IPAError.malformedInfoPlist` for anything Foundation refuses, a
    /// non-dictionary root, or a value type a plist cannot contain;
    /// `IPAError.plistTooDeep` when containers nest past
    /// `limits.maxPlistDepth` (T-05: a deeply nested file must not become
    /// unbounded recursion).
    public static func parse(_ data: Data, limits: InspectionLimits = .default) throws -> InfoPlistModel {
        guard !data.isEmpty else {
            throw IPAError.malformedInfoPlist("the file is empty")
        }

        let raw: Any
        do {
            raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw IPAError.malformedInfoPlist("the bytes are not a property list")
        }

        let value = try PlistValue.make(from: raw, depth: 0, limits: limits)
        guard case let .dictionary(values) = value else {
            throw IPAError.malformedInfoPlist("the root object is not a dictionary")
        }
        return InfoPlistModel(values: values)
    }

    // MARK: Typed accessors

    public func string(for key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case let .string(string) = value else {
            throw IPAError.mistypedInfoPlist(key: key, expected: "String")
        }
        return string
    }

    public func integer(for key: String) throws -> Int? {
        guard let value = values[key] else { return nil }
        guard case let .integer(integer) = value else {
            throw IPAError.mistypedInfoPlist(key: key, expected: "Integer")
        }
        return integer
    }

    public func boolean(for key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard case let .boolean(boolean) = value else {
            throw IPAError.mistypedInfoPlist(key: key, expected: "Boolean")
        }
        return boolean
    }

    public func array(for key: String) throws -> [PlistValue]? {
        guard let value = values[key] else { return nil }
        guard case let .array(array) = value else {
            throw IPAError.mistypedInfoPlist(key: key, expected: "Array")
        }
        return array
    }

    public func dictionary(for key: String) throws -> [String: PlistValue]? {
        guard let value = values[key] else { return nil }
        guard case let .dictionary(dictionary) = value else {
            throw IPAError.mistypedInfoPlist(key: key, expected: "Dictionary")
        }
        return dictionary
    }
}

extension PlistValue {
    /// Converts a Foundation plist object graph.
    ///
    /// On both Darwin and Linux, plist booleans arrive as `NSNumber` with the
    /// `c`/`B` Objective-C type; integers arrive as 64-bit `q` and reals as `d`.
    /// That is checked rather than `as? Bool`, which would also accept `1`.
    static func make(from object: Any, depth: Int, limits: InspectionLimits) throws -> PlistValue {
        guard depth <= limits.maxPlistDepth else {
            throw IPAError.plistTooDeep(limit: limits.maxPlistDepth)
        }

        if let dictionary = object as? [String: Any] {
            var converted: [String: PlistValue] = [:]
            converted.reserveCapacity(dictionary.count)
            for (key, value) in dictionary {
                converted[key] = try make(from: value, depth: depth + 1, limits: limits)
            }
            return .dictionary(converted)
        }

        if let array = object as? [Any] {
            return .array(try array.map { try make(from: $0, depth: depth + 1, limits: limits) })
        }

        if let data = object as? Data {
            return .data(data)
        }

        if let date = object as? Date {
            return .date(date)
        }

        if let number = object as? NSNumber {
            let objCType = String(cString: number.objCType)
            if objCType == "c" || objCType == "B" {
                return .boolean(number.boolValue)
            }
            if objCType == "d" || objCType == "f" {
                return .real(number.doubleValue)
            }
            return .integer(number.intValue)
        }

        if let string = object as? String {
            return .string(string)
        }

        throw IPAError.malformedInfoPlist("unsupported value of type \(type(of: object))")
    }
}
