import Foundation
import SQLite3

public enum PhotoArchivePaths {
    public static var applicationSupportDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PhotoArchiveKit", isDirectory: true)
    }

    public static var defaultCatalogURL: URL {
        applicationSupportDirectoryURL.appendingPathComponent("catalog.sqlite3", isDirectory: false)
    }

    public static var defaultOperationsDirectoryURL: URL {
        applicationSupportDirectoryURL.appendingPathComponent("operations", isDirectory: true)
    }
}

enum CatalogError: LocalizedError {
    case cannotOpen(path: String, message: String)
    case sqlite(message: String, sql: String)
    case invalidCatalogValue(String)

    var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, message):
            return "Could not open catalog at \(path): \(message)"
        case let .sqlite(message, sql):
            return "SQLite error: \(message) [\(sql)]"
        case let .invalidCatalogValue(message):
            return "Invalid catalog value: \(message)"
        }
    }
}

struct CatalogPersistenceResult {
    let liveAssetIDs: [Data: String]
    let duplicateGroupIDs: [Data: String]
}

struct ArchiveCopyCatalogEvidence {
    let resourceID: String
    let rootID: String
    let relativePath: String
    let assetID: String
    let role: ResourceRole
    let byteSize: Int64
    let exactHash: Data
}

struct CachedExactHashEvidence {
    let byteSize: Int64
    let modifiedAt: Date?
    let fileSystemIdentifier: String?
    let exactHash: Data
}

private struct CachedExactHashIndex {
    var byRelativePath: [String: CachedExactHashEvidence] = [:]
    var byFileSystemIdentifier: [String: CachedExactHashEvidence] = [:]
}

struct CachedMetadataEvidence {
    let mediaKind: MediaKind
    let byteSize: Int64
    let modifiedAt: Date?
    let fileSystemIdentifier: String?
    let captureTime: CaptureTime?
    let identifierFingerprint: Data?
    let timedMetadataStatus: LivePhotoTimedMetadataStatus
    let metadataProbeFailed: Bool
}

private struct CachedMetadataIndex {
    var byRelativePath: [String: CachedMetadataEvidence] = [:]
    var byFileSystemIdentifier: [String: CachedMetadataEvidence] = [:]
}

struct DuplicateReviewExpectedResourceEvidence {
    let resourceID: String
    let rootID: String
    let relativePath: String
    let byteSize: Int64
    let modifiedAt: Date?
    let fileSystemIdentifier: String?
}

struct RootRegistryRow {
    let rootID: String
    let label: String
    let kind: SourceRootKind
    let usageRole: RootUsageRole
    let provenance: SourceProvenance
    let canonicalPath: String
    let state: RootRegistrationState
    let currentResourceCount: Int
}

private struct CachedScanSessionRow {
    let sessionID: String
    let startedAt: Date
    let completedAt: Date
    let rootCount: Int
    let resourceCount: Int
    let assetCount: Int
    let warningCount: Int
}

private struct CachedScanResourceRow {
    let report: ScannedResourceReport
    let exactHash: Data?
    let timedMetadataStatus: LivePhotoTimedMetadataStatus?
    let metadataProbeFailed: Bool
}

