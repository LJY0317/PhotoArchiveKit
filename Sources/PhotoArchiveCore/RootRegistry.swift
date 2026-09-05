import Foundation

public enum RootRegistrationState: String, Codable, CaseIterable, Sendable {
    case active
    case inactive
    case removed
    case history
}

public struct RegisteredRootReport: Codable, Sendable, Equatable {
    public let rootID: String
    public let label: String
    public let kind: SourceRootKind
    public let provenance: SourceProvenance
    public let canonicalPath: String
    public let state: RootRegistrationState
    public let isAvailable: Bool
    public let currentResourceCount: Int
}

public struct AgentSafeRegisteredRootReport: Codable, Sendable, Equatable {
    public let rootID: String
    public let kind: SourceRootKind
    public let provenance: SourceProvenance
    public let state: RootRegistrationState
    public let isAvailable: Bool
    public let currentResourceCount: Int

    public init(report: RegisteredRootReport) {
        rootID = report.rootID
        kind = report.kind
        provenance = report.provenance
        state = report.state
        isAvailable = report.isAvailable
        currentResourceCount = report.currentResourceCount
    }
}

public struct RootRemovalReport: Codable, Sendable, Equatable {
    public let rootID: String
    public let state: RootRegistrationState
    public let prunedResourceCount: Int
    public let mediaFilesModified: Bool
}

public struct AgentSafeRootRemovalReport: Codable, Sendable, Equatable {
    public let rootID: String
    public let state: RootRegistrationState
    public let prunedResourceCount: Int
    public let mediaFilesModified: Bool

    public init(report: RootRemovalReport) {
        rootID = report.rootID
        state = report.state
        prunedResourceCount = report.prunedResourceCount
        mediaFilesModified = report.mediaFilesModified
    }
}

public enum RootRegistryError: LocalizedError {
    case rootNotFound(String)
    case rootPathNotDirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .rootNotFound(value):
            return "No catalog root matches: \(value)"
        case let .rootPathNotDirectory(path):
            return "The root path is not an existing directory: \(path)"
        }
    }
}

public enum RootRegistry {
    public static func list(
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL,
        includeHistory: Bool = false
    ) throws -> [RegisteredRootReport] {
        let catalog = try SQLiteCatalog(url: catalogURL)
        return try catalog.rootRegistryRows(includeHistory: includeHistory).map { row in
            RegisteredRootReport(
                rootID: row.rootID,
                label: row.label,
                kind: row.kind,
                provenance: row.provenance,
                canonicalPath: row.canonicalPath,
                state: row.state,
                isAvailable: FileManager.default.fileExists(atPath: row.canonicalPath),
                currentResourceCount: row.currentResourceCount
            )
        }
    }

    @discardableResult
    public static func add(
        url: URL,
        kind: SourceRootKind,
        provenance: SourceProvenance,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> RegisteredRootReport {
        var isDirectory: ObjCBool = false
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw RootRegistryError.rootPathNotDirectory(standardized.path)
        }

        let catalog = try SQLiteCatalog(url: catalogURL)
        let markerKey = try RootMarkerStore.readIfPresent(at: standardized)?.markerKey
        let root = try catalog.resolveRoot(
            ScanRoot(url: standardized, kind: kind, provenance: provenance),
            markerKey: markerKey
        )
        try catalog.setRootRegistration(rootID: root.id, state: .active)
        return try list(catalogURL: catalogURL, includeHistory: true)
            .first(where: { $0.rootID == root.id })!
    }

    @discardableResult
    public static func setState(
        target: String,
        state: RootRegistrationState,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> RegisteredRootReport {
        let catalog = try SQLiteCatalog(url: catalogURL)
        guard let rootID = try catalog.rootID(matching: target) else {
            throw RootRegistryError.rootNotFound(target)
        }
        try catalog.setRootRegistration(rootID: rootID, state: state)
        return try list(catalogURL: catalogURL, includeHistory: true)
            .first(where: { $0.rootID == rootID })!
    }

    public static func remove(
        target: String,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> RootRemovalReport {
        let catalog = try SQLiteCatalog(url: catalogURL)
        guard let rootID = try catalog.rootID(matching: target) else {
            throw RootRegistryError.rootNotFound(target)
        }
        let pruned = try catalog.removeRootFromCurrentCatalog(rootID: rootID)
        return RootRemovalReport(
            rootID: rootID,
            state: .removed,
            prunedResourceCount: pruned,
            mediaFilesModified: false
        )
    }
}
