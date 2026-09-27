import Darwin
import Foundation

public enum FolderSyncJournalPhase: String, Codable, Sendable, Equatable {
    case planning
    case applying
    case verifying
    case incomplete
    case confirmationRequired = "confirmation_required"
    case recoveryRequired = "recovery_required"
    case completed
}

public enum FolderSyncJournalItemState: String, Codable, Sendable, Equatable {
    case planned
    case incomplete
    case verified
    case confirmationRequired = "confirmation_required"
    case resolved
}

public struct FolderSyncDriveRevisionReference: Codable, Sendable, Equatable, Hashable {
    public let fileID: String
    public let revisionID: String
    public let sha256: Data
    public let byteSize: Int64
    public var keepForeverVerified: Bool

    public init(
        fileID: String,
        revisionID: String,
        sha256: Data,
        byteSize: Int64,
        keepForeverVerified: Bool
    ) {
        self.fileID = fileID
        self.revisionID = revisionID
        self.sha256 = sha256
        self.byteSize = byteSize
        self.keepForeverVerified = keepForeverVerified
    }
}

public struct FolderSyncDrivePreservation: Codable, Sendable, Equatable {
    public var baseline: FolderSyncDriveRevisionReference?
    public var appVersion: FolderSyncDriveRevisionReference?
    public var conflicts: [FolderSyncDriveRevisionReference]
    public var recoveryRunID: String?
    public var expectedSourceSHA256: Data?
    public var observedDuplicateFileIDs: [String]
    public var knownRevisionIDsBeforeMutation: [String]?
    public var verifiedRevisionIDsBeforeMutation: [String]?
    public var mutation: FolderSyncDriveMutationProgress?

    public init(
        baseline: FolderSyncDriveRevisionReference? = nil,
        appVersion: FolderSyncDriveRevisionReference? = nil,
        conflicts: [FolderSyncDriveRevisionReference] = [],
        recoveryRunID: String? = nil,
        expectedSourceSHA256: Data? = nil,
        observedDuplicateFileIDs: [String] = [],
        knownRevisionIDsBeforeMutation: [String]? = nil,
        verifiedRevisionIDsBeforeMutation: [String]? = nil,
        mutation: FolderSyncDriveMutationProgress? = nil
    ) {
        self.baseline = baseline
        self.appVersion = appVersion
        self.conflicts = conflicts
        self.recoveryRunID = recoveryRunID
        self.expectedSourceSHA256 = expectedSourceSHA256
        self.observedDuplicateFileIDs = observedDuplicateFileIDs
        self.knownRevisionIDsBeforeMutation = knownRevisionIDsBeforeMutation
        self.verifiedRevisionIDsBeforeMutation = verifiedRevisionIDsBeforeMutation
        self.mutation = mutation
    }
}

public enum FolderSyncDriveMutationKind: String, Codable, Sendable, Equatable {
    case create
    case overwrite
    case delete
    case move
}

public enum FolderSyncDriveCreationStage: String, Codable, Sendable, Equatable {
    case planned
    case emptyObjectCreated
    case contentUploaded
    case verified
}

public struct FolderSyncDriveMutationProgress: Codable, Sendable, Equatable {
    public let kind: FolderSyncDriveMutationKind
    public let sourceRelativePath: String?
    public let destinationRelativePath: String
    public var mutatedFileID: String?
    public var creationStage: FolderSyncDriveCreationStage?
    public var emptyObjectRevisionID: String?
    public var contentRevisionID: String?
    public var applied: Bool
    public var verified: Bool

    public init(
        kind: FolderSyncDriveMutationKind,
        sourceRelativePath: String? = nil,
        destinationRelativePath: String,
        mutatedFileID: String? = nil,
        creationStage: FolderSyncDriveCreationStage? = nil,
        emptyObjectRevisionID: String? = nil,
        contentRevisionID: String? = nil,
        applied: Bool = false,
        verified: Bool = false
    ) {
        self.kind = kind
        self.sourceRelativePath = sourceRelativePath
        self.destinationRelativePath = destinationRelativePath
        self.mutatedFileID = mutatedFileID
        self.creationStage = creationStage
        self.emptyObjectRevisionID = emptyObjectRevisionID
        self.contentRevisionID = contentRevisionID
        self.applied = applied
        self.verified = verified
    }
}

