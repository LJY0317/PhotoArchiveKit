import Foundation

struct TakeoutSidecarIndex: Sendable {
    struct Entry: Sendable {
        let title: String
    }

    private struct Sidecar: Decodable {
        struct TakenTime: Decodable {
            let timestamp: String?
        }

        let title: String?
        let photoTakenTime: TakenTime?
    }

    let entriesBySidecarPath: [String: Entry]
    let captureTimesByMediaPath: [String: Date]

    static func build(from pendingFiles: [PendingFile]) -> TakeoutSidecarIndex {
        var entriesBySidecarPath: [String: Entry] = [:]
        var captureTimesByMediaPath: [String: Date] = [:]

        for pending in pendingFiles {
            guard pending.root.provenance == .googleTakeout,
                  pending.type.mediaKind == .sidecar,
                  pending.url.pathExtension.lowercased() == "json",
                  let data = try? Data(contentsOf: pending.url),
                  let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
                  let title = sidecar.title,
                  !title.isEmpty
            else { continue }

            let instant = sidecar.photoTakenTime?.timestamp
                .flatMap(TimeInterval.init)
                .map(Date.init(timeIntervalSince1970:))
            entriesBySidecarPath[normalizedPath(pending.url)] = Entry(title: title)
            if let instant {
                let mediaURL = pending.url.deletingLastPathComponent().appendingPathComponent(title)
                captureTimesByMediaPath[normalizedPath(mediaURL)] = instant
            }
        }
        return TakeoutSidecarIndex(
            entriesBySidecarPath: entriesBySidecarPath,
            captureTimesByMediaPath: captureTimesByMediaPath
        )
    }

    func hasCaptureTime(for url: URL) -> Bool {
        captureTimesByMediaPath[Self.normalizedPath(url)] != nil
    }

    static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path.decomposedStringWithCanonicalMapping
    }
}

enum TakeoutSidecarImporter {

    static func applyCaptureTimes(
        to resources: inout [ProbedResource],
        index sidecarIndex: TakeoutSidecarIndex
    ) {
        guard !sidecarIndex.captureTimesByMediaPath.isEmpty else { return }

        for resourceIndex in resources.indices {
            guard resources[resourceIndex].root.provenance == .googleTakeout,
                  resources[resourceIndex].mediaKind == .image || resources[resourceIndex].mediaKind == .video,
                  let instant = sidecarIndex.captureTimesByMediaPath[
                    TakeoutSidecarIndex.normalizedPath(resources[resourceIndex].url)
                  ]
            else {
                continue
            }

            let existing = resources[resourceIndex].captureTime
            if existing?.confidence == .trusted, existing?.instant != nil {
                continue
            }

            resources[resourceIndex].captureTime = CaptureTime(
                localTimestamp: existing?.localTimestamp,
                utcOffset: existing?.utcOffset,
                instant: instant,
                source: .googleTakeoutPhotoTakenTime,
                confidence: .providerSidecar
            )
        }
    }

}
