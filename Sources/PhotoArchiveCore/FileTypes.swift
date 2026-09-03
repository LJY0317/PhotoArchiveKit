import Foundation

struct SupportedFileType: Sendable {
    let mediaKind: MediaKind
    let isPotentialLivePhotoStill: Bool
    let isPotentialLivePhotoVideo: Bool
}

enum SupportedFileTypes {
    private static let imageExtensions: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "dng"
    ]

    private static let livePhotoStillExtensions: Set<String> = [
        "heic", "heif", "jpg", "jpeg"
    ]

    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v"
    ]

    private static let sidecarExtensions: Set<String> = [
        "json", "xmp", "aae"
    ]

    static func classify(url: URL) -> SupportedFileType? {
        let ext = url.pathExtension.lowercased()

        if imageExtensions.contains(ext) {
            return SupportedFileType(
                mediaKind: .image,
                isPotentialLivePhotoStill: livePhotoStillExtensions.contains(ext),
                isPotentialLivePhotoVideo: false
            )
        }

        if videoExtensions.contains(ext) {
            return SupportedFileType(
                mediaKind: .video,
                isPotentialLivePhotoStill: false,
                isPotentialLivePhotoVideo: true
            )
        }

        if sidecarExtensions.contains(ext) {
            return SupportedFileType(
                mediaKind: .sidecar,
                isPotentialLivePhotoStill: false,
                isPotentialLivePhotoVideo: false
            )
        }

        return nil
    }
}

struct RootDescriptor: Sendable {
    let id: String
    let label: String
    let kind: SourceRootKind
    let provenance: SourceProvenance
    let url: URL
}

struct PendingFile: Sendable {
    let root: RootDescriptor
    let url: URL
    let relativePath: String
    let type: SupportedFileType
    let byteSize: Int64
    let modifiedAt: Date?
    let createdAt: Date?
}

struct ProbedResource: Sendable {
    let root: RootDescriptor
    let url: URL
    let relativePath: String
    let fileName: String
    let fileExtension: String
    let mediaKind: MediaKind
    let byteSize: Int64
    let modifiedAt: Date?
    var captureTime: CaptureTime?
    var rawLivePhotoIdentifier: String?
    let metadataProbeFailed: Bool
    var exactHash: Data?
    var persistentResourceID: String?
    var persistentAssetID: String?
    var identifierFingerprint: Data?
}

struct AssetAssembly: Sendable {
    let fingerprint: Data
    let resources: [ProbedResource]
}

struct StandaloneAsset: Sendable {
    let resource: ProbedResource
}

struct InternalDuplicateGroup: Sendable {
    let contentHash: Data
    let resources: [ProbedResource]
}

struct InternalEventAsset: Sendable {
    let assetID: String
    let captureInstant: Date
    let localDay: String?
}
