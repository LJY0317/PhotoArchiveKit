import Foundation

public struct ArchiveRootInventoryReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let rootID: String
    public let resourceCount: Int
    public let mediaResourceCount: Int
    public let folderCount: Int
    public let exactHashResourceCount: Int
    public let reusedExactHashCount: Int
    public let snapshotWritten: Bool
    public let mediaFilesModified: Bool
    public let inventoryPath: String

    public init(
        schemaVersion: Int = 1,
        rootID: String,
        resourceCount: Int,
        mediaResourceCount: Int,
        folderCount: Int,
        exactHashResourceCount: Int,
        reusedExactHashCount: Int,
        snapshotWritten: Bool,
        mediaFilesModified: Bool = false,
        inventoryPath: String
    ) {
        self.schemaVersion = schemaVersion
        self.rootID = rootID
        self.resourceCount = resourceCount
        self.mediaResourceCount = mediaResourceCount
        self.folderCount = folderCount
        self.exactHashResourceCount = exactHashResourceCount
        self.reusedExactHashCount = reusedExactHashCount
        self.snapshotWritten = snapshotWritten
        self.mediaFilesModified = mediaFilesModified
        self.inventoryPath = inventoryPath
    }
}

public struct AgentSafeArchiveRootInventoryReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let rootID: String
    public let resourceCount: Int
    public let mediaResourceCount: Int
    public let folderCount: Int
    public let exactHashResourceCount: Int
    public let reusedExactHashCount: Int
    public let snapshotWritten: Bool
    public let mediaFilesModified: Bool

    public init(report: ArchiveRootInventoryReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        rootID = report.rootID
        resourceCount = report.resourceCount
        mediaResourceCount = report.mediaResourceCount
        folderCount = report.folderCount
        exactHashResourceCount = report.exactHashResourceCount
        reusedExactHashCount = report.reusedExactHashCount
        snapshotWritten = report.snapshotWritten
        mediaFilesModified = report.mediaFilesModified
    }
}

public enum ArchiveRootInventoryError: LocalizedError {
    case requiresSingleArchiveRoot
    case stableMarkerRequired(String)
    case rootChanged(String)
    case missingExactHash(String)
    case invalidInventory(String)

    public var errorDescription: String? {
        switch self {
        case .requiresSingleArchiveRoot:
            return "Archive inventory requires exactly one archive root scan."
        case let .stableMarkerRequired(path):
            return "Archive root requires a stable .photoarchive-root marker before indexing: \(path)"
        case let .rootChanged(path):
            return "Archive root marker changed while the inventory was being prepared: \(path)"
        case let .missingExactHash(resourceID):
            return "Archive inventory is missing an exact hash for media resource \(resourceID)."
        case let .invalidInventory(message):
            return "Invalid archive root inventory: \(message)"
        }
    }
}

public enum ArchiveRootIndexer {
    public static func run(
        rootURL rawRootURL: URL,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL,
        writeSnapshot: Bool = false,
        reuseMetadataCache: Bool = true,
        reuseHashCache: Bool = true,
        maxConcurrentProbes: Int = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8),
        progressHandler: ScanProgressHandler? = nil
    ) async throws -> ArchiveRootInventoryReport {
        let rootURL = rawRootURL.resolvingSymlinksInPath().standardizedFileURL
        guard try RootMarkerStore.readIfPresent(at: rootURL) != nil else {
            throw ArchiveRootInventoryError.stableMarkerRequired(rootURL.path)
        }

        let scanner = try ArchiveScanner(catalogURL: catalogURL)
        let scanReport = try await scanner.scan(
            roots: [ScanRoot(url: rootURL, kind: .archive)],
            options: ScanOptions(
                computeExactDuplicates: true,
                computeArchiveIntegrityPreconditions: true,
                reuseMetadataCache: reuseMetadataCache,
                reuseExactHashCache: reuseHashCache,
                exactDuplicateEngine: .automatic,
                maxConcurrentProbes: max(1, maxConcurrentProbes),
                progressHandler: progressHandler
            )
        )
        return try ArchiveRootInventoryStore.makeReport(
            scanReport: scanReport,
            rootURL: rootURL,
            catalogURL: catalogURL,
            writeSnapshot: writeSnapshot
        )
    }
}

struct ArchiveRootInventoryCatalogRow: Sendable {
    let resourceID: String
    let assetID: String?
    let relativePath: String
    let mediaKind: MediaKind
    let role: ResourceRole?
    let byteSize: Int64
    let modifiedAt: Date?
    let exactHash: Data?
}

private struct InventoryEnvelope<Payload: Codable>: Codable {
    let type: String
    let payload: Payload
}

private struct InventoryHeader: Codable {
    let format: String
    let schemaVersion: Int
    let rootID: String
    let markerKey: String
    let createdAt: Date
    let resourceCount: Int
    let folderCount: Int
}

private struct InventoryFolder: Codable {
    let relativePath: String
}

private struct InventoryResource: Codable {
    let resourceID: String
    let assetID: String?
    let relativePath: String
    let mediaKind: MediaKind
    let role: ResourceRole?
    let byteSize: Int64
    let modifiedAtSeconds: Double?
    let sha256: String?
}

