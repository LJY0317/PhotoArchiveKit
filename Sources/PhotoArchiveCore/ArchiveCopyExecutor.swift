import Foundation

public struct ArchiveCopyRootBinding: Sendable, Equatable {
    public let rootID: String
    public let url: URL

    public init(rootID: String, url: URL) {
        self.rootID = rootID
        self.url = url.standardizedFileURL
    }
}

public struct ArchiveCopyReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let planID: String
    public let dryRun: Bool
    public let automaticItemCount: Int
    public let automaticResourceCount: Int
    public let reviewItemCount: Int
    public let alreadyFinalResourceCount: Int
    public let stagedResourceCount: Int
    public let copyRequiredResourceCount: Int
    public let catalogCommitted: Bool
    public let snapshotWritten: Bool
    public let manifestPath: String
    public let snapshotPath: String
    public let filesModified: Bool
}

public struct AgentSafeArchiveCopyReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let planID: String
    public let dryRun: Bool
    public let automaticItemCount: Int
    public let automaticResourceCount: Int
    public let reviewItemCount: Int
    public let alreadyFinalResourceCount: Int
    public let stagedResourceCount: Int
    public let copyRequiredResourceCount: Int
    public let catalogCommitted: Bool
    public let snapshotWritten: Bool
    public let filesModified: Bool

    public init(report: ArchiveCopyReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        planID = report.planID
        dryRun = report.dryRun
        automaticItemCount = report.automaticItemCount
        automaticResourceCount = report.automaticResourceCount
        reviewItemCount = report.reviewItemCount
        alreadyFinalResourceCount = report.alreadyFinalResourceCount
        stagedResourceCount = report.stagedResourceCount
        copyRequiredResourceCount = report.copyRequiredResourceCount
        catalogCommitted = report.catalogCommitted
        snapshotWritten = report.snapshotWritten
        filesModified = report.filesModified
    }
}

public enum ArchiveCopyError: LocalizedError {
    case planMissing
    case invalidPlan(String)
    case planChanged
    case unknownRootBinding(String)
    case duplicateRootBinding(String)
    case catalogMissing
    case rootUnavailable(String)
    case rootMarkerMismatch(String)
    case destinationUnavailable
    case destinationMarkerMismatch
    case unsafePath(String)
    case sourcePreconditionFailed(String)
    case catalogEvidenceMismatch(String)
    case destinationConflict(String)
    case stagingConflict(String)
    case copyFailed(String)
    case verificationFailed(String)
    case catalogCommitFailed(String)
    case snapshotConflict
    case manifestConflict

    public var errorDescription: String? {
        switch self {
        case .planMissing:
            return "The immutable archive plan does not exist."
        case let .invalidPlan(message):
            return "The immutable archive plan is invalid: \(message)"
        case .planChanged:
            return "The archive plan bytes do not match the plan already recorded by this copy session."
        case let .unknownRootBinding(rootID):
            return "An archive-copy root binding references an unknown root ID: \(rootID)"
        case let .duplicateRootBinding(rootID):
            return "An archive-copy root ID was bound more than once: \(rootID)"
        case .catalogMissing:
            return "The catalog required for archive commit does not exist."
        case let .rootUnavailable(rootID):
            return "A source root needed for copying is unavailable: \(rootID)"
        case let .rootMarkerMismatch(rootID):
            return "A source root marker no longer matches the immutable plan: \(rootID)"
        case .destinationUnavailable:
            return "The archive destination is unavailable or is not a directory."
        case .destinationMarkerMismatch:
            return "The archive destination marker no longer matches the immutable plan."
        case let .unsafePath(resourceID):
            return "An archive-copy path crosses an unsafe boundary: \(resourceID)"
        case let .sourcePreconditionFailed(resourceID):
            return "A source resource no longer matches the immutable plan: \(resourceID)"
        case let .catalogEvidenceMismatch(resourceID):
            return "Catalog evidence no longer matches the immutable plan: \(resourceID)"
        case let .destinationConflict(resourceID):
            return "An existing archive destination does not match the immutable plan: \(resourceID)"
        case let .stagingConflict(resourceID):
            return "An existing staged resource does not match the immutable plan: \(resourceID)"
        case let .copyFailed(resourceID):
            return "A resource could not be copied to archive staging: \(resourceID)"
        case let .verificationFailed(resourceID):
            return "A copied archive resource failed byte verification: \(resourceID)"
        case let .catalogCommitFailed(resourceID):
            return "The verified archive copy could not be reconciled into the catalog: \(resourceID)"
        case .snapshotConflict:
            return "An existing archive catalog snapshot differs from the current verified catalog state."
        case .manifestConflict:
            return "An existing archive-copy manifest is invalid or belongs to different plan bytes."
        }
    }
}

