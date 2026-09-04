import Foundation

public struct RootMarker: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let markerKey: String

    public init(schemaVersion: Int = 1, markerKey: String) {
        self.schemaVersion = schemaVersion
        self.markerKey = markerKey
    }
}

public enum RootMarkerError: LocalizedError {
    case rootDoesNotExist(String)
    case rootIsNotDirectory(String)
    case malformedMarker(String)
    case markerAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case let .rootDoesNotExist(path):
            return "Root does not exist: \(path)"
        case let .rootIsNotDirectory(path):
            return "Root is not a directory: \(path)"
        case let .malformedMarker(path):
            return "Root marker is malformed: \(path)"
        case let .markerAlreadyExists(path):
            return "A root marker already exists: \(path)"
        }
    }
}

public enum RootMarkerStore {
    public static let fileName = ".photoarchive-root"

    public static func markerURL(for rootURL: URL) -> URL {
        rootURL.standardizedFileURL.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func readIfPresent(at rootURL: URL) throws -> RootMarker? {
        let url = markerURL(for: rootURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let marker = try JSONDecoder().decode(RootMarker.self, from: Data(contentsOf: url))
            guard marker.schemaVersion == 1, !marker.markerKey.isEmpty else {
                throw RootMarkerError.malformedMarker(url.path)
            }
            return marker
        } catch let error as RootMarkerError {
            throw error
        } catch {
            throw RootMarkerError.malformedMarker(url.path)
        }
    }

    @discardableResult
    public static func create(at rootURL: URL) throws -> RootMarker {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw RootMarkerError.rootDoesNotExist(root.path)
        }
        guard isDirectory.boolValue else {
            throw RootMarkerError.rootIsNotDirectory(root.path)
        }
        let url = markerURL(for: root)
        if FileManager.default.fileExists(atPath: url.path) {
            throw RootMarkerError.markerAlreadyExists(url.path)
        }
        let marker = RootMarker(markerKey: "RM" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: url, options: [.atomic])
        return marker
    }
}
