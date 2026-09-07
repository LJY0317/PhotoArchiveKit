import Foundation

public enum QuarantineError: LocalizedError {
    case targetDoesNotExist(String)
    case targetIsNotDirectory(String)
    case targetOverlapsSource(String)
    case planSessionMismatch
    case exactEvidenceRequired
    case noAutomaticCandidates
    case unknownApprovedItem(String)
    case missingRoot(String)
    case rootRoleDisallowsCleanup(String)
    case unsafeRelativePath(String)
    case missingSource(String)
    case sourceChanged(String)
    case missingPreferredMatch(String)
    case destinationAlreadyExists(String)
    case moveFailed(String)
    case rollbackFailed(String)
    case livePhotoAtomicityViolation(String)

    public var errorDescription: String? {
        switch self {
        case let .targetDoesNotExist(path):
            return "Quarantine target does not exist: \(path)"
        case let .targetIsNotDirectory(path):
            return "Quarantine target is not a directory: \(path)"
        case let .targetOverlapsSource(path):
            return "Quarantine target overlaps a scanned source root: \(path)"
        case .planSessionMismatch:
            return "The reconciliation plan does not belong to the supplied scan session."
        case .exactEvidenceRequired:
            return "Quarantine requires exact-duplicate evidence. Run without --no-exact-duplicates."
        case .noAutomaticCandidates:
            return "The plan has no automatic redundant candidates to quarantine."
        case let .unknownApprovedItem(itemID):
            return "The approved reconciliation item is not present in the current automatic plan: \(itemID)"
        case let .missingRoot(rootID):
            return "A planned source root is missing from the scan report: \(rootID)"
        case let .rootRoleDisallowsCleanup(rootID):
            return "The current root role does not allow automatic redundant removal: \(rootID)"
        case let .unsafeRelativePath(path):
            return "A planned relative path escapes its registered source root: \(path)"
        case let .missingSource(path):
            return "A planned source file is no longer available: \(path)"
        case let .sourceChanged(path):
            return "A planned file no longer matches its preferred exact copy: \(path)"
        case let .missingPreferredMatch(path):
            return "No preferred exact counterpart could be resolved for: \(path)"
        case let .destinationAlreadyExists(path):
            return "Quarantine destination already exists: \(path)"
        case let .moveFailed(path):
            return "Could not move a planned resource into quarantine: \(path)"
        case let .rollbackFailed(path):
            return "Quarantine rollback could not restore a resource: \(path)"
        case let .livePhotoAtomicityViolation(assetID):
            return "A Live Photo mutation must include the complete planned resource set: \(assetID)"
        }
    }
}

public struct QuarantineMoveRecord: Codable, Sendable, Equatable {
    public let itemID: String
    public let rootID: String
    public let role: ResourceRole
    public let sourcePath: String
    public let sourceRelativePath: String?
    public let destinationPath: String
    public let byteSize: Int64
}

public struct QuarantineManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let policy: String
    public let createdAt: Date
    public let state: String
    public let targetPath: String
    public let moves: [QuarantineMoveRecord]
    public let filesModified: Bool
}

public struct QuarantineReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let dryRun: Bool
    public let targetPath: String
    public let itemCount: Int
    public let resourceCount: Int
    public let totalBytes: Int64
    public let moves: [QuarantineMoveRecord]
    public let manifestPath: String?
    public let filesModified: Bool
}

public struct AgentSafeQuarantineReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let sessionID: String
    public let dryRun: Bool
    public let itemCount: Int
    public let resourceCount: Int
    public let filesModified: Bool

    public init(report: QuarantineReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        sessionID = report.sessionID
        dryRun = report.dryRun
        itemCount = report.itemCount
        resourceCount = report.resourceCount
        filesModified = report.filesModified
    }
}

public enum QuarantineExecutor {
    private struct ResourceKey: Hashable {
        let rootID: String
        let relativePath: String
    }

    private struct VerifiedMove {
        let itemID: String
        let sourceURL: URL
        let destinationURL: URL
        let record: QuarantineMoveRecord
    }

    private struct VerifiedItem {
        let itemID: String
        let moves: [VerifiedMove]
    }

