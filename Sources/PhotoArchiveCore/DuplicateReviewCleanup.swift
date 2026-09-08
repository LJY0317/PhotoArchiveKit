import Foundation

public enum DuplicateReviewCleanupError: LocalizedError {
    case sessionMismatch
    case noDecisions
    case unknownItem(String)
    case subjectMismatch(String)
    case invalidDecision(String)
    case removeAllNotConfirmed(String)
    case unknownResource(String)
    case livePhotoAtomicityViolation(String)
    case missingRoot(String)
    case rootIdentityChanged(String)
    case rootRoleDisallowsCleanup(String)
    case nonRedundantCleanupDisallowed(String)
    case missingCatalogEvidence(String)
    case sourceChanged(String)
    case destinationAlreadyExists(String)
    case moveFailed(String)
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sessionMismatch:
            return "The duplicate-review selection no longer matches the current scan session. Refresh the review first."
        case .noDecisions:
            return "There are no reviewed cleanup selections to apply."
        case let .unknownItem(itemID):
            return "The reviewed reconciliation item is not present in the current plan: \(itemID)"
        case let .subjectMismatch(itemID):
            return "The reviewed item subject no longer matches the current plan: \(itemID)"
        case let .invalidDecision(itemID):
            return "The reviewed keep/cleanup resource set is invalid or stale: \(itemID)"
        case let .removeAllNotConfirmed(itemID):
            return "Removing every copy in a group requires an explicit remove-all confirmation: \(itemID)"
        case let .unknownResource(resourceID):
            return "A reviewed resource is not present in the current scan report: \(resourceID)"
        case let .livePhotoAtomicityViolation(itemID):
            return "A reviewed Live Photo cleanup must include a complete occurrence resource set: \(itemID)"
        case let .missingRoot(rootID):
            return "A reviewed source root is missing from the current scan report: \(rootID)"
        case let .rootIdentityChanged(rootID):
            return "A reviewed source root no longer matches its recorded identity: \(rootID)"
        case let .rootRoleDisallowsCleanup(rootID):
            return "The current root role does not allow this duplicate cleanup: \(rootID)"
        case let .nonRedundantCleanupDisallowed(rootID):
            return "A resource without a retained exact counterpart can only be explicitly moved from a staging or primary-library root: \(rootID)"
        case let .missingCatalogEvidence(resourceID):
            return "Current-file verification evidence is unavailable for a selected resource: \(resourceID)"
        case let .sourceChanged(resourceID):
            return "A selected resource changed since the review snapshot: \(resourceID)"
        case let .destinationAlreadyExists(path):
            return "The cleanup destination already exists: \(path)"
        case let .moveFailed(resourceID):
            return "Could not move a reviewed resource to the reversible cleanup destination: \(resourceID)"
        case let .rollbackFailed(resourceID):
            return "Cleanup rollback could not restore a reviewed resource: \(resourceID)"
        }
    }
}

public struct DuplicateReviewCleanupReport: Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let dryRun: Bool
    public let destinationKind: DuplicateCleanupDestinationKind
    public let targetPath: String?
    public let itemCount: Int
    public let resourceCount: Int
    public let totalBytes: Int64
    public let nonRedundantResourceCount: Int
    public let removeAllItemCount: Int
    public let onlyCompleteLivePhotoPairRemovalCount: Int
    public let removedEmptyDirectoryCount: Int
    public let filesModified: Bool
    public let manifestPath: String?

    public init(
        schemaVersion: Int = 1,
        sessionID: String,
        dryRun: Bool,
        destinationKind: DuplicateCleanupDestinationKind,
        targetPath: String?,
        itemCount: Int,
        resourceCount: Int,
        totalBytes: Int64,
        nonRedundantResourceCount: Int,
        removeAllItemCount: Int,
        onlyCompleteLivePhotoPairRemovalCount: Int,
        removedEmptyDirectoryCount: Int,
        filesModified: Bool,
        manifestPath: String?
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.dryRun = dryRun
        self.destinationKind = destinationKind
        self.targetPath = targetPath
        self.itemCount = itemCount
        self.resourceCount = resourceCount
        self.totalBytes = totalBytes
        self.nonRedundantResourceCount = nonRedundantResourceCount
        self.removeAllItemCount = removeAllItemCount
        self.onlyCompleteLivePhotoPairRemovalCount = onlyCompleteLivePhotoPairRemovalCount
        self.removedEmptyDirectoryCount = removedEmptyDirectoryCount
        self.filesModified = filesModified
        self.manifestPath = manifestPath
    }
}

