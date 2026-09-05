import Foundation

public enum DuplicateReviewWorkspaceError: LocalizedError {
    case outputAlreadyExists(String)
    case candidateRootNotFound(String)
    case sourceRootMissing(String)
    case sourceMissing(String)
    case unsafeRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case let .outputAlreadyExists(path):
            return "Duplicate review output already exists: \(path)"
        case let .candidateRootNotFound(value):
            return "No scanned root matches the duplicate-review candidate root: \(value)"
        case let .sourceRootMissing(rootID):
            return "A duplicate-review source root is missing from the scan report: \(rootID)"
        case let .sourceMissing(path):
            return "A duplicate-review source file is no longer available: \(path)"
        case let .unsafeRelativePath(path):
            return "A duplicate-review relative path escapes its registered root: \(path)"
        }
    }
}

public struct DuplicateReviewWorkspaceReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let itemCount: Int
    public let currentItemCount: Int
    public let staleItemCount: Int
    public let offlineItemCount: Int
    public let keeperLinkCount: Int
    public let candidateLinkCount: Int
    public let workspacePath: String
    public let mediaFilesModified: Bool
}

public struct AgentSafeDuplicateReviewWorkspaceReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let itemCount: Int
    public let currentItemCount: Int
    public let staleItemCount: Int
    public let offlineItemCount: Int
    public let keeperLinkCount: Int
    public let candidateLinkCount: Int
    public let mediaFilesModified: Bool

    public init(report: DuplicateReviewWorkspaceReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        itemCount = report.itemCount
        currentItemCount = report.currentItemCount
        staleItemCount = report.staleItemCount
        offlineItemCount = report.offlineItemCount
        keeperLinkCount = report.keeperLinkCount
        candidateLinkCount = report.candidateLinkCount
        mediaFilesModified = report.mediaFilesModified
    }
}

public enum DuplicateReviewWorkspace {
    private enum FreshnessStatus: String {
        case current = "CURRENT"
        case stale = "STALE"
        case offline = "OFFLINE"
    }

    private struct ResourceFreshness {
        let status: FreshnessStatus
        let sourceURL: URL?
        let reason: String?
    }

    private struct RootFreshness {
        let status: FreshnessStatus
        let reason: String?
    }

    public static func create(
        report: ScanReport,
        plan: ReconciliationPlan,
        outputURL rawOutputURL: URL,
        candidateRootTarget: String? = nil,
        fileManager: FileManager = .default
    ) throws -> DuplicateReviewWorkspaceReport {
        let outputURL = rawOutputURL.standardizedFileURL
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw DuplicateReviewWorkspaceError.outputAlreadyExists(outputURL.path)
        }

        let rootsByID = Dictionary(uniqueKeysWithValues: report.roots.map { ($0.rootID, $0) })
        let candidateRootID: String?
        if let candidateRootTarget {
            let expanded = (candidateRootTarget as NSString).expandingTildeInPath
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard let match = report.roots.first(where: {
                $0.rootID == candidateRootTarget
                    || URL(fileURLWithPath: $0.canonicalPath).standardizedFileURL.path == standardized
            }) else {
                throw DuplicateReviewWorkspaceError.candidateRootNotFound(candidateRootTarget)
            }
            candidateRootID = match.rootID
        } else {
            candidateRootID = nil
        }

        let selectedItems = plan.items.filter { item in
            guard item.decision == .automaticRedundant, !item.candidateResources.isEmpty else {
                return false
            }
            guard let candidateRootID else { return true }
            return item.candidateResources.allSatisfy { $0.rootID == candidateRootID }
        }

