import Foundation

public enum SidecarAssociationKind: String, Codable, Sendable {
    case googleTakeoutJSON = "google_takeout_json"
    case xmp
    case appleAAE = "apple_aae"
}

struct SidecarAssociationCandidate: Sendable {
    let sidecarIndex: Int
    let targetIndex: Int
    let kind: SidecarAssociationKind
}

enum SidecarAssociationDetector {
    private struct TakeoutSidecar: Decodable {
        let title: String?
    }

    static func detect(in resources: [ProbedResource]) -> [SidecarAssociationCandidate] {
        var candidates: [SidecarAssociationCandidate] = []
        var usedSidecarIndices = Set<Int>()

        var mediaIndexByNormalizedPath: [String: Int] = [:]
        for index in resources.indices where resources[index].mediaKind != .sidecar {
            mediaIndexByNormalizedPath[normalizedPath(resources[index].url)] = index
        }

        for index in resources.indices {
            let resource = resources[index]
            guard resource.mediaKind == .sidecar,
                  resource.fileExtension == "json",
                  resource.root.provenance == .googleTakeout,
                  let data = try? Data(contentsOf: resource.url),
                  let sidecar = try? JSONDecoder().decode(TakeoutSidecar.self, from: data),
                  let title = sidecar.title,
                  !title.isEmpty
            else {
                continue
            }

            let mediaURL = resource.url.deletingLastPathComponent().appendingPathComponent(title)
            guard let targetIndex = mediaIndexByNormalizedPath[normalizedPath(mediaURL)] else {
                continue
            }
            candidates.append(SidecarAssociationCandidate(
                sidecarIndex: index,
                targetIndex: targetIndex,
                kind: .googleTakeoutJSON
            ))
            usedSidecarIndices.insert(index)
        }

        struct BasenameKey: Hashable {
            let rootID: String
            let directory: String
            let stem: String
        }
        var mediaByBasename: [BasenameKey: [Int]] = [:]
        for index in resources.indices where resources[index].mediaKind != .sidecar {
            let path = resources[index].relativePath as NSString
            let key = BasenameKey(
                rootID: resources[index].root.id,
                directory: path.deletingLastPathComponent,
                stem: (path.lastPathComponent as NSString).deletingPathExtension.lowercased()
            )
            mediaByBasename[key, default: []].append(index)
        }

        for index in resources.indices where !usedSidecarIndices.contains(index) {
            let resource = resources[index]
            guard resource.mediaKind == .sidecar,
                  resource.fileExtension == "xmp" || resource.fileExtension == "aae"
            else {
                continue
            }
            let path = resource.relativePath as NSString
            let key = BasenameKey(
                rootID: resource.root.id,
                directory: path.deletingLastPathComponent,
                stem: (path.lastPathComponent as NSString).deletingPathExtension.lowercased()
            )
            let matches = mediaByBasename[key] ?? []
            let imageMatches = matches.filter { resources[$0].mediaKind == .image }
            let targetIndex: Int?
            if imageMatches.count == 1 {
                targetIndex = imageMatches[0]
            } else if matches.count == 1 {
                targetIndex = matches[0]
            } else {
                targetIndex = nil
            }
            guard let targetIndex else { continue }
            candidates.append(SidecarAssociationCandidate(
                sidecarIndex: index,
                targetIndex: targetIndex,
                kind: resource.fileExtension == "xmp" ? .xmp : .appleAAE
            ))
        }

        return candidates.sorted {
            (resources[$0.sidecarIndex].root.label, resources[$0.sidecarIndex].relativePath)
                < (resources[$1.sidecarIndex].root.label, resources[$1.sidecarIndex].relativePath)
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path.decomposedStringWithCanonicalMapping
    }
}
