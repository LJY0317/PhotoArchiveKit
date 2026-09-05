import Foundation
import SQLite3

public struct CatalogRootBinding: Sendable, Equatable {
    public let rootID: String
    public let url: URL

    public init(rootID: String, url: URL) {
        self.rootID = rootID
        self.url = url.standardizedFileURL
    }
}

public enum CatalogSnapshotOperation: String, Codable, Sendable {
    case export
    case restore
}

public struct CatalogSnapshotReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let operation: CatalogSnapshotOperation
    public let dryRun: Bool
    public let recordCount: Int
    public let rootCount: Int
    public let resourceCount: Int
    public let assetCount: Int
    public let collectionCount: Int
    public let unboundRootCount: Int
    public let snapshotPath: String
    public let catalogPath: String
    public let filesModified: Bool
}

public struct AgentSafeCatalogSnapshotReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let operation: CatalogSnapshotOperation
    public let dryRun: Bool
    public let recordCount: Int
    public let rootCount: Int
    public let resourceCount: Int
    public let assetCount: Int
    public let collectionCount: Int
    public let unboundRootCount: Int
    public let filesModified: Bool

    public init(report: CatalogSnapshotReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        operation = report.operation
        dryRun = report.dryRun
        recordCount = report.recordCount
        rootCount = report.rootCount
        resourceCount = report.resourceCount
        assetCount = report.assetCount
        collectionCount = report.collectionCount
        unboundRootCount = report.unboundRootCount
        filesModified = report.filesModified
    }
}

public enum CatalogSnapshotError: LocalizedError {
    case catalogMissing
    case snapshotMissing
    case outputExists
    case destinationExists
    case unsupportedCatalogSchema
    case malformedSnapshot
    case unsupportedSnapshotSchema(Int)
    case invalidSnapshot(String)
    case unknownRootBinding(String)
    case duplicateRootBinding(String)
    case boundRootMissing(String)
    case boundRootNotDirectory(String)
    case rootMarkerMismatch(String)
    case writeFailed
    case restoreFailed

    public var errorDescription: String? {
        switch self {
        case .catalogMissing:
            return "The source catalog does not exist."
        case .snapshotMissing:
            return "The catalog snapshot does not exist."
        case .outputExists:
            return "The snapshot output path already exists. Refusing to overwrite it."
        case .destinationExists:
            return "The destination catalog already exists. Restore only creates a new catalog."
        case .unsupportedCatalogSchema:
            return "The catalog schema is not supported by this snapshot exporter."
        case .malformedSnapshot:
            return "The JSONL catalog snapshot is malformed."
        case let .unsupportedSnapshotSchema(version):
            return "Unsupported catalog snapshot schema version: \(version)"
        case let .invalidSnapshot(message):
            return "Invalid catalog snapshot: \(message)"
        case let .unknownRootBinding(rootID):
            return "A restore root binding references an unknown root ID: \(rootID)"
        case let .duplicateRootBinding(rootID):
            return "A restore root ID was bound more than once: \(rootID)"
        case let .boundRootMissing(rootID):
            return "A bound restore root does not exist: \(rootID)"
        case let .boundRootNotDirectory(rootID):
            return "A bound restore root is not a directory: \(rootID)"
        case let .rootMarkerMismatch(rootID):
            return "A bound root contains a different .photoarchive-root marker: \(rootID)"
        case .writeFailed:
            return "The catalog snapshot could not be written."
        case .restoreFailed:
            return "The catalog snapshot could not be restored."
        }
    }
}

public enum CatalogSnapshotExporter {
    public static func export(
        catalogURL rawCatalogURL: URL = PhotoArchivePaths.defaultCatalogURL,
        outputURL rawOutputURL: URL
    ) throws -> CatalogSnapshotReport {
        let catalogURL = rawCatalogURL.standardizedFileURL
        let outputURL = rawOutputURL.standardizedFileURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            throw CatalogSnapshotError.catalogMissing
        }
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw CatalogSnapshotError.outputExists
        }

        let database = try SnapshotSQLite(url: catalogURL, readOnly: true)
        guard try database.singleInt("SELECT version FROM schema_info LIMIT 1") == 1 else {
            throw CatalogSnapshotError.unsupportedCatalogSchema
        }

        let parsed = try ParsedSnapshot.read(from: database)
        try parsed.validate()

        let parent = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CatalogSnapshotError.writeFailed
        }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try parsed.writeJSONL(to: handle)
            try handle.close()
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
        } catch {
            try? handle.close()
            throw error
        }

        return parsed.report(
            operation: .export,
            dryRun: false,
            snapshotURL: outputURL,
            catalogURL: catalogURL,
            boundRootIDs: Set(parsed.roots.map(\.rootID)),
            filesModified: true
        )
    }
}

