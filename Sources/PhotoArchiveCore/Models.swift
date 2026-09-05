import Foundation

public enum SourceRootKind: String, Codable, CaseIterable, Sendable {
    case inbox
    case archive
    case importSource = "import_source"
    case reference
}

public enum SourceProvenance: String, Codable, CaseIterable, Sendable {
    case unknown
    case localLibrary = "local_library"
    case appleDirect = "apple_direct"
    case googleTakeout = "google_takeout"
    case googleWeb = "google_web"
    case googleIOSShare = "google_ios_share"
}

public struct ScanRoot: Sendable {
    public let url: URL
    public let label: String
    public let kind: SourceRootKind
    public let provenance: SourceProvenance

    public init(
        url: URL,
        label: String? = nil,
        kind: SourceRootKind = .inbox,
        provenance: SourceProvenance = .unknown
    ) {
        self.url = url.standardizedFileURL
        self.label = label ?? url.lastPathComponent
        self.kind = kind
        self.provenance = provenance
    }
}

public enum ExactDuplicateEngine: String, Codable, CaseIterable, Sendable {
    case automatic
    case native
    case czkawka
}

public enum ScanProgressStage: String, Codable, Sendable {
    case enumerating
    case metadata
    case hashingDuplicates = "hashing_duplicates"
    case hashingIntegrity = "hashing_integrity"
    case cataloging
    case finalizing
}

public struct ScanProgress: Sendable, Equatable {
    public let stage: ScanProgressStage
    public let completedUnitCount: Int
    public let totalUnitCount: Int?

    public init(
        stage: ScanProgressStage,
        completedUnitCount: Int,
        totalUnitCount: Int? = nil
    ) {
        self.stage = stage
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
    }
}

public typealias ScanProgressHandler = @Sendable (ScanProgress) -> Void

public struct ScanOptions: Sendable {
    public var computeExactDuplicates: Bool
    public var computeArchiveIntegrityPreconditions: Bool
    public var reuseExactHashCache: Bool
    public var exactDuplicateEngine: ExactDuplicateEngine
    public var eventGap: TimeInterval
    public var maxConcurrentProbes: Int
    public var progressHandler: ScanProgressHandler?

    public init(
        computeExactDuplicates: Bool = true,
        computeArchiveIntegrityPreconditions: Bool = false,
        reuseExactHashCache: Bool = true,
        exactDuplicateEngine: ExactDuplicateEngine = .automatic,
        eventGap: TimeInterval = 6 * 60 * 60,
        maxConcurrentProbes: Int = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8),
        progressHandler: ScanProgressHandler? = nil
    ) {
        self.computeExactDuplicates = computeExactDuplicates
        self.computeArchiveIntegrityPreconditions = computeArchiveIntegrityPreconditions
        self.reuseExactHashCache = reuseExactHashCache
        self.exactDuplicateEngine = exactDuplicateEngine
        self.eventGap = eventGap
        self.maxConcurrentProbes = max(1, maxConcurrentProbes)
        self.progressHandler = progressHandler
    }
}

public enum MediaKind: String, Codable, Sendable {
    case image
    case video
    case sidecar
}

public enum ResourceRole: String, Codable, Sendable {
    case photo
    case pairedVideo = "paired_video"
    case standaloneImage = "standalone_image"
    case standaloneVideo = "standalone_video"
    case sidecar
}

public enum LivePhotoOccurrenceStatus: String, Codable, Sendable {
    case complete
    case stillOnly = "still_only"
    case videoOnly = "video_only"
    case multipleStills = "multiple_stills"
    case multipleVideos = "multiple_videos"
    case multipleVariants = "multiple_variants"
    case stillImageTimeMissing = "still_image_time_missing"
    case stillImageTimeInvalid = "still_image_time_invalid"
    case stillImageTimeUnreadable = "still_image_time_unreadable"
}

public enum LivePhotoTimedMetadataStatus: String, Codable, Sendable {
    case notApplicable = "not_applicable"
    case valid
    case missing
    case invalid
    case unreadable
}

public enum CaptureTimeSource: String, Codable, Sendable {
    case exifDateTimeOriginal = "exif_datetime_original"
    case quickTimeCreationDate = "quicktime_creation_date"
    case googleTakeoutPhotoTakenTime = "google_takeout_photo_taken_time"
    case fileCreationDate = "file_creation_date"
    case unknown
}