public enum ArchiveCopyExecutor {
    private enum ResourceState {
        case finalVerified
        case stagedVerified
        case copyRequired(sourceURL: URL)
    }

    private struct PreparedResource {
        let itemID: String
        let assetID: String
        let kind: ArchivePlanItemKind
        let planned: ArchivePlannedResource
        let finalURL: URL
        let stagingURL: URL
        let state: ResourceState
    }

    private struct PreparedCopy {
        let planURL: URL
        let plan: ArchivePlan
        let planSHA256: String
        let destinationURL: URL
        let catalogURL: URL
        let metadataRootURL: URL
        let stagingRootURL: URL
        let archivedPlanURL: URL
        let manifestURL: URL
        let snapshotURL: URL
        let resources: [PreparedResource]
        let existingManifest: ArchiveCopyManifest?
    }

    private struct ArchiveCopyManifest: Codable, Equatable {
        let schemaVersion: Int
        let planID: String
        let planSHA256: String
        let state: String
        let updatedAt: Date
        let automaticItemCount: Int
        let automaticResourceCount: Int
        let catalogSessionID: String?
        let snapshotSHA256: String?
    }

    public static func preflight(
        planURL: URL,
        rootBindings: [ArchiveCopyRootBinding] = [],
        destinationURL: URL? = nil,
        catalogURL: URL? = nil
    ) throws -> ArchiveCopyReport {
        let prepared = try prepare(
            planURL: planURL,
            rootBindings: rootBindings,
            destinationURL: destinationURL,
            catalogURL: catalogURL
        )
        return report(
            prepared: prepared,
            dryRun: true,
            catalogCommitted: prepared.existingManifest?.state == "complete",
            snapshotWritten: FileManager.default.fileExists(atPath: prepared.snapshotURL.path),
            filesModified: false
        )
    }