public enum CatalogSnapshotRestorer {
    public static func preflight(
        snapshotURL: URL,
        destinationCatalogURL: URL,
        rootBindings: [CatalogRootBinding] = []
    ) throws -> CatalogSnapshotReport {
        let prepared = try prepare(
            snapshotURL: snapshotURL,
            destinationCatalogURL: destinationCatalogURL,
            rootBindings: rootBindings
        )
        return prepared.snapshot.report(
            operation: .restore,
            dryRun: true,
            snapshotURL: prepared.snapshotURL,
            catalogURL: prepared.destinationURL,
            boundRootIDs: Set(prepared.bindings.keys),
            filesModified: false
        )
    }

    public static func apply(
        snapshotURL: URL,
        destinationCatalogURL: URL,
        rootBindings: [CatalogRootBinding] = []
    ) throws -> CatalogSnapshotReport {
        let prepared = try prepare(
            snapshotURL: snapshotURL,
            destinationCatalogURL: destinationCatalogURL,
            rootBindings: rootBindings
        )
        let fileManager = FileManager.default
        let parent = prepared.destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(
            ".\(prepared.destinationURL.lastPathComponent).restore-\(UUID().uuidString).sqlite3",
            isDirectory: false
        )
        defer {
            try? fileManager.removeItem(at: temporaryURL)
            try? fileManager.removeItem(at: URL(fileURLWithPath: temporaryURL.path + "-wal"))
            try? fileManager.removeItem(at: URL(fileURLWithPath: temporaryURL.path + "-shm"))
        }

        do {
            do {
                let catalog = try SQLiteCatalog(url: temporaryURL)
                _ = catalog.url
            }
            try restore(
                prepared.snapshot,
                to: temporaryURL,
                bindings: prepared.bindings
            )
            try fileManager.moveItem(at: temporaryURL, to: prepared.destinationURL)
        } catch let error as CatalogSnapshotError {
            throw error
        } catch {
            throw CatalogSnapshotError.restoreFailed
        }

        return prepared.snapshot.report(
            operation: .restore,
            dryRun: false,
            snapshotURL: prepared.snapshotURL,
            catalogURL: prepared.destinationURL,
            boundRootIDs: Set(prepared.bindings.keys),
            filesModified: true
        )
    }

    private struct PreparedRestore {
        let snapshotURL: URL
        let destinationURL: URL
        let snapshot: ParsedSnapshot
        let bindings: [String: URL]
    }

    private static func prepare(
        snapshotURL rawSnapshotURL: URL,
        destinationCatalogURL rawDestinationURL: URL,
        rootBindings: [CatalogRootBinding]
    ) throws -> PreparedRestore {
        let snapshotURL = rawSnapshotURL.standardizedFileURL
        let destinationURL = rawDestinationURL.standardizedFileURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            throw CatalogSnapshotError.snapshotMissing
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw CatalogSnapshotError.destinationExists
        }

        let snapshot = try ParsedSnapshot.readJSONL(from: snapshotURL)
        try snapshot.validate()
        let knownRootIDs = Set(snapshot.roots.map(\.rootID))
        let markerByRootID = Dictionary(uniqueKeysWithValues: snapshot.roots.map {
            ($0.rootID, $0.markerKey)
        })
        var bindings: [String: URL] = [:]
        var boundPaths = Set<String>()

        for binding in rootBindings {
            guard knownRootIDs.contains(binding.rootID) else {
                throw CatalogSnapshotError.unknownRootBinding(binding.rootID)
            }
            guard bindings[binding.rootID] == nil else {
                throw CatalogSnapshotError.duplicateRootBinding(binding.rootID)
            }

            let url = binding.url.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw CatalogSnapshotError.boundRootMissing(binding.rootID)
            }
            guard isDirectory.boolValue else {
                throw CatalogSnapshotError.boundRootNotDirectory(binding.rootID)
            }
            guard boundPaths.insert(url.path).inserted else {
                throw CatalogSnapshotError.invalidSnapshot(
                    "two root IDs were bound to the same local directory"
                )
            }