    public static func preflight(
        report: ScanReport,
        plan: ReconciliationPlan,
        targetURL rawTargetURL: URL,
        approvedPreferenceItemIDs: Set<String> = []
    ) throws -> QuarantineReport {
        let verified = try verify(
            report: report,
            plan: plan,
            targetURL: rawTargetURL,
            approvedPreferenceItemIDs: approvedPreferenceItemIDs
        )
        let moves = verified.items.flatMap(\.moves).map(\.record)
        return QuarantineReport(
            schemaVersion: 1,
            sessionID: report.sessionID,
            dryRun: true,
            targetPath: verified.targetURL.path,
            itemCount: verified.items.count,
            resourceCount: moves.count,
            totalBytes: moves.reduce(0) { $0 + $1.byteSize },
            moves: moves,
            manifestPath: nil,
            filesModified: false
        )
    }

    public static func apply(
        report: ScanReport,
        plan: ReconciliationPlan,
        targetURL rawTargetURL: URL,
        approvedPreferenceItemIDs: Set<String> = []
    ) throws -> QuarantineReport {
        let verified = try verify(
            report: report,
            plan: plan,
            targetURL: rawTargetURL,
            approvedPreferenceItemIDs: approvedPreferenceItemIDs
        )
        let fileManager = FileManager.default
        let sessionRoot = verified.targetURL
            .appendingPathComponent("PhotoArchiveKit", isDirectory: true)
            .appendingPathComponent(report.sessionID, isDirectory: true)
        try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: true)

        let allMoves = verified.items.flatMap(\.moves)
        let pendingManifestURL = sessionRoot.appendingPathComponent("manifest.pending.json")
        let finalManifestURL = sessionRoot.appendingPathComponent("manifest.json")
        let pendingManifest = QuarantineManifest(
            schemaVersion: 1,
            sessionID: report.sessionID,
            policy: plan.policy,
            createdAt: Date(),
            state: "pending",
            targetPath: verified.targetURL.path,
            moves: allMoves.map(\.record),
            filesModified: false
        )
        try writeManifest(pendingManifest, to: pendingManifestURL)

        var movedInSession: [VerifiedMove] = []
        do {
            for item in verified.items {
                for move in item.moves {
                    try fileManager.createDirectory(
                        at: move.destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    do {
                        try fileManager.moveItem(at: move.sourceURL, to: move.destinationURL)
                        movedInSession.append(move)
                    } catch {
                        throw QuarantineError.moveFailed(move.sourceURL.path)
                    }
                }
            }

            let finalManifest = QuarantineManifest(
                schemaVersion: 1,
                sessionID: report.sessionID,
                policy: plan.policy,
                createdAt: pendingManifest.createdAt,
                state: "complete",
                targetPath: verified.targetURL.path,
                moves: allMoves.map(\.record),
                filesModified: true
            )
            try writeManifest(finalManifest, to: finalManifestURL)
            try? fileManager.removeItem(at: pendingManifestURL)

            return QuarantineReport(
                schemaVersion: 1,
                sessionID: report.sessionID,
                dryRun: false,
                targetPath: verified.targetURL.path,
                itemCount: verified.items.count,
                resourceCount: allMoves.count,
                totalBytes: allMoves.reduce(0) { $0 + $1.record.byteSize },
                moves: allMoves.map(\.record),
                manifestPath: finalManifestURL.path,
                filesModified: true
            )
        } catch {
            for move in movedInSession.reversed() {
                do {
                    try fileManager.createDirectory(
                        at: move.sourceURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: move.destinationURL.path),
                       !FileManager.default.fileExists(atPath: move.sourceURL.path) {
                        try fileManager.moveItem(at: move.destinationURL, to: move.sourceURL)
                    }
                } catch {
                    throw QuarantineError.rollbackFailed(move.sourceURL.path)
                }
            }
            try? fileManager.removeItem(at: pendingManifestURL)
            throw error
        }
    }

    private static func verify(
        report: ScanReport,
        plan: ReconciliationPlan,
        targetURL rawTargetURL: URL,
        approvedPreferenceItemIDs: Set<String>
    ) throws -> (targetURL: URL, items: [VerifiedItem]) {
        guard report.sessionID == plan.sessionID else {
            throw QuarantineError.planSessionMismatch
        }
        guard !report.exactDuplicateGroups.isEmpty else {
            throw QuarantineError.exactEvidenceRequired
        }

        let targetURL = rawTargetURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            throw QuarantineError.targetDoesNotExist(targetURL.path)
        }
        guard isDirectory.boolValue else {
            throw QuarantineError.targetIsNotDirectory(targetURL.path)
        }