public enum DuplicateReviewCleanupExecutor {
    private struct ResourceKey: Hashable {
        let rootID: String
        let relativePath: String
    }

    private struct VerifiedMove {
        let itemID: String
        let resourceID: String
        let rootID: String
        let role: ResourceRole
        let relativePath: String
        let sourceURL: URL
        let byteSize: Int64
        let isRedundant: Bool
    }

    private struct Verification {
        let moves: [VerifiedMove]
        let itemCount: Int
        let nonRedundantResourceCount: Int
        let removeAllItemCount: Int
        let onlyCompleteLivePhotoPairRemovalCount: Int
    }

    private struct TrashedMove {
        let verified: VerifiedMove
        let trashURL: URL
    }

    private struct QuarantinedMove {
        let verified: VerifiedMove
        let destinationURL: URL
    }

    public static func preflight(
        report: ScanReport,
        plan: ReconciliationPlan,
        decisions: [DuplicateReviewDecision],
        explicitlyRemoveAllItemIDs: Set<String>,
        destination: DuplicateCleanupDestination,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> DuplicateReviewCleanupReport {
        try validateDestination(destination, report: report)
        let verification = try verify(
            report: report,
            plan: plan,
            decisions: decisions,
            explicitlyRemoveAllItemIDs: explicitlyRemoveAllItemIDs,
            catalogURL: catalogURL
        )
        let setting = destinationMetadata(destination)
        return makeReport(
            report: report,
            verification: verification,
            dryRun: true,
            destinationKind: setting.kind,
            targetPath: setting.path,
            removedEmptyDirectoryCount: 0,
            filesModified: false,
            manifestPath: nil
        )
    }

    public static func apply(
        report: ScanReport,
        plan: ReconciliationPlan,
        decisions: [DuplicateReviewDecision],
        explicitlyRemoveAllItemIDs: Set<String>,
        destination: DuplicateCleanupDestination,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> DuplicateReviewCleanupReport {
        try validateDestination(destination, report: report)
        let verification = try verify(
            report: report,
            plan: plan,
            decisions: decisions,
            explicitlyRemoveAllItemIDs: explicitlyRemoveAllItemIDs,
            catalogURL: catalogURL
        )
        switch destination {
        case .systemTrash:
            return try applySystemTrash(
                report: report,
                verification: verification,
                trashMover: systemTrashMover
            )
        case .customQuarantine(let targetURL):
            return try applyCustomQuarantine(
                report: report,
                plan: plan,
                verification: verification,
                targetURL: targetURL
            )
        }
    }

    package static func preflightForTesting(
        report: ScanReport,
        plan: ReconciliationPlan,
        decisions: [DuplicateReviewDecision],
        explicitlyRemoveAllItemIDs: Set<String>,
        destination: DuplicateCleanupDestination,
        catalogURL: URL
    ) throws -> DuplicateReviewCleanupReport {
        try preflight(
            report: report,
            plan: plan,
            decisions: decisions,
            explicitlyRemoveAllItemIDs: explicitlyRemoveAllItemIDs,
            destination: destination,
            catalogURL: catalogURL
        )
    }

    package static func applySystemTrashForTesting(
        report: ScanReport,
        plan: ReconciliationPlan,
        decisions: [DuplicateReviewDecision],
        explicitlyRemoveAllItemIDs: Set<String>,
        catalogURL: URL,
        trashMover: (URL) throws -> URL
    ) throws -> DuplicateReviewCleanupReport {
        let verification = try verify(
            report: report,
            plan: plan,
            decisions: decisions,
            explicitlyRemoveAllItemIDs: explicitlyRemoveAllItemIDs,
            catalogURL: catalogURL
        )
        return try applySystemTrash(
            report: report,
            verification: verification,
            trashMover: trashMover
        )
    }

    private static func verify(
        report: ScanReport,
        plan: ReconciliationPlan,
        decisions: [DuplicateReviewDecision],
        explicitlyRemoveAllItemIDs: Set<String>,
        catalogURL: URL
    ) throws -> Verification {
        guard report.sessionID == plan.sessionID else {
            throw DuplicateReviewCleanupError.sessionMismatch
        }
        guard !decisions.isEmpty else {
            throw DuplicateReviewCleanupError.noDecisions
        }

        let automaticItems = Dictionary(uniqueKeysWithValues: plan.items
            .filter { $0.decision == .automaticRedundant }
            .map { ($0.itemID, $0) })
        let rootsByID = Dictionary(uniqueKeysWithValues: report.roots.map { ($0.rootID, $0) })
        let scannedByID = Dictionary(uniqueKeysWithValues: report.resources.map { ($0.resourceID, $0) })
        let scannedByKey = Dictionary(uniqueKeysWithValues: report.resources.map {
            (ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath), $0)
        })
        let duplicateGroupByKey = duplicateGroupIndex(report.exactDuplicateGroups)
        let duplicateGroupsByID = Dictionary(uniqueKeysWithValues: report.exactDuplicateGroups.map {
            ($0.groupID, $0)
        })

        let selectedResourceIDs = Array(Set(decisions.flatMap { $0.cleanupResourceIDs + $0.keptResourceIDs }))
        let scanner = try ArchiveScanner(catalogURL: catalogURL)
        let detailsByID = try scanner.duplicateReviewResourceDetails(resourceIDs: selectedResourceIDs)
        var hashCache: [String: Data] = [:]
        var moves: [VerifiedMove] = []
        var verifiedRootIDs = Set<String>()
        var nonRedundantResourceCount = 0
        var removeAllItemCount = 0
        var onlyCompleteLivePhotoPairRemovalCount = 0

        for decision in decisions {
            guard let item = automaticItems[decision.itemID] else {
                throw DuplicateReviewCleanupError.unknownItem(decision.itemID)
            }
            guard item.subjectID == decision.subjectID else {
                throw DuplicateReviewCleanupError.subjectMismatch(decision.itemID)
            }

            let itemResourceIDs = try resourceIDs(
                for: item.preferredResources + item.candidateResources,
                scannedByKey: scannedByKey
            )
            let kept = Set(decision.keptResourceIDs)
            let cleanup = Set(decision.cleanupResourceIDs)
            guard kept.isDisjoint(with: cleanup),
                  kept.union(cleanup) == itemResourceIDs,
                  !cleanup.isEmpty
            else {
                throw DuplicateReviewCleanupError.invalidDecision(decision.itemID)
            }

            let removesAll = kept.isEmpty
            if removesAll {
                guard explicitlyRemoveAllItemIDs.contains(decision.itemID) else {
                    throw DuplicateReviewCleanupError.removeAllNotConfirmed(decision.itemID)
                }
                removeAllItemCount += 1
            }

            if item.kind == .livePhotoAsset {
                try validateLivePhotoAtomicity(
                    item: item,
                    cleanupResourceIDs: cleanup,
                    report: report,
                    scannedByKey: scannedByKey
                )
                if removesOnlyCompletePair(
                    item: item,
                    cleanupResourceIDs: cleanup,
                    report: report,
                    scannedByKey: scannedByKey
                ) {
                    onlyCompleteLivePhotoPairRemovalCount += 1
                }
            }

            for resourceID in cleanup.sorted() {
                guard let scanned = scannedByID[resourceID] else {
                    throw DuplicateReviewCleanupError.unknownResource(resourceID)
                }
                guard let root = rootsByID[scanned.rootID] else {
                    throw DuplicateReviewCleanupError.missingRoot(scanned.rootID)
                }
                if verifiedRootIDs.insert(root.rootID).inserted {
                    try validateRootIdentity(root)
                }
                guard root.usageRole != .reference else {
                    throw DuplicateReviewCleanupError.rootRoleDisallowsCleanup(root.rootID)
                }

                let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                let sourceURL = try QuarantineExecutor.safeResourceURL(
                    rootURL: rootURL,
                    relativePath: scanned.relativePath
                )
                try QuarantineExecutor.validateCurrentFile(
                    url: sourceURL,
                    expectedSize: scanned.byteSize,
                    rootURL: rootURL
                )
                let currentHash = try currentHash(
                    resource: scanned,
                    url: sourceURL,
                    details: detailsByID[resourceID],
                    expectedSessionID: report.sessionID,
                    cache: &hashCache
                )

                let key = ResourceKey(rootID: scanned.rootID, relativePath: scanned.relativePath)
                let retained = try retainedExactCounterpart(
                    resource: scanned,
                    key: key,
                    keptResourceIDs: kept,
                    rootsByID: rootsByID,
                    scannedByID: scannedByID,
                    scannedByKey: scannedByKey,
                    duplicateGroupByKey: duplicateGroupByKey,
                    duplicateGroupsByID: duplicateGroupsByID,
                    detailsByID: detailsByID,
                    expectedSessionID: report.sessionID,
                    hashCache: &hashCache
                )

                if let retained {
                    guard currentHash == retained.hash else {
                        throw DuplicateReviewCleanupError.sourceChanged(resourceID)
                    }
                    guard QuarantineExecutor.roleAllowsReconciliationCleanup(
                        sourceRoot: root,
                        preferredRoot: retained.root,
                        sameRoot: root.rootID == retained.root.rootID
                    ) else {
                        throw DuplicateReviewCleanupError.rootRoleDisallowsCleanup(root.rootID)
                    }
                } else {
                    nonRedundantResourceCount += 1
                    guard root.usageRole == .staging || root.usageRole == .primaryLibrary else {
                        throw DuplicateReviewCleanupError.nonRedundantCleanupDisallowed(root.rootID)
                    }
                }

                moves.append(VerifiedMove(
                    itemID: decision.itemID,
                    resourceID: resourceID,
                    rootID: scanned.rootID,
                    role: scanned.role,
                    relativePath: scanned.relativePath,
                    sourceURL: sourceURL,
                    byteSize: scanned.byteSize,
                    isRedundant: retained != nil
                ))
            }
        }

        return Verification(
            moves: moves,
            itemCount: decisions.count,
            nonRedundantResourceCount: nonRedundantResourceCount,
            removeAllItemCount: removeAllItemCount,
            onlyCompleteLivePhotoPairRemovalCount: onlyCompleteLivePhotoPairRemovalCount
        )
    }

    private static func validateRootIdentity(_ root: RootScanReport) throws {
        let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw DuplicateReviewCleanupError.rootIdentityChanged(root.rootID)
        }
        if let expectedMarker = root.stableMarkerKey {
            guard try RootMarkerStore.readIfPresent(at: rootURL)?.markerKey == expectedMarker else {
                throw DuplicateReviewCleanupError.rootIdentityChanged(root.rootID)
            }
        } else if rootURL.resolvingSymlinksInPath().standardizedFileURL.path != rootURL.path {
            throw DuplicateReviewCleanupError.rootIdentityChanged(root.rootID)
        }
    }

