import Foundation

public enum DuplicateReviewPresentationError: LocalizedError {
    case noReusableSnapshot

    public var errorDescription: String? {
        switch self {
        case .noReusableSnapshot:
            return "No reusable exact-duplicate scan snapshot is available for the currently active roots. Refresh the duplicate comparison first."
        }
    }
}

public enum DuplicateReviewPresentationRationale: String, Sendable, Codable {
    case protectedOrPreferredRoot = "preferred_root_role"
    case cleanerFilename = "cleaner_filename"
    case recognizableFilename = "recognizable_filename"
    case earlierDateAdded = "earlier_date_added"
    case matchingParentFolder = "matching_parent_folder"
    case strongerCaptureEvidence = "stronger_capture_evidence"
    case shallowerPath = "shallower_path"
    case deterministicTieBreak = "deterministic_tie_break"
    case completeLivePhotoOccurrence = "complete_live_photo_occurrence"
    case sourceSemantics = "source_semantics"
}

public struct DuplicateReviewPresentationResource: Identifiable, Sendable, Equatable {
    public let id: String
    public let rootID: String
    public let rootLabel: String
    public let relativePath: String
    public let absolutePath: String
    public let fileName: String
    public let mediaKind: MediaKind
    public let role: ResourceRole
    public let byteSize: Int64
    public let addedAt: Date?
    public let captureTime: CaptureTime?

    public var fileURL: URL { URL(fileURLWithPath: absolutePath) }
}

public struct DuplicateReviewPresentationItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: ReconciliationItemKind
    public let decision: ReconciliationDecision
    public let reason: ReconciliationReason
    public let rationale: DuplicateReviewPresentationRationale
    public let preferredResources: [DuplicateReviewPresentationResource]
    public let candidateResources: [DuplicateReviewPresentationResource]

    public var allResources: [DuplicateReviewPresentationResource] {
        preferredResources + candidateResources
    }
}

public struct DuplicateReviewPresentation: Sendable, Equatable {
    public let sessionID: String
    public let policy: String
    public let scopeRootLabels: [String]
    public let items: [DuplicateReviewPresentationItem]

    public var standaloneItemCount: Int {
        items.filter { $0.kind == .standaloneExactGroup }.count
    }

    public var livePhotoItemCount: Int {
        items.filter { $0.kind == .livePhotoAsset }.count
    }

    public var candidateResourceCount: Int {
        items.reduce(0) { $0 + $1.candidateResources.count }
    }
}

public enum DuplicateReviewPresentationBuilder {
    public static func latest(
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> DuplicateReviewPresentation {
        let scanner = try ArchiveScanner(catalogURL: catalogURL)
        guard let report = try scanner.latestReusableDuplicateReviewScanReport() else {
            throw DuplicateReviewPresentationError.noReusableSnapshot
        }
        let plan = ReconciliationPlanner.makePlan(from: report)
        return makePresentation(report: report, plan: plan)
    }

    public static func makePresentation(
        report: ScanReport,
        plan: ReconciliationPlan
    ) -> DuplicateReviewPresentation {
        let rootsByID = Dictionary(uniqueKeysWithValues: report.roots.map { ($0.rootID, $0) })
        let resourcesByKey = Dictionary(uniqueKeysWithValues: report.resources.map {
            (CanonicalResourceKey(rootID: $0.rootID, relativePath: $0.relativePath), $0)
        })

        let items = plan.items
            .filter { $0.decision == .automaticRedundant }
            .map { item in
                DuplicateReviewPresentationItem(
                    id: item.itemID,
                    kind: item.kind,
                    decision: item.decision,
                    reason: item.reason,
                    rationale: rationale(
                        for: item,
                        rootsByID: rootsByID,
                        resourcesByKey: resourcesByKey
                    ),
                    preferredResources: item.preferredResources.compactMap {
                        presentationResource(
                            reference: $0,
                            rootsByID: rootsByID,
                            resourcesByKey: resourcesByKey
                        )
                    },
                    candidateResources: item.candidateResources.compactMap {
                        presentationResource(
                            reference: $0,
                            rootsByID: rootsByID,
                            resourcesByKey: resourcesByKey
                        )
                    }
                )
            }

        return DuplicateReviewPresentation(
            sessionID: report.sessionID,
            policy: plan.policy,
            scopeRootLabels: report.roots.map(\.label).sorted(),
            items: items
        )
    }

    private static func presentationResource(
        reference: ResourceReference,
        rootsByID: [String: RootScanReport],
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport]
    ) -> DuplicateReviewPresentationResource? {
        guard let root = rootsByID[reference.rootID] else { return nil }
        let key = CanonicalResourceKey(rootID: reference.rootID, relativePath: reference.relativePath)
        let scanned = resourcesByKey[key]
        let url = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
            .appendingPathComponent(reference.relativePath)
            .standardizedFileURL
        return DuplicateReviewPresentationResource(
            id: scanned?.resourceID ?? "\(reference.rootID):\(reference.relativePath)",
            rootID: reference.rootID,
            rootLabel: reference.rootLabel,
            relativePath: reference.relativePath,
            absolutePath: url.path,
            fileName: scanned?.fileName ?? url.lastPathComponent,
            mediaKind: scanned?.mediaKind ?? inferredMediaKind(for: reference),
            role: reference.role,
            byteSize: reference.byteSize,
            addedAt: scanned?.addedAt,
            captureTime: scanned?.captureTime
        )
    }

    private static func inferredMediaKind(for reference: ResourceReference) -> MediaKind {
        switch reference.role {
        case .photo, .standaloneImage:
            return .image
        case .pairedVideo, .standaloneVideo:
            return .video
        case .sidecar:
            return .sidecar
        }
    }

    private static func rationale(
        for item: ReconciliationPlanItem,
        rootsByID: [String: RootScanReport],
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport]
    ) -> DuplicateReviewPresentationRationale {
        switch item.reason {
        case .canonicalLocalLivePhotoOccurrence,
                .livePhotoCanonicalCoverage,
                .livePhotoIncompleteOccurrenceExactCoverage:
            return .completeLivePhotoOccurrence
        case .preferredNonTakeoutExactCopy,
                .takeoutSourceFolderSemanticsCaptured,
                .takeoutCollectionSemanticsPending:
            return .sourceSemantics
        case .noCompletePreferredLivePhoto,
                .uncoveredLivePhotoVariant:
            return .completeLivePhotoOccurrence
        case .canonicalExactCopy:
            break
        }

        guard item.preferredResources.count == 1,
              let preferred = item.preferredResources.first,
              let candidate = item.candidateResources.first
        else {
            return .deterministicTieBreak
        }

        switch CanonicalKeeperPolicy.preferenceRationale(
            preferred: preferred,
            candidate: candidate,
            rootsByID: rootsByID,
            resourcesByKey: resourcesByKey
        ) {
        case .protectedOrPreferredRoot: return .protectedOrPreferredRoot
        case .cleanerFilename: return .cleanerFilename
        case .recognizableFilename: return .recognizableFilename
        case .earlierDateAdded: return .earlierDateAdded
        case .matchingParentFolder: return .matchingParentFolder
        case .strongerCaptureEvidence: return .strongerCaptureEvidence
        case .shallowerPath: return .shallowerPath
        case .deterministicTieBreak: return .deterministicTieBreak
        }
    }
}
