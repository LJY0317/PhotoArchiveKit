import Foundation

public enum QuarantineRestoreError: LocalizedError {
    case manifestMissing
    case manifestInvalid
    case manifestNotComplete
    case alreadyRestored
    case missingCatalogEvidence
    case sourceRootUnavailable
    case sourceAlreadyExists
    case missingQuarantineResource
    case quarantineResourceChanged
    case unsafeManifestPath
    case livePhotoAtomicityViolation
    case moveFailed
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return "The quarantine manifest does not exist."
        case .manifestInvalid:
            return "The quarantine manifest is invalid or unsupported."
        case .manifestNotComplete:
            return "Only a completed quarantine manifest can be restored."
        case .alreadyRestored:
            return "This quarantine session has already been restored."
        case .missingCatalogEvidence:
            return "The local catalog no longer has the exact-file evidence required to restore this quarantine safely."
        case .sourceRootUnavailable:
            return "A recorded source root is currently unavailable. Restore will not recreate a missing root."
        case .sourceAlreadyExists:
            return "A restore destination is already occupied. No files were changed."
        case .missingQuarantineResource:
            return "A quarantined resource is missing. No files were changed."
        case .quarantineResourceChanged:
            return "A quarantined resource no longer matches the exact bytes recorded by the local catalog. No files were changed."
        case .unsafeManifestPath:
            return "The quarantine manifest contains a path that is outside its recorded root or session directory."
        case .livePhotoAtomicityViolation:
            return "A Live Photo restore item does not contain both still and paired-video resources."
        case .moveFailed:
            return "A quarantine restore move failed."
        case .rollbackFailed:
            return "A quarantine restore failed and rollback could not fully return the session to quarantine."
        }
    }
}

public struct QuarantineRestoreState: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let state: String
    public let restoredAt: Date
    public let resourceCount: Int
}

public struct QuarantineRestoreReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let dryRun: Bool
    public let itemCount: Int
    public let resourceCount: Int
    public let totalBytes: Int64
    public let manifestPath: String
    public let restoreStatePath: String?
    public let filesModified: Bool
}

public struct AgentSafeQuarantineRestoreReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let sessionID: String
    public let dryRun: Bool
    public let itemCount: Int
    public let resourceCount: Int
    public let filesModified: Bool

    public init(report: QuarantineRestoreReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        sessionID = report.sessionID
        dryRun = report.dryRun
        itemCount = report.itemCount
        resourceCount = report.resourceCount
        filesModified = report.filesModified
    }
}

public enum QuarantineRestoreExecutor {
    private struct VerifiedMove {
        let itemID: String
        let sourceURL: URL
        let quarantineURL: URL
        let byteSize: Int64
    }

    private struct VerifiedItem {
        let itemID: String
        let moves: [VerifiedMove]
    }

