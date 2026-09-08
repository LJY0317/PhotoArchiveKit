import Darwin
import CryptoKit
import Foundation
import ImageIO

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

public struct DuplicateReviewResourceDetails: Sendable, Equatable {
    public let resourceID: String
    public let fileExtension: String
    public let catalogModifiedAt: Date?
    public let exactSHA256Hex: String?
    public let liveIdentifierFingerprintHex: String?
    public let metadataProbeFailed: Bool
    public let lastSeenSessionID: String
    public let originalFileName: String?
    public let originalNameFirstSeenSessionID: String?
    public let catalogFileSystemIdentifier: String?
    public let liveTimedMetadataStatus: LivePhotoTimedMetadataStatus?
    public let metadataProbeVersion: Int?
    public let locationHistoryCount: Int
    public let firstSeenAt: Date?
    public let lastSeenAt: Date?
}

public struct DuplicateReviewExtendedAttribute: Sendable, Equatable {
    public let name: String
    public let byteCount: Int
    public let valueSHA256Hex: String?
}

public struct DuplicateReviewFileSystemFacts: Sendable, Equatable {
    public let exists: Bool
    public let fileType: String?
    public let typeIdentifier: String?
    public let currentByteSize: Int64?
    public let allocatedByteSize: Int64?
    public let totalAllocatedByteSize: Int64?
    public let creationDate: Date?
    public let modificationDate: Date?
    public let fileSystemIdentifier: String?
    public let ownerAccountName: String?
    public let groupOwnerAccountName: String?
    public let posixPermissions: Int?
    public let isImmutable: Bool?
    public let isAppendOnly: Bool?
    public let isHidden: Bool?
    public let isReadable: Bool?
    public let isWritable: Bool?
    public let isExecutable: Bool?
    public let extendedAttributes: [DuplicateReviewExtendedAttribute]
}

public struct DuplicateReviewImageCaptureDateEvidence: Sendable, Equatable {
    public let exifDateTimeOriginal: String?
    public let exifDateTimeDigitized: String?
    public let exifOffsetTimeOriginal: String?
    public let exifOffsetTimeDigitized: String?
    public let exifSubsecTimeOriginal: String?
    public let exifSubsecTimeDigitized: String?
    public let tiffDateTime: String?

    public init(
        exifDateTimeOriginal: String?,
        exifDateTimeDigitized: String?,
        exifOffsetTimeOriginal: String?,
        exifOffsetTimeDigitized: String?,
        exifSubsecTimeOriginal: String?,
        exifSubsecTimeDigitized: String?,
        tiffDateTime: String?
    ) {
        self.exifDateTimeOriginal = exifDateTimeOriginal
        self.exifDateTimeDigitized = exifDateTimeDigitized
        self.exifOffsetTimeOriginal = exifOffsetTimeOriginal
        self.exifOffsetTimeDigitized = exifOffsetTimeDigitized
        self.exifSubsecTimeOriginal = exifSubsecTimeOriginal
        self.exifSubsecTimeDigitized = exifSubsecTimeDigitized
        self.tiffDateTime = tiffDateTime
    }
}

public struct DuplicateReviewPresentationResource: Identifiable, Sendable, Equatable {
    public let id: String
    public let assetID: String?
    public let rootID: String
    public let rootLabel: String
    public let rootKind: SourceRootKind
    public let rootUsageRole: RootUsageRole
    public let rootProvenance: SourceProvenance
    public let stableMarkerKey: String?
    public let relativePath: String
    public let absolutePath: String
    public let fileName: String
    public let fileExtension: String
    public let mediaKind: MediaKind
    public let role: ResourceRole
    public let byteSize: Int64
    public let addedAt: Date?
    public let captureTime: CaptureTime?
    public let details: DuplicateReviewResourceDetails?
    public let fileSystemFacts: DuplicateReviewFileSystemFacts
    public let imageCaptureDateEvidence: DuplicateReviewImageCaptureDateEvidence?

    public var fileURL: URL { URL(fileURLWithPath: absolutePath) }
}

public struct DuplicateReviewPresentationCopy: Identifiable, Sendable, Equatable {
    public let id: String
    public let isKeeper: Bool
    public let resources: [DuplicateReviewPresentationResource]

    public init(
        id: String,
        isKeeper: Bool,
        resources: [DuplicateReviewPresentationResource]
    ) {
        self.id = id
        self.isKeeper = isKeeper
        self.resources = resources
    }

    public var primaryResource: DuplicateReviewPresentationResource? {
        resources.first(where: { $0.role == .photo || $0.role == .standaloneImage })
            ?? resources.first
    }

