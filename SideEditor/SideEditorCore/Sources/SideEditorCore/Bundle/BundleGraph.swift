import Foundation

/// What an IPA contains, in bundle terms.
///
/// Discovery is name-based and never recursive into nested archives: Phase 2
/// lists a nested `.ipa` and its depth, it does not open it (that belongs to the
/// export phase, where the plan requires an explicit entry set).
public struct BundleGraph: Sendable, Equatable {
    public struct AppExtension: Sendable, Equatable {
        /// `Payload/App.app/PlugIns/Widget.appex`
        public let path: String
        public let bundleIdentifier: String?
        public let infoPlistPath: String?
    }

    public struct Framework: Sendable, Equatable {
        /// `Payload/App.app/Frameworks/Lib.framework`
        public let path: String
        public let bundleIdentifier: String?
        public let infoPlistPath: String?
    }

    public struct Application: Sendable, Equatable {
        /// `Payload/App.app`
        public let path: String
        public let bundleIdentifier: String?
        public let shortVersion: String?
        public let minimumOSVersion: String?
        /// `Payload/App.app/App`, when `CFBundleExecutable` names an entry that exists.
        public let executablePath: String?
        public let infoPlist: InfoPlistModel
        public let extensions: [AppExtension]
        public let frameworks: [Framework]
    }

    public struct NestedArchive: Sendable, Equatable {
        public let path: String
        /// Number of path components, so a caller can see nesting without opening it.
        public let depth: Int
    }

    public let applications: [Application]
    public let nestedArchives: [NestedArchive]

    /// The app an IPA is expected to contain. `build` rejects anything but one,
    /// so this is non-nil for every graph it returns.
    public var primaryApplication: Application? {
        applications.count == 1 ? applications[0] : nil
    }

    public init(applications: [Application], nestedArchives: [NestedArchive]) {
        self.applications = applications
        self.nestedArchives = nestedArchives
    }

    /// Builds the graph, reading only the plists it needs (the app and each
    /// extension), each capped at `limits.maxInfoPlistSize`.
    public static func build(archive: IPAArchive, limits: InspectionLimits = .default) throws -> BundleGraph {
        // `isDirectory` covers mode-only directory entries, which have no slash;
        // filtering on the slash alone would list such a directory as a file.
        let fileNames = archive.entries.filter { !$0.isDirectory }.map(\.name)
        let nameSet = Set(fileNames)

        var appPaths = Set<String>()
        for name in fileNames {
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count >= 3, components[0] == "Payload" else { continue }
            let bundleName = String(components[1])
            guard bundleName.hasSuffix(".app") else { continue }
            appPaths.insert("Payload/\(bundleName)")
        }

        let sortedAppPaths = appPaths.sorted()
        guard !sortedAppPaths.isEmpty else { throw IPAError.noApplicationBundle }
        guard sortedAppPaths.count == 1 else {
            throw IPAError.multipleApplicationBundles(sortedAppPaths)
        }

        var applications: [Application] = []
        for appPath in sortedAppPaths {
            applications.append(
                try application(at: appPath, archive: archive, fileNames: fileNames, nameSet: nameSet, limits: limits)
            )
        }

        var nested: [NestedArchive] = []
        for name in fileNames where name.lowercased().hasSuffix(".ipa") {
            let depth = name.split(separator: "/", omittingEmptySubsequences: false).count
            guard depth <= limits.maxNestedArchiveDepth else {
                throw IPAError.nestedArchiveDepthExceeded(
                    path: name,
                    depth: depth,
                    limit: limits.maxNestedArchiveDepth
                )
            }
            nested.append(NestedArchive(path: name, depth: depth))
        }

        return BundleGraph(applications: applications, nestedArchives: nested.sorted { $0.path < $1.path })
    }