    public static func preflight(
        manifestURL: URL,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> QuarantineRestoreReport {
        let verified = try verify(manifestURL: manifestURL, catalogURL: catalogURL)
        return makeReport(
            manifestURL: verified.manifestURL,
            manifest: verified.manifest,
            items: verified.items,
            dryRun: true,
            restoreStatePath: nil,
            filesModified: false
        )
    }

    public static func apply(
        manifestURL: URL,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> QuarantineRestoreReport {
        let verified = try verify(manifestURL: manifestURL, catalogURL: catalogURL)
        let fileManager = FileManager.default
        let restoreStateURL = verified.manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent("restore.json")

        var restored: [VerifiedMove] = []
        do {
            for item in verified.items {
                for move in item.moves {
                    try fileManager.createDirectory(
                        at: move.sourceURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    do {
                        try fileManager.moveItem(at: move.quarantineURL, to: move.sourceURL)
                        restored.append(move)
                    } catch {
                        throw QuarantineRestoreError.moveFailed
                    }
                }
            }

            let state = QuarantineRestoreState(
                schemaVersion: 1,
                sessionID: verified.manifest.sessionID,
                state: "complete",
                restoredAt: Date(),
                resourceCount: restored.count
            )
            try writeState(state, to: restoreStateURL)

            return makeReport(
                manifestURL: verified.manifestURL,
                manifest: verified.manifest,
                items: verified.items,
                dryRun: false,
                restoreStatePath: restoreStateURL.path,
                filesModified: true
            )
        } catch {
            for move in restored.reversed() {
                do {
                    if fileManager.fileExists(atPath: move.sourceURL.path),
                       !fileManager.fileExists(atPath: move.quarantineURL.path) {
                        try fileManager.createDirectory(
                            at: move.quarantineURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fileManager.moveItem(at: move.sourceURL, to: move.quarantineURL)
                    }
                } catch {
                    throw QuarantineRestoreError.rollbackFailed
                }
            }
            throw error
        }
    }

    private static func verify(
        manifestURL rawManifestURL: URL,
        catalogURL: URL
    ) throws -> (manifestURL: URL, manifest: QuarantineManifest, items: [VerifiedItem]) {
        let fileManager = FileManager.default
        let manifestURL = rawManifestURL.standardizedFileURL
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw QuarantineRestoreError.manifestMissing
        }

        let manifest: QuarantineManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(QuarantineManifest.self, from: data)
        } catch {
            throw QuarantineRestoreError.manifestInvalid
        }
        guard manifest.schemaVersion == 1,
              manifest.state == "complete",
              manifest.filesModified
        else {
            throw QuarantineRestoreError.manifestNotComplete
        }
        guard !manifest.moves.isEmpty else {
            throw QuarantineRestoreError.manifestInvalid
        }

        let restoreStateURL = manifestURL.deletingLastPathComponent().appendingPathComponent("restore.json")
        if fileManager.fileExists(atPath: restoreStateURL.path) {
            throw QuarantineRestoreError.alreadyRestored
        }

        let expectedSessionRoot = URL(fileURLWithPath: manifest.targetPath, isDirectory: true)
            .appendingPathComponent("PhotoArchiveKit", isDirectory: true)
            .appendingPathComponent(manifest.sessionID, isDirectory: true)
            .standardizedFileURL
        guard manifestURL.deletingLastPathComponent().standardizedFileURL.path == expectedSessionRoot.path else {
            throw QuarantineRestoreError.unsafeManifestPath
        }

        guard fileManager.fileExists(atPath: catalogURL.path) else {
            throw QuarantineRestoreError.missingCatalogEvidence
        }
        let catalog = try SQLiteCatalog(url: catalogURL)
        let grouped = Dictionary(grouping: manifest.moves, by: \.itemID)
        var items: [VerifiedItem] = []
        items.reserveCapacity(grouped.count)
        var seenSources = Set<String>()
        var seenQuarantine = Set<String>()

        for itemID in grouped.keys.sorted() {
            guard let records = grouped[itemID], !records.isEmpty else { continue }

            let hasLiveRole = records.contains { $0.role == .photo || $0.role == .pairedVideo }
            let isModernManifestItem = records.allSatisfy { $0.sourceRelativePath != nil }
            if hasLiveRole, isModernManifestItem {
                let hasPhoto = records.contains { $0.role == .photo }
                let hasVideo = records.contains { $0.role == .pairedVideo }
                guard hasPhoto, hasVideo else {
                    throw QuarantineRestoreError.livePhotoAtomicityViolation
                }
            }

            var moves: [VerifiedMove] = []
            moves.reserveCapacity(records.count)
            for record in records {
                guard let rootPath = try catalog.quarantineRestoreRootPath(rootID: record.rootID) else {
                    throw QuarantineRestoreError.missingCatalogEvidence
                }
                let rawRootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
                var isRootDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: rawRootURL.path, isDirectory: &isRootDirectory),
                      isRootDirectory.boolValue
                else {
                    throw QuarantineRestoreError.sourceRootUnavailable
                }
                let rootURL = rawRootURL.resolvingSymlinksInPath().standardizedFileURL
                let relativePath = try resolvedRelativePath(record: record, currentRootURL: rootURL)
                let sourceURL = try safeSourceURL(rootURL: rootURL, relativePath: relativePath)
                let quarantineURL = URL(fileURLWithPath: record.destinationPath)
                    .standardizedFileURL

                let resolvedSessionRoot = expectedSessionRoot.resolvingSymlinksInPath().standardizedFileURL
                let resolvedQuarantineURL = quarantineURL.resolvingSymlinksInPath().standardizedFileURL
                guard resolvedQuarantineURL.path == quarantineURL.path,
                      isDescendant(resolvedQuarantineURL, of: resolvedSessionRoot)
                else {
                    throw QuarantineRestoreError.unsafeManifestPath
                }
                guard seenSources.insert(sourceURL.path).inserted,
                      seenQuarantine.insert(quarantineURL.path).inserted
                else {
                    throw QuarantineRestoreError.manifestInvalid
                }
                guard !fileManager.fileExists(atPath: sourceURL.path) else {
                    throw QuarantineRestoreError.sourceAlreadyExists
                }
                guard fileManager.fileExists(atPath: quarantineURL.path) else {
                    throw QuarantineRestoreError.missingQuarantineResource
                }

                let values = try quarantineURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      Int64(values.fileSize ?? -1) == record.byteSize
                else {
                    throw QuarantineRestoreError.quarantineResourceChanged
                }
                guard let expectedHash = try catalog.quarantineRestoreExactHash(
                    rootID: record.rootID,
                    relativePath: relativePath
                ) else {
                    throw QuarantineRestoreError.missingCatalogEvidence
                }
                let currentHash = try FileHasher.sha256(url: quarantineURL)
                guard currentHash == expectedHash else {
                    throw QuarantineRestoreError.quarantineResourceChanged
                }

                moves.append(VerifiedMove(
                    itemID: itemID,
                    sourceURL: sourceURL,
                    quarantineURL: quarantineURL,
                    byteSize: record.byteSize
                ))
            }
            items.append(VerifiedItem(itemID: itemID, moves: moves))
        }

        return (manifestURL, manifest, items)
    }

    private static func resolvedRelativePath(
        record: QuarantineMoveRecord,
        currentRootURL: URL
    ) throws -> String {
        if let relative = record.sourceRelativePath, !relative.isEmpty {
            return relative
        }

        // Schema v1 manifests created before sourceRelativePath was added can still be
        // restored while the root remains at the path recorded at quarantine time.
        let legacySource = URL(fileURLWithPath: record.sourcePath).standardizedFileURL
        guard isDescendant(legacySource, of: currentRootURL) else {
            throw QuarantineRestoreError.missingCatalogEvidence
        }
        let rootComponents = currentRootURL.pathComponents
        let sourceComponents = legacySource.pathComponents
        return sourceComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func safeSourceURL(rootURL: URL, relativePath: String) throws -> URL {
        let relativeURL = URL(fileURLWithPath: relativePath)
        guard !relativeURL.isFileURL || !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw QuarantineRestoreError.unsafeManifestPath
        }
        let result = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard isDescendant(result, of: rootURL) else {
            throw QuarantineRestoreError.unsafeManifestPath
        }

        let parent = result.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard parent.path == rootURL.path || isDescendant(parent, of: rootURL) else {
            throw QuarantineRestoreError.unsafeManifestPath
        }
        return result
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        guard childComponents.count > parentComponents.count else { return false }
        return Array(childComponents.prefix(parentComponents.count)) == parentComponents
    }

    private static func makeReport(
        manifestURL: URL,
        manifest: QuarantineManifest,
        items: [VerifiedItem],
        dryRun: Bool,
        restoreStatePath: String?,
        filesModified: Bool
    ) -> QuarantineRestoreReport {
        let moves = items.flatMap(\.moves)
        return QuarantineRestoreReport(
            schemaVersion: 1,
            sessionID: manifest.sessionID,
            dryRun: dryRun,
            itemCount: items.count,
            resourceCount: moves.count,
            totalBytes: moves.reduce(0) { $0 + $1.byteSize },
            manifestPath: manifestURL.path,
            restoreStatePath: restoreStatePath,
            filesModified: filesModified
        )
    }

    private static func writeState(_ state: QuarantineRestoreState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }
}
