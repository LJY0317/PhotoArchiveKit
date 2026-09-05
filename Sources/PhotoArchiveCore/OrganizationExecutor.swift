import Foundation

public enum OrganizationApplyError: LocalizedError {
    case planSessionMismatch
    case noAutomaticCandidates
    case missingRoot(String)
    case rootRoleDisallowsOrganization(String)
    case rootMarkerRequired(String)
    case missingResource(String)
    case unsafeRelativePath(String)
    case missingSource(String)
    case sourceChanged(String)
    case destinationAlreadyExists(String)
    case livePhotoAtomicityViolation(String)
    case moveFailed(String)
    case postMoveVerificationFailed(String)
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .planSessionMismatch:
            return "The organization plan does not belong to the supplied scan session."
        case .noAutomaticCandidates:
            return "The organization plan has no automatic candidates."
        case let .missingRoot(rootID):
            return "A planned source root is missing from the scan report: \(rootID)"
        case let .rootRoleDisallowsOrganization(rootID):
            return "The current root role does not allow organization mutation: \(rootID)"
        case let .rootMarkerRequired(path):
            return "Organization apply requires a stable .photoarchive-root marker: \(path)"
        case let .missingResource(resourceID):
            return "A planned resource is missing from the scan report: \(resourceID)"
        case let .unsafeRelativePath(path):
            return "A planned path escapes its registered root: \(path)"
        case let .missingSource(path):
            return "A planned source file is no longer available: \(path)"
        case let .sourceChanged(path):
            return "A planned source file changed after the scan: \(path)"
        case let .destinationAlreadyExists(path):
            return "An organization destination already exists: \(path)"
        case let .livePhotoAtomicityViolation(itemID):
            return "A Live Photo organization item is not an atomic still + paired-video pair: \(itemID)"
        case let .moveFailed(path):
            return "Could not move an organization resource: \(path)"
        case let .postMoveVerificationFailed(path):
            return "A moved organization resource failed post-move verification: \(path)"
        case let .rollbackFailed(path):
            return "Organization rollback could not restore a resource: \(path)"
        }
    }
}

public struct OrganizationApplyMoveRecord: Codable, Sendable, Equatable {
    public let itemID: String
    public let resourceID: String
    public let rootID: String
    public let role: ResourceRole
    public let sourcePath: String
    public let destinationPath: String
    public let byteSize: Int64

    public init(
        itemID: String,
        resourceID: String,
        rootID: String,
        role: ResourceRole,
        sourcePath: String,
        destinationPath: String,
        byteSize: Int64
    ) {
        self.itemID = itemID
        self.resourceID = resourceID
        self.rootID = rootID
        self.role = role
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.byteSize = byteSize
    }
}

public struct OrganizationApplyManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let policy: String
    public let createdAt: Date
    public let state: String
    public let moves: [OrganizationApplyMoveRecord]
    public let filesModified: Bool

    public init(
        schemaVersion: Int,
        sessionID: String,
        policy: String,
        createdAt: Date,
        state: String,
        moves: [OrganizationApplyMoveRecord],
        filesModified: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.policy = policy
        self.createdAt = createdAt
        self.state = state
        self.moves = moves
        self.filesModified = filesModified
    }
}

public struct OrganizationApplyReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let dryRun: Bool
    public let itemCount: Int
    public let resourceCount: Int
    public let manifestPath: String?
    public let moves: [OrganizationApplyMoveRecord]
    public let filesModified: Bool
}

public struct AgentSafeOrganizationApplyReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let sessionID: String
    public let dryRun: Bool
    public let itemCount: Int
    public let resourceCount: Int
    public let filesModified: Bool

    public init(report: OrganizationApplyReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        sessionID = report.sessionID
        dryRun = report.dryRun
        itemCount = report.itemCount
        resourceCount = report.resourceCount
        filesModified = report.filesModified
    }
}

public enum OrganizationExecutor {
    private struct VerifiedMove {
        let itemID: String
        let sourceURL: URL
        let destinationURL: URL
        let expectedSize: Int64
        let preMoveFileIdentifier: String?
        let record: OrganizationApplyMoveRecord
    }

    private struct VerifiedItem {
        let itemID: String
        let kind: OrganizationItemKind
        let moves: [VerifiedMove]
    }