enum ArchiveRootInventoryStore {
    static let relativeInventoryPath = ".photoarchive/inventory-v1.jsonl"
    private static let format = "photoarchive-root-inventory-v1"

    static func inventoryURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(relativeInventoryPath, isDirectory: false)
    }

    static func makeReport(
        scanReport: ScanReport,
        rootURL rawRootURL: URL,
        catalogURL: URL,
        writeSnapshot: Bool
    ) throws -> ArchiveRootInventoryReport {
        guard scanReport.roots.count == 1,
              let root = scanReport.roots.first,
              root.kind == .archive
        else {
            throw ArchiveRootInventoryError.requiresSingleArchiveRoot
        }

        let rootURL = rawRootURL.resolvingSymlinksInPath().standardizedFileURL
        guard let marker = try RootMarkerStore.readIfPresent(at: rootURL) else {
            throw ArchiveRootInventoryError.stableMarkerRequired(rootURL.path)
        }
        guard root.stableMarkerKey == marker.markerKey else {
            throw ArchiveRootInventoryError.rootChanged(rootURL.path)
        }

        let catalog = try SQLiteCatalog(url: catalogURL)
        let rows = try catalog.archiveRootInventoryRows(
            rootID: root.rootID,
            sessionID: scanReport.sessionID
        )
        let folders = folderPaths(rows: rows)
        let mediaRows = rows.filter { $0.mediaKind != .sidecar }
        for row in mediaRows where row.exactHash == nil {
            throw ArchiveRootInventoryError.missingExactHash(row.resourceID)
        }

        let outputURL = inventoryURL(rootURL: rootURL)
        if writeSnapshot {
            try write(
                rows: rows,
                folders: folders,
                rootID: root.rootID,
                markerKey: marker.markerKey,
                outputURL: outputURL
            )
        }

        return ArchiveRootInventoryReport(
            rootID: root.rootID,
            resourceCount: rows.count,
            mediaResourceCount: mediaRows.count,
            folderCount: folders.count,
            exactHashResourceCount: mediaRows.filter { $0.exactHash != nil }.count,
            reusedExactHashCount: scanReport.summary.reusedExactHashCount,
            snapshotWritten: writeSnapshot,
            inventoryPath: outputURL.path
        )
    }

    static func portableHashCache(
        rootURL rawRootURL: URL,
        markerKey: String
    ) throws -> [String: PortableHashEvidence] {
        let url = inventoryURL(rootURL: rawRootURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard let first = lines.first else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(InventoryEnvelope<InventoryHeader>.self, from: Data(first))
        guard header.type == "header",
              header.payload.format == format,
              header.payload.schemaVersion == 1,
              header.payload.markerKey == markerKey
        else {
            throw ArchiveRootInventoryError.invalidInventory("header or root marker mismatch")
        }

        var result: [String: PortableHashEvidence] = [:]
        for line in lines.dropFirst() {
            guard let probe = try? decoder.decode(InventoryEnvelope<InventoryResource>.self, from: Data(line)),
                  probe.type == "resource",
                  let sha = probe.payload.sha256,
                  let hash = Data(hexString: sha)
            else {
                continue
            }
            result[probe.payload.relativePath] = PortableHashEvidence(
                byteSize: probe.payload.byteSize,
                modifiedAt: probe.payload.modifiedAtSeconds.map(Date.init(timeIntervalSince1970:)),
                exactHash: hash
            )
        }
        return result
    }

    private static func folderPaths(rows: [ArchiveRootInventoryCatalogRow]) -> [String] {
        var folders = Set<String>()
        for row in rows {
            let directory = (row.relativePath as NSString).deletingLastPathComponent
            guard !directory.isEmpty else { continue }
            var current = ""
            for component in directory.split(separator: "/").map(String.init) where !component.isEmpty {
                current = current.isEmpty ? component : current + "/" + component
                folders.insert(current)
            }
        }
        return folders.sorted()
    }

    private static func write(
        rows: [ArchiveRootInventoryCatalogRow],
        folders: [String],
        rootID: String,
        markerKey: String,
        outputURL: URL
    ) throws {
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".inventory-v1-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        func append<T: Codable>(_ type: String, _ payload: T) throws {
            var data = try encoder.encode(InventoryEnvelope(type: type, payload: payload))
            data.append(0x0A)
            try handle.write(contentsOf: data)
        }

        try append("header", InventoryHeader(
            format: format,
            schemaVersion: 1,
            rootID: rootID,
            markerKey: markerKey,
            createdAt: Date(),
            resourceCount: rows.count,
            folderCount: folders.count
        ))
        for folder in folders {
            try append("folder", InventoryFolder(relativePath: folder))
        }
        for row in rows {
            try append("resource", InventoryResource(
                resourceID: row.resourceID,
                assetID: row.assetID,
                relativePath: row.relativePath,
                mediaKind: row.mediaKind,
                role: row.role,
                byteSize: row.byteSize,
                modifiedAtSeconds: row.modifiedAt?.timeIntervalSince1970,
                sha256: row.exactHash?.lowercaseHexString
            ))
        }
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        }
    }
}

struct PortableHashEvidence: Sendable {
    let byteSize: Int64
    let modifiedAt: Date?
    let exactHash: Data
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
