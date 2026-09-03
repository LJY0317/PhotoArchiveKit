import Foundation
import SQLite3

public enum PhotoArchivePaths {
    public static var defaultCatalogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PhotoArchiveKit", isDirectory: true)
            .appendingPathComponent("catalog.sqlite3", isDirectory: false)
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

    func resolveRoot(_ input: ScanRoot) throws -> RootDescriptor {
        let canonicalURL = input.url.resolvingSymlinksInPath().standardizedFileURL
        let path = canonicalURL.path

        if let existingID = try queryText(
            "SELECT id FROM source_roots WHERE canonical_path = ?",
            bindings: [.text(path)]
        ) {
            try run(
                "UPDATE source_roots SET label = ?, kind = ? WHERE id = ?",
                bindings: [.text(input.label), .text(input.kind.rawValue), .text(existingID)]
            )
            try upsertRootMetadata(rootID: existingID, provenance: input.provenance)
            return RootDescriptor(
                id: existingID,
                label: input.label,
                kind: input.kind,
                provenance: input.provenance,
                url: canonicalURL
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
        return RootDescriptor(
            id: id,
            label: input.label,
            kind: input.kind,
            provenance: input.provenance,
            url: canonicalURL
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
            let existingID = try queryText(
                "SELECT id FROM resources WHERE root_id = ? AND relative_path = ?",
                bindings: [
                    .text(resources[index].root.id),
                    .text(resources[index].relativePath)
                ]
            )
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
                        file_name = ?, file_extension = ?, media_kind = ?, byte_size = ?,
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

            resources[index].persistentResourceID = resourceID
        }
    }

    func persistAssets(
        sessionID: String,
        resources: inout [ProbedResource]
    ) throws -> [Data: String] {
        for resource in resources where resource.persistentResourceID != nil {
            try run(
                "DELETE FROM asset_resources WHERE resource_id = ?",
                bindings: [.text(resource.persistentResourceID!)]
            )
        }

        var liveAssetIDs: [Data: String] = [:]
        let liveGroups = Dictionary(grouping: resources.indices.filter {
            resources[$0].identifierFingerprint != nil
                && (resources[$0].mediaKind == .image || resources[$0].mediaKind == .video)
        }) { resources[$0].identifierFingerprint! }

        for (fingerprint, indices) in liveGroups {
            let assetKey = "live:\(fingerprint.base64EncodedString())"
            let assetID = try ensureAsset(
                assetKey: assetKey,
                kind: "live_photo",
                pairStatus: aggregatePairStatus(indices: indices, resources: resources).rawValue,
                sessionID: sessionID
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
                sessionID: sessionID
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
        sessionID: String
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
        let videoCount = indices.count { resources[$0].mediaKind == .video }
        if stillCount > 0, videoCount > 0 {
            return .complete
        }
        return AssetAssembler.occurrenceStatus(stillCount: stillCount, videoCount: videoCount)
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
