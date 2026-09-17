import Darwin
import Foundation

enum FolderSyncDriveRecoveryKind: String, Codable, Sendable, Equatable {
    case baseline
    case appVersion = "app_version"
    case conflict
}

struct FolderSyncDriveRecoveryRecord: Codable, Sendable, Equatable, Identifiable {
    let originalRelativePath: String
    let kind: FolderSyncDriveRecoveryKind
    let reference: FolderSyncDriveRevisionReference
    let recordedAt: Date

    var id: String {
        reference.fileID + ":" + reference.revisionID
    }
}

enum FolderSyncDriveRecoveryStore {
    private struct FileContents: Codable {
        let schemaVersion: Int
        var records: [FolderSyncDriveRecoveryRecord]
    }

    static func url(for connection: FolderSyncConnection) -> URL {
        FolderSyncJournalStore.connectionStateDirectory(for: connection)
            .appendingPathComponent("drive-revision-recovery.json", isDirectory: false)
    }

    static func load(connection: FolderSyncConnection) throws -> [FolderSyncDriveRecoveryRecord] {
        let fileURL = url(for: connection)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let contents = try decoder.decode(FileContents.self, from: Data(contentsOf: fileURL))
            guard contents.schemaVersion == 1 else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            return contents.records
        } catch let error as FolderSyncConnectionError {
            throw error
        } catch {
            throw FolderSyncConnectionError.recoveryRequired
        }
    }

    static func upsert(
        _ record: FolderSyncDriveRecoveryRecord,
        connection: FolderSyncConnection
    ) throws {
        var records = try load(connection: connection)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try save(records, connection: connection)
    }

    private static func save(
        _ records: [FolderSyncDriveRecoveryRecord],
        connection: FolderSyncConnection
    ) throws {
        let fileURL = url(for: connection)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let contents = FileContents(
            schemaVersion: 1,
            records: records.sorted {
                ($0.originalRelativePath, $0.kind.rawValue, $0.id)
                    < ($1.originalRelativePath, $1.kind.rawValue, $1.id)
            }
        )
        try encoder.encode(contents).write(to: fileURL, options: .atomic)
        _ = chmod(fileURL.path, S_IRUSR | S_IWUSR)
    }
}
