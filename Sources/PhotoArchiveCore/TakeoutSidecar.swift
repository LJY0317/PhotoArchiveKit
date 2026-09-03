import Foundation

enum TakeoutSidecarImporter {
    private struct Sidecar: Decodable {
        struct TakenTime: Decodable {
            let timestamp: String?
        }

        let title: String?
        let photoTakenTime: TakenTime?
    }

    static func applyCaptureTimes(to resources: inout [ProbedResource]) {
        var captureTimesByMediaPath: [String: Date] = [:]

        for resource in resources {
            guard resource.root.provenance == .googleTakeout,
                  resource.mediaKind == .sidecar,
                  resource.fileExtension == "json"
            else {
                continue
            }

            guard let data = try? Data(contentsOf: resource.url),
                  let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
                  let title = sidecar.title,
                  !title.isEmpty,
                  let rawTimestamp = sidecar.photoTakenTime?.timestamp,
                  let timestamp = TimeInterval(rawTimestamp)
            else {
                continue
            }

            let mediaURL = resource.url.deletingLastPathComponent().appendingPathComponent(title)
            captureTimesByMediaPath[normalizedPath(mediaURL)] = Date(timeIntervalSince1970: timestamp)
        }

        guard !captureTimesByMediaPath.isEmpty else { return }

        for index in resources.indices {
            guard resources[index].root.provenance == .googleTakeout,
                  resources[index].mediaKind == .image || resources[index].mediaKind == .video,
                  let instant = captureTimesByMediaPath[normalizedPath(resources[index].url)]
            else {
                continue
            }

            let existing = resources[index].captureTime
            if existing?.confidence == .trusted, existing?.instant != nil {
                continue
            }

            resources[index].captureTime = CaptureTime(
                localTimestamp: existing?.localTimestamp,
                utcOffset: existing?.utcOffset,
                instant: instant,
                source: .googleTakeoutPhotoTakenTime,
                confidence: .providerSidecar
            )
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path.decomposedStringWithCanonicalMapping
    }
}