public enum CaptureTimeConfidence: String, Codable, Sendable {
    case trusted
    case providerSidecar = "provider_sidecar"
    case incompleteTimezone = "incomplete_timezone"
    case fallback
    case unknown
}

public struct CaptureTime: Codable, Sendable, Equatable {
    public let localTimestamp: String?
    public let utcOffset: String?
    public let instant: Date?
    public let source: CaptureTimeSource
    public let confidence: CaptureTimeConfidence

    public init(
        localTimestamp: String?,
        utcOffset: String?,
        instant: Date?,
        source: CaptureTimeSource,
        confidence: CaptureTimeConfidence
    ) {
        self.localTimestamp = localTimestamp
        self.utcOffset = utcOffset
        self.instant = instant
        self.source = source
        self.confidence = confidence
    }
}

public struct ResourceReference: Codable, Sendable, Equatable {
    public let rootID: String
    public let rootLabel: String
    public let relativePath: String
    public let role: ResourceRole
    public let byteSize: Int64

    public init(
        rootID: String,
        rootLabel: String,
        relativePath: String,
        role: ResourceRole,
        byteSize: Int64
    ) {
        self.rootID = rootID
        self.rootLabel = rootLabel
        self.relativePath = relativePath
        self.role = role
        self.byteSize = byteSize
    }
}

public struct LivePhotoOccurrenceReport: Codable, Sendable, Equatable {
    public let rootID: String
    public let rootLabel: String
    public let status: LivePhotoOccurrenceStatus
    public let stillCount: Int
    public let videoCount: Int
    public let resources: [ResourceReference]

    public init(
        rootID: String,
        rootLabel: String,
        status: LivePhotoOccurrenceStatus,
        stillCount: Int,
        videoCount: Int,
        resources: [ResourceReference]
    ) {
        self.rootID = rootID
        self.rootLabel = rootLabel
        self.status = status
        self.stillCount = stillCount
        self.videoCount = videoCount
        self.resources = resources
    }
}

public struct LivePhotoAssetReport: Codable, Sendable, Equatable {
    public let assetID: String
    public let occurrenceCount: Int
    public let stillCopyCount: Int
    public let videoCopyCount: Int
    public let occurrences: [LivePhotoOccurrenceReport]

    public init(
        assetID: String,
        occurrenceCount: Int,
        stillCopyCount: Int,
        videoCopyCount: Int,
        occurrences: [LivePhotoOccurrenceReport]
    ) {
        self.assetID = assetID
        self.occurrenceCount = occurrenceCount
        self.stillCopyCount = stillCopyCount
        self.videoCopyCount = videoCopyCount
        self.occurrences = occurrences
    }
}

public struct ScannedResourceReport: Codable, Sendable, Equatable {
    public let resourceID: String
    public let assetID: String?
    public let rootID: String
    public let rootLabel: String
    public let relativePath: String
    public let fileName: String
    public let mediaKind: MediaKind
    public let role: ResourceRole
    public let byteSize: Int64
    public let captureTime: CaptureTime?

    public init(
        resourceID: String,
        assetID: String?,
        rootID: String,
        rootLabel: String,
        relativePath: String,
        fileName: String,
        mediaKind: MediaKind,
        role: ResourceRole,
        byteSize: Int64,
        captureTime: CaptureTime?
    ) {
        self.resourceID = resourceID
        self.assetID = assetID
        self.rootID = rootID
        self.rootLabel = rootLabel
        self.relativePath = relativePath
        self.fileName = fileName
        self.mediaKind = mediaKind
        self.role = role
        self.byteSize = byteSize
        self.captureTime = captureTime
    }
}

public struct ExactDuplicateGroupReport: Codable, Sendable, Equatable {
    public let groupID: String
    public let byteSize: Int64
    public let members: [ResourceReference]

    public init(groupID: String, byteSize: Int64, members: [ResourceReference]) {
        self.groupID = groupID
        self.byteSize = byteSize
        self.members = members
    }
}

public struct EventSuggestionReport: Codable, Sendable, Equatable {
    public let eventID: String
    public let suggestedFolderName: String
    public let start: Date
    public let end: Date
    public let assetIDs: [String]

    public init(
        eventID: String,
        suggestedFolderName: String,
        start: Date,
        end: Date,
        assetIDs: [String]
    ) {
        self.eventID = eventID
        self.suggestedFolderName = suggestedFolderName
        self.start = start
        self.end = end
        self.assetIDs = assetIDs
    }
}

