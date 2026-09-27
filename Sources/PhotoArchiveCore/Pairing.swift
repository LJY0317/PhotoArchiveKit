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

    static func partitionOccurrences(_ resources: [ProbedResource]) -> [[ProbedResource]] {
        struct DirectoryKey: Hashable {
            let directory: String
        }

        let byDirectory = Dictionary(grouping: resources) { resource in
            DirectoryKey(directory: (resource.relativePath as NSString).deletingLastPathComponent)
        }

        var occurrences: [[ProbedResource]] = []

        for directoryGroup in byDirectory.values {
            let byStem = Dictionary(grouping: directoryGroup) { resource in
                ((resource.relativePath as NSString).lastPathComponent as NSString)
                    .deletingPathExtension
                    .lowercased()
            }
            var consumed = Set<String>()

            for stemGroup in byStem.values {
                let stills = stemGroup.filter { $0.mediaKind == .image }
                let videos = stemGroup.filter { $0.mediaKind == .video }
                guard stills.count == 1, videos.count == 1 else { continue }

                let pair = [stills[0], videos[0]].sorted(by: resourceSort)
                occurrences.append(pair)
                consumed.formUnion(pair.map(\.relativePath))
            }

            let remainder = directoryGroup
                .filter { !consumed.contains($0.relativePath) }
                .sorted(by: resourceSort)
            if !remainder.isEmpty {
                occurrences.append(remainder)
            }
        }

        return occurrences.sorted { lhs, rhs in
            firstPath(in: lhs) < firstPath(in: rhs)
        }
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

    static func occurrenceStatus(resources: [ProbedResource]) -> LivePhotoOccurrenceStatus {
        let stillCount = resources.count { $0.mediaKind == .image }
        let videos = resources.filter { $0.mediaKind == .video }
        let countStatus = occurrenceStatus(stillCount: stillCount, videoCount: videos.count)
        guard countStatus == .complete, let video = videos.first else {
            return countStatus
        }

        switch video.livePhotoTimedMetadataStatus {
        case .valid:
            return .complete
        case .missing:
            return .stillImageTimeMissing
        case .invalid:
            return .stillImageTimeInvalid
        case .unreadable, .notApplicable:
            return .stillImageTimeUnreadable
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

public enum LivePhotoNamingDiagnostics {
    public static let distinctComponentBasenamesCode = "live_photo_verified_distinct_component_names"

    public static func notice(for occurrence: LivePhotoOccurrenceReport) -> ScanNotice? {
        guard occurrence.status == .complete,
              occurrence.stillCount == 1,
              occurrence.videoCount == 1,
              let still = occurrence.resources.first(where: { $0.role == .photo }),
              let video = occurrence.resources.first(where: { $0.role == .pairedVideo })
        else {
            return nil
        }

        let stillStem = basenameStem(still.relativePath)
        let videoStem = basenameStem(video.relativePath)
        guard stillStem != videoStem else { return nil }

        return ScanNotice(
            code: distinctComponentBasenamesCode,
            message: "Verified Live Photo components use different basenames; embedded Live Photo metadata confirms they belong together.",
            rootID: occurrence.rootID,
            relativePath: [still.relativePath, video.relativePath].sorted().first
        )
    }

    private static func basenameStem(_ relativePath: String) -> String {
        (((relativePath as NSString).lastPathComponent) as NSString)
            .deletingPathExtension
            .lowercased()
    }
}