    private static func currentHash(
        resource: ScannedResourceReport,
        url: URL,
        details: DuplicateReviewResourceDetails?,
        expectedSessionID: String,
        cache: inout [String: Data]
    ) throws -> Data {
        if let cached = cache[resource.resourceID] { return cached }
        guard let details,
              details.lastSeenSessionID == expectedSessionID
        else {
            throw DuplicateReviewCleanupError.missingCatalogEvidence(resource.resourceID)
        }

        if let expectedHex = details.exactSHA256Hex {
            let hash = try FileHasher.sha256(url: url)
            guard hash.lowercaseHexString == expectedHex.lowercased() else {
                throw DuplicateReviewCleanupError.sourceChanged(resource.resourceID)
            }
            cache[resource.resourceID] = hash
            return hash
        }

        let values = try url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        let modifiedAt = values.contentModificationDate
        let fileIdentifier = values.fileResourceIdentifier.map { String(describing: $0) }
        guard let catalogModifiedAt = details.catalogModifiedAt,
              let modifiedAt,
              abs(catalogModifiedAt.timeIntervalSince(modifiedAt)) < 0.001,
              details.catalogFileSystemIdentifier == nil
                || details.catalogFileSystemIdentifier == fileIdentifier
        else {
            throw DuplicateReviewCleanupError.sourceChanged(resource.resourceID)
        }

        // There is no historical cryptographic baseline for this unique resource.
        // Hash it now so the exact-counterpart path can still compare current bytes,
        // while the caller reports it as an explicitly selected non-redundant move.
        let hash = try FileHasher.sha256(url: url)
        cache[resource.resourceID] = hash
        return hash
    }

