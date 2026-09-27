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
    public let usageRole: RootUsageRole
    public let provenance: SourceProvenance
    public let canonicalPath: String
    public let state: RootRegistrationState
    public let isAvailable: Bool
    public let currentResourceCount: Int
}

public struct AgentSafeRegisteredRootReport: Codable, Sendable, Equatable {
    public let rootID: String
    public let kind: SourceRootKind
    public let usageRole: RootUsageRole
    public let provenance: SourceProvenance
    public let state: RootRegistrationState
    public let isAvailable: Bool
    public let currentResourceCount: Int

    public init(report: RegisteredRootReport) {
        rootID = report.rootID
        kind = report.kind
        usageRole = report.usageRole
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

public struct ComparisonRootRegistrationResult: Sendable, Equatable {
    public let root: RegisteredRootReport
    public let wasAlreadyRegistered: Bool

    public init(root: RegisteredRootReport, wasAlreadyRegistered: Bool) {
        self.root = root
        self.wasAlreadyRegistered = wasAlreadyRegistered
    }
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
        let displayOrder = try catalog.rootDisplayOrder()
        var rank: [String: Int] = [:]
        for (index, rootID) in displayOrder.enumerated() where rank[rootID] == nil {
            rank[rootID] = index
        }
        return try catalog.rootRegistryRows(includeHistory: includeHistory).map { row in
            RegisteredRootReport(
                rootID: row.rootID,
                label: row.label,
                kind: row.kind,
                usageRole: row.usageRole,
                provenance: row.provenance,
                canonicalPath: row.canonicalPath,
                state: row.state,
                isAvailable: FileManager.default.fileExists(atPath: row.canonicalPath),
                currentResourceCount: row.currentResourceCount
            )
        }.enumerated().sorted { lhs, rhs in
            let leftRank = rank[lhs.element.rootID]
            let rightRank = rank[rhs.element.rootID]
            switch (leftRank, rightRank) {
            case let (.some(left), .some(right)):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    @discardableResult
    public static func setDisplayOrder(
        rootIDs: [String],
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> [RegisteredRootReport] {
        let catalog = try SQLiteCatalog(url: catalogURL)
        let currentIDs = try catalog.rootRegistryRows(includeHistory: false).map(\.rootID)
        let currentSet = Set(currentIDs)
        var seen = Set<String>()
        var normalized = rootIDs.filter { currentSet.contains($0) && seen.insert($0).inserted }
        normalized.append(contentsOf: currentIDs.filter { seen.insert($0).inserted })
        try catalog.setRootDisplayOrder(normalized)
        return try list(catalogURL: catalogURL)
    }

    public static func registeredRoot(
        at url: URL,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> RegisteredRootReport? {
        let path = normalizedComparisonPath(url)
        return try list(catalogURL: catalogURL).first { report in
            normalizedComparisonPath(URL(fileURLWithPath: report.canonicalPath, isDirectory: true)) == path
        }
    }

    @discardableResult
    public static func addComparisonRoot(
        url: URL,
        purpose: RootUserPurpose = .standard,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> ComparisonRootRegistrationResult {
        if let existing = try registeredRoot(at: url, catalogURL: catalogURL) {
            return ComparisonRootRegistrationResult(root: existing, wasAlreadyRegistered: true)
        }

        let provenance = inferredProvenance(at: url)
        let role = storageRole(for: purpose, provenance: provenance, preserving: nil)
        let root = try add(
            url: url,
            kind: role.sourceKind,
            provenance: provenance,
            usageRole: role,
            catalogURL: catalogURL
        )
        return ComparisonRootRegistrationResult(root: root, wasAlreadyRegistered: false)
    }

    @discardableResult
    public static func add(
        url: URL,
        kind: SourceRootKind,
        provenance: SourceProvenance,
        usageRole: RootUsageRole? = nil,
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
        if let usageRole {
            try catalog.setRootUsageRole(rootID: root.id, role: usageRole)
        }
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

    @discardableResult
    public static func setUsageRole(
        target: String,
        role: RootUsageRole,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> RegisteredRootReport {
        let catalog = try SQLiteCatalog(url: catalogURL)
        guard let rootID = try catalog.rootID(matching: target) else {
            throw RootRegistryError.rootNotFound(target)
        }
        try catalog.setRootUsageRole(rootID: rootID, role: role)
        return try list(catalogURL: catalogURL, includeHistory: true)
            .first(where: { $0.rootID == rootID })!
    }

    @discardableResult
    public static func setUserPurpose(
        target: String,
        purpose: RootUserPurpose,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> RegisteredRootReport {
        guard let current = try list(catalogURL: catalogURL, includeHistory: true)
            .first(where: { $0.rootID == target || $0.canonicalPath == target || $0.label == target })
        else {
            throw RootRegistryError.rootNotFound(target)
        }

        let nextRole = storageRole(
            for: purpose,
            provenance: current.provenance,
            preserving: current.usageRole
        )
        guard nextRole != current.usageRole else { return current }
        return try setUsageRole(target: current.rootID, role: nextRole, catalogURL: catalogURL)
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

    private static func storageRole(
        for purpose: RootUserPurpose,
        provenance: SourceProvenance,
        preserving currentRole: RootUsageRole?
    ) -> RootUsageRole {
        switch purpose {
        case .standard:
            if let currentRole, currentRole.userPurpose == .standard {
                return currentRole
            }
            return provenance == .googleTakeout ? .importSource : .staging
        case .archive:
            return .archive
        case .readOnly:
            return .reference
        }
    }

    private static func normalizedComparisonPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath()
            .standardizedFileURL.path
            .decomposedStringWithCanonicalMapping
    }

    private static func inferredProvenance(at rootURL: URL) -> SourceProvenance {
        struct TakeoutSidecarProbe: Decodable {
            struct TimeValue: Decodable { let timestamp: String? }
            let title: String?
            let photoTakenTime: TimeValue?
            let creationTime: TimeValue?
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return .unknown
        }

        var visited = 0
        var jsonProbes = 0
        while let candidate = enumerator.nextObject() as? URL, visited < 10_000, jsonProbes < 100 {
            visited += 1
            guard candidate.pathExtension.lowercased() == "json" else { continue }
            guard let values = try? candidate.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0,
                  size <= 1_000_000
            else {
                continue
            }
            jsonProbes += 1
            guard let data = try? Data(contentsOf: candidate),
                  let sidecar = try? JSONDecoder().decode(TakeoutSidecarProbe.self, from: data),
                  let title = sidecar.title,
                  !title.isEmpty,
                  sidecar.photoTakenTime?.timestamp != nil || sidecar.creationTime?.timestamp != nil
            else {
                continue
            }
            let referencedMedia = candidate.deletingLastPathComponent().appendingPathComponent(title)
            guard FileManager.default.fileExists(atPath: referencedMedia.path) else { continue }
            return .googleTakeout
        }
        return .unknown
    }
}
