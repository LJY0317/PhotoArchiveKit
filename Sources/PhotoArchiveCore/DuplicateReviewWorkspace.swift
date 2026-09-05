import Darwin
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

    private struct ReviewFileFacts {
        let fileName: String
        let parentRelativePath: String
        let byteSize: Int64
        let creationDate: Date?
        let modificationDate: Date?
        let fileSystemIdentifier: String?
        let captureTime: CaptureTime?
        let extendedAttributes: [String: Data]?
    }

    public static func create(
        report: ScanReport,
        plan: ReconciliationPlan,
        outputURL rawOutputURL: URL,
        candidateRootTarget: String? = nil,
        preferenceOnly: Bool = false,
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

        let initiallySelectedItems = plan.items.filter { item in
            guard item.decision == .automaticRedundant, !item.candidateResources.isEmpty else {
                return false
            }
            guard let candidateRootID else { return true }
            return item.candidateResources.allSatisfy { $0.rootID == candidateRootID }
        }

        let scannedResourcesByKey = Dictionary(uniqueKeysWithValues: report.resources.map {
            (CanonicalResourceKey(rootID: $0.rootID, relativePath: $0.relativePath), $0)
        })
        let selectedItems = initiallySelectedItems.filter { item in
            guard preferenceOnly else { return true }
            return CanonicalKeeperPolicy.reviewStrength(
                item: item,
                rootsByID: rootsByID,
                resourcesByKey: scannedResourcesByKey
            ) == .preference
        }
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
                try writeComparison(
                    item: item,
                    status: itemStatus,
                    rootsByID: rootsByID,
                    scannedResourcesByKey: scannedResourcesByKey,
                    freshnessByKey: freshnessByKey,
                    groupURL: groupURL,
                    fileManager: fileManager
                )
                if itemStatus != .current {
                    try writeNeedsRefresh(status: itemStatus, to: groupURL)
                }
            }

            return DuplicateReviewWorkspaceReport(
                schemaVersion: 3,
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

    private static func writeComparison(
        item: ReconciliationPlanItem,
        status: FreshnessStatus,
        rootsByID: [String: RootScanReport],
        scannedResourcesByKey: [CanonicalResourceKey: ScannedResourceReport],
        freshnessByKey: [CanonicalResourceKey: ResourceFreshness],
        groupURL: URL,
        fileManager: FileManager
    ) throws {
        var lines: [String] = [
            "PhotoArchiveKit duplicate comparison",
            "",
            "status: \(status.rawValue)",
            "content evidence: EXACT BYTES IDENTICAL for every keeper/candidate resource matched by this exact decision",
            "embedded metadata: identical for byte-identical matched resources (embedded metadata is part of those bytes)",
            "important: Finder may show different sizes for the symbolic links in this review folder; that is link-path storage, not media quality or original media size.",
            "mutation safety: this review evidence is not deletion authority; quarantine must freshly verify bytes again before moving media.",
            ""
        ]

        if item.kind == .livePhotoAsset,
           item.reason == .canonicalLocalLivePhotoOccurrence {
            lines.append("keeper reason: STRONG — retain the complete Live Photo occurrence; redundant exact-covered resources stay candidates only as an atomic media decision.")
        } else if item.preferredResources.count == 1,
                  let preferred = item.preferredResources.first {
            let rationales = item.candidateResources.map {
                CanonicalKeeperPolicy.preferenceRationale(
                    preferred: preferred,
                    candidate: $0,
                    rootsByID: rootsByID,
                    resourcesByKey: scannedResourcesByKey
                )
            }
            let unique = Array(Set(rationales.map(\.rawValue))).sorted()
            let strength = CanonicalKeeperPolicy.reviewStrength(
                item: item,
                rootsByID: rootsByID,
                resourcesByKey: scannedResourcesByKey
            )
            lines.append("keeper reason: \(strength.rawValue.uppercased()) — \(unique.joined(separator: ", "))")
            if rationales.allSatisfy({ $0 == .deterministicTieBreak }) {
                lines.append("keeper interpretation: EQUIVALENT COPY — PhotoArchiveKit found no provenance-relevant preference in its current policy, so keeper/candidate is only a deterministic tie-break.")
            }
        } else {
            lines.append("keeper reason: multiple-resource policy decision; inspect the resource rows below.")
        }
        lines.append("")
        lines.append("Metadata scope currently compared:")
        lines.append("- original target byte size")
        lines.append("- embedded/capture metadata represented by the scan")
        lines.append("- filename and parent path")
        lines.append("- filesystem creation date (birth time; weak provenance evidence, not proof of first-ever creation/download)")
        lines.append("- filesystem modification date")
        lines.append("- filesystem identity")
        lines.append("- extended attributes (names and byte values compared locally; values are not printed here)")
        lines.append("- ACLs, APFS snapshots, backup history, and external cloud/history records are outside this comparison")
        lines.append("")

        let preferredFacts = item.preferredResources.compactMap { resource -> (ResourceReference, ReviewFileFacts)? in
            let key = CanonicalKeeperPolicy.key(resource)
            guard let sourceURL = freshnessByKey[key]?.sourceURL else { return nil }
            return (
                resource,
                reviewFileFacts(
                    resource: resource,
                    scanned: scannedResourcesByKey[key],
                    sourceURL: sourceURL,
                    root: rootsByID[resource.rootID],
                    fileManager: fileManager
                )
            )
        }
        let candidateFacts = item.candidateResources.compactMap { resource -> (ResourceReference, ReviewFileFacts)? in
            let key = CanonicalKeeperPolicy.key(resource)
            guard let sourceURL = freshnessByKey[key]?.sourceURL else { return nil }
            return (
                resource,
                reviewFileFacts(
                    resource: resource,
                    scanned: scannedResourcesByKey[key],
                    sourceURL: sourceURL,
                    root: rootsByID[resource.rootID],
                    fileManager: fileManager
                )
            )
        }

        for (index, pair) in preferredFacts.enumerated() {
            lines.append(contentsOf: factLines(label: "KEEPER \(index + 1)", facts: pair.1))
        }
        for (index, pair) in candidateFacts.enumerated() {
            lines.append(contentsOf: factLines(label: "CANDIDATE \(index + 1)", facts: pair.1))
        }

        if preferredFacts.count == 1, candidateFacts.count == 1 {
            lines.append("Comparison summary:")
            lines.append(contentsOf: comparisonLines(preferred: preferredFacts[0].1, candidate: candidateFacts[0].1))
        } else {
            lines.append("Comparison summary: multi-resource group; compare each role above. A complete Live Photo may intentionally contain an additional paired video that has no candidate counterpart.")
        }

        try (lines.joined(separator: "\n") + "\n").write(
            to: groupURL.appendingPathComponent("comparison.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func reviewFileFacts(
        resource: ResourceReference,
        scanned: ScannedResourceReport?,
        sourceURL: URL,
        root: RootScanReport?,
        fileManager: FileManager
    ) -> ReviewFileFacts {
        let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path)
        let rootURL = root.map { URL(fileURLWithPath: $0.canonicalPath).standardizedFileURL }
        let parentURL = sourceURL.deletingLastPathComponent().standardizedFileURL
        let parentRelativePath: String
        if let rootURL, parentURL.path == rootURL.path {
            parentRelativePath = "."
        } else if let rootURL {
            let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            parentRelativePath = parentURL.path.hasPrefix(prefix)
                ? String(parentURL.path.dropFirst(prefix.count))
                : parentURL.path
        } else {
            parentRelativePath = parentURL.path
        }
        return ReviewFileFacts(
            fileName: sourceURL.lastPathComponent,
            parentRelativePath: parentRelativePath,
            byteSize: (attributes?[.size] as? NSNumber)?.int64Value ?? resource.byteSize,
            creationDate: attributes?[.creationDate] as? Date,
            modificationDate: attributes?[.modificationDate] as? Date,
            fileSystemIdentifier: (attributes?[.systemFileNumber] as? NSNumber).map { String($0.uint64Value) },
            captureTime: scanned?.captureTime,
            extendedAttributes: extendedAttributes(at: sourceURL)
        )
    }

    private static func factLines(label: String, facts: ReviewFileFacts) -> [String] {
        [
            "\(label):",
            "  filename: \(facts.fileName)",
            "  parent: \(facts.parentRelativePath)",
            "  original target size: \(facts.byteSize) bytes",
            "  filesystem created: \(formatDate(facts.creationDate))",
            "  filesystem modified: \(formatDate(facts.modificationDate))",
            "  embedded capture: \(formatCaptureTime(facts.captureTime))",
            "  filesystem identity: \(facts.fileSystemIdentifier ?? "unavailable")",
            "  extended attributes: \(facts.extendedAttributes.map { String($0.count) } ?? "unavailable")",
            ""
        ]
    }

    private static func comparisonLines(
        preferred: ReviewFileFacts,
        candidate: ReviewFileFacts
    ) -> [String] {
        var lines: [String] = []
        lines.append("- original target size: \(preferred.byteSize == candidate.byteSize ? "same" : "different")")
        lines.append("- filename: \(preferred.fileName == candidate.fileName ? "same" : "different")")
        lines.append("- parent path: \(preferred.parentRelativePath == candidate.parentRelativePath ? "same" : "different")")
        let preferredExtension = (preferred.fileName as NSString).pathExtension
        let candidateExtension = (candidate.fileName as NSString).pathExtension
        let extensionComparison: String
        if preferredExtension == candidateExtension {
            extensionComparison = "same"
        } else if preferredExtension.lowercased() == candidateExtension.lowercased() {
            extensionComparison = "case-only difference (same file format)"
        } else {
            extensionComparison = "different"
        }
        lines.append("- filename extension: \(extensionComparison)")
        lines.append("- filesystem creation date: \(dateComparison(preferred.creationDate, candidate.creationDate))")
        lines.append("- filesystem modification date: \(dateComparison(preferred.modificationDate, candidate.modificationDate))")
        lines.append("- embedded capture metadata: \(captureComparison(preferred.captureTime, candidate.captureTime))")
        lines.append("- filesystem identity: \(preferred.fileSystemIdentifier == candidate.fileSystemIdentifier ? "same" : "different (expected for distinct copies)")")
        lines.append("- extended attributes: \(extendedAttributeComparison(preferred.extendedAttributes, candidate.extendedAttributes))")

        let provenanceRelevantSame = preferred.byteSize == candidate.byteSize
            && preferred.fileName == candidate.fileName
            && preferred.parentRelativePath == candidate.parentRelativePath
            && datesMatch(preferred.creationDate, candidate.creationDate)
            && datesMatch(preferred.modificationDate, candidate.modificationDate)
            && preferred.captureTime == candidate.captureTime
            && preferred.extendedAttributes == candidate.extendedAttributes
        if provenanceRelevantSame {
            lines.append("- RESULT: No provenance-relevant differences were detected in the metadata PhotoArchiveKit currently inspects. The two filesystem objects are still distinct copies, but this evidence does not provide a meaningful original-vs-copy preference.")
        } else {
            lines.append("- RESULT: Files are byte-identical, but one or more filesystem/provenance metadata fields differ. Those differences may help choose a preferred copy without implying a quality difference.")
        }
        return lines
    }

    private static func formatDate(_ date: Date?) -> String {
        guard let date else { return "unavailable" }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func formatCaptureTime(_ capture: CaptureTime?) -> String {
        guard let capture else { return "unavailable" }
        let instant = capture.instant.map { ISO8601DateFormatter().string(from: $0) } ?? "no instant"
        return "\(capture.source.rawValue) / \(capture.confidence.rawValue) / \(instant)"
    }

    private static func dateComparison(_ lhs: Date?, _ rhs: Date?) -> String {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil ? "both unavailable" : "availability differs" }
        if datesMatch(lhs, rhs) { return "same" }
        return lhs < rhs ? "keeper earlier" : "candidate earlier"
    }

    private static func captureComparison(_ lhs: CaptureTime?, _ rhs: CaptureTime?) -> String {
        lhs == rhs ? "same" : "different"
    }

    private static func datesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 0.001
    }

    private static func extendedAttributeComparison(
        _ lhs: [String: Data]?,
        _ rhs: [String: Data]?
    ) -> String {
        guard let lhs, let rhs else { return "unavailable" }
        if lhs == rhs { return "same" }
        let lhsNames = Set(lhs.keys)
        let rhsNames = Set(rhs.keys)
        if lhsNames == rhsNames { return "same attribute names, different value(s)" }
        return "different attribute set"
    }

    private static func extendedAttributes(at url: URL) -> [String: Data]? {
        url.withUnsafeFileSystemRepresentation { path -> [String: Data]? in
            guard let path else { return nil }
            let nameBufferSize = listxattr(path, nil, 0, 0)
            guard nameBufferSize >= 0 else { return nil }
            if nameBufferSize == 0 { return [:] }
            var nameBuffer = [CChar](repeating: 0, count: nameBufferSize)
            let filled = listxattr(path, &nameBuffer, nameBuffer.count, 0)
            guard filled >= 0 else { return nil }

            var names: [String] = []
            var start = 0
            for index in 0..<filled where nameBuffer[index] == 0 {
                if index > start {
                    names.append(String(cString: Array(nameBuffer[start...index])))
                }
                start = index + 1
            }

            var result: [String: Data] = [:]
            for name in names {
                let value = name.withCString { attributeName -> Data? in
                    let size = getxattr(path, attributeName, nil, 0, 0, 0)
                    guard size >= 0 else { return nil }
                    if size == 0 { return Data() }
                    var bytes = [UInt8](repeating: 0, count: size)
                    let read = getxattr(path, attributeName, &bytes, bytes.count, 0, 0)
                    guard read >= 0 else { return nil }
                    return Data(bytes.prefix(read))
                }
                if let value { result[name] = value }
            }
            return result
        }
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
        - comparison.txt: local-private target size, keeper rationale, and metadata-difference summary. Finder's symbolic-link size is not the original media size.

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