final class SQLiteCatalog {
    let url: URL
    private var database: OpaquePointer?
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        self.url = url.standardizedFileURL
        let parent = self.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(self.url.path, &database, flags, nil)
        guard result == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            database = nil
            throw CatalogError.cannotOpen(path: self.url.path, message: message)
        }

        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try migrate()
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func liveIdentifierPrivacyKey() throws -> Data {
        let keyName = "live_identifier_hmac_key_v1"
        if let stored = try setting(keyName) {
            guard let data = Data(base64Encoded: stored), data.count >= 32 else {
                throw CatalogError.invalidCatalogValue("The Live Photo privacy key is malformed.")
            }
            return data
        }

        var generator = SystemRandomNumberGenerator()
        let key = Data((0..<32).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
        try setSetting(keyName, value: key.base64EncodedString())
        return key
    }

    func resolveRoot(_ input: ScanRoot, markerKey: String? = nil) throws -> RootDescriptor {
        let canonicalURL = input.url.resolvingSymlinksInPath().standardizedFileURL
        let path = canonicalURL.path

        if let markerKey,
           let markerRootID = try queryText(
               "SELECT root_id FROM root_markers WHERE marker_key = ?",
               bindings: [.text(markerKey)]
           ) {
            let usageRole = try resolvedUsageRole(rootID: markerRootID, inputKind: input.kind)
            try run(
                "UPDATE source_roots SET label = ?, kind = ?, canonical_path = ? WHERE id = ?",
                bindings: [.text(input.label), .text(usageRole.sourceKind.rawValue), .text(path), .text(markerRootID)]
            )
            try upsertRootMetadata(rootID: markerRootID, provenance: input.provenance)
            return RootDescriptor(
                id: markerRootID,
                label: input.label,
                kind: usageRole.sourceKind,
                usageRole: usageRole,
                provenance: input.provenance,
                url: canonicalURL,
                markerKey: markerKey
            )
        }

        if let existingID = try queryText(
            "SELECT id FROM source_roots WHERE canonical_path = ?",
            bindings: [.text(path)]
        ) {
            let usageRole = try resolvedUsageRole(rootID: existingID, inputKind: input.kind)
            try run(
                "UPDATE source_roots SET label = ?, kind = ? WHERE id = ?",
                bindings: [.text(input.label), .text(usageRole.sourceKind.rawValue), .text(existingID)]
            )
            try upsertRootMetadata(rootID: existingID, provenance: input.provenance)
            if let markerKey {
                try upsertRootMarker(markerKey: markerKey, rootID: existingID)
            }
            return RootDescriptor(
                id: existingID,
                label: input.label,
                kind: usageRole.sourceKind,
                usageRole: usageRole,
                provenance: input.provenance,
                url: canonicalURL,
                markerKey: markerKey
            )
        }

        let id = opaqueID(prefix: "R")
        try run(
            "INSERT INTO source_roots (id, label, kind, canonical_path, created_at) VALUES (?, ?, ?, ?, ?)",
            bindings: [
                .text(id),
                .text(input.label),
                .text(input.kind.rawValue),
                .text(path),
                .double(Date().timeIntervalSince1970)
            ]
        )
        try upsertRootMetadata(rootID: id, provenance: input.provenance)
        if let markerKey {
            try upsertRootMarker(markerKey: markerKey, rootID: id)
        }
        let usageRole = try ensureRootUsageRole(
            rootID: id,
            defaultRole: .defaultForNewRoot(kind: input.kind)
        )
        if usageRole.sourceKind != input.kind {
            try run(
                "UPDATE source_roots SET kind = ? WHERE id = ?",
                bindings: [.text(usageRole.sourceKind.rawValue), .text(id)]
            )
        }
        return RootDescriptor(
            id: id,
            label: input.label,
            kind: usageRole.sourceKind,
            usageRole: usageRole,
            provenance: input.provenance,
            url: canonicalURL,
            markerKey: markerKey
        )
    }

    private func upsertRootMarker(markerKey: String, rootID: String) throws {
        try run(
            """
            INSERT INTO root_markers (marker_key, root_id)
            VALUES (?, ?)
            ON CONFLICT(marker_key) DO UPDATE SET root_id = excluded.root_id
            """,
            bindings: [.text(markerKey), .text(rootID)]
        )
    }

    private func upsertRootMetadata(rootID: String, provenance: SourceProvenance) throws {
        try run(
            """
            INSERT INTO source_root_metadata (root_id, provenance)
            VALUES (?, ?)
            ON CONFLICT(root_id) DO UPDATE SET provenance = excluded.provenance
            """,
            bindings: [.text(rootID), .text(provenance.rawValue)]
        )
    }

    private func ensureRootUsageRole(
        rootID: String,
        defaultRole: RootUsageRole
    ) throws -> RootUsageRole {
        if let raw = try queryText(
            "SELECT role FROM root_usage_roles WHERE root_id = ?",
            bindings: [.text(rootID)]
        ), let role = RootUsageRole(rawValue: raw) {
            return role
        }

        let now = Date().timeIntervalSince1970
        try run(
            "INSERT INTO root_usage_roles (root_id, role, updated_at) VALUES (?, ?, ?)",
            bindings: [.text(rootID), .text(defaultRole.rawValue), .double(now)]
        )
        try run(
            "INSERT INTO root_usage_role_history (root_id, role, changed_at) VALUES (?, ?, ?)",
            bindings: [.text(rootID), .text(defaultRole.rawValue), .double(now)]
        )
        return defaultRole
    }

    private func resolvedUsageRole(
        rootID: String,
        inputKind: SourceRootKind
    ) throws -> RootUsageRole {
        let registrationState = try queryText(
            "SELECT state FROM root_registrations WHERE root_id = ?",
            bindings: [.text(rootID)]
        )
        if registrationState != nil {
            return try ensureRootUsageRole(
                rootID: rootID,
                defaultRole: .legacyDefault(kind: inputKind)
            )
        }

        let desiredRole = RootUsageRole.defaultForNewRoot(kind: inputKind)
        let currentRole = try queryText(
            "SELECT role FROM root_usage_roles WHERE root_id = ?",
            bindings: [.text(rootID)]
        ).flatMap(RootUsageRole.init(rawValue:))
        if currentRole == desiredRole {
            return desiredRole
        }
        if currentRole == nil {
            return try ensureRootUsageRole(rootID: rootID, defaultRole: desiredRole)
        }
        try setRootUsageRole(rootID: rootID, role: desiredRole)
        return desiredRole
    }

    func beginScan(startedAt: Date, rootCount: Int) throws -> String {
        let id = opaqueID(prefix: "S")
        try run(
            "INSERT INTO scan_sessions (id, started_at, status, root_count) VALUES (?, ?, 'running', ?)",
            bindings: [
                .text(id),
                .double(startedAt.timeIntervalSince1970),
                .int64(Int64(rootCount))
            ]
        )
        return id
    }

    func recoverInterruptedScans(completedAt: Date) throws -> Int {
        try run(
            """
            UPDATE scan_sessions
            SET completed_at = ?, status = 'interrupted'
            WHERE status = 'running'
            """,
            bindings: [.double(completedAt.timeIntervalSince1970)]
        )
        return Int(sqlite3_changes(database))
    }

    func finishScan(
        sessionID: String,
        completedAt: Date,
        summary: ScanSummary
    ) throws {
        try run(
            """
            UPDATE scan_sessions
            SET completed_at = ?, status = 'complete', resource_count = ?, asset_count = ?, warning_count = ?
            WHERE id = ?
            """,
            bindings: [
                .double(completedAt.timeIntervalSince1970),
                .int64(Int64(summary.resourceCount)),
                .int64(Int64(summary.logicalAssetCount)),
                .int64(Int64(summary.warningCount)),
                .text(sessionID)
            ]
        )
    }

    func failScan(sessionID: String, completedAt: Date) {
        try? run(
            "UPDATE scan_sessions SET completed_at = ?, status = 'failed' WHERE id = ?",
            bindings: [
                .double(completedAt.timeIntervalSince1970),
                .text(sessionID)
            ]
        )
    }

    func persistResources(
        sessionID: String,
        resources: inout [ProbedResource]
    ) throws {
        for index in resources.indices {
            let pathMatch = try queryText(
                "SELECT id FROM resources WHERE root_id = ? AND relative_path = ?",
                bindings: [
                    .text(resources[index].root.id),
                    .text(resources[index].relativePath)
                ]
            )
            let fileSystemMatch: String?
            if pathMatch == nil, let fileSystemIdentifier = resources[index].fileSystemIdentifier {
                fileSystemMatch = try queryText(
                    "SELECT resource_id FROM resource_file_ids WHERE root_id = ? AND filesystem_identifier = ?",
                    bindings: [
                        .text(resources[index].root.id),
                        .text(fileSystemIdentifier)
                    ]
                )
            } else {
                fileSystemMatch = nil
            }
            let existingID = pathMatch ?? fileSystemMatch
            let resourceID = existingID ?? opaqueID(prefix: "F")

            if existingID == nil {
                try run(
                    """
                    INSERT INTO resources (
                        id, root_id, relative_path, file_name, file_extension, media_kind,
                        byte_size, modified_at, added_at, capture_local_time, capture_utc_offset,
                        capture_instant, capture_source, capture_confidence, exact_hash,
                        live_identifier_fingerprint, metadata_probe_failed, last_seen_session
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: resourceBindings(
                        id: resourceID,
                        resource: resources[index],
                        sessionID: sessionID
                    )
                )
            } else {
                try run(
                    """
                    UPDATE resources SET
                        relative_path = ?, file_name = ?, file_extension = ?, media_kind = ?, byte_size = ?,
                        modified_at = ?, added_at = ?, capture_local_time = ?, capture_utc_offset = ?,
                        capture_instant = ?, capture_source = ?, capture_confidence = ?,
                        exact_hash = ?, live_identifier_fingerprint = ?, metadata_probe_failed = ?,
                        last_seen_session = ?
                    WHERE id = ?
                    """,
                    bindings: updateResourceBindings(
                        id: resourceID,
                        resource: resources[index],
                        sessionID: sessionID
                    )
                )
            }

            try run(
                """
                INSERT OR IGNORE INTO resource_original_names (resource_id, original_file_name, first_seen_session)
                VALUES (?, ?, ?)
                """,
                bindings: [
                    .text(resourceID),
                    .text(resources[index].fileName),
                    .text(sessionID)
                ]
            )

            if let fileSystemIdentifier = resources[index].fileSystemIdentifier {
                try run(
                    """
                    INSERT INTO resource_file_ids (resource_id, root_id, filesystem_identifier)
                    VALUES (?, ?, ?)
                    ON CONFLICT(resource_id) DO UPDATE SET
                        root_id = excluded.root_id,
                        filesystem_identifier = excluded.filesystem_identifier
                    """,
                    bindings: [
                        .text(resourceID),
                        .text(resources[index].root.id),
                        .text(fileSystemIdentifier)
                    ]
                )
            }

            try run(
                """
                INSERT INTO resource_live_metadata_status (resource_id, status, last_seen_session)
                VALUES (?, ?, ?)
                ON CONFLICT(resource_id) DO UPDATE SET
                    status = excluded.status,
                    last_seen_session = excluded.last_seen_session
                """,
                bindings: [
                    .text(resourceID),
                    .text(resources[index].livePhotoTimedMetadataStatus.rawValue),
                    .text(sessionID)
                ]
            )
            try run(
                """
                INSERT INTO resource_metadata_cache_state (resource_id, probe_version, last_seen_session)
                VALUES (?, ?, ?)
                ON CONFLICT(resource_id) DO UPDATE SET
                    probe_version = excluded.probe_version,
                    last_seen_session = excluded.last_seen_session
                """,
                bindings: [
                    .text(resourceID),
                    .int64(Int64(MetadataProbe.cacheVersion)),
                    .text(sessionID)
                ]
            )
            try run(
                """
                INSERT INTO resource_locations (
                    resource_id, root_id, relative_path, first_seen_at, last_seen_at, last_seen_session
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(resource_id, root_id, relative_path) DO UPDATE SET
                    last_seen_at = excluded.last_seen_at,
                    last_seen_session = excluded.last_seen_session
                """,
                bindings: [
                    .text(resourceID),
                    .text(resources[index].root.id),
                    .text(resources[index].relativePath),
                    .double(Date().timeIntervalSince1970),
                    .double(Date().timeIntervalSince1970),
                    .text(sessionID)
                ]
            )

            resources[index].persistentResourceID = resourceID
        }
    }

    func persistAssets(
        sessionID: String,
        resources: inout [ProbedResource]
    ) throws -> [Data: String] {
        var previousAssetIDByResourceID: [String: String] = [:]
        for resource in resources where resource.persistentResourceID != nil {
            let resourceID = resource.persistentResourceID!
            if let previousAssetID = try queryText(
                """
                SELECT ar.asset_id
                FROM asset_resources ar
                JOIN logical_assets la ON la.id = ar.asset_id
                WHERE ar.resource_id = ? AND la.asset_key LIKE 'snapshot:%'
                LIMIT 1
                """,
                bindings: [.text(resourceID)]
            ) {
                previousAssetIDByResourceID[resourceID] = previousAssetID
            }
            try run(
                "DELETE FROM asset_resources WHERE resource_id = ?",
                bindings: [.text(resourceID)]
            )
        }

        var liveAssetIDs: [Data: String] = [:]
        let liveGroups = Dictionary(grouping: resources.indices.filter {
            resources[$0].identifierFingerprint != nil
                && (resources[$0].mediaKind == .image || resources[$0].mediaKind == .video)
        }) { resources[$0].identifierFingerprint! }

        for (fingerprint, indices) in liveGroups {
            let assetKey = "live:\(fingerprint.base64EncodedString())"
            let previousAssetIDs = Set(indices.compactMap { index -> String? in
                guard let resourceID = resources[index].persistentResourceID else { return nil }
                return previousAssetIDByResourceID[resourceID]
            })
            let assetID = try ensureAsset(
                assetKey: assetKey,
                kind: "live_photo",
                pairStatus: aggregatePairStatus(indices: indices, resources: resources).rawValue,
                sessionID: sessionID,
                preferredID: previousAssetIDs.count == 1 ? previousAssetIDs.first : nil
            )
            liveAssetIDs[fingerprint] = assetID

            for index in indices {
                resources[index].persistentAssetID = assetID
                try link(
                    assetID: assetID,
                    resourceID: resources[index].persistentResourceID!,
                    role: AssetAssembler.role(for: resources[index]),
                    sessionID: sessionID
                )
            }
        }

        for index in resources.indices where resources[index].identifierFingerprint == nil {
            guard resources[index].mediaKind != .sidecar,
                  let resourceID = resources[index].persistentResourceID
            else {
                continue
            }

            let kind = resources[index].mediaKind == .image ? "image" : "video"
            let assetKey: String
            if let exactHash = resources[index].exactHash {
                assetKey = "exact:\(exactHash.base64EncodedString())"
            } else {
                assetKey = "resource:\(resourceID)"
            }
            let assetID = try ensureAsset(
                assetKey: assetKey,
                kind: kind,
                pairStatus: nil,
                sessionID: sessionID,
                preferredID: previousAssetIDByResourceID[resourceID]
            )
            resources[index].persistentAssetID = assetID
            try link(
                assetID: assetID,
                resourceID: resourceID,
                role: AssetAssembler.role(for: resources[index]),
                sessionID: sessionID
            )
        }

        return liveAssetIDs
    }

    func persistSidecarAssociations(
        sessionID: String,
        resources: [ProbedResource],
        associations: [SidecarAssociationCandidate]
    ) throws -> [RecognizedSidecarReport] {
        for resource in resources where resource.mediaKind == .sidecar {
            guard let resourceID = resource.persistentResourceID else { continue }
            try run(
                "DELETE FROM sidecar_links WHERE sidecar_resource_id = ?",
                bindings: [.text(resourceID)]
            )
        }

        var reports: [RecognizedSidecarReport] = []
        for association in associations {
            guard resources.indices.contains(association.sidecarIndex),
                  resources.indices.contains(association.targetIndex)
            else {
                continue
            }
            let sidecar = resources[association.sidecarIndex]
            let target = resources[association.targetIndex]
            guard let sidecarResourceID = sidecar.persistentResourceID,
                  let targetAssetID = target.persistentAssetID,
                  sidecar.root.id == target.root.id
            else {
                continue
            }
            try run(
                """
                INSERT INTO sidecar_links (
                    sidecar_resource_id, target_asset_id, kind, last_seen_session
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(sidecar_resource_id) DO UPDATE SET
                    target_asset_id = excluded.target_asset_id,
                    kind = excluded.kind,
                    last_seen_session = excluded.last_seen_session
                """,
                bindings: [
                    .text(sidecarResourceID),
                    .text(targetAssetID),
                    .text(association.kind.rawValue),
                    .text(sessionID)
                ]
            )
            reports.append(RecognizedSidecarReport(
                sidecarResourceID: sidecarResourceID,
                targetAssetID: targetAssetID,
                rootID: sidecar.root.id,
                sidecarRelativePath: sidecar.relativePath,
                targetRelativePath: target.relativePath,
                kind: association.kind
            ))
        }
        return reports.sorted {
            ($0.rootID, $0.sidecarRelativePath) < ($1.rootID, $1.sidecarRelativePath)
        }
    }

    func persistSourceFolderCollections(
        resources: [ProbedResource],
        roots: [RootDescriptor]
    ) throws -> Set<String> {
        let capturedRootIDs = Set(roots.compactMap { root -> String? in
            if root.provenance == .googleTakeout || root.kind == .archive {
                return root.id
            }
            return nil
        })
        let archiveRootIDs = Set(roots.filter { $0.kind == .archive }.map(\.id))
        var currentArchiveSourceKeys = Dictionary(
            uniqueKeysWithValues: archiveRootIDs.map { ($0, Set<String>()) }
        )

        for rootID in archiveRootIDs {
            try run(
                """
                DELETE FROM memberships
                WHERE membership_origin = 'user_archive_folder'
                  AND collection_id IN (
                    SELECT sck.collection_id
                    FROM source_collection_keys sck
                    JOIN collections c ON c.id = sck.collection_id
                    WHERE sck.source_key LIKE ? AND c.collection_type = 'user_archive_folder'
                  )
                """,
                bindings: [.text(rootID + ":%")]
            )
        }

        for resource in resources {
            let collectionType: String
            let membershipOrigin: String
            if resource.root.provenance == .googleTakeout {
                collectionType = "google_takeout_source_folder"
                membershipOrigin = "google_takeout_source_folder"
            } else if resource.root.kind == .archive {
                collectionType = "user_archive_folder"
                membershipOrigin = "user_archive_folder"
            } else {
                continue
            }

            guard resource.mediaKind == .image || resource.mediaKind == .video,
                  let assetID = resource.persistentAssetID
            else {
                continue
            }

            let directory = (resource.relativePath as NSString).deletingLastPathComponent
            guard !directory.isEmpty else { continue }

            var parentCollectionID: String?
            var relativeDirectory = ""
            for component in directory.split(separator: "/").map(String.init) where !component.isEmpty {
                relativeDirectory = relativeDirectory.isEmpty
                    ? component
                    : relativeDirectory + "/" + component
                let sourceKey = resource.root.id + ":" + relativeDirectory
                if resource.root.kind == .archive {
                    currentArchiveSourceKeys[resource.root.id, default: []].insert(sourceKey)
                }

                let collectionID: String
                if let existing = try queryText(
                    "SELECT collection_id FROM source_collection_keys WHERE source_key = ?",
                    bindings: [.text(sourceKey)]
                ) {
                    collectionID = existing
                } else {
                    collectionID = opaqueID(prefix: "C")
                    try run(
                        """
                        INSERT INTO collections (id, name, parent_id, collection_type, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(collectionID),
                            .text(component),
                            parentCollectionID.map(SQLiteBinding.text) ?? .null,
                            .text(collectionType),
                            .double(Date().timeIntervalSince1970)
                        ]
                    )
                    try run(
                        "INSERT INTO source_collection_keys (source_key, collection_id) VALUES (?, ?)",
                        bindings: [.text(sourceKey), .text(collectionID)]
                    )
                }

                parentCollectionID = collectionID
            }

            if let collectionID = parentCollectionID {
                try run(
                    """
                    INSERT INTO memberships (asset_id, collection_id, membership_origin)
                    VALUES (?, ?, ?)
                    ON CONFLICT(asset_id, collection_id) DO UPDATE SET
                        membership_origin = excluded.membership_origin
                    """,
                    bindings: [.text(assetID), .text(collectionID), .text(membershipOrigin)]
                )
            }
        }

        for rootID in archiveRootIDs {
            try pruneStaleUserArchiveCollections(
                rootID: rootID,
                currentSourceKeys: currentArchiveSourceKeys[rootID] ?? []
            )
        }

        return capturedRootIDs
    }

    private func pruneStaleUserArchiveCollections(
        rootID: String,
        currentSourceKeys: Set<String>
    ) throws {
        let existing: [(sourceKey: String, collectionID: String)] = try withStatement(
            """
            SELECT sck.source_key, sck.collection_id
            FROM source_collection_keys sck
            JOIN collections c ON c.id = sck.collection_id
            WHERE sck.source_key LIKE ? AND c.collection_type = 'user_archive_folder'
            """,
            bindings: [.text(rootID + ":%")]
        ) { statement in
            var rows: [(String, String)] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let sourceText = sqlite3_column_text(statement, 0),
                      let collectionText = sqlite3_column_text(statement, 1)
                else {
                    throw sqliteError(sql: "SELECT user archive source collections")
                }
                rows.append((String(cString: sourceText), String(cString: collectionText)))
            }
            return rows
        }

        let stale = existing
            .filter { !currentSourceKeys.contains($0.sourceKey) }
            .sorted {
                $0.sourceKey.split(separator: "/").count
                    > $1.sourceKey.split(separator: "/").count
            }
        for row in stale {
            try run(
                "DELETE FROM source_collection_keys WHERE source_key = ?",
                bindings: [.text(row.sourceKey)]
            )
            try run(
                "DELETE FROM collections WHERE id = ?",
                bindings: [.text(row.collectionID)]
            )
        }
    }

    func reuseCachedMetadata(
        pendingFiles: [PendingFile],
        probeVersion: Int
    ) throws -> (resources: [ProbedResource], remaining: [PendingFile]) {
        let rootIDs = Set(pendingFiles.map { $0.root.id })
        var indexByRootID: [String: CachedMetadataIndex] = [:]
        indexByRootID.reserveCapacity(rootIDs.count)
        for rootID in rootIDs {
            indexByRootID[rootID] = try cachedMetadataIndex(
                rootID: rootID,
                probeVersion: probeVersion
            )
        }

        var reused: [ProbedResource] = []
        var remaining: [PendingFile] = []
        reused.reserveCapacity(pendingFiles.count)
        remaining.reserveCapacity(pendingFiles.count)

        for pending in pendingFiles {
            guard let rootIndex = indexByRootID[pending.root.id] else {
                remaining.append(pending)
                continue
            }

            let pathEvidence = rootIndex.byRelativePath[pending.relativePath]
            let evidence: CachedMetadataEvidence?
            if let currentID = pending.fileSystemIdentifier,
               let pathEvidence,
               let cachedID = pathEvidence.fileSystemIdentifier,
               cachedID != currentID {
                evidence = rootIndex.byFileSystemIdentifier[currentID]
            } else if let pathEvidence {
                evidence = pathEvidence
            } else if let currentID = pending.fileSystemIdentifier {
                evidence = rootIndex.byFileSystemIdentifier[currentID]
            } else {
                evidence = nil
            }

            guard let evidence,
                  !evidence.metadataProbeFailed,
                  evidence.captureTime?.source != .googleTakeoutPhotoTakenTime,
                  evidence.mediaKind == pending.type.mediaKind,
                  evidence.byteSize == pending.byteSize,
                  modificationTimesMatch(evidence.modifiedAt, pending.modifiedAt)
            else {
                remaining.append(pending)
                continue
            }

            if let cachedID = evidence.fileSystemIdentifier,
               let currentID = pending.fileSystemIdentifier,
               cachedID != currentID {
                remaining.append(pending)
                continue
            }

            reused.append(ProbedResource(
                root: pending.root,
                url: pending.url,
                relativePath: pending.relativePath,
                fileName: pending.url.lastPathComponent,
                fileExtension: pending.url.pathExtension.lowercased(),
                mediaKind: pending.type.mediaKind,
                byteSize: pending.byteSize,
                modifiedAt: pending.modifiedAt,
                addedAt: pending.addedAt,
                fileSystemIdentifier: pending.fileSystemIdentifier,
                captureTime: evidence.captureTime,
                rawLivePhotoIdentifier: nil,
                livePhotoTimedMetadataStatus: evidence.timedMetadataStatus,
                metadataProbeFailed: false,
                exactHash: nil,
                persistentResourceID: nil,
                persistentAssetID: nil,
                identifierFingerprint: evidence.identifierFingerprint
            ))
        }

        return (reused, remaining)
    }

    private func cachedMetadataIndex(
        rootID: String,
        probeVersion: Int
    ) throws -> CachedMetadataIndex {
        try withStatement(
            """
            SELECT r.relative_path, r.media_kind, r.byte_size, r.modified_at,
                   r.capture_local_time, r.capture_utc_offset, r.capture_instant,
                   r.capture_source, r.capture_confidence,
                   r.live_identifier_fingerprint, r.metadata_probe_failed,
                   rfi.filesystem_identifier, rlms.status
            FROM resources r
            JOIN resource_metadata_cache_state rmcs ON rmcs.resource_id = r.id
            LEFT JOIN resource_file_ids rfi ON rfi.resource_id = r.id
            LEFT JOIN resource_live_metadata_status rlms ON rlms.resource_id = r.id
            WHERE r.root_id = ? AND rmcs.probe_version = ?
            """,
            bindings: [.text(rootID), .int64(Int64(probeVersion))]
        ) { statement in
            var index = CachedMetadataIndex()
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let relativeText = sqlite3_column_text(statement, 0),
                      let mediaText = sqlite3_column_text(statement, 1),
                      let mediaKind = MediaKind(rawValue: String(cString: mediaText)),
                      let timedText = sqlite3_column_text(statement, 12),
                      let timedStatus = LivePhotoTimedMetadataStatus(rawValue: String(cString: timedText))
                else {
                    throw sqliteError(sql: "SELECT cached metadata index")
                }

                let captureTime: CaptureTime?
                if let sourceText = sqlite3_column_text(statement, 7),
                   let confidenceText = sqlite3_column_text(statement, 8),
                   let source = CaptureTimeSource(rawValue: String(cString: sourceText)),
                   let confidence = CaptureTimeConfidence(rawValue: String(cString: confidenceText)) {
                    captureTime = CaptureTime(
                        localTimestamp: sqlite3_column_text(statement, 4).map { String(cString: $0) },
                        utcOffset: sqlite3_column_text(statement, 5).map { String(cString: $0) },
                        instant: sqlite3_column_type(statement, 6) == SQLITE_NULL
                            ? nil
                            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                        source: source,
                        confidence: confidence
                    )
                } else {
                    captureTime = nil
                }

                let fingerprint: Data?
                if sqlite3_column_type(statement, 9) != SQLITE_NULL,
                   let bytes = sqlite3_column_blob(statement, 9) {
                    fingerprint = Data(
                        bytes: bytes,
                        count: Int(sqlite3_column_bytes(statement, 9))
                    )
                } else {
                    fingerprint = nil
                }
                let modifiedAt = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                let fileSystemIdentifier = sqlite3_column_text(statement, 11)
                    .map { String(cString: $0) }
                let evidence = CachedMetadataEvidence(
                    mediaKind: mediaKind,
                    byteSize: sqlite3_column_int64(statement, 2),
                    modifiedAt: modifiedAt,
                    fileSystemIdentifier: fileSystemIdentifier,
                    captureTime: captureTime,
                    identifierFingerprint: fingerprint,
                    timedMetadataStatus: timedStatus,
                    metadataProbeFailed: sqlite3_column_int64(statement, 10) != 0
                )
                index.byRelativePath[String(cString: relativeText)] = evidence
                if let fileSystemIdentifier {
                    index.byFileSystemIdentifier[fileSystemIdentifier] = evidence
                }
            }
            return index
        }
    }

    func reuseCachedExactHashes(resources: inout [ProbedResource]) throws -> Int {
        let rootIDs = Set(resources.map { $0.root.id })
        var indexByRootID: [String: CachedExactHashIndex] = [:]
        indexByRootID.reserveCapacity(rootIDs.count)
        for rootID in rootIDs {
            indexByRootID[rootID] = try cachedExactHashIndex(rootID: rootID)
        }

        var reused = 0
        for index in resources.indices where resources[index].mediaKind != .sidecar {
            guard resources[index].exactHash == nil,
                  let rootIndex = indexByRootID[resources[index].root.id]
            else {
                continue
            }

            let pathEvidence = rootIndex.byRelativePath[resources[index].relativePath]
            let evidence: CachedExactHashEvidence?
            if let currentID = resources[index].fileSystemIdentifier,
               let pathEvidence,
               let cachedID = pathEvidence.fileSystemIdentifier,
               cachedID != currentID {
                evidence = rootIndex.byFileSystemIdentifier[currentID]
            } else if let pathEvidence {
                evidence = pathEvidence
            } else if let currentID = resources[index].fileSystemIdentifier {
                evidence = rootIndex.byFileSystemIdentifier[currentID]
            } else {
                evidence = nil
            }

            guard let evidence,
                  evidence.byteSize == resources[index].byteSize,
                  modificationTimesMatch(evidence.modifiedAt, resources[index].modifiedAt)
            else {
                continue
            }

            if let cachedID = evidence.fileSystemIdentifier,
               let currentID = resources[index].fileSystemIdentifier,
               cachedID != currentID {
                continue
            }

            resources[index].exactHash = evidence.exactHash
            reused += 1
        }
        return reused
    }

    private func cachedExactHashIndex(rootID: String) throws -> CachedExactHashIndex {
        try withStatement(
            """
            SELECT r.relative_path, r.byte_size, r.modified_at, r.exact_hash,
                   rfi.filesystem_identifier
            FROM resources r
            LEFT JOIN resource_file_ids rfi ON rfi.resource_id = r.id
            WHERE r.root_id = ? AND r.exact_hash IS NOT NULL
            """,
            bindings: [.text(rootID)]
        ) { statement in
            var index = CachedExactHashIndex()
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let relativePathText = sqlite3_column_text(statement, 0),
                      sqlite3_column_type(statement, 3) != SQLITE_NULL,
                      let hashBytes = sqlite3_column_blob(statement, 3)
                else {
                    throw sqliteError(sql: "SELECT cached exact hash index")
                }

                let modifiedAt = sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                let fileSystemIdentifier = sqlite3_column_text(statement, 4)
                    .map { String(cString: $0) }
                let evidence = CachedExactHashEvidence(
                    byteSize: sqlite3_column_int64(statement, 1),
                    modifiedAt: modifiedAt,
                    fileSystemIdentifier: fileSystemIdentifier,
                    exactHash: Data(
                        bytes: hashBytes,
                        count: Int(sqlite3_column_bytes(statement, 3))
                    )
                )
                index.byRelativePath[String(cString: relativePathText)] = evidence
                if let fileSystemIdentifier {
                    index.byFileSystemIdentifier[fileSystemIdentifier] = evidence
                }
            }
            return index
        }
    }

    private func modificationTimesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 0.001
    }

    func persistDuplicateGroups(
        sessionID: String,
        resources: [ProbedResource],
        groups: [InternalDuplicateGroup]
    ) throws -> [Data: String] {
        for resource in resources {
            guard let resourceID = resource.persistentResourceID else { continue }
            try run(
                "DELETE FROM exact_duplicate_members WHERE resource_id = ?",
                bindings: [.text(resourceID)]
            )
        }

        var result: [Data: String] = [:]
        for group in groups {
            let groupID: String
            if let existing = try queryText(
                "SELECT id FROM exact_duplicate_groups WHERE exact_hash = ?",
                bindings: [.blob(group.contentHash)]
            ) {
                groupID = existing
                try run(
                    "UPDATE exact_duplicate_groups SET byte_size = ?, last_seen_session = ? WHERE id = ?",
                    bindings: [
                        .int64(group.resources.first?.byteSize ?? 0),
                        .text(sessionID),
                        .text(groupID)
                    ]
                )
            } else {
                let sequence = try nextDuplicateSequence()
                groupID = String(format: "D%06lld", sequence)
                try run(
                    """
                    INSERT INTO exact_duplicate_groups
                        (id, sequence_number, exact_hash, byte_size, last_seen_session)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(groupID),
                        .int64(sequence),
                        .blob(group.contentHash),
                        .int64(group.resources.first?.byteSize ?? 0),
                        .text(sessionID)
                    ]
                )
            }

            // A duplicate group's membership is a snapshot of the latest scan that
            // observed that exact hash group. Replace the whole membership set so an
            // older member from a root that is not part of the current scan cannot be
            // carried forward into a newly observed/current group.
            try run(
                "DELETE FROM exact_duplicate_members WHERE group_id = ?",
                bindings: [.text(groupID)]
            )

            result[group.contentHash] = groupID
            for resource in group.resources {
                guard let resourceID = resource.persistentResourceID else { continue }
                try run(
                    """
                    INSERT OR REPLACE INTO exact_duplicate_members
                        (group_id, resource_id, last_seen_session)
                    VALUES (?, ?, ?)
                    """,
                    bindings: [.text(groupID), .text(resourceID), .text(sessionID)]
                )
            }
        }

        return result
    }

    func persistEvents(sessionID: String, events: [EventSuggestionReport]) throws {
        try run(
            "DELETE FROM event_suggestions WHERE scan_session_id = ?",
            bindings: [.text(sessionID)]
        )

        for event in events {
            try run(
                """
                INSERT INTO event_suggestions
                    (scan_session_id, event_id, suggested_folder_name, start_at, end_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(sessionID),
                    .text(event.eventID),
                    .text(event.suggestedFolderName),
                    .double(event.start.timeIntervalSince1970),
                    .double(event.end.timeIntervalSince1970)
                ]
            )

            for assetID in event.assetIDs {
                try run(
                    """
                    INSERT INTO event_members (scan_session_id, event_id, asset_id)
                    VALUES (?, ?, ?)
                    """,
                    bindings: [.text(sessionID), .text(event.eventID), .text(assetID)]
                )
            }
        }
    }

    private func ensureAsset(
        assetKey: String,
        kind: String,
        pairStatus: String?,
        sessionID: String,
        preferredID: String? = nil
    ) throws -> String {
        if let existingID = try queryText(
            "SELECT id FROM logical_assets WHERE asset_key = ?",
            bindings: [.text(assetKey)]
        ) {
            try run(
                "UPDATE logical_assets SET kind = ?, pair_status = ?, last_seen_session = ? WHERE id = ?",
                bindings: [
                    .text(kind),
                    pairStatus.map(SQLiteBinding.text) ?? .null,
                    .text(sessionID),
                    .text(existingID)
                ]
            )
            return existingID
        }

        if let preferredID,
           try queryText(
               "SELECT id FROM logical_assets WHERE id = ?",
               bindings: [.text(preferredID)]
           ) != nil {
            try run(
                """
                UPDATE logical_assets
                SET asset_key = ?, kind = ?, pair_status = ?, last_seen_session = ?
                WHERE id = ?
                """,
                bindings: [
                    .text(assetKey),
                    .text(kind),
                    pairStatus.map(SQLiteBinding.text) ?? .null,
                    .text(sessionID),
                    .text(preferredID)
                ]
            )
            return preferredID
        }

        let id = opaqueID(prefix: "A")
        try run(
            """
            INSERT INTO logical_assets (id, asset_key, kind, pair_status, created_at, last_seen_session)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(id),
                .text(assetKey),
                .text(kind),
                pairStatus.map(SQLiteBinding.text) ?? .null,
                .double(Date().timeIntervalSince1970),
                .text(sessionID)
            ]
        )
        return id
    }

    private func link(
        assetID: String,
        resourceID: String,
        role: ResourceRole,
        sessionID: String
    ) throws {
        try run(
            """
            INSERT OR REPLACE INTO asset_resources (asset_id, resource_id, role, last_seen_session)
            VALUES (?, ?, ?, ?)
            """,
            bindings: [
                .text(assetID),
                .text(resourceID),
                .text(role.rawValue),
                .text(sessionID)
            ]
        )
    }

    private func aggregatePairStatus(
        indices: [Int],
        resources: [ProbedResource]
    ) -> LivePhotoOccurrenceStatus {
        let stillCount = indices.count { resources[$0].mediaKind == .image }
        let videos = indices.map { resources[$0] }.filter { $0.mediaKind == .video }
        if stillCount > 0, videos.contains(where: { $0.livePhotoTimedMetadataStatus == .valid }) {
            return .complete
        }
        if stillCount > 0, !videos.isEmpty {
            if videos.contains(where: { $0.livePhotoTimedMetadataStatus == .unreadable }) {
                return .stillImageTimeUnreadable
            }
            if videos.contains(where: { $0.livePhotoTimedMetadataStatus == .invalid }) {
                return .stillImageTimeInvalid
            }
            return .stillImageTimeMissing
        }
        return AssetAssembler.occurrenceStatus(stillCount: stillCount, videoCount: videos.count)
    }

    private func resourceBindings(
        id: String,
        resource: ProbedResource,
        sessionID: String
    ) -> [SQLiteBinding] {
        [
            .text(id),
            .text(resource.root.id),
            .text(resource.relativePath),
            .text(resource.fileName),
            .text(resource.fileExtension),
            .text(resource.mediaKind.rawValue),
            .int64(resource.byteSize),
            resource.modifiedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            resource.addedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            resource.captureTime?.localTimestamp.map(SQLiteBinding.text) ?? .null,
            resource.captureTime?.utcOffset.map(SQLiteBinding.text) ?? .null,
            resource.captureTime?.instant.map { .double($0.timeIntervalSince1970) } ?? .null,
            resource.captureTime.map { .text($0.source.rawValue) } ?? .null,
            resource.captureTime.map { .text($0.confidence.rawValue) } ?? .null,
            resource.exactHash.map(SQLiteBinding.blob) ?? .null,
            resource.identifierFingerprint.map(SQLiteBinding.blob) ?? .null,
            .int64(resource.metadataProbeFailed ? 1 : 0),
            .text(sessionID)
        ]
    }

    private func updateResourceBindings(
        id: String,
        resource: ProbedResource,
        sessionID: String
    ) -> [SQLiteBinding] {
        [
            .text(resource.relativePath),
            .text(resource.fileName),
            .text(resource.fileExtension),
            .text(resource.mediaKind.rawValue),
            .int64(resource.byteSize),
            resource.modifiedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            resource.addedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            resource.captureTime?.localTimestamp.map(SQLiteBinding.text) ?? .null,
            resource.captureTime?.utcOffset.map(SQLiteBinding.text) ?? .null,
            resource.captureTime?.instant.map { .double($0.timeIntervalSince1970) } ?? .null,
            resource.captureTime.map { .text($0.source.rawValue) } ?? .null,
            resource.captureTime.map { .text($0.confidence.rawValue) } ?? .null,
            resource.exactHash.map(SQLiteBinding.blob) ?? .null,
            resource.identifierFingerprint.map(SQLiteBinding.blob) ?? .null,
            .int64(resource.metadataProbeFailed ? 1 : 0),
            .text(sessionID),
            .text(id)
        ]
    }

    private func nextDuplicateSequence() throws -> Int64 {
        try withStatement(
            "SELECT COALESCE(MAX(sequence_number), 0) + 1 FROM exact_duplicate_groups",
            bindings: []
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(sql: "SELECT next duplicate sequence")
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func setting(_ key: String) throws -> String? {
        try queryText(
            "SELECT value FROM settings WHERE key = ?",
            bindings: [.text(key)]
        )
    }

    private func setSetting(_ key: String, value: String) throws {
        try run(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
            bindings: [.text(key), .text(value)]
        )
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS schema_info (
                version INTEGER NOT NULL
            );
            INSERT INTO schema_info (version)
                SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_info);

            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS source_roots (
                id TEXT PRIMARY KEY,
                label TEXT NOT NULL,
                kind TEXT NOT NULL,
                canonical_path TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS root_markers (
                marker_key TEXT PRIMARY KEY,
                root_id TEXT NOT NULL UNIQUE REFERENCES source_roots(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS source_root_metadata (
                root_id TEXT PRIMARY KEY REFERENCES source_roots(id) ON DELETE CASCADE,
                provenance TEXT NOT NULL DEFAULT 'unknown'
            );

            CREATE TABLE IF NOT EXISTS root_registrations (
                root_id TEXT PRIMARY KEY REFERENCES source_roots(id) ON DELETE CASCADE,
                state TEXT NOT NULL CHECK(state IN ('active', 'inactive', 'removed')),
                registered_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS root_usage_roles (
                root_id TEXT PRIMARY KEY REFERENCES source_roots(id) ON DELETE CASCADE,
                role TEXT NOT NULL CHECK(role IN ('staging', 'primary_library', 'archive', 'import_source', 'reference')),
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS root_usage_role_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                root_id TEXT NOT NULL REFERENCES source_roots(id) ON DELETE CASCADE,
                role TEXT NOT NULL CHECK(role IN ('staging', 'primary_library', 'archive', 'import_source', 'reference')),
                changed_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS scan_sessions (
                id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                completed_at REAL,
                status TEXT NOT NULL,
                root_count INTEGER NOT NULL DEFAULT 0,
                resource_count INTEGER NOT NULL DEFAULT 0,
                asset_count INTEGER NOT NULL DEFAULT 0,
                warning_count INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS resources (
                id TEXT PRIMARY KEY,
                root_id TEXT NOT NULL REFERENCES source_roots(id),
                relative_path TEXT NOT NULL,
                file_name TEXT NOT NULL,
                file_extension TEXT NOT NULL,
                media_kind TEXT NOT NULL,
                byte_size INTEGER NOT NULL,
                modified_at REAL,
                added_at REAL,
                capture_local_time TEXT,
                capture_utc_offset TEXT,
                capture_instant REAL,
                capture_source TEXT,
                capture_confidence TEXT,
                exact_hash BLOB,
                live_identifier_fingerprint BLOB,
                metadata_probe_failed INTEGER NOT NULL DEFAULT 0,
                last_seen_session TEXT NOT NULL REFERENCES scan_sessions(id),
                UNIQUE(root_id, relative_path)
            );

            CREATE TABLE IF NOT EXISTS resource_original_names (
                resource_id TEXT PRIMARY KEY REFERENCES resources(id) ON DELETE CASCADE,
                original_file_name TEXT NOT NULL,
                first_seen_session TEXT NOT NULL REFERENCES scan_sessions(id)
            );

            CREATE TABLE IF NOT EXISTS resource_file_ids (
                resource_id TEXT PRIMARY KEY REFERENCES resources(id) ON DELETE CASCADE,
                root_id TEXT NOT NULL REFERENCES source_roots(id) ON DELETE CASCADE,
                filesystem_identifier TEXT NOT NULL,
                UNIQUE(root_id, filesystem_identifier)
            );

            CREATE TABLE IF NOT EXISTS resource_live_metadata_status (
                resource_id TEXT PRIMARY KEY REFERENCES resources(id) ON DELETE CASCADE,
                status TEXT NOT NULL,
                last_seen_session TEXT NOT NULL REFERENCES scan_sessions(id)
            );

            CREATE TABLE IF NOT EXISTS resource_metadata_cache_state (
                resource_id TEXT PRIMARY KEY REFERENCES resources(id) ON DELETE CASCADE,
                probe_version INTEGER NOT NULL,
                last_seen_session TEXT NOT NULL REFERENCES scan_sessions(id)
            );

            CREATE TABLE IF NOT EXISTS resource_locations (
                resource_id TEXT NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
                root_id TEXT NOT NULL REFERENCES source_roots(id) ON DELETE CASCADE,
                relative_path TEXT NOT NULL,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                last_seen_session TEXT NOT NULL REFERENCES scan_sessions(id),
                PRIMARY KEY(resource_id, root_id, relative_path)
            );

            CREATE TABLE IF NOT EXISTS logical_assets (
                id TEXT PRIMARY KEY,
                asset_key TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                pair_status TEXT,
                created_at REAL NOT NULL,
                last_seen_session TEXT NOT NULL REFERENCES scan_sessions(id)
            );

            CREATE TABLE IF NOT EXISTS asset_resources (
                asset_id TEXT NOT NULL REFERENCES logical_assets(id) ON DELETE CASCADE,
                resource_id TEXT NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                last_seen_session TEXT NOT NULL REFERENCES scan_sessions(id),
                PRIMARY KEY(asset_id, resource_id)
            );

            CREATE TABLE IF NOT EXISTS sidecar_links (
                sidecar_resource_id TEXT PRIMARY KEY REFERENCES resources(id) ON DELETE CASCADE,
                target_asset_id TEXT NOT NULL REFERENCES logical_assets(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                last_seen_session TEXT NOT NULL REFERENCES scan_sessions(id)
            );

            CREATE TABLE IF NOT EXISTS collections (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                parent_id TEXT REFERENCES collections(id),
                collection_type TEXT NOT NULL DEFAULT 'user',
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS memberships (
                asset_id TEXT NOT NULL REFERENCES logical_assets(id) ON DELETE CASCADE,
                collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                membership_origin TEXT NOT NULL,
                PRIMARY KEY(asset_id, collection_id)
            );

            CREATE TABLE IF NOT EXISTS source_collection_keys (
                source_key TEXT PRIMARY KEY,
                collection_id TEXT NOT NULL UNIQUE REFERENCES collections(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS provider_objects (
                id TEXT PRIMARY KEY,
                asset_id TEXT NOT NULL REFERENCES logical_assets(id) ON DELETE CASCADE,
                provider TEXT NOT NULL,
                provider_object_id TEXT NOT NULL,
                mapping_method TEXT NOT NULL,
                mapping_confidence TEXT NOT NULL,
                last_observed_at REAL,
                UNIQUE(provider, provider_object_id)
            );

            CREATE TABLE IF NOT EXISTS provider_albums (
                id TEXT PRIMARY KEY,
                collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                provider TEXT NOT NULL,
                provider_album_id TEXT,
                capability_state TEXT NOT NULL,
                UNIQUE(provider, collection_id)
            );

            CREATE TABLE IF NOT EXISTS exact_duplicate_groups (
                id TEXT PRIMARY KEY,
                sequence_number INTEGER NOT NULL UNIQUE,
                exact_hash BLOB NOT NULL UNIQUE,
                byte_size INTEGER NOT NULL,
                last_seen_session TEXT NOT NULL REFERENCES scan_sessions(id)
            );

            CREATE TABLE IF NOT EXISTS exact_duplicate_members (
                group_id TEXT NOT NULL REFERENCES exact_duplicate_groups(id) ON DELETE CASCADE,
                resource_id TEXT NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
                last_seen_session TEXT NOT NULL REFERENCES scan_sessions(id),
                PRIMARY KEY(group_id, resource_id)
            );

            CREATE TABLE IF NOT EXISTS event_suggestions (
                scan_session_id TEXT NOT NULL REFERENCES scan_sessions(id) ON DELETE CASCADE,
                event_id TEXT NOT NULL,
                suggested_folder_name TEXT NOT NULL,
                start_at REAL NOT NULL,
                end_at REAL NOT NULL,
                PRIMARY KEY(scan_session_id, event_id)
            );

            CREATE TABLE IF NOT EXISTS event_members (
                scan_session_id TEXT NOT NULL,
                event_id TEXT NOT NULL,
                asset_id TEXT NOT NULL REFERENCES logical_assets(id) ON DELETE CASCADE,
                PRIMARY KEY(scan_session_id, event_id, asset_id),
                FOREIGN KEY(scan_session_id, event_id)
                    REFERENCES event_suggestions(scan_session_id, event_id)
                    ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS resources_last_seen_idx
                ON resources(last_seen_session);
            CREATE INDEX IF NOT EXISTS resources_size_idx
                ON resources(byte_size);
            CREATE INDEX IF NOT EXISTS resources_live_fingerprint_idx
                ON resources(live_identifier_fingerprint);
            CREATE INDEX IF NOT EXISTS resources_root_idx
                ON resources(root_id);
            CREATE INDEX IF NOT EXISTS resource_locations_last_seen_idx
                ON resource_locations(last_seen_session);
            CREATE INDEX IF NOT EXISTS asset_resources_resource_session_idx
                ON asset_resources(resource_id, last_seen_session);
            CREATE INDEX IF NOT EXISTS asset_resources_session_idx
                ON asset_resources(last_seen_session);
            CREATE INDEX IF NOT EXISTS resource_metadata_cache_version_idx
                ON resource_metadata_cache_state(probe_version);
            CREATE INDEX IF NOT EXISTS logical_assets_session_idx
                ON logical_assets(last_seen_session);
            CREATE INDEX IF NOT EXISTS exact_duplicate_groups_session_idx
                ON exact_duplicate_groups(last_seen_session);
            CREATE INDEX IF NOT EXISTS exact_duplicate_members_session_idx
                ON exact_duplicate_members(last_seen_session, group_id);
            CREATE INDEX IF NOT EXISTS sidecar_links_session_idx
                ON sidecar_links(last_seen_session);
            CREATE INDEX IF NOT EXISTS provider_objects_asset_idx
                ON provider_objects(asset_id);
            CREATE INDEX IF NOT EXISTS root_usage_role_history_root_idx
                ON root_usage_role_history(root_id, changed_at);

            INSERT OR IGNORE INTO root_usage_roles (root_id, role, updated_at)
            SELECT id,
                   CASE kind
                       WHEN 'archive' THEN 'archive'
                       WHEN 'import_source' THEN 'import_source'
                       WHEN 'reference' THEN 'reference'
                       ELSE 'primary_library'
                   END,
                   created_at
            FROM source_roots;

            INSERT INTO root_usage_role_history (root_id, role, changed_at)
            SELECT rur.root_id, rur.role, rur.updated_at
            FROM root_usage_roles rur
            WHERE NOT EXISTS (
                SELECT 1 FROM root_usage_role_history h WHERE h.root_id = rur.root_id
            );
            """
        )

        if try !table("resources", hasColumn: "added_at") {
            try execute("ALTER TABLE resources ADD COLUMN added_at REAL")
        }
    }

    private func table(_ table: String, hasColumn column: String) throws -> Bool {
        try withStatement("PRAGMA table_info(\(table))", bindings: []) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return false }
                guard result == SQLITE_ROW else {
                    throw sqliteError(sql: "PRAGMA table_info(\(table))")
                }
                if let name = sqlite3_column_text(statement, 1),
                   String(cString: name) == column {
                    return true
                }
            }
        }
    }

    private enum SQLiteBinding {
        case text(String)
        case int64(Int64)
        case double(Double)
        case blob(Data)
        case null
    }

    private func execute(_ sql: String) throws {
        guard let database else {
            throw CatalogError.sqlite(message: "database is closed", sql: sql)
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw CatalogError.sqlite(message: message, sql: sql)
        }
    }

    private func run(_ sql: String, bindings: [SQLiteBinding]) throws {
        try withStatement(sql, bindings: bindings) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                throw sqliteError(sql: sql)
            }
        }
    }

    func commitAppliedOrganizationPlan(_ plan: OrganizationPlan) throws {
        var seenResourceIDs = Set<String>()
        let now = Date().timeIntervalSince1970
        let moves = plan.items
            .filter { $0.decision == .automatic }
            .flatMap(\.moves)

        for move in moves {
            guard seenResourceIDs.insert(move.resourceID).inserted,
                  !move.sourceRelativePath.isEmpty,
                  !move.destinationRelativePath.isEmpty,
                  !move.sourceRelativePath.hasPrefix("/"),
                  !move.destinationRelativePath.hasPrefix("/"),
                  !move.sourceRelativePath.split(separator: "/").contains(".."),
                  !move.destinationRelativePath.split(separator: "/").contains("..")
            else {
                throw CatalogError.invalidCatalogValue("Organization plan contains an invalid resource move.")
            }

            let currentRootID = try queryText(
                "SELECT root_id FROM resources WHERE id = ?",
                bindings: [.text(move.resourceID)]
            )
            let currentRelativePath = try queryText(
                "SELECT relative_path FROM resources WHERE id = ?",
                bindings: [.text(move.resourceID)]
            )
            guard currentRootID == move.rootID,
                  currentRelativePath == move.sourceRelativePath
            else {
                throw CatalogError.invalidCatalogValue("Organization plan no longer matches the catalog resource location.")
            }

            if let occupied = try queryText(
                "SELECT id FROM resources WHERE root_id = ? AND relative_path = ? AND id <> ?",
                bindings: [
                    .text(move.rootID),
                    .text(move.destinationRelativePath),
                    .text(move.resourceID)
                ]
            ), !occupied.isEmpty {
                throw CatalogError.invalidCatalogValue("Organization destination is already represented by another catalog resource.")
            }

            let destinationURL = URL(fileURLWithPath: move.destinationRelativePath)
            try run(
                """
                UPDATE resources
                SET relative_path = ?, file_name = ?, file_extension = ?
                WHERE id = ?
                """,
                bindings: [
                    .text(move.destinationRelativePath),
                    .text(destinationURL.lastPathComponent),
                    .text(destinationURL.pathExtension.lowercased()),
                    .text(move.resourceID)
                ]
            )
            try run(
                """
                INSERT INTO resource_locations (
                    resource_id, root_id, relative_path, first_seen_at, last_seen_at, last_seen_session
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(resource_id, root_id, relative_path) DO UPDATE SET
                    last_seen_at = excluded.last_seen_at,
                    last_seen_session = excluded.last_seen_session
                """,
                bindings: [
                    .text(move.resourceID),
                    .text(move.rootID),
                    .text(move.destinationRelativePath),
                    .double(now),
                    .double(now),
                    .text(plan.sessionID)
                ]
            )
        }
    }

    func sourceRootPath(rootID: String) throws -> String? {
        try queryText(
            "SELECT canonical_path FROM source_roots WHERE id = ?",
            bindings: [.text(rootID)]
        )
    }

    func sourceRootUsageRole(rootID: String) throws -> RootUsageRole? {
        try queryText(
            "SELECT role FROM root_usage_roles WHERE root_id = ?",
            bindings: [.text(rootID)]
        ).flatMap(RootUsageRole.init(rawValue:))
    }

    func quarantineRestoreRootPath(rootID: String) throws -> String? {
        try sourceRootPath(rootID: rootID)
    }

    func rootID(matching target: String) throws -> String? {
        if let direct = try queryText(
            "SELECT id FROM source_roots WHERE id = ?",
            bindings: [.text(target)]
        ) {
            return direct
        }

        let expanded = (target as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let canonicalPath = FileManager.default.fileExists(atPath: url.path)
            ? url.resolvingSymlinksInPath().standardizedFileURL.path
            : url.standardizedFileURL.path
        return try queryText(
            "SELECT id FROM source_roots WHERE canonical_path = ?",
            bindings: [.text(canonicalPath)]
        )
    }

    func setRootRegistration(rootID: String, state: RootRegistrationState) throws {
        guard state != .history else {
            throw CatalogError.invalidCatalogValue("history is a derived root registration state")
        }
        let now = Date().timeIntervalSince1970
        try run(
            """
            INSERT INTO root_registrations (root_id, state, registered_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(root_id) DO UPDATE SET
                state = excluded.state,
                updated_at = excluded.updated_at
            """,
            bindings: [.text(rootID), .text(state.rawValue), .double(now), .double(now)]
        )
    }

    func setRootUsageRole(rootID: String, role: RootUsageRole) throws {
        try withTransaction {
            let previous = try queryText(
                "SELECT role FROM root_usage_roles WHERE root_id = ?",
                bindings: [.text(rootID)]
            ).flatMap(RootUsageRole.init(rawValue:))
            let now = Date().timeIntervalSince1970
            try run(
                """
                INSERT INTO root_usage_roles (root_id, role, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(root_id) DO UPDATE SET
                    role = excluded.role,
                    updated_at = excluded.updated_at
                """,
                bindings: [.text(rootID), .text(role.rawValue), .double(now)]
            )
            try run(
                "UPDATE source_roots SET kind = ? WHERE id = ?",
                bindings: [.text(role.sourceKind.rawValue), .text(rootID)]
            )
            if previous != role {
                try run(
                    "INSERT INTO root_usage_role_history (root_id, role, changed_at) VALUES (?, ?, ?)",
                    bindings: [.text(rootID), .text(role.rawValue), .double(now)]
                )
            }
        }
    }

    func rootRegistryRows(includeHistory: Bool) throws -> [RootRegistryRow] {
        let whereClause = includeHistory
            ? ""
            : "WHERE rr.state IS NOT NULL AND rr.state <> 'removed'"
        return try withStatement(
            """
            SELECT sr.id, sr.label, sr.kind, rur.role, COALESCE(srm.provenance, 'unknown'),
                   sr.canonical_path, rr.state,
                   (SELECT COUNT(*) FROM resources r WHERE r.root_id = sr.id)
            FROM source_roots sr
            LEFT JOIN source_root_metadata srm ON srm.root_id = sr.id
            LEFT JOIN root_registrations rr ON rr.root_id = sr.id
            LEFT JOIN root_usage_roles rur ON rur.root_id = sr.id
            \(whereClause)
            ORDER BY sr.canonical_path, sr.id
            """,
            bindings: []
        ) { statement in
            var rows: [RootRegistryRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rootText = sqlite3_column_text(statement, 0),
                      let labelText = sqlite3_column_text(statement, 1),
                      let kindText = sqlite3_column_text(statement, 2),
                      let roleText = sqlite3_column_text(statement, 3),
                      let provenanceText = sqlite3_column_text(statement, 4),
                      let pathText = sqlite3_column_text(statement, 5),
                      let kind = SourceRootKind(rawValue: String(cString: kindText)),
                      let usageRole = RootUsageRole(rawValue: String(cString: roleText)),
                      let provenance = SourceProvenance(rawValue: String(cString: provenanceText))
                else {
                    throw sqliteError(sql: "SELECT root registry rows")
                }
                let state = sqlite3_column_text(statement, 6)
                    .flatMap { RootRegistrationState(rawValue: String(cString: $0)) }
                    ?? .history
                rows.append(RootRegistryRow(
                    rootID: String(cString: rootText),
                    label: String(cString: labelText),
                    kind: kind,
                    usageRole: usageRole,
                    provenance: provenance,
                    canonicalPath: String(cString: pathText),
                    state: state,
                    currentResourceCount: Int(sqlite3_column_int64(statement, 7))
                ))
            }
            return rows
        }
    }

    func latestReusableActiveRootsScanReport() throws -> ScanReport? {
        let activeRoots = try rootRegistryRows(includeHistory: false)
            .filter { $0.state == .active }
        guard !activeRoots.isEmpty else { return nil }

        let activeRootIDs = Set(activeRoots.map(\.rootID))
        let sessions = try cachedCompletedScanSessions(limit: 32)
        for session in sessions where session.rootCount == activeRoots.count {
            let observation = try cachedSessionObservationSummary(sessionID: session.sessionID)
            guard observation.resourceCount == session.resourceCount,
                  observation.rootIDs == activeRootIDs
            else {
                continue
            }
            return try cachedScanReport(session: session, roots: activeRoots)
        }
        return nil
    }

    func latestReusableDuplicateReviewScanReport() throws -> ScanReport? {
        let activeRoots = try rootRegistryRows(includeHistory: false)
            .filter { $0.state == .active }
        guard !activeRoots.isEmpty else { return nil }

        let activeRootIDs = Set(activeRoots.map(\.rootID))
        let sessions = try cachedCompletedScanSessions(limit: 64)
        for session in sessions {
            let observation = try cachedSessionObservationSummary(sessionID: session.sessionID)
            guard observation.resourceCount == session.resourceCount,
                  !observation.rootIDs.isEmpty,
                  observation.rootIDs.isSubset(of: activeRootIDs),
                  try cachedSessionExactDuplicateGroupCount(sessionID: session.sessionID) > 0
            else {
                continue
            }

            let roots = activeRoots.filter { observation.rootIDs.contains($0.rootID) }
            guard roots.count == observation.rootIDs.count else { continue }
            return try cachedScanReport(session: session, roots: roots)
        }
        return nil
    }

    func duplicateReviewExpectedResourceEvidence(
        resourceIDs: [String]
    ) throws -> [String: DuplicateReviewExpectedResourceEvidence] {
        let uniqueIDs = Array(Set(resourceIDs)).sorted()
        guard !uniqueIDs.isEmpty else { return [:] }

        var output: [String: DuplicateReviewExpectedResourceEvidence] = [:]
        for start in stride(from: 0, to: uniqueIDs.count, by: 400) {
            let end = min(start + 400, uniqueIDs.count)
            let chunk = Array(uniqueIDs[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
                SELECT r.id, r.root_id, r.relative_path, r.byte_size, r.modified_at,
                       rfi.filesystem_identifier
                FROM resources r
                LEFT JOIN resource_file_ids rfi ON rfi.resource_id = r.id
                WHERE r.id IN (\(placeholders))
                """
            let rows: [DuplicateReviewExpectedResourceEvidence] = try withStatement(
                sql,
                bindings: chunk.map(SQLiteBinding.text)
            ) { statement in
                var values: [DuplicateReviewExpectedResourceEvidence] = []
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW,
                          let resourceText = sqlite3_column_text(statement, 0),
                          let rootText = sqlite3_column_text(statement, 1),
                          let relativeText = sqlite3_column_text(statement, 2)
                    else {
                        throw sqliteError(sql: "SELECT duplicate review freshness evidence")
                    }
                    values.append(DuplicateReviewExpectedResourceEvidence(
                        resourceID: String(cString: resourceText),
                        rootID: String(cString: rootText),
                        relativePath: String(cString: relativeText),
                        byteSize: sqlite3_column_int64(statement, 3),
                        modifiedAt: sqlite3_column_type(statement, 4) == SQLITE_NULL
                            ? nil
                            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                        fileSystemIdentifier: sqlite3_column_text(statement, 5)
                            .map { String(cString: $0) }
                    ))
                }
                return values
            }
            for row in rows {
                output[row.resourceID] = row
            }
        }
        return output
    }

    private func cachedCompletedScanSessions(limit: Int) throws -> [CachedScanSessionRow] {
        try withStatement(
            """
            SELECT id, started_at, completed_at, root_count, resource_count, asset_count, warning_count
            FROM scan_sessions
            WHERE status = 'complete' AND completed_at IS NOT NULL
            ORDER BY completed_at DESC
            LIMIT ?
            """,
            bindings: [.int64(Int64(limit))]
        ) { statement in
            var rows: [CachedScanSessionRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let idText = sqlite3_column_text(statement, 0)
                else {
                    throw sqliteError(sql: "SELECT reusable scan sessions")
                }
                rows.append(CachedScanSessionRow(
                    sessionID: String(cString: idText),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    completedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    rootCount: Int(sqlite3_column_int64(statement, 3)),
                    resourceCount: Int(sqlite3_column_int64(statement, 4)),
                    assetCount: Int(sqlite3_column_int64(statement, 5)),
                    warningCount: Int(sqlite3_column_int64(statement, 6))
                ))
            }
            return rows
        }
    }

    private func cachedSessionObservationSummary(
        sessionID: String
    ) throws -> (resourceCount: Int, rootIDs: Set<String>) {
        try withStatement(
            """
            SELECT root_id, COUNT(*)
            FROM resources
            WHERE last_seen_session = ?
            GROUP BY root_id
            """,
            bindings: [.text(sessionID)]
        ) { statement in
            var count = 0
            var rootIDs = Set<String>()
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let rootText = sqlite3_column_text(statement, 0)
                else {
                    throw sqliteError(sql: "SELECT reusable scan observation summary")
                }
                rootIDs.insert(String(cString: rootText))
                count += Int(sqlite3_column_int64(statement, 1))
            }
            return (count, rootIDs)
        }
    }

    private func cachedSessionExactDuplicateGroupCount(sessionID: String) throws -> Int {
        try withStatement(
            "SELECT COUNT(*) FROM exact_duplicate_groups WHERE last_seen_session = ?",
            bindings: [.text(sessionID)]
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(sql: "SELECT reusable duplicate-review exact groups")
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func cachedScanReport(
        session: CachedScanSessionRow,
        roots rootRows: [RootRegistryRow]
    ) throws -> ScanReport {
        let rootsByID = Dictionary(uniqueKeysWithValues: rootRows.map { ($0.rootID, $0) })
        let resourceRows = try cachedScanResources(
            sessionID: session.sessionID,
            rootsByID: rootsByID
        )
        guard resourceRows.count == session.resourceCount else {
            throw CatalogError.invalidCatalogValue(
                "The cached scan snapshot is incomplete; run duplicate-review with --refresh."
            )
        }

        let resources = resourceRows.map(\.report)
        let resourceRowsByID = Dictionary(uniqueKeysWithValues: resourceRows.map {
            ($0.report.resourceID, $0)
        })
        let duplicateGroups = try cachedDuplicateGroups(
            sessionID: session.sessionID,
            resourcesByID: resourceRowsByID
        )
        let livePairStatus = try cachedLiveAssetPairStatus(sessionID: session.sessionID)
        let livePhotos = cachedLivePhotoReports(
            resources: resourceRows,
            pairStatusByAssetID: livePairStatus
        )

        let occurrencesByRoot = Dictionary(grouping: livePhotos.flatMap(\.occurrences), by: \.rootID)
        let cachedRoots = try rootRows.map { root -> RootScanReport in
            let rootResources = resourceRows.filter { $0.report.rootID == root.rootID }
            let rootOccurrences = occurrencesByRoot[root.rootID] ?? []
            let recognizedSidecars = try cachedRecognizedSidecarCount(
                sessionID: session.sessionID,
                rootID: root.rootID
            )
            let sidecarCount = rootResources.count { $0.report.mediaKind == .sidecar }
            return RootScanReport(
                rootID: root.rootID,
                label: root.label,
                kind: root.kind,
                usageRole: root.usageRole,
                provenance: root.provenance,
                canonicalPath: root.canonicalPath,
                stableMarkerKey: try queryText(
                    "SELECT marker_key FROM root_markers WHERE root_id = ?",
                    bindings: [.text(root.rootID)]
                ),
                mediaFileCount: rootResources.count {
                    $0.report.mediaKind == .image || $0.report.mediaKind == .video
                },
                completeLivePhotos: rootOccurrences.count { $0.status == .complete },
                stillOnlyLiveResources: rootOccurrences
                    .filter { $0.status == .stillOnly }
                    .reduce(0) { $0 + $1.resources.count },
                videoOnlyLiveResources: rootOccurrences
                    .filter { $0.status == .videoOnly }
                    .reduce(0) { $0 + $1.resources.count },
                standaloneImages: rootResources.count { $0.report.role == .standaloneImage },
                standaloneVideos: rootResources.count { $0.report.role == .standaloneVideo },
                sidecars: sidecarCount,
                recognizedSidecars: recognizedSidecars,
                unrecognizedSidecars: max(sidecarCount - recognizedSidecars, 0),
                metadataProbeFailures: rootResources.count { $0.metadataProbeFailed },
                sourceFolderSemanticsCaptured: root.provenance == .googleTakeout || root.kind == .archive
            )
        }
        .sorted { ($0.label, $0.rootID) < ($1.label, $1.rootID) }

        return ScanReport(
            sessionID: session.sessionID,
            startedAt: session.startedAt,
            completedAt: session.completedAt,
            catalogPath: url.path,
            summary: ScanSummary(
                rootCount: cachedRoots.count,
                resourceCount: resources.count,
                logicalAssetCount: session.assetCount,
                livePhotoAssetCount: livePhotos.count,
                exactDuplicateGroupCount: duplicateGroups.count,
                eventSuggestionCount: 0,
                warningCount: session.warningCount,
                reusedExactHashCount: 0
            ),
            roots: cachedRoots,
            resources: resources,
            livePhotos: livePhotos,
            exactDuplicateGroups: duplicateGroups,
            eventSuggestions: [],
            recognizedSidecars: [],
            notices: [],
            warnings: [],
            filesModified: false
        )
    }

    private func cachedScanResources(
        sessionID: String,
        rootsByID: [String: RootRegistryRow]
    ) throws -> [CachedScanResourceRow] {
        try withStatement(
            """
            SELECT r.id, ar.asset_id, r.root_id, r.relative_path, r.file_name,
                   r.media_kind, ar.role, r.byte_size, r.added_at,
                   r.capture_local_time, r.capture_utc_offset, r.capture_instant,
                   r.capture_source, r.capture_confidence, r.exact_hash,
                   rlms.status, r.metadata_probe_failed
            FROM resources r
            LEFT JOIN asset_resources ar
              ON ar.resource_id = r.id AND ar.last_seen_session = ?
            LEFT JOIN resource_live_metadata_status rlms
              ON rlms.resource_id = r.id AND rlms.last_seen_session = ?
            WHERE r.last_seen_session = ?
            ORDER BY r.root_id, r.relative_path
            """,
            bindings: [.text(sessionID), .text(sessionID), .text(sessionID)]
        ) { statement in
            var rows: [CachedScanResourceRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let resourceText = sqlite3_column_text(statement, 0),
                      let rootText = sqlite3_column_text(statement, 2),
                      let relativeText = sqlite3_column_text(statement, 3),
                      let fileNameText = sqlite3_column_text(statement, 4),
                      let mediaText = sqlite3_column_text(statement, 5),
                      let mediaKind = MediaKind(rawValue: String(cString: mediaText))
                else {
                    throw sqliteError(sql: "SELECT reusable scan resources")
                }

                let rootID = String(cString: rootText)
                guard let root = rootsByID[rootID] else {
                    throw CatalogError.invalidCatalogValue(
                        "The cached scan references a root that is no longer active."
                    )
                }
                let role: ResourceRole
                if let roleText = sqlite3_column_text(statement, 6),
                   let parsedRole = ResourceRole(rawValue: String(cString: roleText)) {
                    role = parsedRole
                } else if mediaKind == .sidecar {
                    role = .sidecar
                } else {
                    throw CatalogError.invalidCatalogValue(
                        "The cached scan is missing a media resource role."
                    )
                }

                let captureTime: CaptureTime?
                if let sourceText = sqlite3_column_text(statement, 12),
                   let confidenceText = sqlite3_column_text(statement, 13),
                   let source = CaptureTimeSource(rawValue: String(cString: sourceText)),
                   let confidence = CaptureTimeConfidence(rawValue: String(cString: confidenceText)) {
                    captureTime = CaptureTime(
                        localTimestamp: sqlite3_column_text(statement, 9)
                            .map { String(cString: $0) },
                        utcOffset: sqlite3_column_text(statement, 10)
                            .map { String(cString: $0) },
                        instant: sqlite3_column_type(statement, 11) == SQLITE_NULL
                            ? nil
                            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                        source: source,
                        confidence: confidence
                    )
                } else {
                    captureTime = nil
                }

                let exactHash: Data?
                if sqlite3_column_type(statement, 14) != SQLITE_NULL,
                   let bytes = sqlite3_column_blob(statement, 14) {
                    exactHash = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 14)))
                } else {
                    exactHash = nil
                }
                let timedStatus = sqlite3_column_text(statement, 15)
                    .flatMap { LivePhotoTimedMetadataStatus(rawValue: String(cString: $0)) }
                let assetID = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let addedAt = sqlite3_column_type(statement, 8) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
                let report = ScannedResourceReport(
                    resourceID: String(cString: resourceText),
                    assetID: assetID,
                    rootID: rootID,
                    rootLabel: root.label,
                    relativePath: String(cString: relativeText),
                    fileName: String(cString: fileNameText),
                    mediaKind: mediaKind,
                    role: role,
                    byteSize: sqlite3_column_int64(statement, 7),
                    addedAt: addedAt,
                    captureTime: captureTime
                )
                rows.append(CachedScanResourceRow(
                    report: report,
                    exactHash: exactHash,
                    timedMetadataStatus: timedStatus,
                    metadataProbeFailed: sqlite3_column_int64(statement, 16) != 0
                ))
            }
            return rows
        }
    }

    private func cachedDuplicateGroups(
        sessionID: String,
        resourcesByID: [String: CachedScanResourceRow]
    ) throws -> [ExactDuplicateGroupReport] {
        try withStatement(
            """
            SELECT edg.id, edg.byte_size, edm.resource_id
            FROM exact_duplicate_groups edg
            JOIN exact_duplicate_members edm ON edm.group_id = edg.id
            WHERE edg.last_seen_session = ? AND edm.last_seen_session = ?
            ORDER BY edg.sequence_number, edm.resource_id
            """,
            bindings: [.text(sessionID), .text(sessionID)]
        ) { statement in
            var order: [String] = []
            var byteSizes: [String: Int64] = [:]
            var members: [String: [ResourceReference]] = [:]
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let groupText = sqlite3_column_text(statement, 0),
                      let resourceText = sqlite3_column_text(statement, 2)
                else {
                    throw sqliteError(sql: "SELECT reusable exact duplicate groups")
                }
                let groupID = String(cString: groupText)
                let resourceID = String(cString: resourceText)
                guard let row = resourcesByID[resourceID] else {
                    throw CatalogError.invalidCatalogValue(
                        "The cached duplicate membership no longer matches the scan snapshot."
                    )
                }
                if members[groupID] == nil { order.append(groupID) }
                byteSizes[groupID] = sqlite3_column_int64(statement, 1)
                members[groupID, default: []].append(resourceReference(row.report))
            }
            return order.compactMap { groupID in
                guard let byteSize = byteSizes[groupID], let groupMembers = members[groupID] else {
                    return nil
                }
                return ExactDuplicateGroupReport(
                    groupID: groupID,
                    byteSize: byteSize,
                    members: groupMembers.sorted(by: cachedResourceReferenceSort)
                )
            }
        }
    }

    private func cachedLiveAssetPairStatus(
        sessionID: String
    ) throws -> [String: LivePhotoOccurrenceStatus] {
        try withStatement(
            """
            SELECT id, pair_status
            FROM logical_assets
            WHERE last_seen_session = ? AND kind = 'live_photo'
            """,
            bindings: [.text(sessionID)]
        ) { statement in
            var values: [String: LivePhotoOccurrenceStatus] = [:]
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let idText = sqlite3_column_text(statement, 0),
                      let statusText = sqlite3_column_text(statement, 1),
                      let status = LivePhotoOccurrenceStatus(rawValue: String(cString: statusText))
                else {
                    continue
                }
                values[String(cString: idText)] = status
            }
            return values
        }
    }

    private func cachedLivePhotoReports(
        resources: [CachedScanResourceRow],
        pairStatusByAssetID: [String: LivePhotoOccurrenceStatus]
    ) -> [LivePhotoAssetReport] {
        let liveRows = resources.filter {
            ($0.report.role == .photo || $0.report.role == .pairedVideo)
                && $0.report.assetID != nil
        }
        let byAsset = Dictionary(grouping: liveRows) { $0.report.assetID! }

        return byAsset.map { assetID, assetRows in
            let byRoot = Dictionary(grouping: assetRows) { $0.report.rootID }
            let occurrences = byRoot.values
                .flatMap { cachedPartitionLiveOccurrences($0) }
                .map { occurrenceRows -> LivePhotoOccurrenceReport in
                    let first = occurrenceRows[0].report
                    let stillCount = occurrenceRows.count { $0.report.role == .photo }
                    let videoCount = occurrenceRows.count { $0.report.role == .pairedVideo }
                    return LivePhotoOccurrenceReport(
                        rootID: first.rootID,
                        rootLabel: first.rootLabel,
                        status: cachedLiveOccurrenceStatus(
                            occurrenceRows,
                            allAssetRows: assetRows,
                            aggregatePairStatus: pairStatusByAssetID[assetID]
                        ),
                        stillCount: stillCount,
                        videoCount: videoCount,
                        resources: occurrenceRows
                            .map { resourceReference($0.report) }
                            .sorted(by: cachedResourceReferenceSort)
                    )
                }
                .sorted {
                    let lhsPath = $0.resources.map(\.relativePath).sorted().first ?? ""
                    let rhsPath = $1.resources.map(\.relativePath).sorted().first ?? ""
                    return ($0.rootID, lhsPath) < ($1.rootID, rhsPath)
                }
            return LivePhotoAssetReport(
                assetID: assetID,
                occurrenceCount: occurrences.count,
                stillCopyCount: assetRows.count { $0.report.role == .photo },
                videoCopyCount: assetRows.count { $0.report.role == .pairedVideo },
                occurrences: occurrences
            )
        }
        .sorted { $0.assetID < $1.assetID }
    }

    private func cachedPartitionLiveOccurrences(
        _ resources: [CachedScanResourceRow]
    ) -> [[CachedScanResourceRow]] {
        let byDirectory = Dictionary(grouping: resources) {
            ($0.report.relativePath as NSString).deletingLastPathComponent
        }
        var occurrences: [[CachedScanResourceRow]] = []
        for directoryRows in byDirectory.values {
            let byStem = Dictionary(grouping: directoryRows) {
                ((($0.report.relativePath as NSString).lastPathComponent) as NSString)
                    .deletingPathExtension
                    .lowercased()
            }
            var consumed = Set<String>()
            for stemRows in byStem.values {
                let stills = stemRows.filter { $0.report.role == .photo }
                let videos = stemRows.filter { $0.report.role == .pairedVideo }
                guard stills.count == 1, videos.count == 1 else { continue }
                let pair = [stills[0], videos[0]].sorted(by: cachedResourceRowSort)
                occurrences.append(pair)
                consumed.formUnion(pair.map { $0.report.resourceID })
            }
            let remainder = directoryRows
                .filter { !consumed.contains($0.report.resourceID) }
                .sorted(by: cachedResourceRowSort)
            if !remainder.isEmpty { occurrences.append(remainder) }
        }
        return occurrences.sorted {
            let lhs = $0.first?.report.relativePath ?? ""
            let rhs = $1.first?.report.relativePath ?? ""
            return lhs < rhs
        }
    }

    private func cachedLiveOccurrenceStatus(
        _ occurrence: [CachedScanResourceRow],
        allAssetRows: [CachedScanResourceRow],
        aggregatePairStatus: LivePhotoOccurrenceStatus?
    ) -> LivePhotoOccurrenceStatus {
        let stillCount = occurrence.count { $0.report.role == .photo }
        let videos = occurrence.filter { $0.report.role == .pairedVideo }
        let countStatus = AssetAssembler.occurrenceStatus(
            stillCount: stillCount,
            videoCount: videos.count
        )
        guard countStatus == .complete, let video = videos.first else {
            return countStatus
        }

        if let timedStatus = video.timedMetadataStatus {
            switch timedStatus {
            case .valid: return .complete
            case .missing: return .stillImageTimeMissing
            case .invalid: return .stillImageTimeInvalid
            case .unreadable, .notApplicable: return .stillImageTimeUnreadable
            }
        }

        if let aggregatePairStatus, aggregatePairStatus != .complete {
            switch aggregatePairStatus {
            case .stillImageTimeMissing, .stillImageTimeInvalid, .stillImageTimeUnreadable:
                return aggregatePairStatus
            default:
                break
            }
        }

        if aggregatePairStatus == .complete {
            let allVideos = allAssetRows.filter { $0.report.role == .pairedVideo }
            let hashes = allVideos.compactMap(\.exactHash)
            if hashes.count == allVideos.count, Set(hashes).count == 1 {
                return .complete
            }
        }

        // Catalogs created before resource_live_metadata_status existed cannot
        // identify which non-identical paired-video variant carried a valid
        // still-image-time marker. Keep that occurrence out of automatic cleanup.
        return .stillImageTimeUnreadable
    }

    private func cachedRecognizedSidecarCount(
        sessionID: String,
        rootID: String
    ) throws -> Int {
        Int(try queryText(
            """
            SELECT CAST(COUNT(*) AS TEXT)
            FROM sidecar_links sl
            JOIN resources r ON r.id = sl.sidecar_resource_id
            WHERE sl.last_seen_session = ? AND r.root_id = ? AND r.last_seen_session = ?
            """,
            bindings: [.text(sessionID), .text(rootID), .text(sessionID)]
        ) ?? "0") ?? 0
    }

    private func resourceReference(_ resource: ScannedResourceReport) -> ResourceReference {
        ResourceReference(
            rootID: resource.rootID,
            rootLabel: resource.rootLabel,
            relativePath: resource.relativePath,
            role: resource.role,
            byteSize: resource.byteSize
        )
    }

    private func cachedResourceRowSort(
        _ lhs: CachedScanResourceRow,
        _ rhs: CachedScanResourceRow
    ) -> Bool {
        (lhs.report.rootLabel, lhs.report.relativePath)
            < (rhs.report.rootLabel, rhs.report.relativePath)
    }

    private func cachedResourceReferenceSort(
        _ lhs: ResourceReference,
        _ rhs: ResourceReference
    ) -> Bool {
        (lhs.rootLabel, lhs.relativePath, lhs.role.rawValue)
            < (rhs.rootLabel, rhs.relativePath, rhs.role.rawValue)
    }

    func removeRootFromCurrentCatalog(rootID: String) throws -> Int {
        let resourceCount = Int(try queryText(
            "SELECT CAST(COUNT(*) AS TEXT) FROM resources WHERE root_id = ?",
            bindings: [.text(rootID)]
        ) ?? "0") ?? 0

        try withTransaction {
            try setRootRegistration(rootID: rootID, state: .removed)

            let affectedAssetIDs: [String] = try withStatement(
                """
                SELECT DISTINCT ar.asset_id
                FROM asset_resources ar
                JOIN resources r ON r.id = ar.resource_id
                WHERE r.root_id = ?
                """,
                bindings: [.text(rootID)]
            ) { statement in
                var values: [String] = []
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW,
                          let text = sqlite3_column_text(statement, 0)
                    else {
                        throw sqliteError(sql: "SELECT affected root asset IDs")
                    }
                    values.append(String(cString: text))
                }
                return values
            }

            let affectedDuplicateGroupIDs: [String] = try withStatement(
                """
                SELECT DISTINCT edm.group_id
                FROM exact_duplicate_members edm
                JOIN resources r ON r.id = edm.resource_id
                WHERE r.root_id = ?
                """,
                bindings: [.text(rootID)]
            ) { statement in
                var values: [String] = []
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW,
                          let text = sqlite3_column_text(statement, 0)
                    else {
                        throw sqliteError(sql: "SELECT affected root duplicate group IDs")
                    }
                    values.append(String(cString: text))
                }
                return values
            }

            let collections: [(String, String)] = try withStatement(
                "SELECT source_key, collection_id FROM source_collection_keys WHERE source_key LIKE ?",
                bindings: [.text(rootID + ":%")]
            ) { statement in
                var rows: [(String, String)] = []
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW,
                          let keyText = sqlite3_column_text(statement, 0),
                          let collectionText = sqlite3_column_text(statement, 1)
                    else {
                        throw sqliteError(sql: "SELECT root source collections")
                    }
                    rows.append((String(cString: keyText), String(cString: collectionText)))
                }
                return rows
            }
            for row in collections {
                try run("DELETE FROM source_collection_keys WHERE source_key = ?", bindings: [.text(row.0)])
                try run("DELETE FROM collections WHERE id = ?", bindings: [.text(row.1)])
            }

            try run("DELETE FROM resources WHERE root_id = ?", bindings: [.text(rootID)])
            for assetID in affectedAssetIDs {
                try run(
                    """
                    DELETE FROM logical_assets
                    WHERE id = ?
                      AND NOT EXISTS (
                          SELECT 1 FROM asset_resources ar WHERE ar.asset_id = logical_assets.id
                      )
                    """,
                    bindings: [.text(assetID)]
                )
            }
            for groupID in affectedDuplicateGroupIDs {
                try run(
                    """
                    DELETE FROM exact_duplicate_groups
                    WHERE id = ?
                      AND (SELECT COUNT(*) FROM exact_duplicate_members edm WHERE edm.group_id = exact_duplicate_groups.id) < 2
                    """,
                    bindings: [.text(groupID)]
                )
            }
        }
        return resourceCount
    }

    func resourceLocationExists(
        resourceID: String,
        rootID: String,
        relativePath: String
    ) throws -> Bool {
        try queryText(
            """
            SELECT '1' FROM resource_locations
            WHERE resource_id = ? AND root_id = ? AND relative_path = ?
            LIMIT 1
            """,
            bindings: [.text(resourceID), .text(rootID), .text(relativePath)]
        ) != nil
    }

    func quarantineRestoreExactHash(rootID: String, relativePath: String) throws -> Data? {
        try queryBlob(
            "SELECT exact_hash FROM resources WHERE root_id = ? AND relative_path = ?",
            bindings: [.text(rootID), .text(relativePath)]
        )
    }

    func archivePlanExactHash(resourceID: String, sessionID: String) throws -> Data? {
        try queryBlob(
            "SELECT exact_hash FROM resources WHERE id = ? AND last_seen_session = ?",
            bindings: [.text(resourceID), .text(sessionID)]
        )
    }

    func archiveCopyEvidence(resourceID: String) throws -> ArchiveCopyCatalogEvidence? {
        try withStatement(
            """
            SELECT r.id, r.root_id, r.relative_path, ar.asset_id, ar.role, r.byte_size, r.exact_hash
            FROM resources r
            JOIN asset_resources ar ON ar.resource_id = r.id
            WHERE r.id = ?
            LIMIT 1
            """,
            bindings: [.text(resourceID)]
        ) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW,
                  let resourceText = sqlite3_column_text(statement, 0),
                  let rootText = sqlite3_column_text(statement, 1),
                  let relativeText = sqlite3_column_text(statement, 2),
                  let assetText = sqlite3_column_text(statement, 3),
                  let roleText = sqlite3_column_text(statement, 4),
                  let role = ResourceRole(rawValue: String(cString: roleText)),
                  sqlite3_column_type(statement, 6) != SQLITE_NULL,
                  let hashBytes = sqlite3_column_blob(statement, 6)
            else {
                throw sqliteError(sql: "SELECT archive copy evidence")
            }
            let hashCount = Int(sqlite3_column_bytes(statement, 6))
            return ArchiveCopyCatalogEvidence(
                resourceID: String(cString: resourceText),
                rootID: String(cString: rootText),
                relativePath: String(cString: relativeText),
                assetID: String(cString: assetText),
                role: role,
                byteSize: sqlite3_column_int64(statement, 5),
                exactHash: Data(bytes: hashBytes, count: hashCount)
            )
        }
    }

    func archiveRootInventoryRows(
        rootID: String,
        sessionID: String
    ) throws -> [ArchiveRootInventoryCatalogRow] {
        try withStatement(
            """
            SELECT r.id, ar.asset_id, r.relative_path, r.media_kind, ar.role,
                   r.byte_size, r.modified_at, r.exact_hash
            FROM resources r
            LEFT JOIN asset_resources ar ON ar.resource_id = r.id
            WHERE r.root_id = ? AND r.last_seen_session = ?
            ORDER BY r.relative_path, r.id
            """,
            bindings: [.text(rootID), .text(sessionID)]
        ) { statement in
            var rows: [ArchiveRootInventoryCatalogRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let resourceText = sqlite3_column_text(statement, 0),
                      let relativeText = sqlite3_column_text(statement, 2),
                      let mediaText = sqlite3_column_text(statement, 3),
                      let mediaKind = MediaKind(rawValue: String(cString: mediaText))
                else {
                    throw sqliteError(sql: "SELECT archive root inventory rows")
                }
                let assetID = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let role = sqlite3_column_text(statement, 4)
                    .flatMap { ResourceRole(rawValue: String(cString: $0)) }
                let modifiedAt = sqlite3_column_type(statement, 6) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
                let exactHash: Data?
                if sqlite3_column_type(statement, 7) != SQLITE_NULL,
                   let bytes = sqlite3_column_blob(statement, 7) {
                    exactHash = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 7)))
                } else {
                    exactHash = nil
                }
                rows.append(ArchiveRootInventoryCatalogRow(
                    resourceID: String(cString: resourceText),
                    assetID: assetID,
                    relativePath: String(cString: relativeText),
                    mediaKind: mediaKind,
                    role: role,
                    byteSize: sqlite3_column_int64(statement, 5),
                    modifiedAt: modifiedAt,
                    exactHash: exactHash
                ))
            }
            return rows
        }
    }

    private func queryText(_ sql: String, bindings: [SQLiteBinding]) throws -> String? {
        try withStatement(sql, bindings: bindings) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else {
                throw sqliteError(sql: sql)
            }
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }

    private func queryBlob(_ sql: String, bindings: [SQLiteBinding]) throws -> Data? {
        try withStatement(sql, bindings: bindings) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else {
                throw sqliteError(sql: sql)
            }
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  let bytes = sqlite3_column_blob(statement, 0)
            else {
                return nil
            }
            let count = Int(sqlite3_column_bytes(statement, 0))
            return Data(bytes: bytes, count: count)
        }
    }

    private func withStatement<T>(
        _ sql: String,
        bindings: [SQLiteBinding],
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let database else {
            throw CatalogError.sqlite(message: "database is closed", sql: sql)
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw sqliteError(sql: sql)
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            try bind(binding, to: statement, index: Int32(offset + 1), sql: sql)
        }
        return try body(statement)
    }

    private func bind(
        _ binding: SQLiteBinding,
        to statement: OpaquePointer,
        index: Int32,
        sql: String
    ) throws {
        let result: Int32
        switch binding {
        case let .text(value):
            result = sqlite3_bind_text(statement, index, value, -1, transientDestructor)
        case let .int64(value):
            result = sqlite3_bind_int64(statement, index, value)
        case let .double(value):
            result = sqlite3_bind_double(statement, index, value)
        case let .blob(value):
            result = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    index,
                    bytes.baseAddress,
                    Int32(value.count),
                    transientDestructor
                )
            }
        case .null:
            result = sqlite3_bind_null(statement, index)
        }

        guard result == SQLITE_OK else {
            throw sqliteError(sql: sql)
        }
    }

    private func sqliteError(sql: String) -> CatalogError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "database is closed"
        return .sqlite(message: message, sql: sql)
    }

    private func opaqueID(prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}