public struct RootScanReport: Codable, Sendable, Equatable {
    public let rootID: String
    public let label: String
    public let kind: SourceRootKind
    public let provenance: SourceProvenance
    public let canonicalPath: String
    public let stableMarkerKey: String?
    public let mediaFileCount: Int
    public let completeLivePhotos: Int
    public let stillOnlyLiveResources: Int
    public let videoOnlyLiveResources: Int
    public let standaloneImages: Int
    public let standaloneVideos: Int
    public let sidecars: Int
    public let metadataProbeFailures: Int
    public let sourceFolderSemanticsCaptured: Bool

    public init(
        rootID: String,
        label: String,
        kind: SourceRootKind,
        provenance: SourceProvenance,
        canonicalPath: String,
        stableMarkerKey: String? = nil,
        mediaFileCount: Int,
        completeLivePhotos: Int,
        stillOnlyLiveResources: Int,
        videoOnlyLiveResources: Int,
        standaloneImages: Int,
        standaloneVideos: Int,
        sidecars: Int,
        metadataProbeFailures: Int,
        sourceFolderSemanticsCaptured: Bool = false
    ) {
        self.rootID = rootID
        self.label = label
        self.kind = kind
        self.provenance = provenance
        self.canonicalPath = canonicalPath
        self.stableMarkerKey = stableMarkerKey
        self.mediaFileCount = mediaFileCount
        self.completeLivePhotos = completeLivePhotos
        self.stillOnlyLiveResources = stillOnlyLiveResources
        self.videoOnlyLiveResources = videoOnlyLiveResources
        self.standaloneImages = standaloneImages
        self.standaloneVideos = standaloneVideos
        self.sidecars = sidecars
        self.metadataProbeFailures = metadataProbeFailures
        self.sourceFolderSemanticsCaptured = sourceFolderSemanticsCaptured
    }
}

public struct ScanWarning: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let rootID: String?
    public let relativePath: String?

    public init(code: String, message: String, rootID: String? = nil, relativePath: String? = nil) {
        self.code = code
        self.message = message
        self.rootID = rootID
        self.relativePath = relativePath
    }
}

public struct ScanSummary: Codable, Sendable, Equatable {
    public let rootCount: Int
    public let resourceCount: Int
    public let logicalAssetCount: Int
    public let livePhotoAssetCount: Int
    public let exactDuplicateGroupCount: Int
    public let eventSuggestionCount: Int
    public let warningCount: Int
    public let reusedExactHashCount: Int

    public init(
        rootCount: Int,
        resourceCount: Int,
        logicalAssetCount: Int,
        livePhotoAssetCount: Int,
        exactDuplicateGroupCount: Int,
        eventSuggestionCount: Int,
        warningCount: Int,
        reusedExactHashCount: Int = 0
    ) {
        self.rootCount = rootCount
        self.resourceCount = resourceCount
        self.logicalAssetCount = logicalAssetCount
        self.livePhotoAssetCount = livePhotoAssetCount
        self.exactDuplicateGroupCount = exactDuplicateGroupCount
        self.eventSuggestionCount = eventSuggestionCount
        self.warningCount = warningCount
        self.reusedExactHashCount = reusedExactHashCount
    }
}

public struct AgentSafeRootReport: Codable, Sendable, Equatable {
    public let rootID: String
    public let kind: SourceRootKind
    public let provenance: SourceProvenance
    public let mediaFileCount: Int
    public let completeLivePhotos: Int
    public let stillOnlyLiveResources: Int
    public let videoOnlyLiveResources: Int
    public let standaloneImages: Int
    public let standaloneVideos: Int
    public let sidecars: Int
    public let metadataProbeFailures: Int
    public let sourceFolderSemanticsCaptured: Bool
}

public struct AgentSafeLivePhotoOccurrenceReport: Codable, Sendable, Equatable {
    public let rootID: String
    public let status: LivePhotoOccurrenceStatus
    public let stillCount: Int
    public let videoCount: Int
}

public struct AgentSafeLivePhotoAssetReport: Codable, Sendable, Equatable {
    public let assetID: String
    public let occurrenceCount: Int
    public let stillCopyCount: Int
    public let videoCopyCount: Int
    public let occurrences: [AgentSafeLivePhotoOccurrenceReport]
}