public enum FolderSyncConflictResolutionStage: String, Codable, Sendable, Equatable {
    case planned
    case preserving
    case preserved
    case applying
    case applied
    case verifying
    case completed
}

public struct FolderSyncConflictResolutionResource: Codable, Sendable, Equatable {
    public let relativePath: String
    public let copyRelativePath: String?
    public let localExpectedSHA256: Data?
    public let remoteExpectedSHA256: Data?
    public var copyDriveFileID: String?
    public var copyDriveMutation: FolderSyncDriveMutationProgress?
    public var sourcePreserved: Bool
    public var applied: Bool
    public var verified: Bool

    public init(
        relativePath: String,
        copyRelativePath: String? = nil,
        localExpectedSHA256: Data? = nil,
        remoteExpectedSHA256: Data? = nil,
        copyDriveFileID: String? = nil,
        copyDriveMutation: FolderSyncDriveMutationProgress? = nil,
        sourcePreserved: Bool = false,
        applied: Bool = false,
        verified: Bool = false
    ) {
        self.relativePath = relativePath
        self.copyRelativePath = copyRelativePath
        self.localExpectedSHA256 = localExpectedSHA256
        self.remoteExpectedSHA256 = remoteExpectedSHA256
        self.copyDriveFileID = copyDriveFileID
        self.copyDriveMutation = copyDriveMutation
        self.sourcePreserved = sourcePreserved
        self.applied = applied
        self.verified = verified
    }
}

public struct FolderSyncConflictResolutionProgress: Codable, Sendable, Equatable {
    public let choice: FolderSyncConflictChoice
    public let expectedFingerprint: String
    public var stage: FolderSyncConflictResolutionStage
    public var resources: [FolderSyncConflictResolutionResource]

    public init(
        choice: FolderSyncConflictChoice,
        expectedFingerprint: String,
        stage: FolderSyncConflictResolutionStage = .planned,
        resources: [FolderSyncConflictResolutionResource]
    ) {
        self.choice = choice
        self.expectedFingerprint = expectedFingerprint
        self.stage = stage
        self.resources = resources
    }
}

public struct FolderSyncJournalResource: Codable, Sendable, Equatable {
    public let relativePath: String
    public let role: ResourceRole
    public var path1Verified: Bool
    public var path2Verified: Bool
    public var drivePreservation: FolderSyncDrivePreservation?

    public init(
        relativePath: String,
        role: ResourceRole,
        path1Verified: Bool = false,
        path2Verified: Bool = false,
        drivePreservation: FolderSyncDrivePreservation? = nil
    ) {
        self.relativePath = relativePath
        self.role = role
        self.path1Verified = path1Verified
        self.path2Verified = path2Verified
        self.drivePreservation = drivePreservation
    }
}

public struct FolderSyncJournalItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var state: FolderSyncJournalItemState
    public var resources: [FolderSyncJournalResource]
    public var note: String?
    public var resolutionChoice: FolderSyncConflictChoice?
    public var conflictResolution: FolderSyncConflictResolutionProgress?

    public init(
        id: String = "SI" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        state: FolderSyncJournalItemState = .planned,
        resources: [FolderSyncJournalResource],
        note: String? = nil,
        resolutionChoice: FolderSyncConflictChoice? = nil,
        conflictResolution: FolderSyncConflictResolutionProgress? = nil
    ) {
        self.id = id
        self.state = state
        self.resources = resources
        self.note = note
        self.resolutionChoice = resolutionChoice
        self.conflictResolution = conflictResolution
    }
}

public struct FolderSyncJournal: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let connectionID: String
    public let operationID: String
    public var currentAttemptID: String
    public let startedAt: Date
    public var updatedAt: Date
    public var retryCount: Int
    public var phase: FolderSyncJournalPhase
    public var preflightCandidatePaths: [String]
    public var unplannedObservedPaths: [String]
    public var historyCheckpointAvailable: Bool
    public var historyRestored: Bool
    public var recoveryArtifactsVerified: Bool
    public var pendingDeletionPlan: FolderSyncDeletionPlan?
    public var items: [FolderSyncJournalItem]

    public init(
        connectionID: String,
        operationID: String,
        currentAttemptID: String,
        startedAt: Date,
        phase: FolderSyncJournalPhase = .planning,
        preflightCandidatePaths: [String] = [],
        items: [FolderSyncJournalItem] = []
    ) {
        self.schemaVersion = 1
        self.connectionID = connectionID
        self.operationID = operationID
        self.currentAttemptID = currentAttemptID
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.retryCount = 0
        self.phase = phase
        self.preflightCandidatePaths = preflightCandidatePaths
        self.unplannedObservedPaths = []
        self.historyCheckpointAvailable = false
        self.historyRestored = false
        self.recoveryArtifactsVerified = false
        self.pendingDeletionPlan = nil
        self.items = items
    }

    public var incompleteItemCount: Int {
        items.count { $0.state != .verified }
    }
}

