import Foundation

enum AssetAssembler {
    static func livePhotoAssemblies(from resources: [ProbedResource]) -> [AssetAssembly] {
        let grouped = Dictionary(grouping: resources.compactMap { resource -> (Data, ProbedResource)? in
            guard let fingerprint = resource.identifierFingerprint,
                  resource.mediaKind == .image || resource.mediaKind == .video
            else {
                return nil
            }
            return (fingerprint, resource)
        }, by: { $0.0 })

        return grouped
            .map { fingerprint, values in
                AssetAssembly(
                    fingerprint: fingerprint,
                    resources: values.map(\.1).sorted(by: resourceSort)
                )
            }
            .sorted { lhs, rhs in
                firstPath(in: lhs.resources) < firstPath(in: rhs.resources)
            }
    }

    static func standaloneResources(from resources: [ProbedResource]) -> [ProbedResource] {
        resources
            .filter { $0.identifierFingerprint == nil }
            .sorted(by: resourceSort)
    }

    static func occurrenceStatus(stillCount: Int, videoCount: Int) -> LivePhotoOccurrenceStatus {
        switch (stillCount, videoCount) {
        case (1, 1):
            return .complete
        case (1, 0):
            return .stillOnly
        case (0, 1):
            return .videoOnly
        case (let stills, 0) where stills > 1:
            return .multipleStills
        case (0, let videos) where videos > 1:
            return .multipleVideos
        case (let stills, 1) where stills > 1:
            return .multipleStills
        case (1, let videos) where videos > 1:
            return .multipleVideos
        default:
            return .multipleVariants
        }
    }

    static func unverifiedBasenamePairWarnings(
        resources: [ProbedResource]
    ) -> [ScanWarning] {
        struct Key: Hashable {
            let rootID: String
            let directory: String
            let stem: String
        }

        let candidates = resources.filter {
            $0.identifierFingerprint == nil
                && ($0.mediaKind == .image || $0.mediaKind == .video)
        }

        let grouped = Dictionary(grouping: candidates) { resource in
            let path = resource.relativePath as NSString
            return Key(
                rootID: resource.root.id,
                directory: path.deletingLastPathComponent,
                stem: (path.lastPathComponent as NSString).deletingPathExtension.lowercased()
            )
        }

        return grouped.values.compactMap { group in
            let images = group.filter { $0.mediaKind == .image }
            let videos = group.filter { $0.mediaKind == .video }
            guard !images.isEmpty, !videos.isEmpty else { return nil }

            let representative = group.sorted(by: resourceSort).first!
            return ScanWarning(
                code: "unverified_basename_pair",
                message: "An image and video share a basename, but no matching Live Photo identifier was found. They were not paired automatically.",
                rootID: representative.root.id,
                relativePath: representative.relativePath
            )
        }
        .sorted {
            ($0.rootID ?? "", $0.relativePath ?? "")
                < ($1.rootID ?? "", $1.relativePath ?? "")
        }
    }

    static func role(for resource: ProbedResource) -> ResourceRole {
        if resource.identifierFingerprint != nil {
            return resource.mediaKind == .image ? .photo : .pairedVideo
        }

        switch resource.mediaKind {
        case .image:
            return .standaloneImage
        case .video:
            return .standaloneVideo
        case .sidecar:
            return .sidecar
        }
    }

    static func resourceReference(_ resource: ProbedResource) -> ResourceReference {
        ResourceReference(
            rootID: resource.root.id,
            rootLabel: resource.root.label,
            relativePath: resource.relativePath,
            role: role(for: resource),
            byteSize: resource.byteSize
        )
    }

    private static func firstPath(in resources: [ProbedResource]) -> String {
        resources.first.map { "\($0.root.label)/\($0.relativePath)" } ?? ""
    }

    private static func resourceSort(_ lhs: ProbedResource, _ rhs: ProbedResource) -> Bool {
        (lhs.root.label, lhs.relativePath) < (rhs.root.label, rhs.relativePath)
    }
}