    public static func apply(
        planURL: URL,
        rootBindings: [ArchiveCopyRootBinding] = [],
        destinationURL: URL? = nil,
        catalogURL: URL? = nil
    ) async throws -> ArchiveCopyReport {
        var prepared = try prepare(
            planURL: planURL,
            rootBindings: rootBindings,
            destinationURL: destinationURL,
            catalogURL: catalogURL
        )
        let fileManager = FileManager.default

        if prepared.existingManifest?.state == "complete" {
            guard fileManager.fileExists(atPath: prepared.snapshotURL.path) else {
                throw ArchiveCopyError.manifestConflict
            }
            return report(
                prepared: prepared,
                dryRun: false,
                catalogCommitted: true,
                snapshotWritten: true,
                filesModified: false
            )
        }

        try createDirectorySafely(prepared.metadataRootURL, under: prepared.destinationURL)
        try persistPlanCopy(prepared)
        try writeManifest(
            ArchiveCopyManifest(
                schemaVersion: 1,
                planID: prepared.plan.planID,
                planSHA256: prepared.planSHA256,
                state: "pending",
                updatedAt: roundedNow(),
                automaticItemCount: prepared.plan.summary.automaticItemCount,
                automaticResourceCount: prepared.plan.summary.automaticResourceCount,
                catalogSessionID: nil,
                snapshotSHA256: nil
            ),
            to: prepared.manifestURL
        )

        let byItem = Dictionary(grouping: prepared.resources, by: \.itemID)
        for item in prepared.plan.items where item.decision == .automatic {
            let itemResources = byItem[item.itemID] ?? []
            guard itemResources.count == item.resources.count else {
                throw ArchiveCopyError.invalidPlan("automatic item resource count changed")
            }

            for resource in itemResources {
                switch resource.state {
                case .finalVerified, .stagedVerified:
                    continue
                case let .copyRequired(sourceURL):
                    try stageCopy(sourceURL: sourceURL, resource: resource)
                }
            }

            // Live Photo safety: every resource must be verified either in final or staging
            // before the first missing member is finalized.
            for resource in itemResources {
                if fileManager.fileExists(atPath: resource.finalURL.path) {
                    try verifyFile(resource.finalURL, planned: resource.planned, conflict: .destination)
                } else {
                    try verifyFile(resource.stagingURL, planned: resource.planned, conflict: .staging)
                }
            }

            for resource in itemResources {
                if fileManager.fileExists(atPath: resource.finalURL.path) {
                    if fileManager.fileExists(atPath: resource.stagingURL.path) {
                        try verifyFile(resource.stagingURL, planned: resource.planned, conflict: .staging)
                        try fileManager.removeItem(at: resource.stagingURL)
                    }
                    continue
                }
                try createDirectorySafely(
                    resource.finalURL.deletingLastPathComponent(),
                    under: prepared.destinationURL
                )
                do {
                    try fileManager.moveItem(at: resource.stagingURL, to: resource.finalURL)
                } catch {
                    throw ArchiveCopyError.copyFailed(resource.planned.resourceID)
                }
                try verifyFile(resource.finalURL, planned: resource.planned, conflict: .verification)
            }
        }

        guard let finalDestinationMarker = try RootMarkerStore.readIfPresent(at: prepared.destinationURL),
              finalDestinationMarker.markerKey == prepared.plan.destination.markerKey
        else {
            throw ArchiveCopyError.destinationMarkerMismatch
        }

        // A final full verification is the filesystem commit boundary.
        for resource in prepared.resources {
            try verifyFile(resource.finalURL, planned: resource.planned, conflict: .verification)
        }
        try? fileManager.removeItem(at: prepared.stagingRootURL)

        let scanner = try ArchiveScanner(catalogURL: prepared.catalogURL)
        let archiveReport = try await scanner.scan(
            roots: [ScanRoot(
                url: prepared.destinationURL,
                label: prepared.destinationURL.lastPathComponent,
                kind: .archive,
                provenance: .localLibrary
            )],
            options: ScanOptions(
                computeExactDuplicates: true,
                computeArchiveIntegrityPreconditions: true
            )
        )
        try validateCatalogCommit(plan: prepared.plan, report: archiveReport)

        let snapshotSHA256 = try ensureCatalogSnapshot(
            catalogURL: prepared.catalogURL,
            targetURL: prepared.snapshotURL
        )
        try writeManifest(
            ArchiveCopyManifest(
                schemaVersion: 1,
                planID: prepared.plan.planID,
                planSHA256: prepared.planSHA256,
                state: "complete",
                updatedAt: roundedNow(),
                automaticItemCount: prepared.plan.summary.automaticItemCount,
                automaticResourceCount: prepared.plan.summary.automaticResourceCount,
                catalogSessionID: archiveReport.sessionID,
                snapshotSHA256: snapshotSHA256
            ),
            to: prepared.manifestURL
        )

        // Re-prepare from filesystem truth so returned checkpoint counts describe the
        // completed state rather than the state observed before copying.
        prepared = try prepare(
            planURL: planURL,
            rootBindings: rootBindings,
            destinationURL: destinationURL,
            catalogURL: catalogURL
        )
        return report(
            prepared: prepared,
            dryRun: false,
            catalogCommitted: true,
            snapshotWritten: true,
            filesModified: true
        )
    }

    private enum VerificationConflict {
        case destination
        case staging
        case verification
    }

    private static func prepare(
        planURL rawPlanURL: URL,
        rootBindings: [ArchiveCopyRootBinding],
        destinationURL destinationOverride: URL?,
        catalogURL catalogOverride: URL?
    ) throws -> PreparedCopy {
        let fileManager = FileManager.default
        let planURL = rawPlanURL.standardizedFileURL
        guard fileManager.fileExists(atPath: planURL.path) else {
            throw ArchiveCopyError.planMissing
        }
        let plan = try ArchivePlanStore.read(from: planURL)
        try validatePlan(plan)
        let planSHA256 = try FileHasher.sha256(url: planURL).lowercaseHexString

        let destinationURL = (destinationOverride
            ?? URL(fileURLWithPath: plan.destination.canonicalPath, isDirectory: true))
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var destinationIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory),
              destinationIsDirectory.boolValue
        else {
            throw ArchiveCopyError.destinationUnavailable
        }
        guard let destinationMarker = try RootMarkerStore.readIfPresent(at: destinationURL),
              destinationMarker.markerKey == plan.destination.markerKey
        else {
            throw ArchiveCopyError.destinationMarkerMismatch
        }