        let rootsByID = Dictionary(uniqueKeysWithValues: report.roots.map { ($0.rootID, $0) })
        let resourcesByKey = Dictionary(uniqueKeysWithValues: report.resources.map {
            (CanonicalResourceKey(rootID: $0.rootID, relativePath: $0.relativePath), $0)
        })
        for root in report.roots {
            let rootURL = URL(fileURLWithPath: root.canonicalPath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if isDescendantOrEqual(targetURL, of: rootURL) || isDescendantOrEqual(rootURL, of: targetURL) {
                throw QuarantineError.targetOverlapsSource(targetURL.path)
            }
        }

        let automaticPlanItems = plan.items.filter { $0.decision == .automaticRedundant }
        let automaticItemIDs = Set(automaticPlanItems.map(\.itemID))
        if let unknownApproval = approvedPreferenceItemIDs.subtracting(automaticItemIDs).sorted().first {
            throw QuarantineError.unknownApprovedItem(unknownApproval)
        }
        let automatic = automaticPlanItems.filter { item in
            let strength = CanonicalKeeperPolicy.reviewStrength(
                item: item,
                rootsByID: rootsByID,
                resourcesByKey: resourcesByKey
            )
            return strength == .strong || approvedPreferenceItemIDs.contains(item.itemID)
        }
        guard !automatic.isEmpty else {
            throw QuarantineError.noAutomaticCandidates
        }

        let duplicateGroupByResource = duplicateGroupIndex(report.exactDuplicateGroups)
        let duplicateGroupsByID = Dictionary(uniqueKeysWithValues: report.exactDuplicateGroups.map {
            ($0.groupID, $0)
        })
        var verifiedItems: [VerifiedItem] = []
        verifiedItems.reserveCapacity(automatic.count)

        for item in automatic {
            if item.kind == .livePhotoAsset {
                try validateLivePhotoAtomicity(item: item, report: report)
            }

            var moves: [VerifiedMove] = []
            moves.reserveCapacity(item.candidateResources.count)
            let plannedCandidateKeys = Set(item.candidateResources.map {
                ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath)
            })

            for candidate in item.candidateResources {
                guard let sourceRoot = rootsByID[candidate.rootID] else {
                    throw QuarantineError.missingRoot(candidate.rootID)
                }
                let sourceRootURL = URL(fileURLWithPath: sourceRoot.canonicalPath)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                let sourceURL = try safeResourceURL(rootURL: sourceRootURL, relativePath: candidate.relativePath)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    throw QuarantineError.missingSource(sourceURL.path)
                }
                try validateCurrentFile(
                    url: sourceURL,
                    expectedSize: candidate.byteSize,
                    rootURL: sourceRootURL
                )

                let key = ResourceKey(rootID: candidate.rootID, relativePath: candidate.relativePath)
                guard let groupID = duplicateGroupByResource[key],
                      let duplicateGroup = duplicateGroupsByID[groupID]
                else {
                    throw QuarantineError.missingPreferredMatch(sourceURL.path)
                }

                let preferredCandidates = item.preferredResources.filter { preferred in
                    guard preferred.role == candidate.role else { return false }
                    let preferredKey = ResourceKey(rootID: preferred.rootID, relativePath: preferred.relativePath)
                    return duplicateGroupByResource[preferredKey] == groupID
                }
                let preferred = preferredCandidates.first ?? duplicateGroup.members.first { member in
                    guard member.rootID == candidate.rootID,
                          member.role == candidate.role
                    else {
                        return false
                    }
                    return !plannedCandidateKeys.contains(
                        ResourceKey(rootID: member.rootID, relativePath: member.relativePath)
                    )
                }
                guard let preferred,
                      let preferredRoot = rootsByID[preferred.rootID]
                else {
                    throw QuarantineError.missingPreferredMatch(sourceURL.path)
                }
                guard roleAllowsReconciliationCleanup(
                    sourceRoot: sourceRoot,
                    preferredRoot: preferredRoot,
                    sameRoot: preferred.rootID == candidate.rootID
                ) else {
                    throw QuarantineError.rootRoleDisallowsCleanup(candidate.rootID)
                }

                let preferredRootURL = URL(fileURLWithPath: preferredRoot.canonicalPath)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                let preferredURL = try safeResourceURL(
                    rootURL: preferredRootURL,
                    relativePath: preferred.relativePath
                )
                guard FileManager.default.fileExists(atPath: preferredURL.path) else {
                    throw QuarantineError.missingSource(preferredURL.path)
                }
                try validateCurrentFile(
                    url: preferredURL,
                    expectedSize: preferred.byteSize,
                    rootURL: preferredRootURL
                )

                let sourceHash = try FileHasher.sha256(url: sourceURL)
                let preferredHash = try FileHasher.sha256(url: preferredURL)
                guard sourceHash == preferredHash else {
                    throw QuarantineError.sourceChanged(sourceURL.path)
                }

                let destinationURL = targetURL
                    .appendingPathComponent("PhotoArchiveKit", isDirectory: true)
                    .appendingPathComponent(report.sessionID, isDirectory: true)
                    .appendingPathComponent(candidate.rootID, isDirectory: true)
                    .appendingPathComponent(candidate.relativePath)
                    .standardizedFileURL
                guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw QuarantineError.destinationAlreadyExists(destinationURL.path)
                }