    public static func preflight(report: ScanReport, plan: OrganizationPlan) throws -> OrganizationApplyReport {
        let items = try verify(report: report, plan: plan)
        let moves = items.flatMap(\.moves).map(\.record)
        return OrganizationApplyReport(
            schemaVersion: 1,
            sessionID: report.sessionID,
            dryRun: true,
            itemCount: items.count,
            resourceCount: moves.count,
            manifestPath: nil,
            moves: moves,
            filesModified: false
        )
    }

    public static func apply(
        report: ScanReport,
        plan: OrganizationPlan,
        manifestDirectoryURL: URL = PhotoArchivePaths.defaultOperationsDirectoryURL,
        commitCatalog: () throws -> Void
    ) throws -> OrganizationApplyReport {
        let verifiedItems = try verify(report: report, plan: plan)
        let allMoves = verifiedItems.flatMap(\.moves)
        let fileManager = FileManager.default
        let operationRoot = manifestDirectoryURL
            .appendingPathComponent(report.sessionID, isDirectory: true)
        try fileManager.createDirectory(at: operationRoot, withIntermediateDirectories: true)
        let pendingURL = operationRoot.appendingPathComponent("organization.pending.json")
        let finalURL = operationRoot.appendingPathComponent("organization.json")
        let createdAt = Date()
        try writeManifest(
            OrganizationApplyManifest(
                schemaVersion: 1,
                sessionID: report.sessionID,
                policy: plan.policy,
                createdAt: createdAt,
                state: "pending",
                moves: allMoves.map(\.record),
                filesModified: false
            ),
            to: pendingURL
        )

        var moved: [VerifiedMove] = []
        do {
            for item in verifiedItems {
                if item.kind == .livePhoto {
                    try validateLivePhotoItem(item)
                }
                for move in item.moves {
                    do {
                        try fileManager.moveItem(at: move.sourceURL, to: move.destinationURL)
                        moved.append(move)
                    } catch {
                        throw OrganizationApplyError.moveFailed(move.sourceURL.path)
                    }
                    try verifyMovedResource(move)
                }
            }

            try writeManifest(
                OrganizationApplyManifest(
                    schemaVersion: 1,
                    sessionID: report.sessionID,
                    policy: plan.policy,
                    createdAt: createdAt,
                    state: "complete",
                    moves: allMoves.map(\.record),
                    filesModified: true
                ),
                to: finalURL
            )
            try commitCatalog()
            try? fileManager.removeItem(at: pendingURL)
            return OrganizationApplyReport(
                schemaVersion: 1,
                sessionID: report.sessionID,
                dryRun: false,
                itemCount: verifiedItems.count,
                resourceCount: allMoves.count,
                manifestPath: finalURL.path,
                moves: allMoves.map(\.record),
                filesModified: true
            )
        } catch {
            for move in moved.reversed() {
                do {
                    if fileManager.fileExists(atPath: move.destinationURL.path),
                       !fileManager.fileExists(atPath: move.sourceURL.path) {
                        try fileManager.createDirectory(
                            at: move.sourceURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fileManager.moveItem(at: move.destinationURL, to: move.sourceURL)
                    }
                } catch {
                    throw OrganizationApplyError.rollbackFailed(move.sourceURL.path)
                }
            }
            try? fileManager.removeItem(at: pendingURL)
            try? fileManager.removeItem(at: finalURL)
            throw error
        }
    }

    private static func verify(report: ScanReport, plan: OrganizationPlan) throws -> [VerifiedItem] {
        guard report.sessionID == plan.sessionID else {
            throw OrganizationApplyError.planSessionMismatch
        }
        let automatic = plan.items.filter { $0.decision == .automatic }
        guard !automatic.isEmpty else {
            throw OrganizationApplyError.noAutomaticCandidates
        }
        let roots = Dictionary(uniqueKeysWithValues: report.roots.map { ($0.rootID, $0) })
        let resources = Dictionary(uniqueKeysWithValues: report.resources.map { ($0.resourceID, $0) })
        var verifiedItems: [VerifiedItem] = []

        for item in automatic {
            if item.kind == .livePhoto {
                let roles = Set(item.moves.map(\.role))
                guard item.moves.count == 2,
                      roles == Set([ResourceRole.photo, ResourceRole.pairedVideo])
                else {
                    throw OrganizationApplyError.livePhotoAtomicityViolation(item.itemID)
                }
            }
            var moves: [VerifiedMove] = []
            for planned in item.moves {
                guard let root = roots[planned.rootID] else {
                    throw OrganizationApplyError.missingRoot(planned.rootID)
                }
                guard root.usageRole.allowsOrganizationMutation else {
                    throw OrganizationApplyError.rootRoleDisallowsOrganization(planned.rootID)
                }
                let rootURL = URL(fileURLWithPath: root.canonicalPath)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                guard try RootMarkerStore.readIfPresent(at: rootURL) != nil else {
                    throw OrganizationApplyError.rootMarkerRequired(rootURL.path)
                }
                guard let resource = resources[planned.resourceID] else {
                    throw OrganizationApplyError.missingResource(planned.resourceID)
                }
                guard resource.rootID == planned.rootID,
                      resource.relativePath == planned.sourceRelativePath
                else {
                    throw OrganizationApplyError.sourceChanged(planned.sourceRelativePath)
                }
                let sourceURL = try safeURL(rootURL: rootURL, relativePath: planned.sourceRelativePath)
                let destinationURL = try safeURL(rootURL: rootURL, relativePath: planned.destinationRelativePath)
                guard sourceURL != destinationURL else { continue }
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    throw OrganizationApplyError.missingSource(sourceURL.path)
                }
                guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw OrganizationApplyError.destinationAlreadyExists(destinationURL.path)
                }
                let current = try currentFileFacts(url: sourceURL, rootURL: rootURL)
                guard current.size == resource.byteSize else {
                    throw OrganizationApplyError.sourceChanged(sourceURL.path)
                }
                moves.append(VerifiedMove(
                    itemID: item.itemID,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    expectedSize: resource.byteSize,
                    preMoveFileIdentifier: current.fileIdentifier,
                    record: OrganizationApplyMoveRecord(
                        itemID: item.itemID,
                        resourceID: planned.resourceID,
                        rootID: planned.rootID,
                        role: planned.role,
                        sourcePath: sourceURL.path,
                        destinationPath: destinationURL.path,
                        byteSize: resource.byteSize
                    )
                ))
            }
            if item.kind == .livePhoto, moves.count != 2 {
                throw OrganizationApplyError.livePhotoAtomicityViolation(item.itemID)
            }
            if !moves.isEmpty {
                verifiedItems.append(VerifiedItem(itemID: item.itemID, kind: item.kind, moves: moves))
            }
        }
        guard !verifiedItems.isEmpty else {
            throw OrganizationApplyError.noAutomaticCandidates
        }
        return verifiedItems
    }

    private static func validateLivePhotoItem(_ item: VerifiedItem) throws {
        let roles = Set(item.moves.map { $0.record.role })
        guard item.moves.count == 2,
              roles == Set([ResourceRole.photo, ResourceRole.pairedVideo])
        else {
            throw OrganizationApplyError.livePhotoAtomicityViolation(item.itemID)
        }
        let stems = Set(item.moves.map { ($0.destinationURL.lastPathComponent as NSString).deletingPathExtension })
        guard stems.count == 1 else {
            throw OrganizationApplyError.livePhotoAtomicityViolation(item.itemID)
        }
    }

    private static func verifyMovedResource(_ move: VerifiedMove) throws {
        let rootURL = move.destinationURL.deletingLastPathComponent()
        let values = try move.destinationURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileResourceIdentifierKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == move.expectedSize
        else {
            throw OrganizationApplyError.postMoveVerificationFailed(move.destinationURL.path)
        }
        if let expected = move.preMoveFileIdentifier,
           let actual = values.fileResourceIdentifier.map({ String(describing: $0) }),
           expected != actual {
            throw OrganizationApplyError.postMoveVerificationFailed(move.destinationURL.path)
        }
        _ = rootURL
    }

    private static func currentFileFacts(url: URL, rootURL: URL) throws -> (size: Int64, fileIdentifier: String?) {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileResourceIdentifierKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            throw OrganizationApplyError.sourceChanged(url.path)
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == url.standardizedFileURL.path,
              isDescendantOrEqual(resolved, of: rootURL)
        else {
            throw OrganizationApplyError.sourceChanged(url.path)
        }
        return (
            Int64(values.fileSize ?? -1),
            values.fileResourceIdentifier.map { String(describing: $0) }
        )
    }

    private static func safeURL(rootURL: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw OrganizationApplyError.unsafeRelativePath(relativePath)
        }
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard isDescendantOrEqual(url, of: rootURL) else {
            throw OrganizationApplyError.unsafeRelativePath(relativePath)
        }
        return url
    }

    private static func isDescendantOrEqual(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        if childPath == parentPath { return true }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }

    private static func writeManifest(_ manifest: OrganizationApplyManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: [.atomic])
    }
}