    private static func application(
        at appPath: String,
        archive: IPAArchive,
        fileNames: [String],
        nameSet: Set<String>,
        limits: InspectionLimits
    ) throws -> Application {
        let infoPlistPath = "\(appPath)/Info.plist"
        guard nameSet.contains(infoPlistPath) else {
            throw IPAError.missingInfoPlist(appPath)
        }
        let infoPlist = try loadInfoPlist(at: infoPlistPath, archive: archive, limits: limits)

        guard let bundleIdentifier = try infoPlist.string(for: "CFBundleIdentifier"), !bundleIdentifier.isEmpty else {
            throw IPAError.malformedInfoPlist("CFBundleIdentifier is missing from \(infoPlistPath)")
        }

        var executablePath: String?
        if let executable = try infoPlist.string(for: "CFBundleExecutable"), !executable.isEmpty {
            let path = "\(appPath)/\(executable)"
            guard nameSet.contains(path) else { throw IPAError.missingEntry(path) }
            executablePath = path
        }

        let extensions = try childBundles(
            prefix: "\(appPath)/PlugIns/",
            suffix: ".appex",
            archive: archive,
            fileNames: fileNames,
            nameSet: nameSet,
            limits: limits
        ).map { pair in
            AppExtension(
                path: pair.0,
                bundleIdentifier: pair.1,
                infoPlistPath: nameSet.contains("\(pair.0)/Info.plist") ? "\(pair.0)/Info.plist" : nil
            )
        }

        let frameworks = try childBundles(
            prefix: "\(appPath)/Frameworks/",
            suffix: ".framework",
            archive: archive,
            fileNames: fileNames,
            nameSet: nameSet,
            limits: limits
        ).map { pair in
            Framework(
                path: pair.0,
                bundleIdentifier: pair.1,
                infoPlistPath: nameSet.contains("\(pair.0)/Info.plist") ? "\(pair.0)/Info.plist" : nil
            )
        }

        return Application(
            path: appPath,
            bundleIdentifier: bundleIdentifier,
            shortVersion: try infoPlist.string(for: "CFBundleShortVersionString"),
            minimumOSVersion: try infoPlist.string(for: "MinimumOSVersion"),
            executablePath: executablePath,
            infoPlist: infoPlist,
            extensions: extensions,
            frameworks: frameworks
        )
    }

    /// Immediate children of `prefix` whose name ends in `suffix`, with their
    /// bundle identifier when they carry a readable `Info.plist`.
    private static func childBundles(
        prefix: String,
        suffix: String,
        archive: IPAArchive,
        fileNames: [String],
        nameSet: Set<String>,
        limits: InspectionLimits
    ) throws -> [(String, String?)] {
        var paths = Set<String>()
        for name in fileNames where name.hasPrefix(prefix) {
            let remainder = name.dropFirst(prefix.count)
            guard let component = remainder.split(separator: "/", omittingEmptySubsequences: false).first,
                  !component.isEmpty, component.hasSuffix(suffix) else { continue }
            paths.insert("\(prefix)\(component)")
        }

        var result: [(String, String?)] = []
        for path in paths.sorted() {
            let plistPath = "\(path)/Info.plist"
            if nameSet.contains(plistPath) {
                let model = try loadInfoPlist(at: plistPath, archive: archive, limits: limits)
                result.append((path, try model.string(for: "CFBundleIdentifier")))
            } else {
                result.append((path, nil))
            }
        }
        return result
    }

    private static func loadInfoPlist(
        at path: String,
        archive: IPAArchive,
        limits: InspectionLimits
    ) throws -> InfoPlistModel {
        guard let entry = archive.entry(named: path) else {
            throw IPAError.missingInfoPlist(path)
        }
        guard entry.uncompressedSize <= limits.maxInfoPlistSize else {
            throw IPAError.infoPlistTooLarge(declared: entry.uncompressedSize, limit: limits.maxInfoPlistSize)
        }
        let data = try archive.readEntry(named: path, maxBytes: limits.maxInfoPlistSize)
        return try InfoPlistModel.parse(data, limits: limits)
    }
}