        let scannedResourcesByKey = Dictionary(uniqueKeysWithValues: report.resources.map {
            (CanonicalResourceKey(rootID: $0.rootID, relativePath: $0.relativePath), $0)
        })
        let selectedResources = selectedItems.flatMap { $0.preferredResources + $0.candidateResources }
        let selectedResourceIDs = selectedResources.compactMap {
            scannedResourcesByKey[CanonicalKeeperPolicy.key($0)]?.resourceID
        }
        let catalog = try SQLiteCatalog(url: URL(fileURLWithPath: report.catalogPath))
        let expectedEvidenceByResourceID = try catalog.duplicateReviewExpectedResourceEvidence(
            resourceIDs: selectedResourceIDs
        )
        let involvedRootIDs = Set(selectedResources.map(\.rootID))
        var rootFreshnessByID: [String: RootFreshness] = [:]
        for rootID in involvedRootIDs {
            guard let root = rootsByID[rootID] else {
                throw DuplicateReviewWorkspaceError.sourceRootMissing(rootID)
            }
            rootFreshnessByID[rootID] = rootFreshness(
                root: root,
                fileManager: fileManager
            )
        }

        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        do {
            try writeReadme(to: outputURL)

            var keeperLinkCount = 0
            var candidateLinkCount = 0
            var currentItemCount = 0
            var staleItemCount = 0
            var offlineItemCount = 0
            for (offset, item) in selectedItems.enumerated() {
                let allResources = item.preferredResources + item.candidateResources
                let freshnessByKey = Dictionary(uniqueKeysWithValues: allResources.map { resource in
                    let key = CanonicalKeeperPolicy.key(resource)
                    let scanned = scannedResourcesByKey[key]
                    let expected = scanned.flatMap { expectedEvidenceByResourceID[$0.resourceID] }
                    let freshness = resourceFreshness(
                        resource: resource,
                        root: rootsByID[resource.rootID],
                        rootFreshness: rootFreshnessByID[resource.rootID],
                        expectedEvidence: expected,
                        fileManager: fileManager
                    )
                    return (key, freshness)
                })
                let itemStatus = aggregateStatus(Array(freshnessByKey.values))
                switch itemStatus {
                case .current: currentItemCount += 1
                case .stale: staleItemCount += 1
                case .offline: offlineItemCount += 1
                }
                let groupURL = outputURL.appendingPathComponent(
                    String(
                        format: "%03d-%@-%@-%@",
                        offset + 1,
                        itemStatus.rawValue,
                        item.kind.rawValue,
                        item.itemID
                    ),
                    isDirectory: true
                )
                let keeperDirectoryName = itemStatus == .current ? "KEEPER" : "OLD_KEEPER"
                let candidateDirectoryName = itemStatus == .current ? "CANDIDATE" : "OLD_CANDIDATE"
                let keeperURL = groupURL.appendingPathComponent(keeperDirectoryName, isDirectory: true)
                let candidateURL = groupURL.appendingPathComponent(candidateDirectoryName, isDirectory: true)
                try fileManager.createDirectory(at: keeperURL, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: candidateURL, withIntermediateDirectories: true)

                var locationLines: [String] = [
                    "status: \(itemStatus.rawValue)",
                    "reason: \(item.reason.rawValue)",
                    "kind: \(item.kind.rawValue)",
                    ""
                ]

                for (index, resource) in item.preferredResources.enumerated() {
                    let freshness = freshnessByKey[CanonicalKeeperPolicy.key(resource)]!
                    if let sourceURL = freshness.sourceURL {
                        try createLink(
                            sourceURL: sourceURL,
                            in: keeperURL,
                            prefix: String(format: "%@-%02d", keeperDirectoryName, index + 1),
                            fileManager: fileManager
                        )
                        keeperLinkCount += 1
                        locationLines.append("[\(keeperDirectoryName)] \(sourceURL.path)")
                    }
                    if let reason = freshness.reason {
                        locationLines.append("  freshness: \(reason)")
                    }
                }

                for (index, resource) in item.candidateResources.enumerated() {
                    let freshness = freshnessByKey[CanonicalKeeperPolicy.key(resource)]!
                    if let sourceURL = freshness.sourceURL {
                        try createLink(
                            sourceURL: sourceURL,
                            in: candidateURL,
                            prefix: String(format: "%@-%02d", candidateDirectoryName, index + 1),
                            fileManager: fileManager
                        )
                        candidateLinkCount += 1
                        locationLines.append("[\(candidateDirectoryName)] \(sourceURL.path)")
                    }
                    if let reason = freshness.reason {
                        locationLines.append("  freshness: \(reason)")
                    }
                }

                let locationsURL = groupURL.appendingPathComponent("locations.txt")
                try (locationLines.joined(separator: "\n") + "\n")
                    .write(to: locationsURL, atomically: true, encoding: .utf8)
                if itemStatus != .current {
                    try writeNeedsRefresh(status: itemStatus, to: groupURL)
                }
            }

            return DuplicateReviewWorkspaceReport(
                schemaVersion: 2,
                itemCount: selectedItems.count,
                currentItemCount: currentItemCount,
                staleItemCount: staleItemCount,
                offlineItemCount: offlineItemCount,
                keeperLinkCount: keeperLinkCount,
                candidateLinkCount: candidateLinkCount,
                workspacePath: outputURL.path,
                mediaFilesModified: false
            )
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    private static func rootFreshness(
        root: RootScanReport,
        fileManager: FileManager
    ) -> RootFreshness {
        let rootURL = URL(fileURLWithPath: root.canonicalPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return RootFreshness(status: .offline, reason: "root_offline")
        }
        guard isDirectory.boolValue else {
            return RootFreshness(status: .stale, reason: "root_is_not_directory")
        }
        if let expectedMarker = root.stableMarkerKey {
            do {
                guard try RootMarkerStore.readIfPresent(at: rootURL)?.markerKey == expectedMarker else {
                    return RootFreshness(status: .stale, reason: "root_marker_changed")
                }
            } catch {
                return RootFreshness(status: .stale, reason: "root_marker_unreadable")
            }
        } else if rootURL.resolvingSymlinksInPath().standardizedFileURL.path != rootURL.path {
            return RootFreshness(status: .stale, reason: "unmarked_root_identity_changed")
        }
        return RootFreshness(status: .current, reason: nil)
    }

    private static func resourceFreshness(
        resource: ResourceReference,
        root: RootScanReport?,
        rootFreshness: RootFreshness?,
        expectedEvidence: DuplicateReviewExpectedResourceEvidence?,
        fileManager: FileManager
    ) -> ResourceFreshness {
        guard let root else {
            return ResourceFreshness(status: .stale, sourceURL: nil, reason: "root_missing_from_snapshot")
        }
        if rootFreshness?.status == .offline {
            return ResourceFreshness(status: .offline, sourceURL: nil, reason: rootFreshness?.reason)
        }
        if rootFreshness?.status == .stale {
            return ResourceFreshness(status: .stale, sourceURL: nil, reason: rootFreshness?.reason)
        }

        let rootURL = URL(fileURLWithPath: root.canonicalPath).standardizedFileURL
        let sourceURL = rootURL.appendingPathComponent(resource.relativePath).standardizedFileURL
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard sourceURL.path.hasPrefix(prefix),
              !resource.relativePath.split(separator: "/").contains("..")
        else {
            return ResourceFreshness(status: .stale, sourceURL: nil, reason: "unsafe_relative_path")
        }
        guard let expectedEvidence,
              expectedEvidence.rootID == resource.rootID,
              expectedEvidence.relativePath == resource.relativePath
        else {
            return ResourceFreshness(status: .stale, sourceURL: nil, reason: "catalog_evidence_missing")
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        guard let values = try? sourceURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            if fileManager.fileExists(atPath: sourceURL.path) {
                return ResourceFreshness(status: .stale, sourceURL: sourceURL, reason: "not_regular_file")
            }
            return ResourceFreshness(status: .stale, sourceURL: nil, reason: "file_missing")
        }
        guard let fileSize = values.fileSize,
              Int64(fileSize) == resource.byteSize,
              Int64(fileSize) == expectedEvidence.byteSize
        else {
            return ResourceFreshness(status: .stale, sourceURL: sourceURL, reason: "size_changed")
        }
        guard let currentModifiedAt = values.contentModificationDate,
              let expectedModifiedAt = expectedEvidence.modifiedAt,
              abs(currentModifiedAt.timeIntervalSince1970 - expectedModifiedAt.timeIntervalSince1970) < 0.001
        else {
            return ResourceFreshness(status: .stale, sourceURL: sourceURL, reason: "modification_time_changed")
        }
        if let expectedID = expectedEvidence.fileSystemIdentifier {
            guard let currentID = values.fileResourceIdentifier.map({ String(describing: $0) }),
                  currentID == expectedID
            else {
                return ResourceFreshness(status: .stale, sourceURL: sourceURL, reason: "filesystem_id_changed")
            }
        }
        return ResourceFreshness(status: .current, sourceURL: sourceURL, reason: nil)
    }

    private static func aggregateStatus(_ freshness: [ResourceFreshness]) -> FreshnessStatus {
        if freshness.contains(where: { $0.status == .offline }) { return .offline }
        if freshness.contains(where: { $0.status == .stale }) { return .stale }
        return .current
    }

    private static func createLink(
        sourceURL: URL,
        in directoryURL: URL,
        prefix: String,
        fileManager: FileManager
    ) throws {
        let originalName = sourceURL.lastPathComponent
        let linkURL = directoryURL.appendingPathComponent(prefix + "--" + originalName)
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: sourceURL)
    }