public enum FolderSyncJournalStore {
    public static func url(for connection: FolderSyncConnection) -> URL {
        connectionStateDirectory(for: connection)
            .appendingPathComponent("sync-journal.json", isDirectory: false)
    }

    public static func load(connection: FolderSyncConnection) throws -> FolderSyncJournal? {
        let journalURL = url(for: connection)
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let journal = try decoder.decode(
                FolderSyncJournal.self,
                from: Data(contentsOf: journalURL)
            )
            guard journal.schemaVersion == 1,
                  journal.connectionID == connection.id
            else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            return journal
        } catch let error as FolderSyncConnectionError {
            throw error
        } catch {
            throw FolderSyncConnectionError.recoveryRequired
        }
    }

    public static func save(
        _ journal: FolderSyncJournal,
        connection: FolderSyncConnection
    ) throws {
        let journalURL = url(for: connection)
        try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
        _ = chmod(journalURL.path, S_IRUSR | S_IWUSR)
    }

    public static func remove(connection: FolderSyncConnection) throws {
        let journalURL = url(for: connection)
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        try FileManager.default.removeItem(at: journalURL)
    }

    static func connectionStateDirectory(for connection: FolderSyncConnection) -> URL {
        URL(fileURLWithPath: connection.workDirectoryPath, isDirectory: true)
            .deletingLastPathComponent()
    }
}

enum FolderSyncHistoryCheckpoint {
    private static let directoryName = "bisync-history-checkpoints"

    static func create(
        connection: FolderSyncConnection,
        attemptID: String
    ) throws {
        let fileManager = FileManager.default
        let workDirectory = URL(
            fileURLWithPath: connection.workDirectoryPath,
            isDirectory: true
        )
        let checkpoint = checkpointURL(connection: connection, attemptID: attemptID)
        if fileManager.fileExists(atPath: checkpoint.path) {
            try fileManager.removeItem(at: checkpoint)
        }
        try fileManager.createDirectory(at: checkpoint, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: workDirectory.path) else { return }
        for child in try fileManager.contentsOfDirectory(
            at: workDirectory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) where child.lastPathComponent != "runs" {
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            try fileManager.copyItem(
                at: child,
                to: checkpoint.appendingPathComponent(child.lastPathComponent)
            )
        }
    }

    static func restore(
        connection: FolderSyncConnection,
        attemptID: String
    ) throws {
        let fileManager = FileManager.default
        let checkpoint = checkpointURL(connection: connection, attemptID: attemptID)
        guard fileManager.fileExists(atPath: checkpoint.path) else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        let workDirectory = URL(
            fileURLWithPath: connection.workDirectoryPath,
            isDirectory: true
        )
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        for child in try fileManager.contentsOfDirectory(
            at: workDirectory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) where child.lastPathComponent != "runs" {
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            try fileManager.removeItem(at: child)
        }

        for child in try fileManager.contentsOfDirectory(
            at: checkpoint,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) {
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            try fileManager.copyItem(
                at: child,
                to: workDirectory.appendingPathComponent(child.lastPathComponent)
            )
        }
    }

    static func remove(
        connection: FolderSyncConnection,
        attemptID: String
    ) throws {
        let checkpoint = checkpointURL(connection: connection, attemptID: attemptID)
        if FileManager.default.fileExists(atPath: checkpoint.path) {
            try FileManager.default.removeItem(at: checkpoint)
        }
    }

    static func exists(
        connection: FolderSyncConnection,
        attemptID: String
    ) -> Bool {
        FileManager.default.fileExists(
            atPath: checkpointURL(connection: connection, attemptID: attemptID).path
        )
    }

    private static func checkpointURL(
        connection: FolderSyncConnection,
        attemptID: String
    ) -> URL {
        FolderSyncJournalStore.connectionStateDirectory(for: connection)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(attemptID, isDirectory: true)
    }
}
