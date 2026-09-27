import CryptoKit
import Foundation

public enum FolderSyncLocation: String, Codable, Sendable, Equatable {
    case externalDrive = "external_drive"
    case googleDrive = "google_drive"
}

public struct FolderSyncDeletionItem: Codable, Sendable, Equatable, Identifiable {
    public let location: FolderSyncLocation
    public let relativePaths: [String]
    public let isLivePhoto: Bool
    public let expectedTargetSHA256ByPath: [String: Data]

    public var id: String {
        location.rawValue + ":" + relativePaths.joined(separator: "\u{1F}")
    }

    public init(
        location: FolderSyncLocation,
        relativePaths: [String],
        isLivePhoto: Bool,
        expectedTargetSHA256ByPath: [String: Data] = [:]
    ) {
        self.location = location
        self.relativePaths = relativePaths.sorted()
        self.isLivePhoto = isLivePhoto
        self.expectedTargetSHA256ByPath = expectedTargetSHA256ByPath
    }
}

public struct FolderSyncDeletionPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let items: [FolderSyncDeletionItem]
    public let previousCompletedLogicalItemCountLowerBound: Int
    public let emptiedNonEmptyDirectories: [String]
    public let requiresConfirmation: Bool

    public var logicalItemCount: Int { items.count }

    public init(
        items: [FolderSyncDeletionItem],
        previousCompletedLogicalItemCountLowerBound: Int,
        emptiedNonEmptyDirectories: [String]
    ) {
        let normalizedItems = items.sorted { lhs, rhs in
            (lhs.location.rawValue, lhs.relativePaths.joined(separator: "/"))
                < (rhs.location.rawValue, rhs.relativePaths.joined(separator: "/"))
        }
        let normalizedDirectories = emptiedNonEmptyDirectories.sorted()
        let count = normalizedItems.count
        let baseline = max(previousCompletedLogicalItemCountLowerBound, 0)
        let largeFraction = count >= 10 && baseline > 0 && count * 100 >= baseline * 20
        let requiresConfirmation = !normalizedDirectories.isEmpty || count >= 100 || largeFraction

        self.items = normalizedItems
        self.previousCompletedLogicalItemCountLowerBound = baseline
        self.emptiedNonEmptyDirectories = normalizedDirectories
        self.requiresConfirmation = requiresConfirmation

        var fingerprint = "baseline=\(baseline)\n"
        for item in normalizedItems {
            fingerprint += "item=\(item.location.rawValue)|\(item.isLivePhoto ? 1 : 0)|"
                + item.relativePaths.joined(separator: "\u{1F}") + "\n"
            for path in item.expectedTargetSHA256ByPath.keys.sorted() {
                fingerprint += "hash=\(path)|"
                    + (item.expectedTargetSHA256ByPath[path]?.lowercaseHexString ?? "") + "\n"
            }
        }
        for directory in normalizedDirectories {
            fingerprint += "empty=\(directory)\n"
        }
        self.id = SHA256.hash(data: Data(fingerprint.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct FolderSyncRecoveryItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let location: FolderSyncLocation
    public let originalRelativePath: String
    public let recoveryRelativePath: String
    public let byteSize: Int64
    public let modifiedAt: Date?
    public let driveRevisionFileID: String?
    public let driveRevisionID: String?
    public let expectedSHA256: Data?

    public init(
        location: FolderSyncLocation,
        originalRelativePath: String,
        recoveryRelativePath: String,
        byteSize: Int64,
        modifiedAt: Date?,
        driveRevisionFileID: String? = nil,
        driveRevisionID: String? = nil,
        expectedSHA256: Data? = nil
    ) {
        self.location = location
        self.originalRelativePath = originalRelativePath
        self.recoveryRelativePath = recoveryRelativePath
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.driveRevisionFileID = driveRevisionFileID
        self.driveRevisionID = driveRevisionID
        self.expectedSHA256 = expectedSHA256
        if let driveRevisionFileID, let driveRevisionID {
            self.id = location.rawValue + ":revision:" + driveRevisionFileID + ":" + driveRevisionID
        } else {
            self.id = location.rawValue + ":" + recoveryRelativePath
        }
    }
}

public struct FolderSyncRecoverySummary: Sendable, Equatable {
    public let itemCount: Int
    public let totalBytes: Int64
    public let externalDriveItemCount: Int
    public let googleDriveItemCount: Int

    public init(items: [FolderSyncRecoveryItem]) {
        itemCount = items.count
        totalBytes = items.reduce(0) { $0 + max($1.byteSize, 0) }
        externalDriveItemCount = items.count { $0.location == .externalDrive }
        googleDriveItemCount = items.count { $0.location == .googleDrive }
    }
}

enum FolderSyncLocalRecoveryStore {
    static func items(connection: FolderSyncConnection) throws -> [FolderSyncRecoveryItem] {
        let root = URL(fileURLWithPath: connection.localRecoveryDirectoryPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var values: [FolderSyncRecoveryItem] = []
        for case let url as URL in enumerator {
            let resource = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            guard resource.isRegularFile == true, resource.isSymbolicLink != true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(rootPrefix) else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            let recoveryRelative = String(resolved.path.dropFirst(rootPrefix.count))
            guard let original = originalRelativePath(
                recoveryRelativePath: recoveryRelative,
                sideDirectory: "path1"
            ) ?? originalRelativePath(
                recoveryRelativePath: recoveryRelative,
                sideDirectory: "path1-conflicts"
            ) else { continue }
            values.append(
                FolderSyncRecoveryItem(
                    location: .externalDrive,
                    originalRelativePath: original,
                    recoveryRelativePath: recoveryRelative,
                    byteSize: Int64(resource.fileSize ?? 0),
                    modifiedAt: resource.contentModificationDate
                )
            )
        }
        return values.sorted { $0.recoveryRelativePath < $1.recoveryRelativePath }
    }

    static func restore(
        _ item: FolderSyncRecoveryItem,
        connection: FolderSyncConnection,
        root: RegisteredRootReport
    ) throws {
        guard item.location == .externalDrive,
              let safeOriginal = safeRelativePath(item.originalRelativePath),
              let safeRecovery = safeRelativePath(item.recoveryRelativePath)
        else {
            throw FolderSyncConnectionError.recoveryRequired
        }

        let recoveryRoot = URL(fileURLWithPath: connection.localRecoveryDirectoryPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let source = recoveryRoot.appendingPathComponent(safeRecovery).standardizedFileURL
        let recoveryPrefix = recoveryRoot.path.hasSuffix("/") ? recoveryRoot.path : recoveryRoot.path + "/"
        guard source.path.hasPrefix(recoveryPrefix),
              FileManager.default.fileExists(atPath: source.path)
        else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        let sourceValues = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
            throw FolderSyncConnectionError.recoveryRequired
        }

        let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = rootURL.appendingPathComponent(safeOriginal).standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FolderSyncConnectionError.restoreDestinationExists
        }

        let available = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity
        if let available, Int64(available) < Int64(sourceValues.fileSize ?? 0) {
            throw FolderSyncConnectionError.insufficientRecoverySpace
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".photoarchive-restore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        guard try FileHasher.sha256(url: source) == FileHasher.sha256(url: temporary) else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FolderSyncConnectionError.restoreDestinationExists
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    static func discard(
        _ item: FolderSyncRecoveryItem,
        connection: FolderSyncConnection,
        testingTrashDirectory: URL? = nil
    ) throws {
        guard item.location == .externalDrive,
              let safeRecovery = safeRelativePath(item.recoveryRelativePath)
        else {
            throw FolderSyncConnectionError.recoveryRequired
        }

        let recoveryRoot = URL(fileURLWithPath: connection.localRecoveryDirectoryPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let source = recoveryRoot.appendingPathComponent(safeRecovery).standardizedFileURL
        let recoveryPrefix = recoveryRoot.path.hasSuffix("/") ? recoveryRoot.path : recoveryRoot.path + "/"
        guard source.path.hasPrefix(recoveryPrefix),
              FileManager.default.fileExists(atPath: source.path)
        else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        let values = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? 0) == item.byteSize
        else {
            throw FolderSyncConnectionError.recoveryItemChanged
        }
        if let expected = item.modifiedAt,
           let current = values.contentModificationDate,
           abs(expected.timeIntervalSince(current)) > 1 {
            throw FolderSyncConnectionError.recoveryItemChanged
        }

        if let testingTrashDirectory {
            try FileManager.default.createDirectory(
                at: testingTrashDirectory,
                withIntermediateDirectories: true
            )
            let destination = testingTrashDirectory
                .appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
        }
    }

    static func originalRelativePath(
        recoveryRelativePath: String,
        sideDirectory: String
    ) -> String? {
        let components = recoveryRelativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard let sideIndex = components.firstIndex(where: { String($0) == sideDirectory }),
              components.index(after: sideIndex) < components.endIndex
        else { return nil }
        let suffix = components[components.index(after: sideIndex)...].joined(separator: "/")
        return safeRelativePath(suffix)
    }

    static func safeRelativePath(_ value: String) -> String? {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              value.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components.joined(separator: "/")
    }
}

public enum FolderSyncConflictChoice: String, Codable, Sendable, Equatable, Hashable {
    case keepBoth = "keep_both"
    case useExternalDrive = "use_external_drive"
    case useGoogleDrive = "use_google_drive"
    case keepModified = "keep_modified"
    case deleteBoth = "delete_both"
}

public enum FolderSyncConflictKind: String, Codable, Sendable, Equatable {
    case bothModified = "both_modified"
    case deleteModify = "delete_modify"
}

public struct FolderSyncConflictItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let relativePaths: [String]
    public let isLivePhoto: Bool
    public let conflictKind: FolderSyncConflictKind
    public let note: String?
    public let expectedFingerprint: String
    public let externalDriveDescription: String
    public let googleDriveDescription: String
    public let availableChoices: [FolderSyncConflictChoice]

    public init(
        id: String,
        relativePaths: [String],
        isLivePhoto: Bool,
        conflictKind: FolderSyncConflictKind,
        note: String? = nil,
        expectedFingerprint: String,
        externalDriveDescription: String,
        googleDriveDescription: String,
        availableChoices: [FolderSyncConflictChoice]
    ) {
        self.id = id
        self.relativePaths = relativePaths.sorted()
        self.isLivePhoto = isLivePhoto
        self.conflictKind = conflictKind
        self.note = note
        self.expectedFingerprint = expectedFingerprint
        self.externalDriveDescription = externalDriveDescription
        self.googleDriveDescription = googleDriveDescription
        self.availableChoices = availableChoices
    }
}