    private static func retainedExactCounterpart(
        resource: ScannedResourceReport,
        key: ResourceKey,
        keptResourceIDs: Set<String>,
        rootsByID: [String: RootScanReport],
        scannedByID: [String: ScannedResourceReport],
        scannedByKey: [ResourceKey: ScannedResourceReport],
        duplicateGroupByKey: [ResourceKey: String],
        duplicateGroupsByID: [String: ExactDuplicateGroupReport],
        detailsByID: [String: DuplicateReviewResourceDetails],
        expectedSessionID: String,
        hashCache: inout [String: Data]
    ) throws -> (resource: ScannedResourceReport, root: RootScanReport, hash: Data)? {
        guard let groupID = duplicateGroupByKey[key],
              let group = duplicateGroupsByID[groupID]
        else { return nil }

        for member in group.members where member.role == resource.role {
            let memberKey = ResourceKey(rootID: member.rootID, relativePath: member.relativePath)
            guard let retained = scannedByKey[memberKey],
                  keptResourceIDs.contains(retained.resourceID),
                  let retainedRoot = rootsByID[retained.rootID]
            else { continue }

            let rootURL = URL(fileURLWithPath: retainedRoot.canonicalPath, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let url = try QuarantineExecutor.safeResourceURL(
                rootURL: rootURL,
                relativePath: retained.relativePath
            )
            try QuarantineExecutor.validateCurrentFile(
                url: url,
                expectedSize: retained.byteSize,
                rootURL: rootURL
            )
            let hash = try currentHash(
                resource: retained,
                url: url,
                details: detailsByID[retained.resourceID],
                expectedSessionID: expectedSessionID,
                cache: &hashCache
            )
            return (retained, retainedRoot, hash)
        }
        _ = scannedByID
        return nil
    }

    private static func resourceIDs(
        for references: [ResourceReference],
        scannedByKey: [ResourceKey: ScannedResourceReport]
    ) throws -> Set<String> {
        var result = Set<String>()
        for reference in references {
            let key = ResourceKey(rootID: reference.rootID, relativePath: reference.relativePath)
            guard let scanned = scannedByKey[key] else {
                throw DuplicateReviewCleanupError.invalidDecision(reference.relativePath)
            }
            result.insert(scanned.resourceID)
        }
        return result
    }

    private static func validateLivePhotoAtomicity(
        item: ReconciliationPlanItem,
        cleanupResourceIDs: Set<String>,
        report: ScanReport,
        scannedByKey: [ResourceKey: ScannedResourceReport]
    ) throws {
        guard let asset = report.livePhotos.first(where: { $0.assetID == item.subjectID }) else {
            throw DuplicateReviewCleanupError.livePhotoAtomicityViolation(item.itemID)
        }
        var covered = Set<String>()
        for occurrence in asset.occurrences {
            let occurrenceIDs = Set(occurrence.resources.compactMap {
                scannedByKey[ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath)]?.resourceID
            })
            let intersection = occurrenceIDs.intersection(cleanupResourceIDs)
            if intersection.isEmpty { continue }
            guard intersection == occurrenceIDs else {
                throw DuplicateReviewCleanupError.livePhotoAtomicityViolation(item.itemID)
            }
            covered.formUnion(occurrenceIDs)
        }
        guard covered == cleanupResourceIDs else {
            throw DuplicateReviewCleanupError.livePhotoAtomicityViolation(item.itemID)
        }
    }