        let catalogURL = (catalogOverride ?? URL(fileURLWithPath: plan.catalogPath)).standardizedFileURL
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            throw ArchiveCopyError.catalogMissing
        }
        let catalog = try SQLiteCatalog(url: catalogURL)

        let knownRoots = Dictionary(uniqueKeysWithValues: plan.sourceRoots.map { ($0.rootID, $0) })
        var boundRoots: [String: URL] = [:]
        for binding in rootBindings {
            guard knownRoots[binding.rootID] != nil else {
                throw ArchiveCopyError.unknownRootBinding(binding.rootID)
            }
            guard boundRoots[binding.rootID] == nil else {
                throw ArchiveCopyError.duplicateRootBinding(binding.rootID)
            }
            boundRoots[binding.rootID] = binding.url.resolvingSymlinksInPath().standardizedFileURL
        }

        let metadataRootURL = destinationURL.appendingPathComponent(".photoarchive", isDirectory: true)
        try validateExistingDirectoryBoundary(metadataRootURL, under: destinationURL)
        let stagingRootURL = metadataRootURL
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(plan.planID, isDirectory: true)
        let archivedPlanURL = metadataRootURL
            .appendingPathComponent("plans", isDirectory: true)
            .appendingPathComponent(plan.planID + ".json", isDirectory: false)
        let manifestURL = metadataRootURL
            .appendingPathComponent("operations", isDirectory: true)
            .appendingPathComponent(plan.planID, isDirectory: true)
            .appendingPathComponent("copy.json", isDirectory: false)
        let snapshotURL = metadataRootURL
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent(plan.planID + ".jsonl", isDirectory: false)

        let existingManifest = try readManifestIfPresent(manifestURL)
        if let existingManifest {
            guard existingManifest.schemaVersion == 1,
                  existingManifest.planID == plan.planID,
                  existingManifest.planSHA256 == planSHA256,
                  existingManifest.state == "pending" || existingManifest.state == "complete"
            else {
                throw ArchiveCopyError.manifestConflict
            }
            if existingManifest.state == "complete" {
                guard let expectedSnapshotSHA256 = existingManifest.snapshotSHA256,
                      fileManager.fileExists(atPath: snapshotURL.path),
                      try FileHasher.sha256(url: snapshotURL).lowercaseHexString
                        == expectedSnapshotSHA256
                else {
                    throw ArchiveCopyError.snapshotConflict
                }
            }
        }
        if fileManager.fileExists(atPath: archivedPlanURL.path) {
            guard try FileHasher.sha256(url: archivedPlanURL).lowercaseHexString == planSHA256 else {
                throw ArchiveCopyError.planChanged
            }
        }

        var preparedResources: [PreparedResource] = []
        for item in plan.items where item.decision == .automatic {
            for resource in item.resources {
                guard let expectedHash = resource.expectedSHA256,
                      let evidence = try catalog.archiveCopyEvidence(resourceID: resource.resourceID),
                      evidence.rootID == resource.sourceRootID,
                      evidence.relativePath == resource.sourceRelativePath,
                      evidence.assetID == item.assetID,
                      evidence.role == resource.role,
                      evidence.byteSize == resource.byteSize,
                      evidence.exactHash.lowercaseHexString == expectedHash.lowercased()
                else {
                    throw ArchiveCopyError.catalogEvidenceMismatch(resource.resourceID)
                }
                let finalURL = try safeRelativeURL(
                    rootURL: destinationURL,
                    relativePath: resource.destinationRelativePath,
                    resourceID: resource.resourceID
                )
                try validateDestinationAncestors(
                    finalURL: finalURL,
                    destinationURL: destinationURL,
                    resourceID: resource.resourceID
                )
                let stagingURL = try safeRelativeURL(
                    rootURL: stagingRootURL,
                    relativePath: resource.destinationRelativePath,
                    resourceID: resource.resourceID
                )
                try validateExistingDirectoryBoundary(
                    stagingURL.deletingLastPathComponent(),
                    under: destinationURL
                )

                let state: ResourceState
                if fileManager.fileExists(atPath: finalURL.path) {
                    try verifyFile(finalURL, planned: resource, conflict: .destination)
                    if fileManager.fileExists(atPath: stagingURL.path) {
                        try verifyFile(stagingURL, planned: resource, conflict: .staging)
                    }
                    state = .finalVerified
                } else if fileManager.fileExists(atPath: stagingURL.path) {
                    try verifyFile(stagingURL, planned: resource, conflict: .staging)
                    state = .stagedVerified
                } else {
                    guard let root = knownRoots[resource.sourceRootID],
                          let markerKey = root.markerKey
                    else {
                        throw ArchiveCopyError.sourcePreconditionFailed(resource.resourceID)
                    }
                    let rootURL = (boundRoots[root.rootID]
                        ?? URL(fileURLWithPath: root.canonicalPath, isDirectory: true))
                        .resolvingSymlinksInPath()
                        .standardizedFileURL
                    var rootIsDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &rootIsDirectory),
                          rootIsDirectory.boolValue
                    else {
                        throw ArchiveCopyError.rootUnavailable(root.rootID)
                    }
                    guard let currentMarker = try RootMarkerStore.readIfPresent(at: rootURL),
                          currentMarker.markerKey == markerKey
                    else {
                        throw ArchiveCopyError.rootMarkerMismatch(root.rootID)
                    }
                    let sourceURL = try safeRelativeURL(
                        rootURL: rootURL,
                        relativePath: resource.sourceRelativePath,
                        resourceID: resource.resourceID
                    )
                    try verifyFile(sourceURL, planned: resource, conflict: .verification, source: true)
                    state = .copyRequired(sourceURL: sourceURL)
                }

                preparedResources.append(PreparedResource(
                    itemID: item.itemID,
                    assetID: item.assetID,
                    kind: item.kind,
                    planned: resource,
                    finalURL: finalURL,
                    stagingURL: stagingURL,
                    state: state
                ))
            }
        }

        return PreparedCopy(
            planURL: planURL,
            plan: plan,
            planSHA256: planSHA256,
            destinationURL: destinationURL,
            catalogURL: catalogURL,
            metadataRootURL: metadataRootURL,
            stagingRootURL: stagingRootURL,
            archivedPlanURL: archivedPlanURL,
            manifestURL: manifestURL,
            snapshotURL: snapshotURL,
            resources: preparedResources,
            existingManifest: existingManifest
        )
    }

    private static func validatePlan(_ plan: ArchivePlan) throws {
        guard plan.schemaVersion == 2,
              plan.policy == "canonical_representation_year_folder_v1",
              plan.mediaFilesModified == false,
              plan.planID.hasPrefix("AP"),
              plan.planID.allSatisfy({ $0.isLetter || $0.isNumber }),
              !plan.catalogPath.isEmpty,
              !plan.destination.markerKey.isEmpty
        else {
            throw ArchiveCopyError.invalidPlan("unsupported header or identifier")
        }

        let rootIDs = Set(plan.sourceRoots.map(\.rootID))
        guard rootIDs.count == plan.sourceRoots.count else {
            throw ArchiveCopyError.invalidPlan("duplicate source root ID")
        }
        let itemIDs = Set(plan.items.map(\.itemID))
        guard itemIDs.count == plan.items.count else {
            throw ArchiveCopyError.invalidPlan("duplicate item ID")
        }

        let automatic = plan.items.filter { $0.decision == .automatic }
        let review = plan.items.filter { $0.decision == .review }
        let automaticResources = automatic.flatMap(\.resources)
        guard automatic.count == plan.summary.automaticItemCount,
              review.count == plan.summary.reviewItemCount,
              automaticResources.count == plan.summary.automaticResourceCount,
              review.reduce(0, { $0 + $1.resources.count }) == plan.summary.reviewResourceCount
        else {
            throw ArchiveCopyError.invalidPlan("summary does not match item contents")
        }
        let destinationCollisionKeys = automaticResources.map {
            $0.destinationRelativePath.precomposedStringWithCanonicalMapping.lowercased()
        }
        guard Set(automaticResources.map(\.resourceID)).count == automaticResources.count,
              Set(destinationCollisionKeys).count == automaticResources.count
        else {
            throw ArchiveCopyError.invalidPlan("duplicate automatic resource or destination")
        }

        for item in automatic {
            guard item.reason == .canonicalRepresentation, !item.resources.isEmpty else {
                throw ArchiveCopyError.invalidPlan("automatic item has no canonical authority")
            }
            if item.kind == .livePhoto {
                guard item.resources.count == 2,
                      Set(item.resources.map(\.role)) == Set([ResourceRole.photo, ResourceRole.pairedVideo]),
                      Set(item.resources.map {
                          ($0.destinationRelativePath as NSString).deletingPathExtension
                      }).count == 1
                else {
                    throw ArchiveCopyError.invalidPlan("Live Photo automatic item is not atomic")
                }
            }
            for resource in item.resources {
                guard rootIDs.contains(resource.sourceRootID),
                      resource.byteSize >= 0,
                      !resource.sourceRelativePath.isEmpty,
                      !resource.destinationRelativePath.isEmpty,
                      let hash = resource.expectedSHA256,
                      hash.count == 64,
                      hash.allSatisfy({ $0.isHexDigit })
                else {
                    throw ArchiveCopyError.invalidPlan("automatic resource lacks replay preconditions")
                }
                try validateRelativePath(resource.sourceRelativePath, resourceID: resource.resourceID)
                try validateRelativePath(resource.destinationRelativePath, resourceID: resource.resourceID)
            }
        }
    }

    private static func stageCopy(sourceURL: URL, resource: PreparedResource) throws {
        let fileManager = FileManager.default
        try createDirectorySafely(
            resource.stagingURL.deletingLastPathComponent(),
            under: resource.stagingURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        )
        let temporaryURL = resource.stagingURL.deletingLastPathComponent()
            .appendingPathComponent(".partial-" + UUID().uuidString, isDirectory: false)
        defer { try? fileManager.removeItem(at: temporaryURL) }
        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        } catch {
            throw ArchiveCopyError.copyFailed(resource.planned.resourceID)
        }
        try verifyFile(temporaryURL, planned: resource.planned, conflict: .verification)
        do {
            try fileManager.moveItem(at: temporaryURL, to: resource.stagingURL)
        } catch {
            throw ArchiveCopyError.copyFailed(resource.planned.resourceID)
        }
        try verifyFile(resource.stagingURL, planned: resource.planned, conflict: .verification)
    }

    private static func validateCatalogCommit(plan: ArchivePlan, report: ScanReport) throws {
        let byPath = Dictionary(uniqueKeysWithValues: report.resources.map { ($0.relativePath, $0) })
        for item in plan.items where item.decision == .automatic {
            for planned in item.resources {
                guard let archived = byPath[planned.destinationRelativePath],
                      archived.assetID == item.assetID,
                      archived.byteSize == planned.byteSize,
                      archived.role == planned.role
                else {
                    throw ArchiveCopyError.catalogCommitFailed(planned.resourceID)
                }
            }
        }
    }

    private static func ensureCatalogSnapshot(catalogURL: URL, targetURL: URL) throws -> String {
        let fileManager = FileManager.default
        try createDirectorySafely(
            targetURL.deletingLastPathComponent(),
            under: targetURL.deletingLastPathComponent().deletingLastPathComponent()
        )
        if !fileManager.fileExists(atPath: targetURL.path) {
            _ = try CatalogSnapshotExporter.export(catalogURL: catalogURL, outputURL: targetURL)
            return try FileHasher.sha256(url: targetURL).lowercaseHexString
        }

        let candidateURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".candidate-" + UUID().uuidString + ".jsonl")
        defer { try? fileManager.removeItem(at: candidateURL) }
        _ = try CatalogSnapshotExporter.export(catalogURL: catalogURL, outputURL: candidateURL)
        let existing = try FileHasher.sha256(url: targetURL)
        let candidate = try FileHasher.sha256(url: candidateURL)
        guard existing == candidate else {
            throw ArchiveCopyError.snapshotConflict
        }
        return existing.lowercaseHexString
    }

    private static func persistPlanCopy(_ prepared: PreparedCopy) throws {
        let fileManager = FileManager.default
        try createDirectorySafely(
            prepared.archivedPlanURL.deletingLastPathComponent(),
            under: prepared.metadataRootURL
        )
        if fileManager.fileExists(atPath: prepared.archivedPlanURL.path) {
            guard try FileHasher.sha256(url: prepared.archivedPlanURL).lowercaseHexString
                    == prepared.planSHA256
            else {
                throw ArchiveCopyError.planChanged
            }
            return
        }
        let temporaryURL = prepared.archivedPlanURL.deletingLastPathComponent()
            .appendingPathComponent(".partial-" + UUID().uuidString + ".json")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: prepared.planURL, to: temporaryURL)
        guard try FileHasher.sha256(url: temporaryURL).lowercaseHexString == prepared.planSHA256 else {
            throw ArchiveCopyError.planChanged
        }
        try fileManager.moveItem(at: temporaryURL, to: prepared.archivedPlanURL)
    }

    private static func readManifestIfPresent(_ url: URL) throws -> ArchiveCopyManifest? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ArchiveCopyManifest.self, from: Data(contentsOf: url))
        } catch {
            throw ArchiveCopyError.manifestConflict
        }
    }

    private static func writeManifest(_ manifest: ArchiveCopyManifest, to url: URL) throws {
        try createDirectorySafely(
            url.deletingLastPathComponent(),
            under: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: [.atomic])
    }

    private static func report(
        prepared: PreparedCopy,
        dryRun: Bool,
        catalogCommitted: Bool,
        snapshotWritten: Bool,
        filesModified: Bool
    ) -> ArchiveCopyReport {
        var final = 0
        var staged = 0
        var required = 0
        for resource in prepared.resources {
            switch resource.state {
            case .finalVerified: final += 1
            case .stagedVerified: staged += 1
            case .copyRequired: required += 1
            }
        }
        return ArchiveCopyReport(
            schemaVersion: 1,
            planID: prepared.plan.planID,
            dryRun: dryRun,
            automaticItemCount: prepared.plan.summary.automaticItemCount,
            automaticResourceCount: prepared.plan.summary.automaticResourceCount,
            reviewItemCount: prepared.plan.summary.reviewItemCount,
            alreadyFinalResourceCount: final,
            stagedResourceCount: staged,
            copyRequiredResourceCount: required,
            catalogCommitted: catalogCommitted,
            snapshotWritten: snapshotWritten,
            manifestPath: prepared.manifestURL.path,
            snapshotPath: prepared.snapshotURL.path,
            filesModified: filesModified
        )
    }

    private static func verifyFile(
        _ url: URL,
        planned: ArchivePlannedResource,
        conflict: VerificationConflict,
        source: Bool = false
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw conflictError(conflict, resourceID: planned.resourceID, source: source)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == planned.byteSize,
              url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path,
              let expected = planned.expectedSHA256,
              try FileHasher.sha256(url: url).lowercaseHexString == expected.lowercased()
        else {
            throw conflictError(conflict, resourceID: planned.resourceID, source: source)
        }
    }

    private static func conflictError(
        _ conflict: VerificationConflict,
        resourceID: String,
        source: Bool
    ) -> ArchiveCopyError {
        if source { return .sourcePreconditionFailed(resourceID) }
        switch conflict {
        case .destination: return .destinationConflict(resourceID)
        case .staging: return .stagingConflict(resourceID)
        case .verification: return .verificationFailed(resourceID)
        }
    }

    private static func safeRelativeURL(
        rootURL: URL,
        relativePath: String,
        resourceID: String
    ) throws -> URL {
        try validateRelativePath(relativePath, resourceID: resourceID)
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard isDescendantOrEqual(url, of: rootURL) else {
            throw ArchiveCopyError.unsafePath(resourceID)
        }
        return url
    }

    private static func validateRelativePath(_ path: String, resourceID: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw ArchiveCopyError.unsafePath(resourceID)
        }
    }

    private static func validateDestinationAncestors(
        finalURL: URL,
        destinationURL: URL,
        resourceID: String
    ) throws {
        let relative = String(finalURL.path.dropFirst(destinationURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relative.split(separator: "/").map(String.init)
        var current = destinationURL
        let fileManager = FileManager.default
        for component in components.dropLast() {
            current.appendPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory) else { continue }
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw ArchiveCopyError.unsafePath(resourceID)
            }
        }
    }

    private static func validateExistingDirectoryBoundary(_ url: URL, under rootURL: URL) throws {
        guard isDescendantOrEqual(url, of: rootURL) else {
            throw ArchiveCopyError.unsafePath("archive-control")
        }
        let fileManager = FileManager.default
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        var current = URL(fileURLWithPath: NSString.path(withComponents: rootComponents), isDirectory: true)
        for component in targetComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory) else { continue }
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw ArchiveCopyError.unsafePath("archive-control")
            }
        }
    }

    private static func createDirectorySafely(_ url: URL, under rootURL: URL) throws {
        guard isDescendantOrEqual(url, of: rootURL) else {
            throw ArchiveCopyError.unsafePath("archive-control")
        }
        try validateExistingDirectoryBoundary(url, under: rootURL)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try validateExistingDirectoryBoundary(url, under: rootURL)
    }

    private static func isDescendantOrEqual(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        if childPath == parentPath { return true }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }

    private static func roundedNow() -> Date {
        Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    }
}