    private static func writeReadme(to outputURL: URL) throws {
        let text = """
        PhotoArchiveKit exact-duplicate review workspace

        This folder contains symbolic links only. Original media bytes were not copied, moved, renamed, or deleted.

        Each numbered folder is one previous automatic exact-duplicate decision with a current freshness state:
        - CURRENT: size, modification time, filesystem identity, and root identity still match the catalog evidence.
        - STALE: one or more files/root facts changed or disappeared. Run duplicate-review --refresh before trusting the old decision.
        - OFFLINE: a required root is not currently available. Reconnect it before refreshing or acting.

        CURRENT groups contain:
        - KEEPER: the copy PhotoArchiveKit currently prefers to keep.
        - CANDIDATE: byte-identical copy/copies eligible for quarantine only after fresh cryptographic verification.

        STALE/OFFLINE groups use OLD_KEEPER and OLD_CANDIDATE because those names describe historical decisions only.
        - locations.txt: local-private original paths for Finder review.

        Use Finder thumbnails or Quick Look on the links. Do not treat this workspace itself as a backup.
        """
        try (text + "\n").write(
            to: outputURL.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func writeNeedsRefresh(status: FreshnessStatus, to groupURL: URL) throws {
        let action = status == .offline
            ? "Reconnect the unavailable root, then run duplicate-review --refresh before trusting this decision."
            : "Run duplicate-review --refresh before trusting this decision."
        let text = """
        \(status.rawValue) / NEEDS REFRESH

        This group's previous exact-duplicate decision is not current enough for normal review.
        \(action)

        Do not quarantine files based on this group's OLD_KEEPER / OLD_CANDIDATE labels.
        """
        try (text + "\n").write(
            to: groupURL.appendingPathComponent("NEEDS-REFRESH.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