                moves.append(VerifiedMove(
                    itemID: item.itemID,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    record: QuarantineMoveRecord(
                        itemID: item.itemID,
                        rootID: candidate.rootID,
                        role: candidate.role,
                        sourcePath: sourceURL.path,
                        sourceRelativePath: candidate.relativePath,
                        destinationPath: destinationURL.path,
                        byteSize: candidate.byteSize
                    )
                ))
            }

            if item.kind == .livePhotoAsset,
               moves.count != item.candidateResources.count {
                throw QuarantineError.sourceChanged(item.subjectID)
            }

            verifiedItems.append(VerifiedItem(itemID: item.itemID, moves: moves))
        }

        return (targetURL, verifiedItems)
    }

    private static func roleAllowsReconciliationCleanup(
        sourceRoot: RootScanReport,
        preferredRoot: RootScanReport,
        sameRoot: Bool
    ) -> Bool {
        switch sourceRoot.usageRole {
        case .reference:
            return false
        case .staging, .primaryLibrary, .archive:
            // These roles may dedupe inside themselves, but generic reconciliation must
            // never collapse the root itself merely because another root has a replica.
            return sameRoot && sourceRoot.usageRole.allowsSameRootExactDedupe
        case .importSource:
            if sourceRoot.provenance == .googleTakeout,
               !sourceRoot.sourceFolderSemanticsCaptured {
                return false
            }
            if sameRoot {
                return sourceRoot.usageRole.allowsSameRootExactDedupe
            }
            return sourceRoot.usageRole.allowsReconciliationCrossRootCleanup
                && preferredRoot.usageRole.canRetainAgainstImportCleanup
        }
    }

    private static func validateLivePhotoAtomicity(
        item: ReconciliationPlanItem,
        report: ScanReport
    ) throws {
        guard let asset = report.livePhotos.first(where: { $0.assetID == item.subjectID }) else {
            throw QuarantineError.livePhotoAtomicityViolation(item.subjectID)
        }

        let planned = Set(
            item.candidateResources.map {
                ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath)
            }
        )
        guard !planned.isEmpty else {
            throw QuarantineError.livePhotoAtomicityViolation(item.subjectID)
        }

        var covered = Set<ResourceKey>()
        for occurrence in asset.occurrences {
            let occurrenceResources = Set(occurrence.resources.map {
                ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath)
            })
            let intersection = occurrenceResources.intersection(planned)
            if intersection.isEmpty { continue }
            guard intersection == occurrenceResources else {
                throw QuarantineError.livePhotoAtomicityViolation(item.subjectID)
            }
            covered.formUnion(occurrenceResources)
        }
        guard covered == planned else {
            throw QuarantineError.livePhotoAtomicityViolation(item.subjectID)
        }
    }

    private static func duplicateGroupIndex(
        _ groups: [ExactDuplicateGroupReport]
    ) -> [ResourceKey: String] {
        var result: [ResourceKey: String] = [:]
        for group in groups {
            for member in group.members {
                result[ResourceKey(rootID: member.rootID, relativePath: member.relativePath)] = group.groupID
            }
        }
        return result
    }

    private static func validateCurrentFile(
        url: URL,
        expectedSize: Int64,
        rootURL: URL
    ) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == expectedSize
        else {
            throw QuarantineError.sourceChanged(url.path)
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == url.standardizedFileURL.path,
              isDescendantOrEqual(resolved, of: rootURL)
        else {
            throw QuarantineError.sourceChanged(url.path)
        }
    }

    private static func safeResourceURL(rootURL: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw QuarantineError.unsafeRelativePath(relativePath)
        }
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard isDescendantOrEqual(candidate, of: rootURL) else {
            throw QuarantineError.unsafeRelativePath(relativePath)
        }
        return candidate
    }

    private static func isDescendantOrEqual(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        if childPath == parentPath { return true }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }

    private static func writeManifest(_ manifest: QuarantineManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }
}
