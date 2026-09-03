import Foundation

public enum SourceRootKind: String, Codable, CaseIterable, Sendable {
    case inbox
    case archive
    case importSource = "import_source"
    case reference
}

public struct ScanRoot: Sendable {
    public let url: URL
    public let label: String
    public let kind: SourceRootKind

    public init(url: URL, label: String? = nil, kind: SourceRootKind = .inbox) {
        self.url = url.standardizedFileURL
        self.label = label ?? url.lastPathComponent
        self.kind = kind
    }
}

public struct ScanOptions: Sendable {
    public var computeExactDuplicates: Bool
    public var eventGap: TimeInterval
    public var maxConcurrentProbes: Int

    public init(
        computeExactDuplicates: Bool = true,
        eventGap: TimeInterval = 6 * 60 * 60,
        maxConcurrentProbes: Int = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
    ) {
        self.computeExactDuplicates = computeExactDuplicates
        self.eventGap = eventGap
        self.maxConcurrentProbes = max(1, maxConcurrentProbes)
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
}

public enum CaptureTimeSource: String, Codable, Sendable {
    case exifDateTimeOriginal = "exif_datetime_original"
    case quickTimeCreationDate = "quicktime_creation_date"
    case fileCreationDate = "file_creation_date"
    case unknown
}

public enum CaptureTimeConfidence: String, Codable, Sendable {
    case trusted
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
    public let canonicalPath: String
    public let mediaFileCount: Int
    public let completeLivePhotos: Int
    public let stillOnlyLiveResources: Int
    public let videoOnlyLiveResources: Int
    public let standaloneImages: Int
    public let standaloneVideos: Int
    public let sidecars: Int
    public let metadataProbeFailures: Int

    public init(
        rootID: String,
        label: String,
        kind: SourceRootKind,
        canonicalPath: String,
        mediaFileCount: Int,
        completeLivePhotos: Int,
        stillOnlyLiveResources: Int,
        videoOnlyLiveResources: Int,
        standaloneImages: Int,
        standaloneVideos: Int,
        sidecars: Int,
        metadataProbeFailures: Int
    ) {
        self.rootID = rootID
        self.label = label
        self.kind = kind
        self.canonicalPath = canonicalPath
        self.mediaFileCount = mediaFileCount
        self.completeLivePhotos = completeLivePhotos
        self.stillOnlyLiveResources = stillOnlyLiveResources
        self.videoOnlyLiveResources = videoOnlyLiveResources
        self.standaloneImages = standaloneImages
        self.standaloneVideos = standaloneVideos
        self.sidecars = sidecars
        self.metadataProbeFailures = metadataProbeFailures
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

    public init(
        rootCount: Int,
        resourceCount: Int,
        logicalAssetCount: Int,
        livePhotoAssetCount: Int,
        exactDuplicateGroupCount: Int,
        eventSuggestionCount: Int,
        warningCount: Int
    ) {
        self.rootCount = rootCount
        self.resourceCount = resourceCount
        self.logicalAssetCount = logicalAssetCount
        self.livePhotoAssetCount = livePhotoAssetCount
        self.exactDuplicateGroupCount = exactDuplicateGroupCount
        self.eventSuggestionCount = eventSuggestionCount
        self.warningCount = warningCount
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
        self.livePhotos = livePhotos
        self.exactDuplicateGroups = exactDuplicateGroups
        self.eventSuggestions = eventSuggestions
        self.warnings = warnings
        self.filesModified = filesModified
    }
}