public struct AgentSafeExactDuplicateGroupReport: Codable, Sendable, Equatable {
    public let groupID: String
    public let memberCount: Int
    public let rootIDs: [String]
    public let roles: [ResourceRole]
}

public struct AgentSafeEventSuggestionReport: Codable, Sendable, Equatable {
    public let eventID: String
    public let assetIDs: [String]
}

public struct AgentSafeWarning: Codable, Sendable, Equatable {
    public let code: String
    public let rootID: String?
}

public struct AgentSafeScanReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let sessionID: String
    public let summary: ScanSummary
    public let roots: [AgentSafeRootReport]
    public let livePhotos: [AgentSafeLivePhotoAssetReport]
    public let exactDuplicateGroups: [AgentSafeExactDuplicateGroupReport]
    public let eventSuggestions: [AgentSafeEventSuggestionReport]
    public let warnings: [AgentSafeWarning]
    public let filesModified: Bool

    public init(report: ScanReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        sessionID = report.sessionID
        summary = report.summary
        roots = report.roots.map { root in
            AgentSafeRootReport(
                rootID: root.rootID,
                kind: root.kind,
                provenance: root.provenance,
                mediaFileCount: root.mediaFileCount,
                completeLivePhotos: root.completeLivePhotos,
                stillOnlyLiveResources: root.stillOnlyLiveResources,
                videoOnlyLiveResources: root.videoOnlyLiveResources,
                standaloneImages: root.standaloneImages,
                standaloneVideos: root.standaloneVideos,
                sidecars: root.sidecars,
                metadataProbeFailures: root.metadataProbeFailures,
                sourceFolderSemanticsCaptured: root.sourceFolderSemanticsCaptured
            )
        }
        livePhotos = report.livePhotos.map { asset in
            AgentSafeLivePhotoAssetReport(
                assetID: asset.assetID,
                occurrenceCount: asset.occurrenceCount,
                stillCopyCount: asset.stillCopyCount,
                videoCopyCount: asset.videoCopyCount,
                occurrences: asset.occurrences.map { occurrence in
                    AgentSafeLivePhotoOccurrenceReport(
                        rootID: occurrence.rootID,
                        status: occurrence.status,
                        stillCount: occurrence.stillCount,
                        videoCount: occurrence.videoCount
                    )
                }
            )
        }
        exactDuplicateGroups = report.exactDuplicateGroups.map { group in
            AgentSafeExactDuplicateGroupReport(
                groupID: group.groupID,
                memberCount: group.members.count,
                rootIDs: Array(Set(group.members.map(\.rootID))).sorted(),
                roles: Array(Set(group.members.map { $0.role.rawValue }))
                    .sorted()
                    .compactMap(ResourceRole.init(rawValue:))
            )
        }
        eventSuggestions = report.eventSuggestions.map { event in
            AgentSafeEventSuggestionReport(eventID: event.eventID, assetIDs: event.assetIDs)
        }
        warnings = report.warnings.map { warning in
            AgentSafeWarning(code: warning.code, rootID: warning.rootID)
        }
        filesModified = report.filesModified
    }
}

public struct ScanReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let startedAt: Date
    public let completedAt: Date
    public let catalogPath: String
    public let summary: ScanSummary
    public let roots: [RootScanReport]
    public let resources: [ScannedResourceReport]
    public let livePhotos: [LivePhotoAssetReport]
    public let exactDuplicateGroups: [ExactDuplicateGroupReport]
    public let eventSuggestions: [EventSuggestionReport]
    public let warnings: [ScanWarning]
    public let filesModified: Bool

    public init(
        schemaVersion: Int = 1,
        sessionID: String,
        startedAt: Date,
        completedAt: Date,
        catalogPath: String,
        summary: ScanSummary,
        roots: [RootScanReport],
        resources: [ScannedResourceReport] = [],
        livePhotos: [LivePhotoAssetReport],
        exactDuplicateGroups: [ExactDuplicateGroupReport],
        eventSuggestions: [EventSuggestionReport],
        warnings: [ScanWarning],
        filesModified: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.catalogPath = catalogPath
        self.summary = summary
        self.roots = roots
        self.resources = resources
        self.livePhotos = livePhotos
        self.exactDuplicateGroups = exactDuplicateGroups
        self.eventSuggestions = eventSuggestions
        self.warnings = warnings
        self.filesModified = filesModified
    }
}
