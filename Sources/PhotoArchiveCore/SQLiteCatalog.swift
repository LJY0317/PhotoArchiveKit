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
            try run(
                "UPDATE source_roots SET label = ?, kind = ?, canonical_path = ? WHERE id = ?",
                bindings: [.text(input.label), .text(input.kind.rawValue), .text(path), .text(markerRootID)]
            )
            try upsertRootMetadata(rootID: markerRootID, provenance: input.provenance)
            return RootDescriptor(
                id: markerRootID,
                label: input.label,
                kind: input.kind,
                provenance: input.provenance,
                url: canonicalURL,
                markerKey: markerKey
            )
        }

        if let existingID = try queryText(
            "SELECT id FROM source_roots WHERE canonical_path = ?",
            bindings: [.text(path)]
        ) {
            try run(
                "UPDATE source_roots SET label = ?, kind = ? WHERE id = ?",
                bindings: [.text(input.label), .text(input.kind.rawValue), .text(existingID)]
            )
            try upsertRootMetadata(rootID: existingID, provenance: input.provenance)
            if let markerKey {
                try upsertRootMarker(markerKey: markerKey, rootID: existingID)
            }
            return RootDescriptor(
                id: existingID,
                label: input.label,
                kind: input.kind,
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
        return RootDescriptor(
            id: id,
            label: input.label,
            kind: input.kind,
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
                        byte_size, modified_at, capture_local_time, capture_utc_offset,
                        capture_instant, capture_source, capture_confidence, exact_hash,
                        live_identifier_fingerprint, metadata_probe_failed, last_seen_session
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        modified_at = ?, capture_local_time = ?, capture_utc_offset = ?,
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
            CREATE INDEX IF NOT EXISTS resource_locations_last_seen_idx
                ON resource_locations(last_seen_session);
            CREATE INDEX IF NOT EXISTS provider_objects_asset_idx
                ON provider_objects(asset_id);
            """
        )
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

    func quarantineRestoreRootPath(rootID: String) throws -> String? {
        try sourceRootPath(rootID: rootID)
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