    private static func removesOnlyCompletePair(
        item: ReconciliationPlanItem,
        cleanupResourceIDs: Set<String>,
        report: ScanReport,
        scannedByKey: [ResourceKey: ScannedResourceReport]
    ) -> Bool {
        guard let asset = report.livePhotos.first(where: { $0.assetID == item.subjectID }) else {
            return false
        }
        let complete = asset.occurrences.filter { occurrence in
            occurrence.resources.contains { $0.role == .photo }
                && occurrence.resources.contains { $0.role == .pairedVideo }
        }
        guard complete.count == 1, let only = complete.first else { return false }
        let ids = Set(only.resources.compactMap {
            scannedByKey[ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath)]?.resourceID
        })
        return !ids.isEmpty && ids.isSubset(of: cleanupResourceIDs)
    }

    private static func duplicateGroupIndex(
        _ groups: [ExactDuplicateGroupReport]
    ) -> [ResourceKey: String] {
        var output: [ResourceKey: String] = [:]
        for group in groups {
            for member in group.members {
                output[ResourceKey(rootID: member.rootID, relativePath: member.relativePath)] = group.groupID
            }
        }
        return output
    }

    private static func applySystemTrash(
        report: ScanReport,
        verification: Verification,
        trashMover: (URL) throws -> URL
    ) throws -> DuplicateReviewCleanupReport {
        var trashed: [TrashedMove] = []
        do {
            for move in verification.moves {
                do {
                    let resultingURL = try trashMover(move.sourceURL)
                    trashed.append(TrashedMove(verified: move, trashURL: resultingURL))
                } catch {
                    throw DuplicateReviewCleanupError.moveFailed(move.resourceID)
                }
            }
        } catch {
            for move in trashed.reversed() {
                do {
                    try FileManager.default.createDirectory(
                        at: move.verified.sourceURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: move.trashURL.path),
                       !FileManager.default.fileExists(atPath: move.verified.sourceURL.path) {
                        try FileManager.default.moveItem(at: move.trashURL, to: move.verified.sourceURL)
                    }
                } catch {
                    throw DuplicateReviewCleanupError.rollbackFailed(move.verified.resourceID)
                }
            }
            throw error
        }

        let records = trashed.map {
            QuarantineMoveRecord(
                itemID: $0.verified.itemID,
                rootID: $0.verified.rootID,
                role: $0.verified.role,
                sourcePath: $0.verified.sourceURL.path,
                sourceRelativePath: $0.verified.relativePath,
                destinationPath: $0.trashURL.path,
                byteSize: $0.verified.byteSize
            )
        }
        let removed = EmptyParentDirectoryCleaner.removeNowEmptyParents(
            sourceRecords: records,
            roots: report.roots
        )
        return makeReport(
            report: report,
            verification: verification,
            dryRun: false,
            destinationKind: .systemTrash,
            targetPath: nil,
            removedEmptyDirectoryCount: removed.count,
            filesModified: !trashed.isEmpty || !removed.isEmpty,
            manifestPath: nil
        )
    }

    private static func systemTrashMover(_ sourceURL: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: sourceURL, resultingItemURL: &resultingURL)
        guard let resultingURL else {
            throw DuplicateReviewCleanupError.moveFailed(sourceURL.lastPathComponent)
        }
        return resultingURL as URL
    }

    private static func applyCustomQuarantine(
        report: ScanReport,
        plan: ReconciliationPlan,
        verification: Verification,
        targetURL rawTargetURL: URL
    ) throws -> DuplicateReviewCleanupReport {
        let targetURL = rawTargetURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw QuarantineError.targetDoesNotExist(targetURL.path)
        }
        let operationID = "review-\(report.sessionID)-\(UUID().uuidString.lowercased())"
        let sessionRoot = targetURL
            .appendingPathComponent("PhotoArchiveKit", isDirectory: true)
            .appendingPathComponent(operationID, isDirectory: true)
        let pendingManifestURL = sessionRoot.appendingPathComponent("manifest.pending.json")
        let finalManifestURL = sessionRoot.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)

        let destinations = try verification.moves.map { move -> QuarantinedMove in
            let destination = sessionRoot
                .appendingPathComponent(move.rootID, isDirectory: true)
                .appendingPathComponent(move.relativePath)
                .standardizedFileURL
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw DuplicateReviewCleanupError.destinationAlreadyExists(destination.path)
            }
            return QuarantinedMove(verified: move, destinationURL: destination)
        }
        let records = destinations.map {
            QuarantineMoveRecord(
                itemID: $0.verified.itemID,
                rootID: $0.verified.rootID,
                role: $0.verified.role,
                sourcePath: $0.verified.sourceURL.path,
                sourceRelativePath: $0.verified.relativePath,
                destinationPath: $0.destinationURL.path,
                byteSize: $0.verified.byteSize
            )
        }
        let pending = QuarantineManifest(
            schemaVersion: 1,
            sessionID: operationID,
            policy: "\(plan.policy)+manual_review_selection_v1",
            createdAt: Date(),
            state: "pending",
            targetPath: targetURL.path,
            moves: records,
            filesModified: false
        )
        try writeManifest(pending, to: pendingManifestURL)

        var moved: [QuarantinedMove] = []
        do {
            for move in destinations {
                try FileManager.default.createDirectory(
                    at: move.destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    try FileManager.default.moveItem(at: move.verified.sourceURL, to: move.destinationURL)
                } catch {
                    throw DuplicateReviewCleanupError.moveFailed(move.verified.resourceID)
                }
                moved.append(move)
            }
        } catch {
            for move in moved.reversed() {
                do {
                    try FileManager.default.createDirectory(
                        at: move.verified.sourceURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: move.destinationURL.path),
                       !FileManager.default.fileExists(atPath: move.verified.sourceURL.path) {
                        try FileManager.default.moveItem(at: move.destinationURL, to: move.verified.sourceURL)
                    }
                } catch {
                    throw DuplicateReviewCleanupError.rollbackFailed(move.verified.resourceID)
                }
            }
            try? FileManager.default.removeItem(at: sessionRoot)
            throw error
        }

        let final = QuarantineManifest(
            schemaVersion: 1,
            sessionID: operationID,
            policy: pending.policy,
            createdAt: pending.createdAt,
            state: "complete",
            targetPath: targetURL.path,
            moves: records,
            filesModified: true
        )
        try writeManifest(final, to: finalManifestURL)
        try? FileManager.default.removeItem(at: pendingManifestURL)
        let removed = EmptyParentDirectoryCleaner.removeNowEmptyParents(
            sourceRecords: records,
            roots: report.roots
        )
        return makeReport(
            report: report,
            verification: verification,
            dryRun: false,
            destinationKind: .customQuarantine,
            targetPath: targetURL.path,
            removedEmptyDirectoryCount: removed.count,
            filesModified: !moved.isEmpty || !removed.isEmpty,
            manifestPath: finalManifestURL.path
        )
    }

    private static func destinationMetadata(
        _ destination: DuplicateCleanupDestination
    ) -> (kind: DuplicateCleanupDestinationKind, path: String?) {
        switch destination {
        case .systemTrash:
            return (.systemTrash, nil)
        case .customQuarantine(let url):
            return (.customQuarantine, url.standardizedFileURL.path)
        }
    }

    private static func validateDestination(
        _ destination: DuplicateCleanupDestination,
        report: ScanReport
    ) throws {
        guard case .customQuarantine(let rawTargetURL) = destination else { return }
        let targetURL = rawTargetURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            throw QuarantineError.targetDoesNotExist(targetURL.path)
        }
        guard isDirectory.boolValue else {
            throw QuarantineError.targetIsNotDirectory(targetURL.path)
        }
        for root in report.roots {
            let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if isDescendantOrEqual(targetURL, of: rootURL)
                || isDescendantOrEqual(rootURL, of: targetURL) {
                throw QuarantineError.targetOverlapsSource(targetURL.path)
            }
        }
    }

    private static func isDescendantOrEqual(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        if childPath == parentPath { return true }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }

    private static func makeReport(
        report: ScanReport,
        verification: Verification,
        dryRun: Bool,
        destinationKind: DuplicateCleanupDestinationKind,
        targetPath: String?,
        removedEmptyDirectoryCount: Int,
        filesModified: Bool,
        manifestPath: String?
    ) -> DuplicateReviewCleanupReport {
        DuplicateReviewCleanupReport(
            sessionID: report.sessionID,
            dryRun: dryRun,
            destinationKind: destinationKind,
            targetPath: targetPath,
            itemCount: verification.itemCount,
            resourceCount: verification.moves.count,
            totalBytes: verification.moves.reduce(0) { $0 + $1.byteSize },
            nonRedundantResourceCount: verification.nonRedundantResourceCount,
            removeAllItemCount: verification.removeAllItemCount,
            onlyCompleteLivePhotoPairRemovalCount: verification.onlyCompleteLivePhotoPairRemovalCount,
            removedEmptyDirectoryCount: removedEmptyDirectoryCount,
            filesModified: filesModified,
            manifestPath: manifestPath
        )
    }

    private static func writeManifest(_ manifest: QuarantineManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }
}