            if let expectedMarker = markerByRootID[binding.rootID] ?? nil,
               let actualMarker = try RootMarkerStore.readIfPresent(at: url),
               actualMarker.markerKey != expectedMarker {
                throw CatalogSnapshotError.rootMarkerMismatch(binding.rootID)
            }
            bindings[binding.rootID] = url
        }

        return PreparedRestore(
            snapshotURL: snapshotURL,
            destinationURL: destinationURL,
            snapshot: snapshot,
            bindings: bindings
        )
    }

    private static func restore(
        _ snapshot: ParsedSnapshot,
        to catalogURL: URL,
        bindings: [String: URL]
    ) throws {
        let database = try SnapshotSQLite(url: catalogURL, readOnly: false)
        try database.execute("PRAGMA journal_mode = DELETE")
        try database.execute("BEGIN IMMEDIATE")
        do {
            let now = Date().timeIntervalSince1970
            let sessionID = "SRESTORE" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            try database.run(
                """
                INSERT INTO scan_sessions
                    (id, started_at, completed_at, status, root_count, resource_count, asset_count, warning_count)
                VALUES (?, ?, ?, 'snapshot_restored', ?, ?, ?, 0)
                """,
                bindings: [
                    .text(sessionID),
                    .double(now),
                    .double(now),
                    .int64(Int64(snapshot.roots.count)),
                    .int64(Int64(snapshot.resources.count)),
                    .int64(Int64(snapshot.assets.count))
                ]
            )

            for root in snapshot.roots {
                let boundURL = bindings[root.rootID]
                let canonicalPath = boundURL?.path ?? "snapshot://\(root.rootID)"
                let label = boundURL?.lastPathComponent ?? root.rootID
                let usageRole = root.usageRole ?? RootUsageRole.legacyDefault(kind: root.kind)
                try database.run(
                    """
                    INSERT INTO source_roots (id, label, kind, canonical_path, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(root.rootID),
                        .text(label),
                        .text(usageRole.sourceKind.rawValue),
                        .text(canonicalPath),
                        .double(now)
                    ]
                )
                try database.run(
                    "INSERT INTO source_root_metadata (root_id, provenance) VALUES (?, ?)",
                    bindings: [.text(root.rootID), .text(root.provenance.rawValue)]
                )
                try database.run(
                    "INSERT INTO root_usage_roles (root_id, role, updated_at) VALUES (?, ?, ?)",
                    bindings: [.text(root.rootID), .text(usageRole.rawValue), .double(now)]
                )
                try database.run(
                    "INSERT INTO root_usage_role_history (root_id, role, changed_at) VALUES (?, ?, ?)",
                    bindings: [.text(root.rootID), .text(usageRole.rawValue), .double(now)]
                )
                if let markerKey = root.markerKey {
                    try database.run(
                        "INSERT INTO root_markers (marker_key, root_id) VALUES (?, ?)",
                        bindings: [.text(markerKey), .text(root.rootID)]
                    )
                }
            }

            for resource in snapshot.resources {
                let fileName = (resource.relativePath as NSString).lastPathComponent
                let fileExtension = (fileName as NSString).pathExtension.lowercased()
                try database.run(
                    """
                    INSERT INTO resources (
                        id, root_id, relative_path, file_name, file_extension, media_kind,
                        byte_size, modified_at, capture_local_time, capture_utc_offset,
                        capture_instant, capture_source, capture_confidence, exact_hash,
                        live_identifier_fingerprint, metadata_probe_failed, last_seen_session
                    ) VALUES (?, ?, ?, ?, ?, ?, 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0, ?)
                    """,
                    bindings: [
                        .text(resource.resourceID),
                        .text(resource.rootID),
                        .text(resource.relativePath),
                        .text(fileName),
                        .text(fileExtension),
                        .text(resource.mediaKind.rawValue),
                        .text(sessionID)
                    ]
                )
                try database.run(
                    """
                    INSERT OR IGNORE INTO resource_locations
                        (resource_id, root_id, relative_path, first_seen_at, last_seen_at, last_seen_session)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(resource.resourceID),
                        .text(resource.rootID),
                        .text(resource.relativePath),
                        .double(now),
                        .double(now),
                        .text(sessionID)
                    ]
                )
            }

            for originalName in snapshot.originalNames {
                try database.run(
                    """
                    INSERT INTO resource_original_names
                        (resource_id, original_file_name, first_seen_session)
                    VALUES (?, ?, ?)
                    """,
                    bindings: [
                        .text(originalName.resourceID),
                        .text(originalName.originalFileName),
                        .text(sessionID)
                    ]
                )
            }

            for location in snapshot.locations {
                try database.run(
                    """
                    INSERT OR IGNORE INTO resource_locations
                        (resource_id, root_id, relative_path, first_seen_at, last_seen_at, last_seen_session)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(location.resourceID),
                        .text(location.rootID),
                        .text(location.relativePath),
                        .double(now),
                        .double(now),
                        .text(sessionID)
                    ]
                )
            }

            for asset in snapshot.assets {
                try database.run(
                    """
                    INSERT INTO logical_assets
                        (id, asset_key, kind, pair_status, created_at, last_seen_session)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(asset.assetID),
                        .text("snapshot:\(asset.assetID)"),
                        .text(asset.kind),
                        asset.pairStatus.map(SnapshotBinding.text) ?? .null,
                        .double(now),
                        .text(sessionID)
                    ]
                )
            }

            for link in snapshot.assetResources {
                try database.run(
                    """
                    INSERT INTO asset_resources (asset_id, resource_id, role, last_seen_session)
                    VALUES (?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(link.assetID),
                        .text(link.resourceID),
                        .text(link.role.rawValue),
                        .text(sessionID)
                    ]
                )
            }

            for collection in snapshot.collections {
                try database.run(
                    """
                    INSERT INTO collections (id, name, parent_id, collection_type, created_at)
                    VALUES (?, ?, NULL, ?, ?)
                    """,
                    bindings: [
                        .text(collection.collectionID),
                        .text(collection.name),
                        .text(collection.collectionType),
                        .double(now)
                    ]
                )
            }
            for collection in snapshot.collections where collection.parentID != nil {
                try database.run(
                    "UPDATE collections SET parent_id = ? WHERE id = ?",
                    bindings: [
                        .text(collection.parentID!),
                        .text(collection.collectionID)
                    ]
                )
            }

            for membership in snapshot.memberships {
                try database.run(
                    """
                    INSERT INTO memberships (asset_id, collection_id, membership_origin)
                    VALUES (?, ?, ?)
                    """,
                    bindings: [
                        .text(membership.assetID),
                        .text(membership.collectionID),
                        .text(membership.membershipOrigin)
                    ]
                )
            }

            for key in snapshot.sourceCollectionKeys {
                try database.run(
                    "INSERT INTO source_collection_keys (source_key, collection_id) VALUES (?, ?)",
                    bindings: [
                        .text(key.rootID + ":" + key.relativeDirectory),
                        .text(key.collectionID)
                    ]
                )
            }

            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }
}

private struct SnapshotHeaderPayload: Codable, Equatable {
    let format: String
}

private struct SnapshotRootPayload: Codable, Equatable {
    let rootID: String
    let kind: SourceRootKind
    let usageRole: RootUsageRole?
    let provenance: SourceProvenance
    let markerKey: String?
}

private struct SnapshotResourcePayload: Codable, Equatable {
    let resourceID: String
    let rootID: String
    let relativePath: String
    let mediaKind: MediaKind
}

private struct SnapshotOriginalNamePayload: Codable, Equatable {
    let resourceID: String
    let originalFileName: String
}

private struct SnapshotLocationPayload: Codable, Equatable {
    let resourceID: String
    let rootID: String
    let relativePath: String
}

private struct SnapshotAssetPayload: Codable, Equatable {
    let assetID: String
    let kind: String
    let pairStatus: String?
}

private struct SnapshotAssetResourcePayload: Codable, Equatable {
    let assetID: String
    let resourceID: String
    let role: ResourceRole
}

private struct SnapshotCollectionPayload: Codable, Equatable {
    let collectionID: String
    let name: String
    let parentID: String?
    let collectionType: String
}

private struct SnapshotMembershipPayload: Codable, Equatable {
    let assetID: String
    let collectionID: String
    let membershipOrigin: String
}

private struct SnapshotSourceCollectionKeyPayload: Codable, Equatable {
    let rootID: String
    let relativeDirectory: String
    let collectionID: String
}

private struct SnapshotEnvelope<Payload: Codable>: Codable {
    let schemaVersion: Int
    let recordType: String
    let payload: Payload

    init(recordType: String, payload: Payload) {
        schemaVersion = 1
        self.recordType = recordType
        self.payload = payload
    }
}

private struct SnapshotRecordProbe: Codable {
    let schemaVersion: Int
    let recordType: String
}

private struct ParsedSnapshot {
    static let format = "photoarchive_catalog_jsonl"

    var headerCount = 0
    var roots: [SnapshotRootPayload] = []
    var resources: [SnapshotResourcePayload] = []
    var originalNames: [SnapshotOriginalNamePayload] = []
    var locations: [SnapshotLocationPayload] = []
    var assets: [SnapshotAssetPayload] = []
    var assetResources: [SnapshotAssetResourcePayload] = []
    var collections: [SnapshotCollectionPayload] = []
    var memberships: [SnapshotMembershipPayload] = []
    var sourceCollectionKeys: [SnapshotSourceCollectionKeyPayload] = []

    var recordCount: Int {
        headerCount
            + roots.count
            + resources.count
            + originalNames.count
            + locations.count
            + assets.count
            + assetResources.count
            + collections.count
            + memberships.count
            + sourceCollectionKeys.count
    }

    static func read(from database: SnapshotSQLite) throws -> ParsedSnapshot {
        var snapshot = ParsedSnapshot()
        snapshot.headerCount = 1

        let hasUsageRoles = try database.singleInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'root_usage_roles'"
        ) == 1
        let rootSQL: String
        let rootColumnCount: Int
        if hasUsageRoles {
            rootSQL = """
            SELECT r.id, r.kind, rur.role, COALESCE(m.provenance, 'unknown'), rm.marker_key
            FROM source_roots r
            LEFT JOIN root_usage_roles rur ON rur.root_id = r.id
            LEFT JOIN source_root_metadata m ON m.root_id = r.id
            LEFT JOIN root_markers rm ON rm.root_id = r.id
            ORDER BY r.id
            """
            rootColumnCount = 5
        } else {
            rootSQL = """
            SELECT r.id, r.kind, NULL, COALESCE(m.provenance, 'unknown'), rm.marker_key
            FROM source_roots r
            LEFT JOIN source_root_metadata m ON m.root_id = r.id
            LEFT JOIN root_markers rm ON rm.root_id = r.id
            ORDER BY r.id
            """
            rootColumnCount = 5
        }
        snapshot.roots = try database.textRows(
            rootSQL,
            columnCount: rootColumnCount
        ).map { row in
            guard let rootID = row[0],
                  let kindRaw = row[1],
                  let kind = SourceRootKind(rawValue: kindRaw),
                  let provenanceRaw = row[3],
                  let provenance = SourceProvenance(rawValue: provenanceRaw)
            else {
                throw CatalogSnapshotError.invalidSnapshot("invalid source root row")
            }
            let usageRole = row[2].flatMap(RootUsageRole.init(rawValue:))
            return SnapshotRootPayload(
                rootID: rootID,
                kind: kind,
                usageRole: usageRole,
                provenance: provenance,
                markerKey: row[4]
            )
        }

        snapshot.resources = try database.textRows(
            "SELECT id, root_id, relative_path, media_kind FROM resources ORDER BY id",
            columnCount: 4
        ).map { row in
            guard let resourceID = row[0],
                  let rootID = row[1],
                  let relativePath = row[2],
                  let mediaKindRaw = row[3],
                  let mediaKind = MediaKind(rawValue: mediaKindRaw)
            else {
                throw CatalogSnapshotError.invalidSnapshot("invalid resource row")
            }
            return SnapshotResourcePayload(
                resourceID: resourceID,
                rootID: rootID,
                relativePath: relativePath,
                mediaKind: mediaKind
            )
        }

        snapshot.originalNames = try database.textRows(
            "SELECT resource_id, original_file_name FROM resource_original_names ORDER BY resource_id",
            columnCount: 2
        ).map { row in
            guard let resourceID = row[0], let name = row[1] else {
                throw CatalogSnapshotError.invalidSnapshot("invalid original-name row")
            }
            return SnapshotOriginalNamePayload(resourceID: resourceID, originalFileName: name)
        }

        snapshot.locations = try database.textRows(
            "SELECT resource_id, root_id, relative_path FROM resource_locations ORDER BY resource_id, root_id, relative_path",
            columnCount: 3
        ).map { row in
            guard let resourceID = row[0], let rootID = row[1], let relativePath = row[2] else {
                throw CatalogSnapshotError.invalidSnapshot("invalid resource-location row")
            }
            return SnapshotLocationPayload(
                resourceID: resourceID,
                rootID: rootID,
                relativePath: relativePath
            )
        }

        snapshot.assets = try database.textRows(
            "SELECT id, kind, pair_status FROM logical_assets ORDER BY id",
            columnCount: 3
        ).map { row in
            guard let assetID = row[0], let kind = row[1] else {
                throw CatalogSnapshotError.invalidSnapshot("invalid logical-asset row")
            }
            return SnapshotAssetPayload(assetID: assetID, kind: kind, pairStatus: row[2])
        }

        snapshot.assetResources = try database.textRows(
            "SELECT asset_id, resource_id, role FROM asset_resources ORDER BY asset_id, resource_id",
            columnCount: 3
        ).map { row in
            guard let assetID = row[0],
                  let resourceID = row[1],
                  let roleRaw = row[2],
                  let role = ResourceRole(rawValue: roleRaw)
            else {
                throw CatalogSnapshotError.invalidSnapshot("invalid asset-resource row")
            }
            return SnapshotAssetResourcePayload(
                assetID: assetID,
                resourceID: resourceID,
                role: role
            )
        }

        snapshot.collections = try database.textRows(
            "SELECT id, name, parent_id, collection_type FROM collections ORDER BY id",
            columnCount: 4
        ).map { row in
            guard let collectionID = row[0], let name = row[1], let type = row[3] else {
                throw CatalogSnapshotError.invalidSnapshot("invalid collection row")
            }
            return SnapshotCollectionPayload(
                collectionID: collectionID,
                name: name,
                parentID: row[2],
                collectionType: type
            )
        }

        snapshot.memberships = try database.textRows(
            "SELECT asset_id, collection_id, membership_origin FROM memberships ORDER BY asset_id, collection_id",
            columnCount: 3
        ).map { row in
            guard let assetID = row[0], let collectionID = row[1], let origin = row[2] else {
                throw CatalogSnapshotError.invalidSnapshot("invalid membership row")
            }
            return SnapshotMembershipPayload(
                assetID: assetID,
                collectionID: collectionID,
                membershipOrigin: origin
            )
        }

        let knownRootIDs = snapshot.roots.map(\.rootID).sorted { $0.count > $1.count }
        snapshot.sourceCollectionKeys = try database.textRows(
            "SELECT source_key, collection_id FROM source_collection_keys ORDER BY source_key",
            columnCount: 2
        ).map { row in
            guard let sourceKey = row[0], let collectionID = row[1],
                  let rootID = knownRootIDs.first(where: { sourceKey.hasPrefix($0 + ":") })
            else {
                throw CatalogSnapshotError.invalidSnapshot("invalid source-collection key")
            }
            return SnapshotSourceCollectionKeyPayload(
                rootID: rootID,
                relativeDirectory: String(sourceKey.dropFirst(rootID.count + 1)),
                collectionID: collectionID
            )
        }
        return snapshot
    }

    static func readJSONL(from url: URL) throws -> ParsedSnapshot {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CatalogSnapshotError.malformedSnapshot
        }
        let decoder = JSONDecoder()
        var snapshot = ParsedSnapshot()
        var sawFirstRecord = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = Data(rawLine.utf8)
            let probe: SnapshotRecordProbe
            do {
                probe = try decoder.decode(SnapshotRecordProbe.self, from: line)
            } catch {
                throw CatalogSnapshotError.malformedSnapshot
            }
            guard probe.schemaVersion == 1 else {
                throw CatalogSnapshotError.unsupportedSnapshotSchema(probe.schemaVersion)
            }
            if !sawFirstRecord, probe.recordType != "header" {
                throw CatalogSnapshotError.invalidSnapshot("the first record must be the header")
            }
            sawFirstRecord = true

            do {
                switch probe.recordType {
                case "header":
                    let envelope = try decoder.decode(
                        SnapshotEnvelope<SnapshotHeaderPayload>.self,
                        from: line
                    )
                    guard envelope.payload.format == format else {
                        throw CatalogSnapshotError.invalidSnapshot("unknown snapshot format")
                    }
                    snapshot.headerCount += 1
                case "root":
                    snapshot.roots.append(try decoder.decode(
                        SnapshotEnvelope<SnapshotRootPayload>.self,
                        from: line
                    ).payload)
                case "resource":
                    snapshot.resources.append(try decoder.decode(
                        SnapshotEnvelope<SnapshotResourcePayload>.self,
                        from: line
                    ).payload)
                case "resource_original_name":
                    snapshot.originalNames.append(try decoder.decode(
                        SnapshotEnvelope<SnapshotOriginalNamePayload>.self,
                        from: line
                    ).payload)
                case "resource_location":
                    snapshot.locations.append(try decoder.decode(
                        SnapshotEnvelope<SnapshotLocationPayload>.self,
                        from: line
                    ).payload)
                case "asset":
                    snapshot.assets.append(try decoder.decode(
                        SnapshotEnvelope<SnapshotAssetPayload>.self,
                        from: line
                    ).payload)
                case "asset_resource":
                    snapshot.assetResources.append(try decoder.decode(
                        SnapshotEnvelope<SnapshotAssetResourcePayload>.self,
                        from: line
                    ).payload)
                case "collection":
                    snapshot.collections.append(try decoder.decode(
                        SnapshotEnvelope<SnapshotCollectionPayload>.self,
                        from: line
                    ).payload)
                case "membership":
                    snapshot.memberships.append(try decoder.decode(
                        SnapshotEnvelope<SnapshotMembershipPayload>.self,
                        from: line
                    ).payload)
                case "source_collection_key":
                    snapshot.sourceCollectionKeys.append(try decoder.decode(
                        SnapshotEnvelope<SnapshotSourceCollectionKeyPayload>.self,
                        from: line
                    ).payload)
                default:
                    throw CatalogSnapshotError.invalidSnapshot(
                        "unknown record type \(probe.recordType)"
                    )
                }
            } catch let error as CatalogSnapshotError {
                throw error
            } catch {
                throw CatalogSnapshotError.malformedSnapshot
            }
        }
        return snapshot
    }

    func validate() throws {
        guard headerCount == 1 else {
            throw CatalogSnapshotError.invalidSnapshot("exactly one header is required")
        }
        let rootIDs = try uniqueSet(roots.map(\.rootID), name: "root ID")
        let resourceIDs = try uniqueSet(resources.map(\.resourceID), name: "resource ID")
        let assetIDs = try uniqueSet(assets.map(\.assetID), name: "asset ID")
        let collectionIDs = try uniqueSet(collections.map(\.collectionID), name: "collection ID")
        _ = try uniqueSet(roots.compactMap(\.markerKey), name: "root marker key")
        _ = try uniqueSet(
            resources.map { compositeKey($0.rootID, $0.relativePath) },
            name: "root/resource path"
        )
        _ = try uniqueSet(originalNames.map(\.resourceID), name: "resource original-name key")
        _ = try uniqueSet(
            locations.map { compositeKey($0.resourceID, $0.rootID, $0.relativePath) },
            name: "resource location key"
        )
        _ = try uniqueSet(
            assetResources.map { compositeKey($0.assetID, $0.resourceID) },
            name: "asset-resource key"
        )
        _ = try uniqueSet(
            memberships.map { compositeKey($0.assetID, $0.collectionID) },
            name: "membership key"
        )
        _ = try uniqueSet(
            sourceCollectionKeys.map { compositeKey($0.rootID, $0.relativeDirectory) },
            name: "source collection key"
        )
        _ = try uniqueSet(
            sourceCollectionKeys.map(\.collectionID),
            name: "source collection target"
        )

        for root in roots {
            if let usageRole = root.usageRole, usageRole.sourceKind != root.kind {
                throw CatalogSnapshotError.invalidSnapshot("root usage role conflicts with its kind")
            }
        }

        for resource in resources {
            guard rootIDs.contains(resource.rootID) else {
                throw CatalogSnapshotError.invalidSnapshot("resource references an unknown root")
            }
            try validateRelativePath(resource.relativePath)
        }
        for originalName in originalNames {
            guard resourceIDs.contains(originalName.resourceID),
                  !originalName.originalFileName.isEmpty,
                  !originalName.originalFileName.contains("/"),
                  originalName.originalFileName != ".",
                  originalName.originalFileName != ".."
            else {
                throw CatalogSnapshotError.invalidSnapshot("invalid original filename reference")
            }
        }
        for location in locations {
            guard resourceIDs.contains(location.resourceID), rootIDs.contains(location.rootID) else {
                throw CatalogSnapshotError.invalidSnapshot("resource location has an unknown reference")
            }
            try validateRelativePath(location.relativePath)
        }
        for asset in assets {
            if let pairStatus = asset.pairStatus,
               LivePhotoOccurrenceStatus(rawValue: pairStatus) == nil {
                throw CatalogSnapshotError.invalidSnapshot("asset has an unknown pair status")
            }
        }
        for link in assetResources {
            guard assetIDs.contains(link.assetID), resourceIDs.contains(link.resourceID) else {
                throw CatalogSnapshotError.invalidSnapshot("asset-resource link has an unknown reference")
            }
        }
        for collection in collections {
            if let parentID = collection.parentID, !collectionIDs.contains(parentID) {
                throw CatalogSnapshotError.invalidSnapshot("collection has an unknown parent")
            }
        }
        var parentByCollectionID: [String: String] = [:]
        for collection in collections {
            if let parentID = collection.parentID {
                parentByCollectionID[collection.collectionID] = parentID
            }
        }
        for collectionID in collectionIDs {
            var cursor: String? = collectionID
            var visited = Set<String>()
            while let current = cursor {
                guard visited.insert(current).inserted else {
                    throw CatalogSnapshotError.invalidSnapshot("collection hierarchy contains a cycle")
                }
                cursor = parentByCollectionID[current]
            }
        }
        for membership in memberships {
            guard assetIDs.contains(membership.assetID),
                  collectionIDs.contains(membership.collectionID)
            else {
                throw CatalogSnapshotError.invalidSnapshot("membership has an unknown reference")
            }
        }
        for key in sourceCollectionKeys {
            guard rootIDs.contains(key.rootID), collectionIDs.contains(key.collectionID) else {
                throw CatalogSnapshotError.invalidSnapshot("source collection key has an unknown reference")
            }
            try validateRelativePath(key.relativeDirectory, allowEmpty: true)
        }
    }

    func writeJSONL(to handle: FileHandle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        func write<Payload: Codable>(_ recordType: String, _ payload: Payload) throws {
            let envelope = SnapshotEnvelope(recordType: recordType, payload: payload)
            var data = try encoder.encode(envelope)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        }

        try write("header", SnapshotHeaderPayload(format: Self.format))
        for value in roots { try write("root", value) }
        for value in resources { try write("resource", value) }
        for value in originalNames { try write("resource_original_name", value) }
        for value in locations { try write("resource_location", value) }
        for value in assets { try write("asset", value) }
        for value in assetResources { try write("asset_resource", value) }
        for value in collections { try write("collection", value) }
        for value in memberships { try write("membership", value) }
        for value in sourceCollectionKeys { try write("source_collection_key", value) }
    }

    func report(
        operation: CatalogSnapshotOperation,
        dryRun: Bool,
        snapshotURL: URL,
        catalogURL: URL,
        boundRootIDs: Set<String>,
        filesModified: Bool
    ) -> CatalogSnapshotReport {
        CatalogSnapshotReport(
            schemaVersion: 1,
            operation: operation,
            dryRun: dryRun,
            recordCount: recordCount,
            rootCount: roots.count,
            resourceCount: resources.count,
            assetCount: assets.count,
            collectionCount: collections.count,
            unboundRootCount: roots.count { !boundRootIDs.contains($0.rootID) },
            snapshotPath: snapshotURL.path,
            catalogPath: catalogURL.path,
            filesModified: filesModified
        )
    }

    private func uniqueSet(_ values: [String], name: String) throws -> Set<String> {
        var result = Set<String>()
        for value in values {
            guard !value.isEmpty, result.insert(value).inserted else {
                throw CatalogSnapshotError.invalidSnapshot("duplicate or empty \(name)")
            }
        }
        return result
    }

    private func validateRelativePath(_ value: String, allowEmpty: Bool = false) throws {
        if value.isEmpty {
            if allowEmpty { return }
            throw CatalogSnapshotError.invalidSnapshot("empty relative path")
        }
        guard !value.hasPrefix("/"), !value.contains("\0") else {
            throw CatalogSnapshotError.invalidSnapshot("absolute or malformed path in snapshot")
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw CatalogSnapshotError.invalidSnapshot("path escapes its root")
        }
    }

    private func compositeKey(_ values: String...) -> String {
        values.joined(separator: "\u{1F}")
    }
}

private enum SnapshotBinding {
    case text(String)
    case int64(Int64)
    case double(Double)
    case null
}

private final class SnapshotSQLite {
    private var database: OpaquePointer?
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, readOnly: Bool) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE))
            | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            throw CatalogSnapshotError.restoreFailed
        }
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func singleInt(_ sql: String) throws -> Int64? {
        guard let database else { throw CatalogSnapshotError.restoreFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CatalogSnapshotError.restoreFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    func textRows(_ sql: String, columnCount: Int) throws -> [[String?]] {
        guard let database else { throw CatalogSnapshotError.restoreFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CatalogSnapshotError.restoreFailed
        }
        defer { sqlite3_finalize(statement) }

        var rows: [[String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw CatalogSnapshotError.restoreFailed }
            var row: [String?] = []
            row.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                if sqlite3_column_type(statement, Int32(index)) == SQLITE_NULL {
                    row.append(nil)
                } else if let text = sqlite3_column_text(statement, Int32(index)) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    func execute(_ sql: String) throws {
        guard let database else { throw CatalogSnapshotError.restoreFailed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            sqlite3_free(errorMessage)
            throw CatalogSnapshotError.restoreFailed
        }
    }

    func run(_ sql: String, bindings: [SnapshotBinding]) throws {
        guard let database else { throw CatalogSnapshotError.restoreFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CatalogSnapshotError.restoreFailed
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .text(value):
                result = sqlite3_bind_text(statement, index, value, -1, transientDestructor)
            case let .int64(value):
                result = sqlite3_bind_int64(statement, index, value)
            case let .double(value):
                result = sqlite3_bind_double(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw CatalogSnapshotError.restoreFailed }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CatalogSnapshotError.restoreFailed
        }
    }
}
