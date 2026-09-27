import Foundation

public struct OperationArtifactRetentionPolicy: Sendable, Equatable {
    public let maxCompletedDirectoryCount: Int
    public let maxCompletedBytes: Int64
    public let maxCompletedAge: TimeInterval

    public init(
        maxCompletedDirectoryCount: Int,
        maxCompletedBytes: Int64,
        maxCompletedAge: TimeInterval
    ) {
        self.maxCompletedDirectoryCount = max(0, maxCompletedDirectoryCount)
        self.maxCompletedBytes = max(0, maxCompletedBytes)
        self.maxCompletedAge = max(0, maxCompletedAge)
    }

    public static let `default` = OperationArtifactRetentionPolicy(
        maxCompletedDirectoryCount: 64,
        maxCompletedBytes: 256 * 1024 * 1024,
        maxCompletedAge: 90 * 24 * 60 * 60
    )
}

public struct OperationArtifactRetentionReport: Sendable, Equatable {
    public let scannedDirectoryCount: Int
    public let removedDirectoryCount: Int
    public let reclaimedBytes: Int64
    public let protectedDirectoryCount: Int
    public let unmanagedRootEntryCount: Int

    public init(
        scannedDirectoryCount: Int,
        removedDirectoryCount: Int,
        reclaimedBytes: Int64,
        protectedDirectoryCount: Int,
        unmanagedRootEntryCount: Int
    ) {
        self.scannedDirectoryCount = scannedDirectoryCount
        self.removedDirectoryCount = removedDirectoryCount
        self.reclaimedBytes = reclaimedBytes
        self.protectedDirectoryCount = protectedDirectoryCount
        self.unmanagedRootEntryCount = unmanagedRootEntryCount
    }
}

public enum OperationArtifactRetention {
    private struct ManagedEntry {
        let url: URL
        let lastActivityAt: Date
        let byteSize: Int64
        let preserved: Bool
    }

    private struct CompletedEvidence {
        let lastActivityAt: Date
    }

    public static func maintain(
        directoryURL: URL = PhotoArchivePaths.defaultOperationsDirectoryURL,
        policy: OperationArtifactRetentionPolicy = .default,
        now: Date = Date(),
        preservingDirectoryNames: Set<String> = []
    ) throws -> OperationArtifactRetentionReport {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return OperationArtifactRetentionReport(
                scannedDirectoryCount: 0,
                removedDirectoryCount: 0,
                reclaimedBytes: 0,
                protectedDirectoryCount: 0,
                unmanagedRootEntryCount: 0
            )
        }

        let root = directoryURL.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            // The app owns this directory boundary. Never follow a replacement symlink
            // into an unrelated tree merely to enforce diagnostic retention.
            return OperationArtifactRetentionReport(
                scannedDirectoryCount: 0,
                removedDirectoryCount: 0,
                reclaimedBytes: 0,
                protectedDirectoryCount: 0,
                unmanagedRootEntryCount: 0
            )
        }
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )

        var managed: [ManagedEntry] = []
        var scannedDirectoryCount = 0
        var protectedDirectoryCount = 0
        var unmanagedRootEntryCount = 0
        for child in children {
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                unmanagedRootEntryCount += 1
                continue
            }
            scannedDirectoryCount += 1
            let url = child.standardizedFileURL
            guard let evidence = completedOrganizationEvidence(in: url) else {
                protectedDirectoryCount += 1
                continue
            }
            managed.append(ManagedEntry(
                url: url,
                lastActivityAt: evidence.lastActivityAt,
                byteSize: directoryByteSize(url),
                preserved: preservingDirectoryNames.contains(url.lastPathComponent)
            ))
        }

        managed.sort {
            if $0.lastActivityAt == $1.lastActivityAt {
                return $0.url.lastPathComponent > $1.url.lastPathComponent
            }
            return $0.lastActivityAt > $1.lastActivityAt
        }

        var remainingCount = managed.count
        var remainingBytes = managed.reduce(Int64(0)) { $0 + $1.byteSize }
        var removedDirectoryCount = 0
        var reclaimedBytes: Int64 = 0

        for entry in managed.reversed() {
            let pressureRequiresRemoval = remainingCount > policy.maxCompletedDirectoryCount
                || remainingBytes > policy.maxCompletedBytes
            let expired = now.timeIntervalSince(entry.lastActivityAt) >= policy.maxCompletedAge
            guard pressureRequiresRemoval || expired else { continue }
            if entry.preserved {
                protectedDirectoryCount += 1
                continue
            }

            try fileManager.removeItem(at: entry.url)
            remainingCount -= 1
            remainingBytes = max(0, remainingBytes - entry.byteSize)
            removedDirectoryCount += 1
            reclaimedBytes += entry.byteSize
        }

        return OperationArtifactRetentionReport(
            scannedDirectoryCount: scannedDirectoryCount,
            removedDirectoryCount: removedDirectoryCount,
            reclaimedBytes: reclaimedBytes,
            protectedDirectoryCount: protectedDirectoryCount,
            unmanagedRootEntryCount: unmanagedRootEntryCount
        )
    }

    private static func completedOrganizationEvidence(in directory: URL) -> CompletedEvidence? {
        let fileManager = FileManager.default
        let pendingURL = directory.appendingPathComponent("organization.pending.json")
        guard !fileManager.fileExists(atPath: pendingURL.path) else { return nil }

        let allowedNames: Set<String> = ["organization.json", "empty-directories.json"]
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ), !children.isEmpty else {
            return nil
        }
        for child in children {
            guard allowedNames.contains(child.lastPathComponent),
                  let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true
            else {
                return nil
            }
        }

        let organizationURL = directory.appendingPathComponent("organization.json")
        guard let data = try? Data(contentsOf: organizationURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(OrganizationApplyManifest.self, from: data),
              manifest.schemaVersion == 1,
              manifest.state == "complete",
              manifest.filesModified,
              manifest.sessionID == directory.lastPathComponent
        else {
            return nil
        }

        var lastActivityAt = manifest.createdAt
        let cleanupURL = directory.appendingPathComponent("empty-directories.json")
        if fileManager.fileExists(atPath: cleanupURL.path) {
            guard let cleanupData = try? Data(contentsOf: cleanupURL),
                  let cleanup = try? decoder.decode(EmptyDirectoryCleanupManifest.self, from: cleanupData),
                  cleanup.schemaVersion == 1,
                  cleanup.state == "complete",
                  cleanup.sessionID == manifest.sessionID
            else {
                return nil
            }
            lastActivityAt = max(lastActivityAt, cleanup.createdAt)
        }
        return CompletedEvidence(lastActivityAt: lastActivityAt)
    }

    private static func directoryByteSize(_ directory: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else {
            return 0
        }
        return children.reduce(Int64(0)) { total, child in
            guard let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else {
                return total
            }
            return total + Int64(values.fileSize ?? 0)
        }
    }
}