    public var totalByteSize: Int64 {
        resources.reduce(0) { $0 + $1.byteSize }
    }

    public var hasLivePhotoStill: Bool {
        resources.contains { $0.role == .photo }
    }

    public var hasPairedVideo: Bool {
        resources.contains { $0.role == .pairedVideo }
    }

    public var isCompleteLivePhotoOccurrence: Bool {
        hasLivePhotoStill && hasPairedVideo
    }
}

public struct DuplicateReviewPresentationItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let subjectID: String
    public let kind: ReconciliationItemKind
    public let decision: ReconciliationDecision
    public let reason: ReconciliationReason
    public let rationale: DuplicateReviewPresentationRationale
    public let preferredResources: [DuplicateReviewPresentationResource]
    public let candidateResources: [DuplicateReviewPresentationResource]
    public let copies: [DuplicateReviewPresentationCopy]

    public var allResources: [DuplicateReviewPresentationResource] {
        preferredResources + candidateResources
    }
}

public struct DuplicateReviewScopeRoot: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct DuplicateReviewPresentation: Sendable, Equatable {
    public let sessionID: String
    public let policy: String
    public let scopeRoots: [DuplicateReviewScopeRoot]
    public let items: [DuplicateReviewPresentationItem]

    public var scopeRootLabels: [String] {
        scopeRoots.map(\.label)
    }

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
        let resourceIDs = Set(plan.items.flatMap { item in
            (item.preferredResources + item.candidateResources).compactMap { reference in
                report.resources.first(where: {
                    $0.rootID == reference.rootID && $0.relativePath == reference.relativePath
                })?.resourceID
            }
        })
        let details = try scanner.duplicateReviewResourceDetails(resourceIDs: Array(resourceIDs))
        return makePresentation(report: report, plan: plan, detailsByResourceID: details)
    }

    public static func makePresentation(
        report: ScanReport,
        plan: ReconciliationPlan,
        detailsByResourceID: [String: DuplicateReviewResourceDetails] = [:],
        fileManager: FileManager = .default
    ) -> DuplicateReviewPresentation {
        let rootsByID = Dictionary(uniqueKeysWithValues: report.roots.map { ($0.rootID, $0) })
        let resourcesByKey = Dictionary(uniqueKeysWithValues: report.resources.map {
            (CanonicalResourceKey(rootID: $0.rootID, relativePath: $0.relativePath), $0)
        })

        let livePhotosByID = Dictionary(uniqueKeysWithValues: report.livePhotos.map { ($0.assetID, $0) })

        let items = plan.items
            .filter { $0.decision == .automaticRedundant }
            .map { item in
                let preferred = item.preferredResources.compactMap {
                    presentationResource(
                        reference: $0,
                        rootsByID: rootsByID,
                        resourcesByKey: resourcesByKey,
                        detailsByResourceID: detailsByResourceID,
                        fileManager: fileManager
                    )
                }
                let candidates = item.candidateResources.compactMap {
                    presentationResource(
                        reference: $0,
                        rootsByID: rootsByID,
                        resourcesByKey: resourcesByKey,
                        detailsByResourceID: detailsByResourceID,
                        fileManager: fileManager
                    )
                }
                return DuplicateReviewPresentationItem(
                    id: item.itemID,
                    subjectID: item.subjectID,
                    kind: item.kind,
                    decision: item.decision,
                    reason: item.reason,
                    rationale: rationale(
                        for: item,
                        rootsByID: rootsByID,
                        resourcesByKey: resourcesByKey
                    ),
                    preferredResources: preferred,
                    candidateResources: candidates,
                    copies: presentationCopies(
                        item: item,
                        preferred: preferred,
                        candidates: candidates,
                        livePhoto: livePhotosByID[item.subjectID]
                    )
                )
            }

        return DuplicateReviewPresentation(
            sessionID: report.sessionID,
            policy: plan.policy,
            scopeRoots: report.roots
                .map { DuplicateReviewScopeRoot(id: $0.rootID, label: $0.label) }
                .sorted { $0.label < $1.label },
            items: items
        )
    }

    private static func presentationResource(
        reference: ResourceReference,
        rootsByID: [String: RootScanReport],
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport],
        detailsByResourceID: [String: DuplicateReviewResourceDetails],
        fileManager: FileManager
    ) -> DuplicateReviewPresentationResource? {
        guard let root = rootsByID[reference.rootID] else { return nil }
        let key = CanonicalResourceKey(rootID: reference.rootID, relativePath: reference.relativePath)
        let scanned = resourcesByKey[key]
        let url = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
            .appendingPathComponent(reference.relativePath)
            .standardizedFileURL
        return DuplicateReviewPresentationResource(
            id: scanned?.resourceID ?? "\(reference.rootID):\(reference.relativePath)",
            assetID: scanned?.assetID,
            rootID: reference.rootID,
            rootLabel: reference.rootLabel,
            rootKind: root.kind,
            rootUsageRole: root.usageRole,
            rootProvenance: root.provenance,
            stableMarkerKey: root.stableMarkerKey,
            relativePath: reference.relativePath,
            absolutePath: url.path,
            fileName: scanned?.fileName ?? url.lastPathComponent,
            fileExtension: detailsByResourceID[scanned?.resourceID ?? ""]?.fileExtension
                ?? url.pathExtension,
            mediaKind: scanned?.mediaKind ?? inferredMediaKind(for: reference),
            role: reference.role,
            byteSize: reference.byteSize,
            addedAt: scanned?.addedAt,
            captureTime: scanned?.captureTime,
            details: scanned.flatMap { detailsByResourceID[$0.resourceID] },
            fileSystemFacts: fileSystemFacts(at: url, fileManager: fileManager),
            imageCaptureDateEvidence: imageCaptureDateEvidence(at: url)
        )
    }

    private static func imageCaptureDateEvidence(
        at url: URL
    ) -> DuplicateReviewImageCaptureDateEvidence? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
        else {
            return nil
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary
        let evidence = DuplicateReviewImageCaptureDateEvidence(
            exifDateTimeOriginal: exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exifDateTimeDigitized: exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            exifOffsetTimeOriginal: exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String,
            exifOffsetTimeDigitized: exif?[kCGImagePropertyExifOffsetTimeDigitized] as? String,
            exifSubsecTimeOriginal: exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String,
            exifSubsecTimeDigitized: exif?[kCGImagePropertyExifSubsecTimeDigitized] as? String,
            tiffDateTime: tiff?[kCGImagePropertyTIFFDateTime] as? String
        )
        guard evidence.exifDateTimeOriginal != nil
                || evidence.exifDateTimeDigitized != nil
                || evidence.tiffDateTime != nil
                || evidence.exifOffsetTimeOriginal != nil
                || evidence.exifOffsetTimeDigitized != nil
        else {
            return nil
        }
        return evidence
    }

    private static func presentationCopies(
        item: ReconciliationPlanItem,
        preferred: [DuplicateReviewPresentationResource],
        candidates: [DuplicateReviewPresentationResource],
        livePhoto: LivePhotoAssetReport?
    ) -> [DuplicateReviewPresentationCopy] {
        guard item.kind == .livePhotoAsset, let livePhoto else {
            return preferred.map {
                DuplicateReviewPresentationCopy(id: "keeper:\($0.id)", isKeeper: true, resources: [$0])
            } + candidates.map {
                DuplicateReviewPresentationCopy(id: "candidate:\($0.id)", isKeeper: false, resources: [$0])
            }
        }

        let preferredIDs = Set(preferred.map(\.id))
        let resourcesByKey = Dictionary(uniqueKeysWithValues: (preferred + candidates).map {
            ("\($0.rootID):\($0.relativePath)", $0)
        })
        var usedIDs = Set<String>()
        var copies: [DuplicateReviewPresentationCopy] = []

        for occurrence in livePhoto.occurrences {
            let resources = occurrence.resources.compactMap {
                resourcesByKey["\($0.rootID):\($0.relativePath)"]
            }
            guard !resources.isEmpty else { continue }
            usedIDs.formUnion(resources.map(\.id))
            let isKeeper = resources.contains { preferredIDs.contains($0.id) }
            let stableID = resources.map(\.id).sorted().joined(separator: "|")
            copies.append(DuplicateReviewPresentationCopy(
                id: "occurrence:\(stableID)",
                isKeeper: isKeeper,
                resources: resources.sorted(by: resourcePresentationSort)
            ))
        }

        for resource in preferred where !usedIDs.contains(resource.id) {
            copies.append(DuplicateReviewPresentationCopy(
                id: "keeper:\(resource.id)",
                isKeeper: true,
                resources: [resource]
            ))
        }
        for resource in candidates where !usedIDs.contains(resource.id) {
            copies.append(DuplicateReviewPresentationCopy(
                id: "candidate:\(resource.id)",
                isKeeper: false,
                resources: [resource]
            ))
        }

        return copies.sorted {
            if $0.isKeeper != $1.isKeeper { return $0.isKeeper && !$1.isKeeper }
            return ($0.primaryResource?.absolutePath ?? $0.id) < ($1.primaryResource?.absolutePath ?? $1.id)
        }
    }

    private static func resourcePresentationSort(
        _ lhs: DuplicateReviewPresentationResource,
        _ rhs: DuplicateReviewPresentationResource
    ) -> Bool {
        let rank: (ResourceRole) -> Int = { role in
            switch role {
            case .photo, .standaloneImage: return 0
            case .pairedVideo, .standaloneVideo: return 1
            case .sidecar: return 2
            }
        }
        if rank(lhs.role) != rank(rhs.role) { return rank(lhs.role) < rank(rhs.role) }
        return lhs.absolutePath < rhs.absolutePath
    }

    private static func fileSystemFacts(
        at url: URL,
        fileManager: FileManager
    ) -> DuplicateReviewFileSystemFacts {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        else {
            return DuplicateReviewFileSystemFacts(
                exists: false,
                fileType: nil,
                typeIdentifier: nil,
                currentByteSize: nil,
                allocatedByteSize: nil,
                totalAllocatedByteSize: nil,
                creationDate: nil,
                modificationDate: nil,
                fileSystemIdentifier: nil,
                ownerAccountName: nil,
                groupOwnerAccountName: nil,
                posixPermissions: nil,
                isImmutable: nil,
                isAppendOnly: nil,
                isHidden: nil,
                isReadable: nil,
                isWritable: nil,
                isExecutable: nil,
                extendedAttributes: []
            )
        }

        let resourceValues = try? url.resourceValues(forKeys: [
            .typeIdentifierKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .isHiddenKey,
            .isReadableKey,
            .isWritableKey,
            .isExecutableKey
        ])

        return DuplicateReviewFileSystemFacts(
            exists: true,
            fileType: (attributes[.type] as? FileAttributeType)?.rawValue,
            typeIdentifier: resourceValues?.typeIdentifier,
            currentByteSize: (attributes[.size] as? NSNumber)?.int64Value,
            allocatedByteSize: resourceValues?.fileAllocatedSize.map(Int64.init),
            totalAllocatedByteSize: resourceValues?.totalFileAllocatedSize.map(Int64.init),
            creationDate: attributes[.creationDate] as? Date,
            modificationDate: attributes[.modificationDate] as? Date,
            fileSystemIdentifier: (attributes[.systemFileNumber] as? NSNumber).map { String($0.uint64Value) },
            ownerAccountName: attributes[.ownerAccountName] as? String,
            groupOwnerAccountName: attributes[.groupOwnerAccountName] as? String,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue,
            isImmutable: attributes[.immutable] as? Bool,
            isAppendOnly: attributes[.appendOnly] as? Bool,
            isHidden: resourceValues?.isHidden,
            isReadable: resourceValues?.isReadable,
            isWritable: resourceValues?.isWritable,
            isExecutable: resourceValues?.isExecutable,
            extendedAttributes: extendedAttributeFacts(at: url)
        )
    }

    private static func extendedAttributeFacts(at url: URL) -> [DuplicateReviewExtendedAttribute] {
        url.withUnsafeFileSystemRepresentation { path -> [DuplicateReviewExtendedAttribute] in
            guard let path else { return [] }
            let nameBufferSize = listxattr(path, nil, 0, 0)
            guard nameBufferSize > 0 else { return [] }
            var nameBuffer = [CChar](repeating: 0, count: nameBufferSize)
            let filled = listxattr(path, &nameBuffer, nameBuffer.count, 0)
            guard filled > 0 else { return [] }

            var output: [DuplicateReviewExtendedAttribute] = []
            var start = 0
            for index in 0..<filled where nameBuffer[index] == 0 {
                guard index > start else {
                    start = index + 1
                    continue
                }
                let name = String(cString: Array(nameBuffer[start...index]))
                let byteCount = name.withCString { getxattr(path, $0, nil, 0, 0, 0) }
                let digest: String?
                if byteCount > 0 {
                    var bytes = [UInt8](repeating: 0, count: byteCount)
                    let read = name.withCString {
                        getxattr(path, $0, &bytes, bytes.count, 0, 0)
                    }
                    if read >= 0 {
                        digest = SHA256.hash(data: Data(bytes.prefix(read)))
                            .map { String(format: "%02x", $0) }
                            .joined()
                    } else {
                        digest = nil
                    }
                } else if byteCount == 0 {
                    digest = SHA256.hash(data: Data())
                        .map { String(format: "%02x", $0) }
                        .joined()
                } else {
                    digest = nil
                }
                output.append(DuplicateReviewExtendedAttribute(
                    name: name,
                    byteCount: max(0, byteCount),
                    valueSHA256Hex: digest
                ))
                start = index + 1
            }
            return output.sorted { $0.name < $1.name }
        }
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
