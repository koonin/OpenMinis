import Foundation

/// Reads and writes PendingShare data to the App Group shared container.
/// Compiled into both the main app target and the Share Extension target.
enum SharedContainerStore {
    static let appGroupID = "group.com.koon.minis"

    private static let pendingShareKey = "pendingShare"

    /// The real App Group container, or `nil` when the active provisioning
    /// profile does not include App Groups (for example a Personal Team build).
    static var appGroupContainerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
    }

    static var isAppGroupAvailable: Bool {
        appGroupContainerURL != nil
    }

    /// Personal development teams cannot provision App Groups. Keep Debug
    /// builds usable by falling back to this process's Application Support
    /// directory; cross-process sharing remains unavailable in that mode.
    static var containerURL: URL { resolvedContainerURL }

    private static let resolvedContainerURL: URL = {
        let fallback = fallbackContainerURL
        if let groupURL = appGroupContainerURL {
            // Run before any store opens its files. Keep the fallback as a
            // recovery copy and never replace existing App Group content.
            do {
                try SharedStorageMigration.migrateOnce(from: fallback, to: groupURL)
            } catch {
                NSLog("[SharedStorage] migration incomplete; source retained: %@", error.localizedDescription)
            }
            return groupURL
        }
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }()

    static var fallbackContainerURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PersonalTeamShared", isDirectory: true)
    }

    static var sharedDefaults: UserDefaults? {
        if isAppGroupAvailable {
            return UserDefaults(suiteName: appGroupID)
        }
        return .standard
    }

    /// Directory in the shared container for transferring attachment files.
    static var sharedFileDirectory: URL? {
        containerURL.appendingPathComponent("ShareExtension", isDirectory: true)
    }

    // MARK: - Write (called by Share Extension)

    static func savePendingShare(_ share: PendingShare) {
        guard let defaults = sharedDefaults else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(share) {
            defaults.set(data, forKey: pendingShareKey)
            defaults.synchronize()
        }
    }

    // MARK: - Read & Consume (called by main app)

    static func loadPendingShare() -> PendingShare? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: pendingShareKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingShare.self, from: data)
    }

    static func clearPendingShare() {
        sharedDefaults?.removeObject(forKey: pendingShareKey)
        sharedDefaults?.synchronize()
    }

    /// Remove all files from the shared transfer directory.
    static func cleanSharedFiles() {
        guard let dir = sharedFileDirectory else { return }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }
}

/// Copy-only migration for restoring App Group signing after a fallback build.
/// A successful marker prevents deleted files from being resurrected on launch.
/// Failed copies leave no marker and can safely retry; conflicts retain both copies.
enum SharedStorageMigration {
    static let markerName = ".app-group-migration-v1"

    static func migrateOnce(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        let marker = source.appendingPathComponent(markerName)
        guard !fm.fileExists(atPath: marker.path) else { return }
        for name in ["MinisFileProvider", "MinisConfig"] {
            let child = source.appendingPathComponent(name)
            if fm.fileExists(atPath: child.path) {
                try mergeMissing(from: child, to: destination.appendingPathComponent(name))
            }
        }
        try Data("Copied to App Group; fallback retained for recovery.\n".utf8)
            .write(to: marker, options: .atomic)
    }

    static func mergeMissing(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let sourceAttributes = try fm.attributesOfItem(atPath: source.path)
        let destinationAttributes: [FileAttributeKey: Any]?
        do {
            destinationAttributes = try fm.attributesOfItem(atPath: destination.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            destinationAttributes = nil
        }
        // Never follow an existing destination symlink outside the storage tree.
        if destinationAttributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            // A previous partial copy may already have copied a venv symlink.
            // Treat it as an existing leaf, not a directory to traverse.
            if sourceAttributes[.type] as? FileAttributeType == .typeSymbolicLink { return }
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if sourceAttributes[.type] as? FileAttributeType == .typeDirectory {
            if let destinationAttributes,
               destinationAttributes[.type] as? FileAttributeType != .typeDirectory {
                throw CocoaError(.fileWriteFileExists)
            }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try mergeMissing(from: child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else if destinationAttributes == nil {
            try fm.copyItem(at: source, to: destination)
        }
    }
}
