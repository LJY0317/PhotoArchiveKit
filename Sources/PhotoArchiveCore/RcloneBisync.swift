import Darwin
import CryptoKit
import Foundation

public enum FolderSyncProgressStage: String, Sendable, Equatable {
    case checking
    case preparing
    case preflight
    case syncing
    case finalizing
}

public struct FolderSyncProgress: Sendable, Equatable {
    public let stage: FolderSyncProgressStage

    public init(stage: FolderSyncProgressStage) {
        self.stage = stage
    }
}

public typealias FolderSyncProgressHandler = @Sendable (FolderSyncProgress) -> Void

public struct FolderSyncRunReport: Sendable, Equatable {
    public let connection: FolderSyncConnection
    public let conflictPreserved: Bool
    public let changedObjectCount: Int

    public init(
        connection: FolderSyncConnection,
        conflictPreserved: Bool,
        changedObjectCount: Int
    ) {
        self.connection = connection
        self.conflictPreserved = conflictPreserved
        self.changedObjectCount = changedObjectCount
    }
}

package struct RcloneBisyncTestingMetricsSnapshot: Sendable, Equatable {
    package let metadataProbeCount: Int
    package let fullHashBytes: Int64
    package let remoteProbeDownloadBytes: Int64
    package let remoteHashQueryCount: Int
    package let applyTransferredBytes: Int64
    package let applyTransferCount: Int
}

package final class RcloneBisyncTestingMetricsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var metadataProbeCount = 0
    private var fullHashBytes: Int64 = 0
    private var remoteProbeDownloadBytes: Int64 = 0
    private var remoteHashQueryCount = 0
    private var applyTransferredBytes: Int64 = 0
    private var applyTransferCount = 0

    package init() {}

    fileprivate func recordMetadataProbe(remoteDownloadBytes: Int64?) {
        lock.lock()
        metadataProbeCount += 1
        if let remoteDownloadBytes {
            self.remoteProbeDownloadBytes += remoteDownloadBytes
        }
        lock.unlock()
    }

    fileprivate func recordFullHash(bytes: Int64) {
        lock.lock()
        fullHashBytes += bytes
        lock.unlock()
    }

    fileprivate func recordRemoteHashQuery() {
        lock.lock()
        remoteHashQueryCount += 1
        lock.unlock()
    }

    fileprivate func recordApplyStats(bytes: Int64, transfers: Int) {
        lock.lock()
        applyTransferredBytes = bytes
        applyTransferCount = transfers
        lock.unlock()
    }

    package func snapshot() -> RcloneBisyncTestingMetricsSnapshot {
        lock.lock()
        let value = RcloneBisyncTestingMetricsSnapshot(
            metadataProbeCount: metadataProbeCount,
            fullHashBytes: fullHashBytes,
            remoteProbeDownloadBytes: remoteProbeDownloadBytes,
            remoteHashQueryCount: remoteHashQueryCount,
            applyTransferredBytes: applyTransferredBytes,
            applyTransferCount: applyTransferCount
        )
        lock.unlock()
        return value
    }
}

private enum BisyncSide: Hashable {
    case path1
    case path2
}

private struct RcloneLogLine: Decodable {
    let level: String?
    let msg: String?
    let object: String?
    let skipped: String?
    let source: String?
    let stats: RcloneStats?
}

private struct RcloneStats: Decodable {
    let bytes: Int64?
    let transfers: Int?
}

private struct RcloneAbout: Decodable {
    let free: Int64?
}

private struct RcloneListEntry: Decodable {
    let Path: String?
    let Name: String?
    let Size: Int64?
    let IsDir: Bool?
    let ModTime: String?
}

private enum BisyncExecutionPolicy: Sendable {
    case blockedForConcurrentMutationSafety
    case manualProduction
    case syntheticTesting
}

private struct BisyncDryRunAnalysis {
    var sourceSidesByPath: [String: Set<BisyncSide>] = [:]
    var nonDeletionChangeSidesByPath: [String: Set<BisyncSide>] = [:]
    var candidatePaths = Set<String>()
    var conflictPaths = Set<String>()
    var deletionPaths = Set<String>()
    var deletedFromSideByPath: [String: BisyncSide] = [:]
    var renameSourcePaths = Set<String>()
    var renameDestinationBySource: [String: String] = [:]
    var metadataUpdatePaths = Set<String>()
    var conflictPreserved = false

    var effectiveDeletionPaths: Set<String> {
        deletionPaths.subtracting(renameSourcePaths)
    }

    var deleteModifyPaths: Set<String> {
        Set(effectiveDeletionPaths.filter { path in
            guard let deletedFrom = deletedFromSideByPath[path] else { return false }
            let survivingSide: BisyncSide = deletedFrom == .path1 ? .path2 : .path1
            return nonDeletionChangeSidesByPath[path]?.contains(survivingSide) == true
        })
    }

    mutating func add(path: String, source: BisyncSide?) {
        guard let normalized = Self.safeRelativePath(path) else { return }
        candidatePaths.insert(normalized)
        if let source {
            sourceSidesByPath[normalized, default: []].insert(source)
        }
    }

    static func safeRelativePath(_ value: String) -> String? {
        // rclone paths use `/` separators. A backslash is a valid macOS/Drive
        // filename character, so never reinterpret it as a separator here.
        let normalized = value
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              normalized.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components.joined(separator: "/")
    }
}

private struct LocalDestinationPreapplyResult {
    var appliedPaths = Set<String>()
    var concurrentlyChangedPaths = Set<String>()
}

private struct DriveDestinationProtectionResult {
    var protectedPaths = Set<String>()
    var conflictPaths = Set<String>()
}

private struct ConflictResolutionSnapshot {
    let localHash: Data?
    let remoteHash: Data?
    let remoteFile: DriveFileState?
}

public final class RcloneBisyncService: @unchecked Sendable {
    public static let accessFilePrefix = ".photoarchive-bisync-access-"
    /// PhotoArchiveKit synchronizes only from the user-initiated control in
    /// the review app. There is deliberately no background watcher.
    public static let productionApplyAvailable = false

    private let executableURL: URL?
    private let environmentOverrides: [String: String]
    private let remoteTypeFilter: String
    private let executionPolicy: BisyncExecutionPolicy
    private let additionalApplyArguments: [String]
    private let afterPreflightHook: (@Sendable () async throws -> Void)?
    private let beforeLocalDestinationSwapHook: (@Sendable (String) throws -> Void)?
    private let afterLocalDestinationSwapHook: (@Sendable (String) throws -> Void)?
    private let testingLocalSwapErrorCode: Int32?
    private let testingMetrics: RcloneBisyncTestingMetricsRecorder?
    private let testingLocalRecoveryFreeBytes: Int64?
    private let testingRemoteRecoveryFreeBytes: Int64?
    private let testingLocalRecoveryTrashDirectory: URL?
    private let testingDriveRevisionManager: (any DriveRevisionManaging)?
    private let testingUseDriveRevisionProtection: Bool
    private let testingUseProtectedDirectHistoryReconcile: Bool
    private let afterDriveRevisionPinnedBeforeJournalHook: (@Sendable (String) throws -> Void)?
    private let afterDriveBaselineHeadVerifiedBeforeRevisionListHook: (@Sendable (String) throws -> Void)?
    private let afterDriveEmptyObjectJournaledBeforeUploadHook: (@Sendable (String) throws -> Void)?
    private let beforeDriveApplyHook: (@Sendable () throws -> Void)?
    private let afterDriveApplyBeforeJournalHook: (@Sendable () throws -> Void)?
    private let beforeDriveMutationHook: (@Sendable (FolderSyncDriveMutationKind, String, String) throws -> Void)?
    private let afterConflictResolutionStepHook: (@Sendable (String) throws -> Void)?
    private let processLock = NSLock()
    private var currentProcess: Process?
    private var cancelRequested = false

    public init(
        executableURL: URL? = nil,
        environment: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.environmentOverrides = environment
        self.remoteTypeFilter = "drive"
        self.executionPolicy = .blockedForConcurrentMutationSafety
        self.additionalApplyArguments = []
        self.afterPreflightHook = nil
        self.beforeLocalDestinationSwapHook = nil
        self.afterLocalDestinationSwapHook = nil
        self.testingLocalSwapErrorCode = nil
        self.testingMetrics = nil
        self.testingLocalRecoveryFreeBytes = nil
        self.testingRemoteRecoveryFreeBytes = nil
        self.testingLocalRecoveryTrashDirectory = nil
        self.testingDriveRevisionManager = nil
        self.testingUseDriveRevisionProtection = false
        self.testingUseProtectedDirectHistoryReconcile = false
        self.afterDriveRevisionPinnedBeforeJournalHook = nil
        self.afterDriveBaselineHeadVerifiedBeforeRevisionListHook = nil
        self.afterDriveEmptyObjectJournaledBeforeUploadHook = nil
        self.beforeDriveApplyHook = nil
        self.afterDriveApplyBeforeJournalHook = nil
        self.beforeDriveMutationHook = nil
        self.afterConflictResolutionStepHook = nil
    }

    package init(
        syntheticTestingExecutableURL executableURL: URL? = nil,
        environment: [String: String] = [:],
        remoteTypeFilter: String = "alias",
        allowBisyncApply: Bool = true,
        additionalApplyArguments: [String] = [],
        afterPreflight: (@Sendable () async throws -> Void)? = nil,
        beforeLocalDestinationSwap: (@Sendable (String) throws -> Void)? = nil,
        afterLocalDestinationSwap: (@Sendable (String) throws -> Void)? = nil,
        testingLocalSwapErrorCode: Int32? = nil,
        testingMetrics: RcloneBisyncTestingMetricsRecorder? = nil,
        testingLocalRecoveryFreeBytes: Int64? = nil,
        testingRemoteRecoveryFreeBytes: Int64? = nil,
        testingLocalRecoveryTrashDirectory: URL? = nil,
        testingDriveRevisionManager: (any DriveRevisionManaging)? = nil,
        testingUseDriveRevisionProtection: Bool = false,
        testingUseProtectedDirectHistoryReconcile: Bool = false,
        afterDriveRevisionPinnedBeforeJournal: (@Sendable (String) throws -> Void)? = nil,
        afterDriveBaselineHeadVerifiedBeforeRevisionList: (@Sendable (String) throws -> Void)? = nil,
        afterDriveEmptyObjectJournaledBeforeUpload: (@Sendable (String) throws -> Void)? = nil,
        beforeDriveApply: (@Sendable () throws -> Void)? = nil,
        afterDriveApplyBeforeJournal: (@Sendable () throws -> Void)? = nil,
        beforeDriveMutation: (@Sendable (FolderSyncDriveMutationKind, String, String) throws -> Void)? = nil,
        afterConflictResolutionStep: (@Sendable (String) throws -> Void)? = nil
    ) {
        self.executableURL = executableURL
        self.environmentOverrides = environment
        self.remoteTypeFilter = remoteTypeFilter
        self.executionPolicy = allowBisyncApply ? .syntheticTesting : .blockedForConcurrentMutationSafety
        self.additionalApplyArguments = additionalApplyArguments
        self.afterPreflightHook = afterPreflight
        self.beforeLocalDestinationSwapHook = beforeLocalDestinationSwap
        self.afterLocalDestinationSwapHook = afterLocalDestinationSwap
        self.testingLocalSwapErrorCode = testingLocalSwapErrorCode
        self.testingMetrics = testingMetrics
        self.testingLocalRecoveryFreeBytes = testingLocalRecoveryFreeBytes
        self.testingRemoteRecoveryFreeBytes = testingRemoteRecoveryFreeBytes
        self.testingLocalRecoveryTrashDirectory = testingLocalRecoveryTrashDirectory
        self.testingDriveRevisionManager = testingDriveRevisionManager
        self.testingUseDriveRevisionProtection = testingUseDriveRevisionProtection
        self.testingUseProtectedDirectHistoryReconcile = testingUseProtectedDirectHistoryReconcile
        self.afterDriveRevisionPinnedBeforeJournalHook = afterDriveRevisionPinnedBeforeJournal
        self.afterDriveBaselineHeadVerifiedBeforeRevisionListHook = afterDriveBaselineHeadVerifiedBeforeRevisionList
        self.afterDriveEmptyObjectJournaledBeforeUploadHook = afterDriveEmptyObjectJournaledBeforeUpload
        self.beforeDriveApplyHook = beforeDriveApply
        self.afterDriveApplyBeforeJournalHook = afterDriveApplyBeforeJournal
        self.beforeDriveMutationHook = beforeDriveMutation
        self.afterConflictResolutionStepHook = afterConflictResolutionStep
    }

    public func cancelCurrentRun() {
        processLock.lock()
        cancelRequested = true
        let process = currentProcess
        processLock.unlock()
        if let process, process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGINT)
        }
    }

    public func driveRemotes() throws -> [RcloneDriveRemote] {
        let executable = try resolvedExecutableURL()
        _ = try validateCapabilities(executable: executable)
        let result = try runSmall(
            executable: executable,
            arguments: ["listremotes", "--type", remoteTypeFilter, "--exact", "--json"]
        )
        guard result.exitCode == 0 else { throw FolderSyncConnectionError.connectionCheckRequired }
        return try JSONDecoder().decode([RcloneDriveRemote].self, from: result.stdout)
    }

    public func recoveryItems(
        connection: FolderSyncConnection
    ) throws -> [FolderSyncRecoveryItem] {
        var values = try FolderSyncLocalRecoveryStore.items(connection: connection)
        let driveRevisionRecords = try FolderSyncDriveRecoveryStore.load(connection: connection)
        let indexedDrivePaths = Set(driveRevisionRecords.map(\.originalRelativePath))
        for record in driveRevisionRecords where record.reference.keepForeverVerified {
            values.append(
                FolderSyncRecoveryItem(
                    location: .googleDrive,
                    originalRelativePath: record.originalRelativePath,
                    recoveryRelativePath: "revision/\(record.kind.rawValue)/\(record.reference.fileID)/\(record.reference.revisionID)",
                    byteSize: record.reference.byteSize,
                    modifiedAt: nil,
                    driveRevisionFileID: record.reference.fileID,
                    driveRevisionID: record.reference.revisionID,
                    expectedSHA256: record.reference.sha256
                )
            )
        }
        let executable = try resolvedExecutableURL()
        _ = try validateCapabilities(executable: executable)
        let spec = "\(connection.remoteName):\(connection.remoteRecoveryPath)"
        let result = try runSmall(
            executable: executable,
            arguments: ["lsjson", spec, "--recursive", "--files-only", "--drive-skip-gdocs"]
        )
        if result.exitCode != 0 {
            let message = String(data: result.stderr, encoding: .utf8)?.lowercased() ?? ""
            if message.contains("directory not found")
                || message.contains("path not found")
                || message.contains("object not found") {
                return values.sorted { $0.recoveryRelativePath < $1.recoveryRelativePath }
            }
            throw FolderSyncConnectionError.connectionCheckRequired
        }

        let formatter = ISO8601DateFormatter()
        let entries = try JSONDecoder().decode([RcloneListEntry].self, from: result.stdout)
        for entry in entries where entry.IsDir != true {
            guard let raw = entry.Path ?? entry.Name,
                  let recoveryRelative = BisyncDryRunAnalysis.safeRelativePath(raw),
                  let original = FolderSyncLocalRecoveryStore.originalRelativePath(
                    recoveryRelativePath: recoveryRelative,
                    sideDirectory: "path2"
                  ), !indexedDrivePaths.contains(original)
            else { continue }
            values.append(
                FolderSyncRecoveryItem(
                    location: .googleDrive,
                    originalRelativePath: original,
                    recoveryRelativePath: recoveryRelative,
                    byteSize: max(entry.Size ?? 0, 0),
                    modifiedAt: entry.ModTime.flatMap(formatter.date(from:))
                )
            )
        }
        return values.sorted { lhs, rhs in
            (lhs.location.rawValue, lhs.recoveryRelativePath)
                < (rhs.location.rawValue, rhs.recoveryRelativePath)
        }
    }

    public func restoreRecoveryItem(
        _ item: FolderSyncRecoveryItem,
        connection: FolderSyncConnection,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws {
        let operationLock: PhotoArchiveOperationLock
        do {
            operationLock = try PhotoArchiveOperationLock.acquire(catalogURL: catalogURL)
        } catch {
            throw FolderSyncConnectionError.operationAlreadyRunning
        }
        defer { operationLock.release() }

        switch item.location {
        case .externalDrive:
            let root = try FolderSyncConnectionManager.verifyLocalRoot(
                connection,
                catalogURL: catalogURL
            )
            try FolderSyncLocalRecoveryStore.restore(
                item,
                connection: connection,
                root: root
            )
        case .googleDrive:
            guard let fileID = item.driveRevisionFileID,
                  let revisionID = item.driveRevisionID,
                  let expectedSHA256 = item.expectedSHA256,
                  let safeOriginal = BisyncDryRunAnalysis.safeRelativePath(item.originalRelativePath)
            else {
                throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
            }
            let records = try FolderSyncDriveRecoveryStore.load(connection: connection)
            guard let record = records.first(where: {
                $0.originalRelativePath == safeOriginal
                    && $0.reference.fileID == fileID
                    && $0.reference.revisionID == revisionID
                    && $0.reference.sha256 == expectedSHA256
                    && $0.reference.byteSize == item.byteSize
                    && $0.reference.keepForeverVerified
            }) else {
                throw FolderSyncConnectionError.recoveryItemChanged
            }
            let executable = try resolvedExecutableURL()
            _ = try validateCapabilities(executable: executable)
            let manager = try driveRevisionManager(executable: executable, connection: connection)
            let revision: DriveRevisionState?
            do {
                revision = try manager.revision(fileID: fileID, revisionID: revisionID)
            } catch {
                throw mapDriveAPIError(error, afterMutation: false)
            }
            guard let revision,
                  revision.keepForever,
                  revision.byteSize == record.reference.byteSize else {
                throw FolderSyncConnectionError.recoveryItemChanged
            }
            let existing = try driveLiveFiles(
                manager: manager,
                connection: connection,
                relativePath: safeOriginal
            )
            guard existing.isEmpty else {
                throw FolderSyncConnectionError.restoreDestinationExists
            }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhotoArchiveKit-drive-restore-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                try manager.downloadRevision(fileID: fileID, revisionID: revisionID, to: temporary)
            } catch {
                throw mapDriveAPIError(error, afterMutation: false)
            }
            guard FileManager.default.fileExists(atPath: temporary.path),
                  try FileHasher.sha256(url: temporary) == expectedSHA256,
                  Int64((try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    == item.byteSize else {
                throw FolderSyncConnectionError.recoveryItemChanged
            }
            let copy = try runSmall(
                executable: executable,
                arguments: [
                    "copyto", temporary.path,
                    remoteSpec(connection) + "/" + safeOriginal,
                    "--ignore-existing",
                    "--drive-keep-revision-forever",
                    "--drive-skip-gdocs"
                ]
            )
            guard copy.exitCode == 0 else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            let restored = try driveLiveFiles(
                manager: manager,
                connection: connection,
                relativePath: safeOriginal
            )
            guard restored.count == 1,
                  let restoredFile = restored.first,
                  restoredFile.sha256 == expectedSHA256,
                  let restoredRevisionID = restoredFile.headRevisionID else {
                if !restored.isEmpty {
                    throw FolderSyncConnectionError.restoreDestinationExists
                }
                throw FolderSyncConnectionError.recoveryRequired
            }
            do {
                guard let restoredRevision = try manager.revision(
                    fileID: restoredFile.id,
                    revisionID: restoredRevisionID
                ), restoredRevision.keepForever else {
                    throw FolderSyncConnectionError.recoveryRequired
                }
            } catch let error as FolderSyncConnectionError {
                throw error
            } catch {
                throw mapDriveAPIError(error, afterMutation: true)
            }
        }
    }

    public func discardRecoveryItem(
        _ item: FolderSyncRecoveryItem,
        connection: FolderSyncConnection,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws {
        let operationLock: PhotoArchiveOperationLock
        do {
            operationLock = try PhotoArchiveOperationLock.acquire(catalogURL: catalogURL)
        } catch {
            throw FolderSyncConnectionError.operationAlreadyRunning
        }
        defer { operationLock.release() }

        switch item.location {
        case .externalDrive:
            try FolderSyncLocalRecoveryStore.discard(
                item,
                connection: connection,
                testingTrashDirectory: testingLocalRecoveryTrashDirectory
            )
        case .googleDrive:
            if item.driveRevisionFileID != nil || item.driveRevisionID != nil {
                // Drive revision deletion is permanent. Keep explicit revision
                // recovery records until a future, separately designed cleanup
                // flow can make that irreversible action clear to the user.
                throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
            }
            guard let safeRecovery = BisyncDryRunAnalysis.safeRelativePath(item.recoveryRelativePath) else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            let executable = try resolvedExecutableURL()
            _ = try validateCapabilities(executable: executable)
            let spec = "\(connection.remoteName):\(connection.remoteRecoveryPath)/\(safeRecovery)"
            let stat = try runSmall(
                executable: executable,
                arguments: ["lsjson", spec, "--stat", "--drive-skip-gdocs"]
            )
            guard stat.exitCode == 0,
                  let entry = try? JSONDecoder().decode(RcloneListEntry.self, from: stat.stdout),
                  entry.IsDir != true,
                  max(entry.Size ?? 0, 0) == item.byteSize
            else {
                throw FolderSyncConnectionError.recoveryItemChanged
            }
            if let expected = item.modifiedAt,
               let raw = entry.ModTime,
               let current = ISO8601DateFormatter().date(from: raw),
               abs(expected.timeIntervalSince(current)) > 1 {
                throw FolderSyncConnectionError.recoveryItemChanged
            }
            let deleted = try runSmall(
                executable: executable,
                arguments: ["deletefile", spec, "--drive-skip-gdocs"]
            )
            guard deleted.exitCode == 0 else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
        }
    }

    public func synchronize(
        connection initialConnection: FolderSyncConnection,
        confirmInitialSync: Bool,
        approvedDeletionPlanID: String? = nil,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL,
        storeURL: URL = FolderSyncConnectionStore.defaultURL,
        progressHandler: FolderSyncProgressHandler? = nil
    ) async throws -> FolderSyncRunReport {
        resetCancellation()
        defer { clearCancellation() }
        var connection = initialConnection
        let now = Date()
        var existingJournal: FolderSyncJournal?
        do {
            existingJournal = try FolderSyncJournalStore.load(connection: connection)
        } catch {
            connection.lastAttemptAt = now
            connection.status = .recoveryRequired
            try? FolderSyncConnectionStore.upsert(connection, url: storeURL)
            throw FolderSyncConnectionError.recoveryRequired
        }
        progressHandler?(FolderSyncProgress(stage: .checking))
        let root = try FolderSyncConnectionManager.verifyLocalRoot(connection, catalogURL: catalogURL)
        guard connection.isInitialized || confirmInitialSync else {
            throw FolderSyncConnectionError.initialConfirmationRequired
        }
        guard connection.isInitialized || connection.initialSyncStartedAt == nil else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        if let journal = existingJournal,
           journal.phase == .recoveryRequired,
           !connection.isInitialized {
            // A failed first resync has no trustworthy prior bisync history to
            // resume from. Never turn it into an implicit fresh resync.
            throw FolderSyncConnectionError.recoveryRequired
        }
        if let journal = existingJournal,
           journal.phase == .recoveryRequired,
           connection.isInitialized,
           !journal.historyRestored {
            connection.lastAttemptAt = now
            connection.status = .recoveryRequired
            try? FolderSyncConnectionStore.upsert(connection, url: storeURL)
            throw FolderSyncConnectionError.recoveryRequired
        }
        if existingJournal?.phase == .confirmationRequired,
           existingJournal?.pendingDeletionPlan?.id != approvedDeletionPlanID {
            connection.lastAttemptAt = now
            connection.status = .confirmationRequired
            try? FolderSyncConnectionStore.upsert(connection, url: storeURL)
            throw FolderSyncConnectionError.confirmationRequired
        }
        if executionPolicy == .blockedForConcurrentMutationSafety {
            connection.lastAttemptAt = now
            connection.status = .safetyUnavailable
            try FolderSyncConnectionStore.upsert(connection, url: storeURL)
            throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
        }
        let executable = try resolvedExecutableURL()
        _ = try validateCapabilities(executable: executable)
        let remotes = try driveRemotes()
        guard remotes.contains(where: { $0.name == connection.remoteName }) else {
            throw FolderSyncConnectionError.connectionCheckRequired
        }

        let operationLock: PhotoArchiveOperationLock
        do {
            operationLock = try PhotoArchiveOperationLock.acquire(catalogURL: catalogURL)
        } catch {
            // Do not rewrite the persisted state here. Another process may be
            // the owner of the same connection and legitimately be `running`.
            throw FolderSyncConnectionError.operationAlreadyRunning
        }
        defer { operationLock.release() }

        try recoverInterruptedLocalSwapArtifacts(
            executable: executable,
            connection: connection,
            root: root
        )

        let driveManager: (any DriveRevisionManaging)? = usesDriveRevisionProtection
            ? try driveRevisionManager(executable: executable, connection: connection)
            : nil
        if let driveManager, var interrupted = existingJournal {
            try reconcileInterruptedDriveProtection(
                manager: driveManager,
                executable: executable,
                connection: connection,
                journal: &interrupted
            )
            existingJournal = interrupted
        }

        connection.lastAttemptAt = now
        connection.status = .running
        try FolderSyncConnectionStore.upsert(connection, url: storeURL)

        var applyStarted = false
        var localDestinationPreapply = LocalDestinationPreapplyResult()
        var driveDestinationProtection = DriveDestinationProtectionResult()
        var drivePreflightTargets: [String: FolderSyncDriveRevisionReference] = [:]
        var journal: FolderSyncJournal?
        var historyCheckpointAttemptID: String?
        do {

            progressHandler?(FolderSyncProgress(stage: .preparing))
            try prepareLocalState(connection: connection)
            try ensureNotCancelled()
            if !connection.isInitialized {
                try prepareInitialAccessMarker(
                    executable: executable,
                    connection: connection,
                    localRootPath: root.canonicalPath
                )
                try verifyInitialMergeIsNonDestructive(
                    executable: executable,
                    connection: connection,
                    localRootPath: root.canonicalPath
                )
            } else {
                let localProbe = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
                    .appendingPathComponent(accessFileName(connection))
                guard FileManager.default.fileExists(atPath: localProbe.path) else {
                    throw FolderSyncConnectionError.connectionCheckRequired
                }
            }
            try ensureNotCancelled()

            let runID = Self.runIdentifier(now)
            let paths = try runPaths(connection: connection, runID: runID)
            defer { try? FileManager.default.removeItem(at: paths.livePhotoProbeDirectory) }
            let commonArguments = commonBisyncArguments(
                connection: connection,
                localRootPath: root.canonicalPath,
                runPaths: paths
            )

            progressHandler?(FolderSyncProgress(stage: .preflight))
            let dryLog = paths.logDirectory.appendingPathComponent("preflight.jsonl")
            var dryArguments = commonArguments
            if !connection.isInitialized {
                // Same-path different-content files were rejected above, so
                // Path1 preference cannot discard distinct user content here.
                dryArguments.append(contentsOf: ["--resync-mode", "path1"])
            }
            dryArguments.append(contentsOf: ["--dry-run", "--use-json-log", "--log-level", "NOTICE"])
            let dryResult = try runToFiles(
                executable: executable,
                arguments: dryArguments,
                logDirectory: paths.logDirectory,
                basename: "preflight"
            )
            try ensureNotCancelled()
            guard dryResult.exitCode == 0 else {
                throw classifyFailure(logURL: dryResult.stderrURL)
            }
            var analysis = try Self.parseAnalysis(url: dryLog)
            var interruptedDriveCreatePaths = Set<String>()
            if let driveManager {
                if var interruptedJournal = existingJournal {
                    interruptedDriveCreatePaths = try reconcileInterruptedDriveCreates(
                        manager: driveManager,
                        connection: connection,
                        root: root,
                        journal: &interruptedJournal
                    )
                    existingJournal = interruptedJournal
                    Self.reclassifyInterruptedDriveCreates(
                        analysis: &analysis,
                        paths: interruptedDriveCreatePaths
                    )
                }
                drivePreflightTargets = try snapshotDriveMutationTargets(
                    manager: driveManager,
                    connection: connection,
                    analysis: analysis,
                    ownedCreateRecoveryPaths: interruptedDriveCreatePaths
                )
            }
            try ensureRecoveryCapacity(
                executable: executable,
                connection: connection,
                root: root,
                analysis: analysis
            )
            let benignRecoveryConflicts = try recoveryConflictsWithIdenticalContent(
                executable: executable,
                connection: connection,
                root: root,
                analysis: analysis,
                existingJournal: existingJournal,
                temporaryDirectory: paths.livePhotoProbeDirectory
            )
            let livePhotoPlan = try await makeLivePhotoPlan(
                executable: executable,
                connection: connection,
                root: root,
                analysis: analysis,
                benignRecoveryConflicts: benignRecoveryConflicts,
                temporaryDirectory: paths.livePhotoProbeDirectory
            )
            let liveMergedJournalItems = Self.mergingLivePhotoItems(
                defaultItems: Self.journalItems(for: analysis),
                livePhotoItems: livePhotoPlan.items
            )
            let plannedJournalItems = Self.carryingDrivePreservation(
                items: liveMergedJournalItems,
                existingJournal: existingJournal
            )
            let preflightUnresolvedConflictPaths = analysis.conflictPaths
                .subtracting(benignRecoveryConflicts)
            let deleteModifyPaths = analysis.deleteModifyPaths
            if livePhotoPlan.requiresConfirmation
                || !preflightUnresolvedConflictPaths.isEmpty
                || !deleteModifyPaths.isEmpty {
                let attemptID = Self.runIdentifier(Date())
                let confirmationItems = plannedJournalItems.map { item in
                    var value = item
                    let paths = Set(value.resources.map(\.relativePath))
                    if !paths.intersection(deleteModifyPaths).isEmpty {
                        value.state = .confirmationRequired
                        value.note = "delete_modify_conflict"
                    } else if !paths.intersection(preflightUnresolvedConflictPaths).isEmpty {
                        value.state = .confirmationRequired
                        value.note = "both_sides_modified"
                    }
                    return value
                }
                journal = FolderSyncJournal(
                    connectionID: connection.id,
                    operationID: existingJournal?.operationID
                        ?? "SO" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    currentAttemptID: attemptID,
                    startedAt: existingJournal?.startedAt ?? now,
                    phase: .confirmationRequired,
                    preflightCandidatePaths: analysis.candidatePaths.sorted(),
                    items: confirmationItems
                )
                if var currentJournal = journal {
                    currentJournal.retryCount = existingJournal.map { $0.retryCount + 1 } ?? 0
                    currentJournal.updatedAt = Date()
                    journal = currentJournal
                    try FolderSyncJournalStore.save(currentJournal, connection: connection)
                }
                throw FolderSyncConnectionError.confirmationRequired
            }
            if usesDirectDriveMutationAPI {
                let unsupportedPaths = unsupportedDirectMutationPaths(
                    analysis: analysis,
                    benignRecoveryConflicts: benignRecoveryConflicts
                )
                guard unsupportedPaths.isEmpty else {
                    throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
                }
            }
            let deletionPlan = try makeDeletionPlan(
                executable: executable,
                connection: connection,
                root: root,
                analysis: analysis,
                items: plannedJournalItems,
                temporaryDirectory: paths.livePhotoProbeDirectory
            )
            if let deletionPlan,
               deletionPlan.requiresConfirmation,
               deletionPlan.id != approvedDeletionPlanID {
                let attemptID = Self.runIdentifier(Date())
                journal = FolderSyncJournal(
                    connectionID: connection.id,
                    operationID: existingJournal?.operationID
                        ?? "SO" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    currentAttemptID: attemptID,
                    startedAt: existingJournal?.startedAt ?? now,
                    phase: .confirmationRequired,
                    preflightCandidatePaths: analysis.candidatePaths.sorted(),
                    items: plannedJournalItems
                )
                journal?.pendingDeletionPlan = deletionPlan
                if let journal {
                    try FolderSyncJournalStore.save(journal, connection: connection)
                }
                throw FolderSyncConnectionError.confirmationRequired
            }
            try ensureNotCancelled()
            try await afterPreflightHook?()
            try ensureNotCancelled()
            if let deletionPlan,
               try deletionPlanStillMatches(
                    deletionPlan,
                    executable: executable,
                    connection: connection,
                    root: root,
                    temporaryDirectory: paths.livePhotoProbeDirectory
               ) == false {
                let attemptID = Self.runIdentifier(Date())
                journal = FolderSyncJournal(
                    connectionID: connection.id,
                    operationID: existingJournal?.operationID
                        ?? "SO" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    currentAttemptID: attemptID,
                    startedAt: existingJournal?.startedAt ?? now,
                    phase: .confirmationRequired,
                    preflightCandidatePaths: analysis.candidatePaths.sorted(),
                    items: plannedJournalItems.map { item in
                        var value = item
                        value.state = .confirmationRequired
                        value.note = "deletion_target_changed_before_apply"
                        return value
                    }
                )
                if let journal {
                    try FolderSyncJournalStore.save(journal, connection: connection)
                }
                throw FolderSyncConnectionError.confirmationRequired
            }
            if try verifyAllDeletionTargetsUnchanged(
                analysis: analysis,
                executable: executable,
                connection: connection,
                root: root,
                deletionPlan: deletionPlan,
                temporaryDirectory: paths.livePhotoProbeDirectory
            ) == false {
                let attemptID = Self.runIdentifier(Date())
                journal = FolderSyncJournal(
                    connectionID: connection.id,
                    operationID: existingJournal?.operationID
                        ?? "SO" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    currentAttemptID: attemptID,
                    startedAt: existingJournal?.startedAt ?? now,
                    phase: .confirmationRequired,
                    preflightCandidatePaths: analysis.candidatePaths.sorted(),
                    items: plannedJournalItems.map { item in
                        var value = item
                        value.state = .confirmationRequired
                        value.note = "deletion_target_changed_before_apply"
                        return value
                    }
                )
                if let journal {
                    try FolderSyncJournalStore.save(journal, connection: connection)
                }
                throw FolderSyncConnectionError.confirmationRequired
            }
            if try verifyRenameMovePreconditions(
                analysis: analysis,
                executable: executable,
                connection: connection,
                root: root
            ) == false {
                let attemptID = Self.runIdentifier(Date())
                journal = FolderSyncJournal(
                    connectionID: connection.id,
                    operationID: existingJournal?.operationID
                        ?? "SO" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    currentAttemptID: attemptID,
                    startedAt: existingJournal?.startedAt ?? now,
                    phase: .confirmationRequired,
                    preflightCandidatePaths: analysis.candidatePaths.sorted(),
                    items: plannedJournalItems.map { item in
                        var value = item
                        value.state = .confirmationRequired
                        value.note = "rename_destination_conflict"
                        return value
                    }
                )
                if let journal {
                    try FolderSyncJournalStore.save(journal, connection: connection)
                }
                throw FolderSyncConnectionError.confirmationRequired
            }
            if !connection.isInitialized {
                try verifyInitialMergeIsNonDestructive(
                    executable: executable,
                    connection: connection,
                    localRootPath: root.canonicalPath
                )
            }
            if await livePhotoPreconditionsStillMatch(
                livePhotoPlan.preconditions,
                executable: executable,
                connection: connection,
                root: root,
                temporaryDirectory: paths.livePhotoProbeDirectory
            ) == false {
                let attemptID = Self.runIdentifier(Date())
                journal = FolderSyncJournal(
                    connectionID: connection.id,
                    operationID: existingJournal?.operationID
                        ?? "SO" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    currentAttemptID: attemptID,
                    startedAt: existingJournal?.startedAt ?? now,
                    phase: .confirmationRequired,
                    preflightCandidatePaths: analysis.candidatePaths.sorted(),
                    items: plannedJournalItems.map { item in
                        var value = item
                        value.state = .confirmationRequired
                        if value.resources.contains(where: { resource in
                            livePhotoPlan.preconditions.contains {
                                $0.relativePath == resource.relativePath
                            }
                        }) {
                            value.note = "live_photo_precondition_changed_before_apply"
                        }
                        return value
                    }
                )
                if let journal {
                    try FolderSyncJournalStore.save(journal, connection: connection)
                }
                throw FolderSyncConnectionError.confirmationRequired
            }

            progressHandler?(FolderSyncProgress(stage: .syncing))
            let attemptID = Self.runIdentifier(Date())
            if var prior = existingJournal {
                prior.currentAttemptID = attemptID
                prior.retryCount += 1
                prior.updatedAt = Date()
                prior.phase = .applying
                prior.preflightCandidatePaths = analysis.candidatePaths.sorted()
                prior.unplannedObservedPaths = []
                prior.historyRestored = false
                prior.recoveryArtifactsVerified = false
                prior.pendingDeletionPlan = nil
                prior.items = plannedJournalItems
                journal = prior
            } else {
                journal = FolderSyncJournal(
                    connectionID: connection.id,
                    operationID: "SO" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    currentAttemptID: attemptID,
                    startedAt: now,
                    phase: .applying,
                    preflightCandidatePaths: analysis.candidatePaths.sorted(),
                    items: plannedJournalItems
                )
            }
            try FolderSyncHistoryCheckpoint.create(
                connection: connection,
                attemptID: attemptID
            )
            historyCheckpointAttemptID = attemptID
            journal?.historyCheckpointAvailable = true
            journal?.updatedAt = Date()
            if let journal {
                try FolderSyncJournalStore.save(journal, connection: connection)
            }

            if let driveManager, var currentJournal = journal {
                driveDestinationProtection = try preapplyDriveDestinationMutations(
                    manager: driveManager,
                    connection: connection,
                    root: root,
                    analysis: analysis,
                    items: plannedJournalItems,
                    runID: runID,
                    preflightTargets: drivePreflightTargets,
                    journal: &currentJournal,
                    applyStarted: &applyStarted
                )
                journal = currentJournal
            }

            localDestinationPreapply = try preapplyLocalDestinationOverwrites(
                executable: executable,
                connection: connection,
                root: root,
                analysis: analysis,
                items: plannedJournalItems,
                runPaths: paths,
                applyStarted: &applyStarted
            )

            let usesProtectedDirectHistoryReconcile = remoteTypeFilter == "drive"
                || testingUseProtectedDirectHistoryReconcile
            var applyArguments = commonArguments
            if !connection.isInitialized {
                applyArguments.append(contentsOf: ["--resync-mode", "path1"])
                // First setup has no trustworthy prior bisync listing. If a
                // same-path file changes after preflight, never let the
                // initial resync overwrite it merely because Path1 was chosen
                // as the conflict preference. `--immutable` still permits
                // unique files to merge, but existing mismatches fail closed.
                // If the only same-path work is metadata normalization for
                // already-equal content, allow rclone to align it after the
                // fresh just-before-apply check above. `--immutable` treats
                // such modtime-only drift as a modification and would strand a
                // harmless first setup in recovery.
                if analysis.metadataUpdatePaths.isEmpty {
                    applyArguments.append(contentsOf: ["--immutable", "--checksum"])
                } else {
                    applyArguments.append("--checksum")
                }
                connection.initialSyncStartedAt = Date()
                try FolderSyncConnectionStore.upsert(connection, url: storeURL)
            }
            applyArguments.append(contentsOf: ["--use-json-log", "--log-level", "NOTICE"])
            if testingMetrics != nil {
                applyArguments.append(contentsOf: [
                    "--stats-log-level", "NOTICE",
                    "--stats-one-line",
                    "--stats", "1s"
                ])
            }
            if driveManager != nil {
                applyArguments.append("--drive-keep-revision-forever")
            }
            applyArguments.append(contentsOf: additionalApplyArguments)
            try beforeDriveApplyHook?()
            let applyResult: FileProcessResult
            if usesProtectedDirectHistoryReconcile {
                // Direct Drive/local mutation above is the only code allowed
                // to change user files. Re-run bisync only as a dry listing so
                // it can describe the verified post-mutation trees and write
                // candidate history files. Those history files are promoted
                // only after exact verification below.
                try removeBisyncDryHistoryArtifacts(connection: connection)
                var reconcileArguments = applyArguments
                reconcileArguments.append("--dry-run")
                applyResult = try runToFiles(
                    executable: executable,
                    arguments: reconcileArguments,
                    logDirectory: paths.logDirectory,
                    basename: "history-reconcile"
                )
            } else {
                // Legacy synthetic/non-Drive runs still use rclone as the
                // mutating engine. Production/public Drive apply does not use
                // this branch.
                applyStarted = true
                applyResult = try runToFiles(
                    executable: executable,
                    arguments: applyArguments,
                    logDirectory: paths.logDirectory,
                    basename: "apply"
                )
            }
            if let stats = Self.lastStats(url: applyResult.stderrURL) {
                testingMetrics?.recordApplyStats(
                    bytes: stats.bytes ?? 0,
                    transfers: stats.transfers ?? 0
                )
            }
            try ensureNotCancelled()
            let observedApplyAnalysis = try? Self.parseAnalysis(url: applyResult.stderrURL)
            if var currentJournal = journal, let observedApplyAnalysis {
                let unplanned = observedApplyAnalysis.candidatePaths
                    .subtracting(analysis.candidatePaths)
                    .sorted()
                if !unplanned.isEmpty {
                    currentJournal.unplannedObservedPaths = Array(
                        Set(currentJournal.unplannedObservedPaths).union(unplanned)
                    ).sorted()
                    let existingPaths = Set(
                        currentJournal.items.flatMap { $0.resources.map(\.relativePath) }
                    )
                    let newPaths = Set(unplanned).subtracting(existingPaths)
                    currentJournal.items.append(contentsOf: Self.journalItems(forPaths: newPaths))
                    currentJournal.updatedAt = Date()
                    journal = currentJournal
                    try? FolderSyncJournalStore.save(currentJournal, connection: connection)
                }
            }
            guard applyResult.exitCode == 0 else {
                throw classifyFailure(logURL: applyResult.stderrURL)
            }
            try afterDriveApplyBeforeJournalHook?()
            if let driveManager, var currentJournal = journal {
                let postApply = try verifyDriveDestinationOverwrites(
                    manager: driveManager,
                    connection: connection,
                    root: root,
                    relativePaths: driveDestinationProtection.protectedPaths,
                    journal: &currentJournal,
                    afterMutation: true
                )
                driveDestinationProtection.protectedPaths.formUnion(postApply.protectedPaths)
                driveDestinationProtection.conflictPaths.formUnion(postApply.conflictPaths)
                journal = currentJournal
            }
            guard let applyAnalysis = observedApplyAnalysis else {
                throw FolderSyncConnectionError.unsupportedBisyncLog
            }
            if !initialConnection.isInitialized {
                try verifyInitialMergeCompleted(
                    executable: executable,
                    connection: connection,
                    localRootPath: root.canonicalPath
                )
            }
            progressHandler?(FolderSyncProgress(stage: .finalizing))
            if initialConnection.isInitialized,
               !usesProtectedDirectHistoryReconcile,
               let preApplyAttemptID = historyCheckpointAttemptID {
                let postApplyAttemptID = preApplyAttemptID + "-post-apply"
                try FolderSyncHistoryCheckpoint.create(
                    connection: connection,
                    attemptID: postApplyAttemptID
                )
                do {
                    try FolderSyncHistoryCheckpoint.restore(
                        connection: connection,
                        attemptID: preApplyAttemptID
                    )
                    let observed = try inspectRecoveryChanges(
                        executable: executable,
                        connection: connection,
                        root: root
                    )
                    try FolderSyncHistoryCheckpoint.restore(
                        connection: connection,
                        attemptID: preApplyAttemptID
                    )
                    let unplanned = observed.candidatePaths
                        .subtracting(analysis.candidatePaths)
                        .sorted()
                    if !unplanned.isEmpty {
                        if var currentJournal = journal {
                            currentJournal.phase = .confirmationRequired
                            currentJournal.updatedAt = Date()
                            currentJournal.historyRestored = true
                            currentJournal.unplannedObservedPaths = unplanned
                            let existingPaths = Set(
                                currentJournal.items.flatMap { $0.resources.map(\.relativePath) }
                            )
                            currentJournal.items.append(
                                contentsOf: Self.journalItems(
                                    forPaths: Set(unplanned).subtracting(existingPaths)
                                )
                            )
                            currentJournal.items = currentJournal.items.map { item in
                                var value = item
                                if value.state != .verified {
                                    value.state = .confirmationRequired
                                    value.note = "post_apply_unplanned_change"
                                }
                                return value
                            }
                            journal = currentJournal
                            try FolderSyncJournalStore.save(currentJournal, connection: connection)
                        }
                        try? FolderSyncHistoryCheckpoint.remove(
                            connection: connection,
                            attemptID: postApplyAttemptID
                        )
                        throw FolderSyncConnectionError.confirmationRequired
                    }
                    try FolderSyncHistoryCheckpoint.restore(
                        connection: connection,
                        attemptID: postApplyAttemptID
                    )
                } catch {
                    if case FolderSyncConnectionError.confirmationRequired = error {
                        throw error
                    }
                    try? FolderSyncHistoryCheckpoint.restore(
                        connection: connection,
                        attemptID: preApplyAttemptID
                    )
                    throw error
                }
                try? FolderSyncHistoryCheckpoint.remove(
                    connection: connection,
                    attemptID: postApplyAttemptID
                )
            }
            if var currentJournal = journal {
                currentJournal.phase = .verifying
                currentJournal.updatedAt = Date()
                let unplanned = applyAnalysis.candidatePaths
                    .subtracting(analysis.candidatePaths)
                    .sorted()
                currentJournal.unplannedObservedPaths = unplanned
                if !unplanned.isEmpty {
                    currentJournal.phase = .confirmationRequired
                    currentJournal.items = currentJournal.items.map { item in
                        var value = item
                        value.state = .confirmationRequired
                        value.note = usesProtectedDirectHistoryReconcile
                            ? "history_reconcile_observed_unplanned_change"
                            : "apply_observed_unplanned_change"
                        return value
                    }
                    try FolderSyncJournalStore.save(currentJournal, connection: connection)
                    journal = currentJournal
                    if usesProtectedDirectHistoryReconcile {
                        try? removeBisyncDryHistoryArtifacts(connection: connection)
                        throw FolderSyncConnectionError.confirmationRequired
                    }
                    throw FolderSyncConnectionError.recoveryRequired
                }
                let verification = try await verifyJournalItems(
                    executable: executable,
                    connection: connection,
                    root: root,
                    items: currentJournal.items,
                    analysis: analysis,
                    preconditions: livePhotoPlan.preconditions,
                    deletionPlan: deletionPlan,
                    runPaths: paths,
                    temporaryDirectory: paths.livePhotoProbeDirectory
                )
                currentJournal.items = verification.items
                currentJournal.recoveryArtifactsVerified = verification.recoveryArtifactsVerified
                if verification.sourcePreconditionChanged {
                    currentJournal.phase = .confirmationRequired
                    currentJournal.items = currentJournal.items.map { item in
                        var value = item
                        if value.resources.contains(where: { resource in
                            livePhotoPlan.preconditions.contains {
                                $0.relativePath == resource.relativePath
                            }
                        }) {
                            value.state = .confirmationRequired
                            value.note = "live_photo_precondition_changed_during_apply"
                        }
                        return value
                    }
                    currentJournal.updatedAt = Date()
                    journal = currentJournal
                    try FolderSyncJournalStore.save(currentJournal, connection: connection)
                    throw FolderSyncConnectionError.confirmationRequired
                }
                currentJournal.phase = .completed
                currentJournal.updatedAt = Date()
                try FolderSyncJournalStore.save(currentJournal, connection: connection)
            }
            if usesProtectedDirectHistoryReconcile {
                do {
                    try promoteBisyncDryHistory(
                        connection: connection,
                        allowCreatingMain: !initialConnection.isInitialized
                    )
                    let postPromotion = try inspectRecoveryChanges(
                        executable: executable,
                        connection: connection,
                        root: root
                    )
                    guard postPromotion.candidatePaths.isEmpty else {
                        if var currentJournal = journal {
                            currentJournal.phase = .confirmationRequired
                            currentJournal.updatedAt = Date()
                            currentJournal.unplannedObservedPaths = postPromotion.candidatePaths.sorted()
                            journal = currentJournal
                            try FolderSyncJournalStore.save(currentJournal, connection: connection)
                        }
                        throw FolderSyncConnectionError.confirmationRequired
                    }
                    try removeBisyncDryHistoryArtifacts(connection: connection)
                } catch {
                    if let attemptID = historyCheckpointAttemptID,
                       FolderSyncHistoryCheckpoint.exists(
                        connection: connection,
                        attemptID: attemptID
                       ) {
                        try? FolderSyncHistoryCheckpoint.restore(
                            connection: connection,
                            attemptID: attemptID
                        )
                    }
                    throw error
                }
            }
            connection.isInitialized = true
            connection.initialSyncStartedAt = nil
            connection.lastSuccessAt = Date()
            let benignPreappliedLocalPaths = try identicalLocalRemotePaths(
                localDestinationPreapply.appliedPaths,
                executable: executable,
                connection: connection,
                root: root
            )
            guard benignPreappliedLocalPaths == localDestinationPreapply.appliedPaths else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            let observedApplyConflictPaths = usesProtectedDirectHistoryReconcile
                ? Set<String>()
                : applyAnalysis.conflictPaths
            let unresolvedConflictPaths = analysis.conflictPaths
                .union(observedApplyConflictPaths)
                .subtracting(benignRecoveryConflicts)
                .subtracting(benignPreappliedLocalPaths)
            let hasConflict = !unresolvedConflictPaths.isEmpty
                || !localDestinationPreapply.concurrentlyChangedPaths.isEmpty
                || !driveDestinationProtection.conflictPaths.isEmpty
            connection.status = hasConflict ? .conflict : .success
            try FolderSyncConnectionStore.upsert(connection, url: storeURL)
            if let attemptID = historyCheckpointAttemptID {
                try? FolderSyncHistoryCheckpoint.remove(
                    connection: connection,
                    attemptID: attemptID
                )
            }
            try? FolderSyncJournalStore.remove(connection: connection)
            if !hasConflict {
                try? FileManager.default.removeItem(at: paths.logDirectory)
            }
            return FolderSyncRunReport(
                connection: connection,
                conflictPreserved: hasConflict,
                changedObjectCount: analysis.candidatePaths.count
            )
        } catch {
            let finalError: Error = isCancellationRequested() ? CancellationError() : error
            if journal?.phase == .confirmationRequired {
                connection.status = .confirmationRequired
                if let currentJournal = journal {
                    try? FolderSyncJournalStore.save(currentJournal, connection: connection)
                }
            } else if applyStarted || (!connection.isInitialized && connection.initialSyncStartedAt != nil) {
                // Once any run has crossed the apply boundary, some user files
                // may already have moved. Keep that uncertainty explicit even
                // when the initiating error looks like a connection failure or
                // cancellation. A later recovery path must re-establish state;
                // it must not assume the failed run was mutation-free.
                connection.status = .recoveryRequired
                if var currentJournal = journal ?? existingJournal {
                    currentJournal.phase = .recoveryRequired
                    currentJournal.updatedAt = Date()
                    currentJournal.items = currentJournal.items.map { item in
                        var value = item
                        if value.state != .verified {
                            value.state = .incomplete
                        }
                        return value
                    }
                    if let attemptID = historyCheckpointAttemptID,
                       FolderSyncHistoryCheckpoint.exists(
                           connection: connection,
                           attemptID: attemptID
                       ) {
                        do {
                            try FolderSyncHistoryCheckpoint.restore(
                                connection: connection,
                                attemptID: attemptID
                            )
                            currentJournal.historyRestored = true
                            if connection.isInitialized,
                               let recoveryAnalysis = try? inspectRecoveryChanges(
                                   executable: executable,
                                   connection: connection,
                                   root: root
                               ) {
                                let observedPaths = recoveryAnalysis.candidatePaths
                                let plannedPaths = Set(currentJournal.preflightCandidatePaths)
                                currentJournal.unplannedObservedPaths = observedPaths
                                    .subtracting(plannedPaths)
                                    .sorted()
                                let existingPaths = Set(
                                    currentJournal.items.flatMap { $0.resources.map(\.relativePath) }
                                )
                                let missingItems = observedPaths.subtracting(existingPaths)
                                currentJournal.items.append(
                                    contentsOf: Self.journalItems(forPaths: missingItems)
                                )
                                // The inspection itself is a bisync dry-run and
                                // may create transient workdir files. Restore the
                                // exact pre-apply history again before exposing
                                // the journal for a later retry.
                                try FolderSyncHistoryCheckpoint.restore(
                                    connection: connection,
                                    attemptID: attemptID
                                )
                            }
                        } catch {
                            currentJournal.historyRestored = false
                        }
                    }
                    try? FolderSyncJournalStore.save(currentJournal, connection: connection)
                }
            } else if !applyStarted,
                      let syncError = finalError as? FolderSyncConnectionError,
                      syncError.isCleanPreApplySafetyFailure {
                // Capability, auth, permission or pin-limit checks can fail
                // after a durable journal/checkpoint was created but before
                // any user-file apply began. A Drive revision pin itself is
                // preservation metadata, not a destructive content mutation,
                // so restore history and discard only the transient attempt
                // journal instead of manufacturing an interrupted apply.
                if let attemptID = historyCheckpointAttemptID {
                    try? FolderSyncHistoryCheckpoint.restore(
                        connection: connection,
                        attemptID: attemptID
                    )
                    try? FolderSyncHistoryCheckpoint.remove(
                        connection: connection,
                        attemptID: attemptID
                    )
                }
                try? FolderSyncJournalStore.remove(connection: connection)
                connection.status = status(for: syncError)
            } else if !applyStarted,
                      let syncError = finalError as? FolderSyncConnectionError,
                      case .confirmationRequired = syncError {
                // A mutation-boundary guard can discover a new destination
                // after the ordinary preflight but before any app/rclone
                // mutation has succeeded. Persist that as a stable
                // confirmation state rather than leaving an `applying`
                // journal that would be upgraded to recovery-required on the
                // next launch.
                if var currentJournal = (try? FolderSyncJournalStore.load(connection: connection))
                    ?? journal
                    ?? existingJournal {
                    if currentJournal.phase != .confirmationRequired {
                        currentJournal.phase = .confirmationRequired
                        currentJournal.updatedAt = Date()
                        currentJournal.items = currentJournal.items.map { item in
                            var value = item
                            if value.state != .verified {
                                value.state = .confirmationRequired
                                if value.note == nil {
                                    value.note = "destination_changed_at_mutation_boundary"
                                }
                            }
                            return value
                        }
                        try? FolderSyncJournalStore.save(currentJournal, connection: connection)
                    }
                    journal = currentJournal
                }
                connection.status = .confirmationRequired
            } else {
                if existingJournal?.phase == .recoveryRequired {
                    connection.status = .recoveryRequired
                } else {
                    connection.status = finalError is CancellationError ? .cancelled : status(for: finalError)
                }
            }
            try? FolderSyncConnectionStore.upsert(connection, url: storeURL)
            throw finalError
        }
    }

    private static func journalItems(
        for analysis: BisyncDryRunAnalysis
    ) -> [FolderSyncJournalItem] {
        journalItems(forPaths: analysis.candidatePaths)
    }

    private static func carryingDrivePreservation(
        items: [FolderSyncJournalItem],
        existingJournal: FolderSyncJournal?
    ) -> [FolderSyncJournalItem] {
        guard let existingJournal else { return items }
        let existingByPath = Dictionary(
            uniqueKeysWithValues: existingJournal.items.flatMap { item in
                item.resources.compactMap { resource -> (String, FolderSyncDrivePreservation)? in
                    guard let preservation = resource.drivePreservation else { return nil }
                    return (resource.relativePath, preservation)
                }
            }
        )
        return items.map { item in
            var value = item
            value.resources = item.resources.map { resource in
                var updated = resource
                updated.drivePreservation = existingByPath[resource.relativePath]
                return updated
            }
            return value
        }
    }

    private static func journalItems(
        forPaths paths: Set<String>
    ) -> [FolderSyncJournalItem] {
        paths.sorted().map { path in
            let url = URL(fileURLWithPath: path)
            let role: ResourceRole
            if let type = SupportedFileTypes.classify(url: url), type.isPotentialLivePhotoStill {
                role = .photo
            } else if let type = SupportedFileTypes.classify(url: url), type.isPotentialLivePhotoVideo {
                role = .pairedVideo
            } else if SupportedFileTypes.classify(url: url)?.mediaKind == .image {
                role = .standaloneImage
            } else {
                role = .standaloneVideo
            }
            return FolderSyncJournalItem(
                resources: [
                    FolderSyncJournalResource(relativePath: path, role: role)
                ]
            )
        }
    }

    private func makeDeletionPlan(
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        analysis: BisyncDryRunAnalysis,
        items: [FolderSyncJournalItem],
        temporaryDirectory: URL
    ) throws -> FolderSyncDeletionPlan? {
        let deletionPaths = analysis.effectiveDeletionPaths
        guard !deletionPaths.isEmpty else { return nil }

        var deletionItems: [FolderSyncDeletionItem] = []
        var deletionPathsByLocation: [FolderSyncLocation: Set<String>] = [:]
        for item in items {
            let itemPaths = Set(item.resources.map(\.relativePath))
            let deletedPaths = itemPaths.intersection(deletionPaths)
            guard !deletedPaths.isEmpty else { continue }

            // Partial Live Photo deletion is rejected by makeLivePhotoPlan.
            // A deletable logical item must therefore be fully represented by
            // the deletion set before it can reach this policy layer.
            guard deletedPaths == itemPaths else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            let deletedSides = Set(deletedPaths.compactMap { analysis.deletedFromSideByPath[$0] })
            guard deletedSides.count == 1, let deletedFrom = deletedSides.first else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            let location: FolderSyncLocation = deletedFrom == .path1 ? .googleDrive : .externalDrive
            var expectedHashes: [String: Data] = [:]
            for path in deletedPaths.sorted() {
                expectedHashes[path] = try exactHashForDeletionTarget(
                    location: location,
                    relativePath: path,
                    executable: executable,
                    connection: connection,
                    root: root,
                    temporaryDirectory: temporaryDirectory
                )
            }
            deletionPathsByLocation[location, default: []].formUnion(deletedPaths)
            deletionItems.append(
                FolderSyncDeletionItem(
                    location: location,
                    relativePaths: deletedPaths.sorted(),
                    isLivePhoto: Set(item.resources.map(\.role))
                        == Set([ResourceRole.photo, ResourceRole.pairedVideo]),
                    expectedTargetSHA256ByPath: expectedHashes
                )
            )
        }
        guard !deletionItems.isEmpty else { return nil }

        var targetPathsByLocation: [FolderSyncLocation: Set<String>] = [:]
        for location in deletionPathsByLocation.keys {
            targetPathsByLocation[location] = try currentUserFilePaths(
                location: location,
                executable: executable,
                connection: connection,
                root: root
            )
        }

        let lowerBounds = targetPathsByLocation.values.map(Self.logicalItemCountLowerBound)
        let previousLogicalItemLowerBound = lowerBounds.min() ?? deletionItems.count

        var emptiedDirectories = Set<String>()
        for (location, deletedPaths) in deletionPathsByLocation {
            guard let targetPaths = targetPathsByLocation[location] else { continue }
            var candidateDirectories = Set<String>()
            for path in deletedPaths {
                var directory = (path as NSString).deletingLastPathComponent
                while true {
                    candidateDirectories.insert(directory == "." ? "" : directory)
                    guard !directory.isEmpty, directory != "." else { break }
                    let parent = (directory as NSString).deletingLastPathComponent
                    if parent == directory { break }
                    directory = parent == "." ? "" : parent
                }
            }
            for directory in candidateDirectories {
                let targetUnderDirectory = targetPaths.filter {
                    Self.path($0, isInside: directory)
                }
                guard !targetUnderDirectory.isEmpty,
                      targetUnderDirectory.isSubset(of: deletedPaths)
                else { continue }
                emptiedDirectories.insert(location.rawValue + ":" + directory)
            }
        }

        return FolderSyncDeletionPlan(
            items: deletionItems,
            previousCompletedLogicalItemCountLowerBound: previousLogicalItemLowerBound,
            emptiedNonEmptyDirectories: Array(emptiedDirectories)
        )
    }

    private func exactHashForDeletionTarget(
        location: FolderSyncLocation,
        relativePath: String,
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        temporaryDirectory: URL
    ) throws -> Data {
        switch location {
        case .externalDrive:
            guard let url = try localResourceURL(
                rootPath: root.canonicalPath,
                relativePath: relativePath
            ), FileManager.default.fileExists(atPath: url.path)
            else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            return try FileHasher.sha256(url: url)
        case .googleDrive:
            if let hash = try remoteSHA256(
                executable: executable,
                connection: connection,
                relativePath: relativePath
            ) {
                return hash
            }
            let destination = temporaryDirectory
                .appendingPathComponent("deletion-precondition-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            let result = try runSmall(
                executable: executable,
                arguments: [
                    "copyto",
                    remoteSpec(connection) + "/" + relativePath,
                    destination.path,
                    "--drive-skip-gdocs"
                ]
            )
            guard result.exitCode == 0,
                  FileManager.default.fileExists(atPath: destination.path)
            else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                testingMetrics?.recordMetadataProbe(remoteDownloadBytes: Int64(size))
            }
            return try FileHasher.sha256(url: destination)
        }
    }

    private func deletionPlanStillMatches(
        _ plan: FolderSyncDeletionPlan,
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        temporaryDirectory: URL
    ) throws -> Bool {
        for item in plan.items {
            for path in item.relativePaths {
                guard let expected = item.expectedTargetSHA256ByPath[path] else { return false }
                do {
                    let current = try exactHashForDeletionTarget(
                        location: item.location,
                        relativePath: path,
                        executable: executable,
                        connection: connection,
                        root: root,
                        temporaryDirectory: temporaryDirectory
                    )
                    guard current == expected else { return false }
                } catch {
                    return false
                }
            }
        }
        return true
    }

    private func currentUserFilePaths(
        location: FolderSyncLocation,
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport
    ) throws -> Set<String> {
        switch location {
        case .externalDrive:
            let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            ) else {
                throw FolderSyncConnectionError.rootUnavailable
            }
            let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            var paths = Set<String>()
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(prefix) else {
                    throw FolderSyncConnectionError.rootIdentityChanged
                }
                let relative = String(resolved.path.dropFirst(prefix.count))
                if let safe = BisyncDryRunAnalysis.safeRelativePath(relative),
                   !isExcludedSyncPath(safe, connection: connection) {
                    paths.insert(safe)
                }
            }
            return paths
        case .googleDrive:
            let result = try runSmall(
                executable: executable,
                arguments: [
                    "lsjson", remoteSpec(connection),
                    "--recursive", "--files-only", "--drive-skip-gdocs"
                ]
            )
            guard result.exitCode == 0 else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            let entries = try JSONDecoder().decode([RcloneListEntry].self, from: result.stdout)
            return Set(entries.compactMap { entry in
                guard entry.IsDir != true,
                      let raw = entry.Path ?? entry.Name,
                      let safe = BisyncDryRunAnalysis.safeRelativePath(raw),
                      !isExcludedSyncPath(safe, connection: connection)
                else { return nil }
                return safe
            })
        }
    }

    private func ensureRecoveryCapacity(
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        analysis: BisyncDryRunAnalysis
    ) throws {
        var localRequired: Int64 = 0
        var remoteRequired: Int64 = 0
        for path in analysis.candidatePaths
            .subtracting(analysis.renameSourcePaths)
            .subtracting(analysis.conflictPaths) {
            let targetLocation: FolderSyncLocation?
            if let deletedFrom = analysis.deletedFromSideByPath[path] {
                targetLocation = deletedFrom == .path1 ? .googleDrive : .externalDrive
            } else {
                let sides = analysis.sourceSidesByPath[path] ?? []
                if sides == [.path1] {
                    targetLocation = .googleDrive
                } else if sides == [.path2] {
                    targetLocation = .externalDrive
                } else {
                    targetLocation = nil
                }
            }
            guard let targetLocation else { continue }
            switch targetLocation {
            case .externalDrive:
                guard let url = try localResourceURL(
                    rootPath: root.canonicalPath,
                    relativePath: path
                ) else { throw FolderSyncConnectionError.rootIdentityChanged }
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw FolderSyncConnectionError.connectionCheckRequired
                }
                localRequired += Int64(values.fileSize ?? 0)
            case .googleDrive:
                remoteRequired += try remoteObjectSizeIfPresent(
                    executable: executable,
                    spec: remoteSpec(connection) + "/" + path
                )
            }
        }

        if localRequired > 0 {
            let available: Int64
            if let testingLocalRecoveryFreeBytes {
                available = testingLocalRecoveryFreeBytes
            } else {
                let recoveryURL = URL(
                    fileURLWithPath: connection.localRecoveryDirectoryPath,
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: recoveryURL,
                    withIntermediateDirectories: true
                )
                let value = try recoveryURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                    .volumeAvailableCapacity
                guard let value else { throw FolderSyncConnectionError.connectionCheckRequired }
                available = Int64(value)
            }
            guard available >= localRequired else {
                throw FolderSyncConnectionError.insufficientRecoverySpace
            }
        }

        if remoteRequired > 0 {
            let available: Int64
            if let testingRemoteRecoveryFreeBytes {
                available = testingRemoteRecoveryFreeBytes
            } else {
                let result = try runSmall(
                    executable: executable,
                    arguments: ["about", "\(connection.remoteName):", "--json"]
                )
                guard result.exitCode == 0,
                      let free = try? JSONDecoder().decode(RcloneAbout.self, from: result.stdout).free
                else {
                    throw FolderSyncConnectionError.connectionCheckRequired
                }
                available = free
            }
            guard available >= remoteRequired else {
                throw FolderSyncConnectionError.insufficientRecoverySpace
            }
        }
    }

    private func remoteObjectSizeIfPresent(
        executable: URL,
        spec: String
    ) throws -> Int64 {
        let result = try runSmall(
            executable: executable,
            arguments: ["lsjson", spec, "--stat", "--drive-skip-gdocs"]
        )
        if result.exitCode == 0 {
            let entry = try JSONDecoder().decode(RcloneListEntry.self, from: result.stdout)
            return max(entry.Size ?? 0, 0)
        }
        let message = String(data: result.stderr, encoding: .utf8)?.lowercased() ?? ""
        if message.contains("not found")
            || message.contains("doesn't exist")
            || message.contains("does not exist")
            || message.contains("directory not found") {
            return 0
        }
        throw FolderSyncConnectionError.connectionCheckRequired
    }

    private func isExcludedSyncPath(
        _ relativePath: String,
        connection: FolderSyncConnection
    ) -> Bool {
        let name = URL(fileURLWithPath: relativePath).lastPathComponent
        return relativePath == RootMarkerStore.fileName
            || relativePath.hasPrefix(".photoarchive/")
            || name == ".DS_Store"
            || name.hasPrefix("._")
            || name == accessFileName(connection)
    }

    private static func logicalItemCountLowerBound(_ paths: Set<String>) -> Int {
        var potentialLiveResources = 0
        var ordinaryResources = 0
        for path in paths {
            if let type = SupportedFileTypes.classify(url: URL(fileURLWithPath: path)),
               type.isPotentialLivePhotoStill || type.isPotentialLivePhotoVideo {
                potentialLiveResources += 1
            } else {
                ordinaryResources += 1
            }
        }
        return ordinaryResources + (potentialLiveResources + 1) / 2
    }

    private static func path(_ path: String, isInside directory: String) -> Bool {
        guard !directory.isEmpty else { return true }
        return path == directory || path.hasPrefix(directory + "/")
    }

    private func recoveryConflictsWithIdenticalContent(
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        analysis: BisyncDryRunAnalysis,
        existingJournal: FolderSyncJournal?,
        temporaryDirectory: URL
    ) throws -> Set<String> {
        guard let journal = existingJournal,
              journal.phase == .recoveryRequired,
              journal.historyRestored
        else { return [] }

        let priorPaths = Set(journal.preflightCandidatePaths)
        let candidates = analysis.conflictPaths.intersection(priorPaths)
        var identical = Set<String>()
        for relativePath in candidates.sorted() {
            guard let local = try localResourceURL(
                rootPath: root.canonicalPath,
                relativePath: relativePath
            ), FileManager.default.fileExists(atPath: local.path)
            else { continue }

            let destination = temporaryDirectory
                .appendingPathComponent("recovery-conflict-\(UUID().uuidString)", isDirectory: false)
                .appendingPathExtension(URL(fileURLWithPath: relativePath).pathExtension)
            let remoteObject = remoteSpec(connection) + "/" + relativePath
            let result = try runSmall(
                executable: executable,
                arguments: ["copyto", remoteObject, destination.path, "--drive-skip-gdocs"]
            )
            guard result.exitCode == 0,
                  FileManager.default.fileExists(atPath: destination.path)
            else { continue }
            defer { try? FileManager.default.removeItem(at: destination) }

            let localHash = try FileHasher.sha256(url: local)
            let remoteHash = try FileHasher.sha256(url: destination)
            if localHash == remoteHash {
                identical.insert(relativePath)
            }
        }
        return identical
    }

    private func reconcileInterruptedDriveCreates(
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        journal: inout FolderSyncJournal
    ) throws -> Set<String> {
        guard journal.phase == .recoveryRequired, journal.historyRestored else {
            return []
        }

        let pending = journal.items.flatMap { item in
            item.resources.compactMap { resource -> (String, FolderSyncDrivePreservation)? in
                guard let preservation = resource.drivePreservation,
                      let mutation = preservation.mutation,
                      mutation.kind == .create,
                      mutation.verified == false,
                      mutation.destinationRelativePath == resource.relativePath,
                      mutation.creationStage == .planned
                        || mutation.creationStage == .emptyObjectCreated
                        || mutation.creationStage == .contentUploaded
                else { return nil }
                return (resource.relativePath, preservation)
            }
        }
        guard !pending.isEmpty else { return [] }

        var resumable = Set<String>()
        for (relativePath, preservation) in pending {
            guard let mutation = preservation.mutation,
                  let fileID = mutation.mutatedFileID,
                  let expectedHash = preservation.expectedSourceSHA256,
                  let local = try localResourceURL(
                    rootPath: root.canonicalPath,
                    relativePath: relativePath
                  ),
                  FileManager.default.fileExists(atPath: local.path),
                  try FileHasher.sha256(url: local) == expectedHash else {
                try markDriveMutationConfirmation(
                    relativePaths: [relativePath],
                    note: "incomplete_drive_create_source_changed",
                    connection: connection,
                    journal: &journal
                )
                throw FolderSyncConnectionError.confirmationRequired
            }

            let current: DriveFileState?
            do {
                current = try manager.file(id: fileID)
            } catch {
                throw mapDriveAPIError(error, afterMutation: false)
            }

            if mutation.creationStage == .planned, current == nil {
                // The generated ID was journaled before metadata creation. The
                // ordinary local-only preflight remains authoritative here.
                continue
            }

            let live = try driveLiveFiles(
                manager: manager,
                connection: connection,
                relativePath: relativePath
            )
            let parentID = try driveParentFolderID(
                manager: manager,
                basePath: connection.remotePath,
                relativePath: relativePath
            )
            let name = URL(fileURLWithPath: relativePath).lastPathComponent
            let onlyCurrent = current.flatMap { file in
                live.count == 1 && live.first?.id == file.id ? file : nil
            }

            let safeToResume: Bool
            switch mutation.creationStage ?? .planned {
            case .planned:
                safeToResume = onlyCurrent.map {
                    Self.isOwnedEmptyDrivePlaceholder(
                        $0,
                        fileID: fileID,
                        parentID: parentID,
                        name: name,
                        recordedRevisionID: nil
                    )
                } ?? false
                if safeToResume, let onlyCurrent {
                    try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                        value.mutation?.creationStage = .emptyObjectCreated
                        value.mutation?.emptyObjectRevisionID = onlyCurrent.headRevisionID
                    }
                    try FolderSyncJournalStore.save(journal, connection: connection)
                }
            case .emptyObjectCreated:
                safeToResume = onlyCurrent.map {
                    Self.isOwnedEmptyDrivePlaceholder(
                        $0,
                        fileID: fileID,
                        parentID: parentID,
                        name: name,
                        recordedRevisionID: mutation.emptyObjectRevisionID
                    )
                } ?? false
            case .contentUploaded:
                safeToResume = onlyCurrent.map {
                    Self.isOwnedUploadedDriveFile(
                        $0,
                        fileID: fileID,
                        parentID: parentID,
                        name: name,
                        expectedHash: expectedHash,
                        recordedRevisionID: mutation.contentRevisionID
                    )
                } ?? false
            case .verified:
                safeToResume = false
            }

            if safeToResume {
                resumable.insert(relativePath)
                continue
            }

            var captureByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
            if let current { captureByID[current.id] = current }
            for file in captureByID.values where file.mimeType != "application/vnd.google-apps.folder" {
                _ = try captureDriveConflictHead(
                    file: file,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal,
                    afterMutation: false
                )
            }
            try markDriveMutationConfirmation(
                relativePaths: [relativePath],
                note: "incomplete_drive_create_changed_externally",
                connection: connection,
                journal: &journal
            )
            throw FolderSyncConnectionError.confirmationRequired
        }
        return resumable
    }

    private static func reclassifyInterruptedDriveCreates(
        analysis: inout BisyncDryRunAnalysis,
        paths: Set<String>
    ) {
        for path in paths {
            analysis.candidatePaths.insert(path)
            analysis.conflictPaths.remove(path)
            analysis.deletionPaths.remove(path)
            analysis.deletedFromSideByPath.removeValue(forKey: path)
            analysis.renameSourcePaths.remove(path)
            analysis.renameDestinationBySource.removeValue(forKey: path)
            for sourcePath in analysis.renameDestinationBySource.keys
            where analysis.renameDestinationBySource[sourcePath] == path {
                analysis.renameDestinationBySource.removeValue(forKey: sourcePath)
                analysis.renameSourcePaths.remove(sourcePath)
            }
            analysis.metadataUpdatePaths.remove(path)
            analysis.sourceSidesByPath[path] = [.path1]
            analysis.nonDeletionChangeSidesByPath[path] = [.path1]
        }
    }

    private func driveFolderID(
        manager: any DriveRevisionManaging,
        path: String
    ) throws -> String {
        var parentID: String
        do {
            parentID = try manager.rootFolderID()
        } catch {
            throw mapDriveAPIError(error, afterMutation: false)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for component in components {
            let matches: [DriveFileState]
            do {
                matches = try manager.children(
                    parentID: parentID,
                    named: component,
                    includeTrashed: false
                ).filter { $0.mimeType == "application/vnd.google-apps.folder" && !$0.trashed }
            } catch {
                throw mapDriveAPIError(error, afterMutation: false)
            }
            guard matches.count == 1, let folder = matches.first else {
                if matches.count > 1 { throw FolderSyncConnectionError.confirmationRequired }
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            parentID = folder.id
        }
        return parentID
    }

    private func driveEnsureFolderID(
        manager: any DriveRevisionManaging,
        path: String,
        afterMutation: Bool
    ) throws -> String {
        var parentID: String
        do {
            parentID = try manager.rootFolderID()
        } catch {
            throw mapDriveAPIError(error, afterMutation: afterMutation)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for component in components {
            let matches: [DriveFileState]
            do {
                matches = try manager.children(
                    parentID: parentID,
                    named: component,
                    includeTrashed: false
                ).filter { $0.mimeType == "application/vnd.google-apps.folder" && !$0.trashed }
            } catch {
                throw mapDriveAPIError(error, afterMutation: afterMutation)
            }
            if matches.count == 1, let existing = matches.first {
                parentID = existing.id
                continue
            }
            guard matches.isEmpty else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            let created: DriveFileState
            do {
                created = try manager.createFolder(parentID: parentID, name: component)
            } catch {
                // A concurrent creator may have won between list and create.
                // Re-read once and accept only one unambiguous folder.
                let retry = (try? manager.children(
                    parentID: parentID,
                    named: component,
                    includeTrashed: false
                ).filter { $0.mimeType == "application/vnd.google-apps.folder" && !$0.trashed }) ?? []
                guard retry.count == 1, let existing = retry.first else {
                    throw mapDriveAPIError(error, afterMutation: afterMutation)
                }
                parentID = existing.id
                continue
            }
            let verify = try manager.children(
                parentID: parentID,
                named: component,
                includeTrashed: false
            ).filter { $0.mimeType == "application/vnd.google-apps.folder" && !$0.trashed }
            guard verify.count == 1, verify.first?.id == created.id else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            parentID = created.id
        }
        return parentID
    }

    private func driveParentFolderID(
        manager: any DriveRevisionManaging,
        basePath: String,
        relativePath: String
    ) throws -> String {
        guard let safe = BisyncDryRunAnalysis.safeRelativePath(relativePath) else {
            throw FolderSyncConnectionError.connectionCheckRequired
        }
        let parent = (safe as NSString).deletingLastPathComponent
        let normalizedParent = parent == "." ? "" : parent
        let combined = normalizedParent.isEmpty ? basePath : basePath + "/" + normalizedParent
        return try driveFolderID(manager: manager, path: combined)
    }

    private func driveFiles(
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        relativePath: String,
        includeTrashed: Bool
    ) throws -> [DriveFileState] {
        let parentID = try driveParentFolderID(
            manager: manager,
            basePath: connection.remotePath,
            relativePath: relativePath
        )
        let name = URL(fileURLWithPath: relativePath).lastPathComponent
        do {
            return try manager.children(
                parentID: parentID,
                named: name,
                includeTrashed: includeTrashed
            )
        } catch {
            throw mapDriveAPIError(error, afterMutation: false)
        }
    }

    private func driveLiveFiles(
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        relativePath: String
    ) throws -> [DriveFileState] {
        try driveFiles(
            manager: manager,
            connection: connection,
            relativePath: relativePath,
            includeTrashed: false
        ).filter { !$0.trashed }
    }

    private func observedDriveHeadReference(
        file: DriveFileState,
        manager: any DriveRevisionManaging,
        afterMutation: Bool
    ) throws -> FolderSyncDriveRevisionReference {
        guard file.mimeType != "application/vnd.google-apps.folder",
              let hash = file.sha256,
              let revisionID = file.headRevisionID
        else {
            throw afterMutation
                ? FolderSyncConnectionError.recoveryRequired
                : FolderSyncConnectionError.concurrentMutationSafetyUnavailable
        }
        let revision: DriveRevisionState?
        do {
            revision = try manager.revision(fileID: file.id, revisionID: revisionID)
        } catch {
            throw mapDriveAPIError(error, afterMutation: afterMutation)
        }
        guard let revision,
              revision.id == revisionID,
              revision.byteSize == file.byteSize
        else {
            throw afterMutation
                ? FolderSyncConnectionError.recoveryRequired
                : FolderSyncConnectionError.confirmationRequired
        }
        return FolderSyncDriveRevisionReference(
            fileID: file.id,
            revisionID: revisionID,
            sha256: hash,
            byteSize: file.byteSize,
            keepForeverVerified: revision.keepForever
        )
    }

    private func drivePreservation(
        in journal: FolderSyncJournal,
        relativePath: String
    ) -> FolderSyncDrivePreservation? {
        for item in journal.items {
            if let resource = item.resources.first(where: { $0.relativePath == relativePath }) {
                return resource.drivePreservation
            }
        }
        return nil
    }

    private func updateDrivePreservation(
        in journal: inout FolderSyncJournal,
        relativePath: String,
        _ update: (inout FolderSyncDrivePreservation) -> Void
    ) throws {
        for itemIndex in journal.items.indices {
            for resourceIndex in journal.items[itemIndex].resources.indices
            where journal.items[itemIndex].resources[resourceIndex].relativePath == relativePath {
                var preservation = journal.items[itemIndex].resources[resourceIndex].drivePreservation
                    ?? FolderSyncDrivePreservation()
                update(&preservation)
                journal.items[itemIndex].resources[resourceIndex].drivePreservation = preservation
                journal.updatedAt = Date()
                return
            }
        }
        throw FolderSyncConnectionError.recoveryRequired
    }

    private func savePinnedDriveRecovery(
        reference: FolderSyncDriveRevisionReference,
        relativePath: String,
        kind: FolderSyncDriveRecoveryKind,
        connection: FolderSyncConnection
    ) throws {
        guard reference.keepForeverVerified else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        try FolderSyncDriveRecoveryStore.upsert(
            FolderSyncDriveRecoveryRecord(
                originalRelativePath: relativePath,
                kind: kind,
                reference: reference,
                recordedAt: Date()
            ),
            connection: connection
        )
    }

    private func pinObservedDriveReference(
        _ reference: FolderSyncDriveRevisionReference,
        relativePath: String,
        manager: any DriveRevisionManaging,
        afterMutation: Bool,
        invokeCrashHook: Bool
    ) throws -> FolderSyncDriveRevisionReference {
        if reference.keepForeverVerified {
            if invokeCrashHook, afterDriveRevisionPinnedBeforeJournalHook != nil {
                do {
                    try manager.pinRevision(fileID: reference.fileID, revisionID: reference.revisionID)
                    try afterDriveRevisionPinnedBeforeJournalHook?(relativePath)
                } catch {
                    throw mapDriveAPIError(error, afterMutation: afterMutation)
                }
            }
            return reference
        }
        do {
            try manager.pinRevision(fileID: reference.fileID, revisionID: reference.revisionID)
            if invokeCrashHook {
                try afterDriveRevisionPinnedBeforeJournalHook?(relativePath)
            }
            guard let verified = try manager.revision(
                fileID: reference.fileID,
                revisionID: reference.revisionID
            ), verified.keepForever, verified.byteSize == reference.byteSize else {
                throw DriveRevisionAPIError.invalidResponse
            }
        } catch {
            throw mapDriveAPIError(error, afterMutation: afterMutation)
        }
        var value = reference
        value.keepForeverVerified = true
        return value
    }

    private func captureDriveConflictHead(
        file: DriveFileState,
        relativePath: String,
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        journal: inout FolderSyncJournal,
        afterMutation: Bool
    ) throws -> FolderSyncDriveRevisionReference {
        var reference = try observedDriveHeadReference(
            file: file,
            manager: manager,
            afterMutation: afterMutation
        )
        if let existing = drivePreservation(in: journal, relativePath: relativePath),
           let known = ([existing.baseline, existing.appVersion].compactMap { $0 } + existing.conflicts)
            .first(where: {
                $0.fileID == reference.fileID && $0.revisionID == reference.revisionID
            }) {
            reference = known
        } else {
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { preservation in
                preservation.conflicts.append(reference)
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
        }
        let pinned = try pinObservedDriveReference(
            reference,
            relativePath: relativePath,
            manager: manager,
            afterMutation: afterMutation,
            invokeCrashHook: false
        )
        if pinned != reference {
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { preservation in
                preservation.conflicts = preservation.conflicts.map {
                    ($0.fileID == pinned.fileID && $0.revisionID == pinned.revisionID) ? pinned : $0
                }
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
        }
        try savePinnedDriveRecovery(
            reference: pinned,
            relativePath: relativePath,
            kind: .conflict,
            connection: connection
        )
        return pinned
    }

    private func snapshotDriveMutationTargets(
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        analysis: BisyncDryRunAnalysis,
        ownedCreateRecoveryPaths: Set<String> = []
    ) throws -> [String: FolderSyncDriveRevisionReference] {
        let renamePaths = analysis.renameSourcePaths.union(analysis.renameDestinationBySource.values)
        let ordinaryCandidates = analysis.candidatePaths.filter { path in
            analysis.sourceSidesByPath[path] == Set([BisyncSide.path1])
                && !analysis.deletionPaths.contains(path)
                && !analysis.conflictPaths.contains(path)
                && !analysis.metadataUpdatePaths.contains(path)
                && !renamePaths.contains(path)
                && !ownedCreateRecoveryPaths.contains(path)
        }
        let driveDeletionCandidates = analysis.effectiveDeletionPaths.filter {
            analysis.deletedFromSideByPath[$0] == .path1
        }
        let driveRenameCandidates = analysis.renameDestinationBySource.keys.filter { sourcePath in
            analysis.sourceSidesByPath[sourcePath] == Set([BisyncSide.path2])
        }
        let candidates = ordinaryCandidates
            .union(driveDeletionCandidates)
            .union(driveRenameCandidates)
            .sorted()
        var values: [String: FolderSyncDriveRevisionReference] = [:]
        for relativePath in candidates {
            let matches = try driveLiveFiles(
                manager: manager,
                connection: connection,
                relativePath: relativePath
            )
            let requiresExistingTarget = driveDeletionCandidates.contains(relativePath)
                || driveRenameCandidates.contains(relativePath)
            guard !matches.isEmpty else {
                if requiresExistingTarget {
                    throw FolderSyncConnectionError.confirmationRequired
                }
                continue
            }
            guard matches.count == 1,
                  let file = matches.first,
                  file.mimeType != "application/vnd.google-apps.folder" else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            values[relativePath] = try observedDriveHeadReference(
                file: file,
                manager: manager,
                afterMutation: false
            )
        }
        return values
    }

    private func preapplyDriveDestinationMutations(
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        analysis: BisyncDryRunAnalysis,
        items: [FolderSyncJournalItem],
        runID: String,
        preflightTargets: [String: FolderSyncDriveRevisionReference],
        journal: inout FolderSyncJournal,
        applyStarted: inout Bool
    ) throws -> DriveDestinationProtectionResult {
        guard usesDirectDriveMutationAPI else {
            return try preprotectDriveDestinationOverwritesLegacy(
                manager: manager,
                connection: connection,
                root: root,
                analysis: analysis,
                items: items,
                runID: runID,
                preflightTargets: preflightTargets,
                journal: &journal
            )
        }
        return try preapplyDriveDestinationMutationsByID(
            manager: manager,
            connection: connection,
            root: root,
            analysis: analysis,
            runID: runID,
            preflightTargets: preflightTargets,
            journal: &journal,
            applyStarted: &applyStarted
        )
    }

    private func preapplyDriveDestinationMutationsByID(
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        analysis: BisyncDryRunAnalysis,
        runID: String,
        preflightTargets: [String: FolderSyncDriveRevisionReference],
        journal: inout FolderSyncJournal,
        applyStarted: inout Bool
    ) throws -> DriveDestinationProtectionResult {
        let renamePaths = analysis.renameSourcePaths.union(analysis.renameDestinationBySource.values)
        let ordinaryPaths = analysis.candidatePaths.filter { path in
            analysis.sourceSidesByPath[path] == Set([BisyncSide.path1])
                && !analysis.deletionPaths.contains(path)
                && !analysis.conflictPaths.contains(path)
                && !analysis.metadataUpdatePaths.contains(path)
                && !renamePaths.contains(path)
        }.sorted()
        let deletionPaths = analysis.effectiveDeletionPaths.filter {
            analysis.deletedFromSideByPath[$0] == .path1
        }.sorted()
        let renameSources = analysis.renameDestinationBySource.keys.filter { sourcePath in
            analysis.sourceSidesByPath[sourcePath] == Set([BisyncSide.path2])
        }.sorted()

        var result = DriveDestinationProtectionResult()
        for relativePath in ordinaryPaths {
            guard let local = try localResourceURL(
                rootPath: root.canonicalPath,
                relativePath: relativePath
            ), FileManager.default.fileExists(atPath: local.path) else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            let values = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            let expectedHash = try FileHasher.sha256(url: local)

            if let preflight = preflightTargets[relativePath] {
                let baseline = try prepareDriveMutationBaseline(
                    manager: manager,
                    connection: connection,
                    relativePath: relativePath,
                    runID: runID,
                    preflight: preflight,
                    journal: &journal
                )
                try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                    value.expectedSourceSHA256 = expectedHash
                    value.mutation = FolderSyncDriveMutationProgress(
                        kind: .overwrite,
                        destinationRelativePath: relativePath,
                        mutatedFileID: baseline.fileID
                    )
                }
                try FolderSyncJournalStore.save(journal, connection: connection)

                applyStarted = true
                try beforeDriveMutationHook?(.overwrite, relativePath, relativePath)
                let updated: DriveFileState
                do {
                    updated = try manager.updateFile(fileID: baseline.fileID, source: local)
                } catch {
                    throw mapDriveAPIError(error, afterMutation: true)
                }
                let app = try pinDriveMutationHead(
                    updated,
                    expectedHash: expectedHash,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal
                )
                var foundConflict = try preserveDriveRevisionsCreatedDuringMutation(
                    fileID: baseline.fileID,
                    appRevisionID: app.revisionID,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal
                )
                let live = try driveLiveFiles(
                    manager: manager,
                    connection: connection,
                    relativePath: relativePath
                )
                if live.count != 1 || live.first?.id != baseline.fileID {
                    foundConflict = true
                    for file in live where file.id != baseline.fileID
                        && file.mimeType != "application/vnd.google-apps.folder" {
                        _ = try captureDriveConflictHead(
                            file: file,
                            relativePath: relativePath,
                            manager: manager,
                            connection: connection,
                            journal: &journal,
                            afterMutation: true
                        )
                    }
                    try updateDrivePreservation(in: &journal, relativePath: relativePath) {
                        $0.observedDuplicateFileIDs = live.map(\.id).sorted()
                    }
                }
                try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                    value.appVersion = app
                    value.mutation?.applied = true
                    value.mutation?.verified = !foundConflict
                }
                try FolderSyncJournalStore.save(journal, connection: connection)
                if foundConflict {
                    result.conflictPaths.insert(relativePath)
                    try markDriveMutationConfirmation(
                        relativePaths: [relativePath],
                        note: "drive_concurrent_mutation_preserved",
                        connection: connection,
                        journal: &journal
                    )
                    throw FolderSyncConnectionError.confirmationRequired
                }
            } else {
                var mutation = drivePreservation(in: journal, relativePath: relativePath)?.mutation
                let ownedFileID = mutation?.kind == .create ? mutation?.mutatedFileID : nil
                let fresh = try driveLiveFiles(
                    manager: manager,
                    connection: connection,
                    relativePath: relativePath
                )
                let canResumeOwnedCreate = ownedFileID.map { fileID in
                    fresh.count == 1 && fresh.first?.id == fileID
                } ?? false
                guard fresh.isEmpty || canResumeOwnedCreate else {
                    for file in fresh where file.mimeType != "application/vnd.google-apps.folder" {
                        _ = try captureDriveConflictHead(
                            file: file,
                            relativePath: relativePath,
                            manager: manager,
                            connection: connection,
                            journal: &journal,
                            afterMutation: false
                        )
                    }
                    try markDriveMutationConfirmation(
                        relativePaths: [relativePath],
                        note: "destination_changed_at_mutation_boundary",
                        connection: connection,
                        journal: &journal
                    )
                    throw FolderSyncConnectionError.confirmationRequired
                }
                let parentID = try driveEnsureParentFolderID(
                    manager: manager,
                    basePath: connection.remotePath,
                    relativePath: relativePath,
                    afterMutation: false
                )
                if mutation?.kind != .create || mutation?.mutatedFileID == nil {
                    let fileID: String
                    do {
                        fileID = try manager.generateFileID()
                    } catch {
                        throw mapDriveAPIError(error, afterMutation: false)
                    }
                    mutation = FolderSyncDriveMutationProgress(
                        kind: .create,
                        destinationRelativePath: relativePath,
                        mutatedFileID: fileID,
                        creationStage: .planned
                    )
                    try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                        value.expectedSourceSHA256 = expectedHash
                        value.recoveryRunID = runID
                        value.mutation = mutation
                    }
                    try FolderSyncJournalStore.save(journal, connection: connection)
                }
                guard let fileID = mutation?.mutatedFileID else {
                    throw FolderSyncConnectionError.recoveryRequired
                }
                let name = URL(fileURLWithPath: relativePath).lastPathComponent
                var current = try manager.file(id: fileID)
                if current == nil {
                    guard mutation?.creationStage != .contentUploaded,
                          mutation?.creationStage != .verified else {
                        throw FolderSyncConnectionError.recoveryRequired
                    }
                    applyStarted = true
                    try beforeDriveMutationHook?(.create, relativePath, relativePath)
                    do {
                        current = try manager.createEmptyFile(
                            id: fileID,
                            parentID: parentID,
                            name: name
                        )
                    } catch {
                        if let existing = try? manager.file(id: fileID) {
                            current = existing
                        } else {
                            throw mapDriveAPIError(error, afterMutation: true)
                        }
                    }
                }
                guard var created = current else {
                    throw FolderSyncConnectionError.recoveryRequired
                }

                if created.sha256 == expectedHash {
                    guard Self.isOwnedUploadedDriveFile(
                        created,
                        fileID: fileID,
                        parentID: parentID,
                        name: name,
                        expectedHash: expectedHash,
                        recordedRevisionID: mutation?.contentRevisionID
                    ) else {
                        _ = try captureDriveConflictHead(
                            file: created,
                            relativePath: relativePath,
                            manager: manager,
                            connection: connection,
                            journal: &journal,
                            afterMutation: false
                        )
                        try markDriveMutationConfirmation(
                            relativePaths: [relativePath],
                            note: "incomplete_drive_create_changed_externally",
                            connection: connection,
                            journal: &journal
                        )
                        throw FolderSyncConnectionError.confirmationRequired
                    }
                    try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                        if value.mutation?.creationStage != .verified {
                            value.mutation?.creationStage = .contentUploaded
                        }
                        value.mutation?.applied = true
                    }
                    try FolderSyncJournalStore.save(journal, connection: connection)
                } else {
                    let recordedEmptyRevision = mutation?.emptyObjectRevisionID
                    guard Self.isOwnedEmptyDrivePlaceholder(
                        created,
                        fileID: fileID,
                        parentID: parentID,
                        name: name,
                        recordedRevisionID: recordedEmptyRevision
                    ) else {
                        _ = try captureDriveConflictHead(
                            file: created,
                            relativePath: relativePath,
                            manager: manager,
                            connection: connection,
                            journal: &journal,
                            afterMutation: false
                        )
                        try markDriveMutationConfirmation(
                            relativePaths: [relativePath],
                            note: "incomplete_drive_create_changed_externally",
                            connection: connection,
                            journal: &journal
                        )
                        throw FolderSyncConnectionError.confirmationRequired
                    }
                    guard mutation?.creationStage != .contentUploaded,
                          mutation?.creationStage != .verified else {
                        throw FolderSyncConnectionError.recoveryRequired
                    }
                    try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                        value.mutation?.creationStage = .emptyObjectCreated
                        value.mutation?.emptyObjectRevisionID = created.headRevisionID
                    }
                    try FolderSyncJournalStore.save(journal, connection: connection)
                    try afterDriveEmptyObjectJournaledBeforeUploadHook?(relativePath)
                    applyStarted = true
                    try beforeDriveMutationHook?(.create, relativePath, relativePath)
                    do {
                        created = try manager.updateFile(fileID: fileID, source: local)
                    } catch {
                        throw mapDriveAPIError(error, afterMutation: true)
                    }
                    guard let contentRevisionID = created.headRevisionID else {
                        throw FolderSyncConnectionError.recoveryRequired
                    }
                    try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                        value.mutation?.creationStage = .contentUploaded
                        value.mutation?.contentRevisionID = contentRevisionID
                        value.mutation?.applied = true
                    }
                    try FolderSyncJournalStore.save(journal, connection: connection)
                }
                let app = try pinDriveMutationHead(
                    created,
                    expectedHash: expectedHash,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal
                )
                let live = try driveLiveFiles(
                    manager: manager,
                    connection: connection,
                    relativePath: relativePath
                )
                let hasCollision = live.count != 1 || live.first?.id != fileID
                try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                    value.appVersion = app
                    value.mutation?.applied = true
                    value.mutation?.verified = !hasCollision
                    if !hasCollision {
                        value.mutation?.creationStage = .verified
                    }
                    value.observedDuplicateFileIDs = hasCollision ? live.map(\.id).sorted() : []
                }
                try FolderSyncJournalStore.save(journal, connection: connection)
                if hasCollision {
                    for file in live where file.id != fileID
                        && file.mimeType != "application/vnd.google-apps.folder" {
                        _ = try captureDriveConflictHead(
                            file: file,
                            relativePath: relativePath,
                            manager: manager,
                            connection: connection,
                            journal: &journal,
                            afterMutation: true
                        )
                    }
                    try moveDriveFileToRecovery(
                        manager: manager,
                        connection: connection,
                        runID: runID,
                        relativePath: relativePath,
                        fileID: fileID
                    )
                    result.conflictPaths.insert(relativePath)
                    try markDriveMutationConfirmation(
                        relativePaths: [relativePath],
                        note: "destination_changed_at_mutation_boundary",
                        connection: connection,
                        journal: &journal
                    )
                    throw FolderSyncConnectionError.confirmationRequired
                }
            }
        }

        for relativePath in deletionPaths {
            guard let preflight = preflightTargets[relativePath] else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            let baseline = try prepareDriveMutationBaseline(
                manager: manager,
                connection: connection,
                relativePath: relativePath,
                runID: runID,
                preflight: preflight,
                journal: &journal
            )
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                value.mutation = FolderSyncDriveMutationProgress(
                    kind: .delete,
                    sourceRelativePath: relativePath,
                    destinationRelativePath: relativePath,
                    mutatedFileID: baseline.fileID
                )
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
            applyStarted = true
            try beforeDriveMutationHook?(.delete, relativePath, relativePath)
            let moved = try moveDriveFileToRecovery(
                manager: manager,
                connection: connection,
                runID: runID,
                relativePath: relativePath,
                fileID: baseline.fileID
            )
            var changed = moved.headRevisionID != baseline.revisionID || moved.sha256 != baseline.sha256
            if changed {
                _ = try captureDriveConflictHead(
                    file: moved,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal,
                    afterMutation: true
                )
                let originalParent = try driveParentFolderID(
                    manager: manager,
                    basePath: connection.remotePath,
                    relativePath: relativePath
                )
                do {
                    _ = try manager.moveFile(
                        fileID: baseline.fileID,
                        parentID: originalParent,
                        name: URL(fileURLWithPath: relativePath).lastPathComponent
                    )
                } catch {
                    throw mapDriveAPIError(error, afterMutation: true)
                }
            }
            let remaining = try driveLiveFiles(
                manager: manager,
                connection: connection,
                relativePath: relativePath
            )
            if !remaining.isEmpty {
                changed = true
                for file in remaining where file.mimeType != "application/vnd.google-apps.folder" {
                    _ = try captureDriveConflictHead(
                        file: file,
                        relativePath: relativePath,
                        manager: manager,
                        connection: connection,
                        journal: &journal,
                        afterMutation: true
                    )
                }
            }
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                value.mutation?.applied = true
                value.mutation?.verified = !changed
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
            if changed {
                result.conflictPaths.insert(relativePath)
                try markDriveMutationConfirmation(
                    relativePaths: [relativePath],
                    note: "drive_concurrent_mutation_preserved",
                    connection: connection,
                    journal: &journal
                )
                throw FolderSyncConnectionError.confirmationRequired
            }
        }

        for sourcePath in renameSources {
            guard let destinationPath = analysis.renameDestinationBySource[sourcePath],
                  let preflight = preflightTargets[sourcePath],
                  let localDestination = try localResourceURL(
                    rootPath: root.canonicalPath,
                    relativePath: destinationPath
                  ), FileManager.default.fileExists(atPath: localDestination.path)
            else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            let localValues = try localDestination.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey
            ])
            guard localValues.isRegularFile == true, localValues.isSymbolicLink != true,
                  try FileHasher.sha256(url: localDestination) == preflight.sha256 else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            let baseline = try prepareDriveMutationBaseline(
                manager: manager,
                connection: connection,
                relativePath: sourcePath,
                runID: runID,
                preflight: preflight,
                journal: &journal
            )
            let freshDestination = try driveLiveFiles(
                manager: manager,
                connection: connection,
                relativePath: destinationPath
            )
            guard freshDestination.isEmpty else {
                try markDriveMutationConfirmation(
                    relativePaths: [sourcePath],
                    note: "rename_destination_conflict",
                    connection: connection,
                    journal: &journal
                )
                throw FolderSyncConnectionError.confirmationRequired
            }
            let destinationParent = try driveEnsureParentFolderID(
                manager: manager,
                basePath: connection.remotePath,
                relativePath: destinationPath,
                afterMutation: false
            )
            try updateDrivePreservation(in: &journal, relativePath: sourcePath) { value in
                value.mutation = FolderSyncDriveMutationProgress(
                    kind: .move,
                    sourceRelativePath: sourcePath,
                    destinationRelativePath: destinationPath,
                    mutatedFileID: baseline.fileID
                )
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
            applyStarted = true
            try beforeDriveMutationHook?(.move, sourcePath, destinationPath)
            let moved: DriveFileState
            do {
                moved = try manager.moveFile(
                    fileID: baseline.fileID,
                    parentID: destinationParent,
                    name: URL(fileURLWithPath: destinationPath).lastPathComponent
                )
            } catch {
                throw mapDriveAPIError(error, afterMutation: true)
            }
            var changed = moved.headRevisionID != baseline.revisionID || moved.sha256 != baseline.sha256
            let destinationFiles = try driveLiveFiles(
                manager: manager,
                connection: connection,
                relativePath: destinationPath
            )
            if destinationFiles.count != 1 || destinationFiles.first?.id != baseline.fileID {
                changed = true
                for file in destinationFiles where file.id != baseline.fileID
                    && file.mimeType != "application/vnd.google-apps.folder" {
                    _ = try captureDriveConflictHead(
                        file: file,
                        relativePath: destinationPath,
                        manager: manager,
                        connection: connection,
                        journal: &journal,
                        afterMutation: true
                    )
                }
            }
            if changed {
                if moved.headRevisionID != baseline.revisionID || moved.sha256 != baseline.sha256 {
                    _ = try captureDriveConflictHead(
                        file: moved,
                        relativePath: sourcePath,
                        manager: manager,
                        connection: connection,
                        journal: &journal,
                        afterMutation: true
                    )
                }
                let sourceParent = try driveParentFolderID(
                    manager: manager,
                    basePath: connection.remotePath,
                    relativePath: sourcePath
                )
                do {
                    _ = try manager.moveFile(
                        fileID: baseline.fileID,
                        parentID: sourceParent,
                        name: URL(fileURLWithPath: sourcePath).lastPathComponent
                    )
                } catch {
                    throw mapDriveAPIError(error, afterMutation: true)
                }
            }
            try updateDrivePreservation(in: &journal, relativePath: sourcePath) { value in
                value.mutation?.applied = true
                value.mutation?.verified = !changed
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
            if changed {
                result.conflictPaths.insert(sourcePath)
                try markDriveMutationConfirmation(
                    relativePaths: [sourcePath],
                    note: "rename_destination_conflict",
                    connection: connection,
                    journal: &journal
                )
                throw FolderSyncConnectionError.confirmationRequired
            }
        }
        return result
    }

    private static func isOwnedEmptyDrivePlaceholder(
        _ file: DriveFileState,
        fileID: String,
        parentID: String,
        name: String,
        recordedRevisionID: String?
    ) -> Bool {
        guard file.id == fileID,
              !file.trashed,
              file.name == name,
              file.parentIDs.contains(parentID),
              file.byteSize == 0 else {
            return false
        }
        let emptyHash = Data(SHA256.hash(data: Data()))
        if let hash = file.sha256, hash != emptyHash {
            return false
        }
        if let recordedRevisionID,
           file.headRevisionID != recordedRevisionID {
            return false
        }
        return true
    }

    private static func isOwnedUploadedDriveFile(
        _ file: DriveFileState,
        fileID: String,
        parentID: String,
        name: String,
        expectedHash: Data,
        recordedRevisionID: String?
    ) -> Bool {
        guard let recordedRevisionID else { return false }
        return file.id == fileID
            && !file.trashed
            && file.name == name
            && file.parentIDs.contains(parentID)
            && file.sha256 == expectedHash
            && file.headRevisionID == recordedRevisionID
    }

    private func prepareDriveMutationBaseline(
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        relativePath: String,
        runID: String,
        preflight: FolderSyncDriveRevisionReference,
        journal: inout FolderSyncJournal
    ) throws -> FolderSyncDriveRevisionReference {
        var baseline = drivePreservation(in: journal, relativePath: relativePath)?.baseline ?? preflight
        try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
            value.baseline = baseline
            value.recoveryRunID = runID
        }
        try FolderSyncJournalStore.save(journal, connection: connection)
        baseline = try pinObservedDriveReference(
            baseline,
            relativePath: relativePath,
            manager: manager,
            afterMutation: false,
            invokeCrashHook: true
        )
        try savePinnedDriveRecovery(
            reference: baseline,
            relativePath: relativePath,
            kind: .baseline,
            connection: connection
        )
        try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
            value.baseline = baseline
            value.recoveryRunID = runID
        }
        try FolderSyncJournalStore.save(journal, connection: connection)
        let fresh = try driveLiveFiles(
            manager: manager,
            connection: connection,
            relativePath: relativePath
        )
        guard fresh.count == 1, let target = fresh.first else {
            for file in fresh where file.mimeType != "application/vnd.google-apps.folder" {
                if file.id == baseline.fileID,
                   file.headRevisionID == baseline.revisionID,
                   file.sha256 == baseline.sha256 { continue }
                _ = try captureDriveConflictHead(
                    file: file,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal,
                    afterMutation: false
                )
            }
            try updateDrivePreservation(in: &journal, relativePath: relativePath) {
                $0.observedDuplicateFileIDs = fresh.map(\.id).sorted()
            }
            try markDriveMutationConfirmation(
                relativePaths: [relativePath],
                note: "drive_target_changed_before_mutation",
                connection: connection,
                journal: &journal
            )
            throw FolderSyncConnectionError.confirmationRequired
        }
        let reference = try observedDriveHeadReference(
            file: target,
            manager: manager,
            afterMutation: false
        )
        guard reference.fileID == baseline.fileID,
              reference.revisionID == baseline.revisionID,
              reference.sha256 == baseline.sha256 else {
            _ = try captureDriveConflictHead(
                file: target,
                relativePath: relativePath,
                manager: manager,
                connection: connection,
                journal: &journal,
                afterMutation: false
            )
            try markDriveMutationConfirmation(
                relativePaths: [relativePath],
                note: "drive_target_changed_before_mutation",
                connection: connection,
                journal: &journal
            )
            throw FolderSyncConnectionError.confirmationRequired
        }
        try afterDriveBaselineHeadVerifiedBeforeRevisionListHook?(relativePath)
        let revisionIDs: [String]
        do {
            revisionIDs = try manager.revisions(fileID: baseline.fileID).map(\.id).sorted()
        } catch {
            throw mapDriveAPIError(error, afterMutation: false)
        }
        let stableFiles = try driveLiveFiles(
            manager: manager,
            connection: connection,
            relativePath: relativePath
        )
        guard stableFiles.count == 1, let stableTarget = stableFiles.first else {
            for file in stableFiles where file.mimeType != "application/vnd.google-apps.folder" {
                if file.id == baseline.fileID,
                   file.headRevisionID == baseline.revisionID,
                   file.sha256 == baseline.sha256 { continue }
                _ = try captureDriveConflictHead(
                    file: file,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal,
                    afterMutation: false
                )
            }
            try markDriveMutationConfirmation(
                relativePaths: [relativePath],
                note: "drive_target_changed_during_revision_snapshot",
                connection: connection,
                journal: &journal
            )
            throw FolderSyncConnectionError.confirmationRequired
        }
        let stableReference = try observedDriveHeadReference(
            file: stableTarget,
            manager: manager,
            afterMutation: false
        )
        guard stableReference.fileID == baseline.fileID,
              stableReference.revisionID == baseline.revisionID,
              stableReference.sha256 == baseline.sha256 else {
            _ = try captureDriveConflictHead(
                file: stableTarget,
                relativePath: relativePath,
                manager: manager,
                connection: connection,
                journal: &journal,
                afterMutation: false
            )
            try markDriveMutationConfirmation(
                relativePaths: [relativePath],
                note: "drive_target_changed_during_revision_snapshot",
                connection: connection,
                journal: &journal
            )
            throw FolderSyncConnectionError.confirmationRequired
        }
        let verifiedRevisionIDs: [String]
        do {
            verifiedRevisionIDs = try manager.revisions(fileID: baseline.fileID).map(\.id).sorted()
        } catch {
            throw mapDriveAPIError(error, afterMutation: false)
        }
        guard verifiedRevisionIDs == revisionIDs else {
            try markDriveMutationConfirmation(
                relativePaths: [relativePath],
                note: "drive_revision_snapshot_changed_before_mutation",
                connection: connection,
                journal: &journal
            )
            throw FolderSyncConnectionError.confirmationRequired
        }
        try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
            value.baseline = baseline
            value.knownRevisionIDsBeforeMutation = revisionIDs
            value.verifiedRevisionIDsBeforeMutation = verifiedRevisionIDs
        }
        try FolderSyncJournalStore.save(journal, connection: connection)
        return baseline
    }

    private func pinDriveMutationHead(
        _ file: DriveFileState,
        expectedHash: Data,
        relativePath: String,
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        journal: inout FolderSyncJournal
    ) throws -> FolderSyncDriveRevisionReference {
        guard file.sha256 == expectedHash else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        var reference = try observedDriveHeadReference(
            file: file,
            manager: manager,
            afterMutation: true
        )
        reference = try pinObservedDriveReference(
            reference,
            relativePath: relativePath,
            manager: manager,
            afterMutation: true,
            invokeCrashHook: false
        )
        try savePinnedDriveRecovery(
            reference: reference,
            relativePath: relativePath,
            kind: .appVersion,
            connection: connection
        )
        return reference
    }

    private func preserveDriveRevisionsCreatedDuringMutation(
        fileID: String,
        appRevisionID: String,
        relativePath: String,
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        journal: inout FolderSyncJournal
    ) throws -> Bool {
        let preservation = drivePreservation(in: journal, relativePath: relativePath)
        let verifiedBeforeMutation = preservation?.verifiedRevisionIDsBeforeMutation
            ?? preservation?.baseline.map { [$0.revisionID] }
            ?? []
        let known = Set(verifiedBeforeMutation)
        let revisions: [DriveRevisionState]
        do {
            revisions = try manager.revisions(fileID: fileID)
        } catch {
            throw mapDriveAPIError(error, afterMutation: true)
        }
        var found = false
        for revision in revisions where !known.contains(revision.id) && revision.id != appRevisionID {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhotoArchiveKit-drive-race-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                try manager.downloadRevision(fileID: fileID, revisionID: revision.id, to: temporary)
            } catch {
                throw mapDriveAPIError(error, afterMutation: true)
            }
            let values = try temporary.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(values.fileSize ?? 0)
            guard size == revision.byteSize else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            var reference = FolderSyncDriveRevisionReference(
                fileID: fileID,
                revisionID: revision.id,
                sha256: try FileHasher.sha256(url: temporary),
                byteSize: size,
                keepForeverVerified: revision.keepForever
            )
            reference = try pinObservedDriveReference(
                reference,
                relativePath: relativePath,
                manager: manager,
                afterMutation: true,
                invokeCrashHook: false
            )
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                if !value.conflicts.contains(where: {
                    $0.fileID == reference.fileID && $0.revisionID == reference.revisionID
                }) {
                    value.conflicts.append(reference)
                }
            }
            try savePinnedDriveRecovery(
                reference: reference,
                relativePath: relativePath,
                kind: .conflict,
                connection: connection
            )
            found = true
        }
        if let current = try manager.file(id: fileID),
           current.headRevisionID != appRevisionID {
            _ = try captureDriveConflictHead(
                file: current,
                relativePath: relativePath,
                manager: manager,
                connection: connection,
                journal: &journal,
                afterMutation: true
            )
            found = true
        }
        return found
    }

    @discardableResult
    private func moveDriveFileToRecovery(
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        runID: String,
        relativePath: String,
        fileID: String
    ) throws -> DriveFileState {
        let recoveryBase = connection.remoteRecoveryPath + "/" + runID + "/path2"
        let parentID = try driveEnsureParentFolderID(
            manager: manager,
            basePath: recoveryBase,
            relativePath: relativePath,
            afterMutation: true
        )
        do {
            return try manager.moveFile(
                fileID: fileID,
                parentID: parentID,
                name: URL(fileURLWithPath: relativePath).lastPathComponent
            )
        } catch {
            throw mapDriveAPIError(error, afterMutation: true)
        }
    }

    private func driveEnsureParentFolderID(
        manager: any DriveRevisionManaging,
        basePath: String,
        relativePath: String,
        afterMutation: Bool
    ) throws -> String {
        guard let safe = BisyncDryRunAnalysis.safeRelativePath(relativePath) else {
            throw FolderSyncConnectionError.connectionCheckRequired
        }
        let parent = (safe as NSString).deletingLastPathComponent
        let normalizedParent = parent == "." ? "" : parent
        let fullPath = normalizedParent.isEmpty ? basePath : basePath + "/" + normalizedParent
        return try driveEnsureFolderID(
            manager: manager,
            path: fullPath,
            afterMutation: afterMutation
        )
    }

    private func markDriveMutationConfirmation(
        relativePaths: Set<String>,
        note: String,
        connection: FolderSyncConnection,
        journal: inout FolderSyncJournal
    ) throws {
        journal.phase = .confirmationRequired
        journal.updatedAt = Date()
        journal.items = journal.items.map { item in
            var value = item
            let paths = Set(value.resources.map(\.relativePath))
            if !paths.intersection(relativePaths).isEmpty {
                value.state = .confirmationRequired
                value.note = note
            }
            return value
        }
        try FolderSyncJournalStore.save(journal, connection: connection)
    }

    private func preprotectDriveDestinationOverwritesLegacy(
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        analysis: BisyncDryRunAnalysis,
        items _: [FolderSyncJournalItem],
        runID: String,
        preflightTargets: [String: FolderSyncDriveRevisionReference],
        journal: inout FolderSyncJournal
    ) throws -> DriveDestinationProtectionResult {
        guard usesDriveRevisionProtection else { return DriveDestinationProtectionResult() }
        let renamePaths = analysis.renameSourcePaths.union(analysis.renameDestinationBySource.values)
        let candidates = analysis.candidatePaths.filter { path in
            analysis.sourceSidesByPath[path] == Set([BisyncSide.path1])
                && !analysis.deletionPaths.contains(path)
                && !analysis.conflictPaths.contains(path)
                && !analysis.metadataUpdatePaths.contains(path)
                && !renamePaths.contains(path)
        }.sorted()

        var result = DriveDestinationProtectionResult()
        for relativePath in candidates {
            guard let preflightTarget = preflightTargets[relativePath] else {
                // There was no existing Drive destination at preflight, so
                // this is creation rather than the overwrite path protected
                // by revision identity.
                continue
            }
            var baseline = drivePreservation(in: journal, relativePath: relativePath)?.baseline
                ?? preflightTarget
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                value.baseline = baseline
                value.recoveryRunID = runID
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
            baseline = try pinObservedDriveReference(
                baseline,
                relativePath: relativePath,
                manager: manager,
                afterMutation: false,
                invokeCrashHook: true
            )
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                value.baseline = baseline
                value.recoveryRunID = runID
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
            try savePinnedDriveRecovery(
                reference: baseline,
                relativePath: relativePath,
                kind: .baseline,
                connection: connection
            )

            let current = try driveLiveFiles(
                manager: manager,
                connection: connection,
                relativePath: relativePath
            )
            guard !current.isEmpty else {
                journal.phase = .confirmationRequired
                try FolderSyncJournalStore.save(journal, connection: connection)
                throw FolderSyncConnectionError.confirmationRequired
            }
            if current.count != 1 {
                for file in current where file.mimeType != "application/vnd.google-apps.folder" {
                    if file.id == baseline.fileID,
                       file.headRevisionID == baseline.revisionID,
                       file.sha256 == baseline.sha256 {
                        continue
                    }
                    _ = try captureDriveConflictHead(
                        file: file,
                        relativePath: relativePath,
                        manager: manager,
                        connection: connection,
                        journal: &journal,
                        afterMutation: false
                    )
                }
                try updateDrivePreservation(in: &journal, relativePath: relativePath) { preservation in
                    preservation.observedDuplicateFileIDs = current.map(\.id).sorted()
                }
                journal.phase = .confirmationRequired
                try FolderSyncJournalStore.save(journal, connection: connection)
                throw FolderSyncConnectionError.confirmationRequired
            }
            guard let target = current.first,
                  target.mimeType != "application/vnd.google-apps.folder",
                  let local = try localResourceURL(
                    rootPath: root.canonicalPath,
                    relativePath: relativePath
                  ), FileManager.default.fileExists(atPath: local.path)
            else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            let localValues = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard localValues.isRegularFile == true, localValues.isSymbolicLink != true else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            let expectedSourceHash = try FileHasher.sha256(url: local)
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                value.baseline = baseline
                value.expectedSourceSHA256 = expectedSourceHash
                value.recoveryRunID = runID
            }
            try FolderSyncJournalStore.save(journal, connection: connection)

            let fresh = try driveLiveFiles(
                manager: manager,
                connection: connection,
                relativePath: relativePath
            )
            guard fresh.count == 1, let freshTarget = fresh.first else {
                for file in fresh where file.mimeType != "application/vnd.google-apps.folder" {
                    if file.id == baseline.fileID,
                       file.headRevisionID == baseline.revisionID,
                       file.sha256 == baseline.sha256 {
                        continue
                    }
                    _ = try captureDriveConflictHead(
                        file: file,
                        relativePath: relativePath,
                        manager: manager,
                        connection: connection,
                        journal: &journal,
                        afterMutation: false
                    )
                }
                try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                    value.observedDuplicateFileIDs = fresh.map(\.id).sorted()
                }
                journal.phase = .confirmationRequired
                try FolderSyncJournalStore.save(journal, connection: connection)
                throw FolderSyncConnectionError.confirmationRequired
            }
            let freshReference = try observedDriveHeadReference(
                file: freshTarget,
                manager: manager,
                afterMutation: false
            )
            guard freshReference.fileID == baseline.fileID,
                  freshReference.revisionID == baseline.revisionID,
                  freshReference.sha256 == baseline.sha256 else {
                _ = try captureDriveConflictHead(
                    file: freshTarget,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal,
                    afterMutation: false
                )
                journal.phase = .confirmationRequired
                try FolderSyncJournalStore.save(journal, connection: connection)
                throw FolderSyncConnectionError.confirmationRequired
            }
            result.protectedPaths.insert(relativePath)
        }
        return result
    }

    private func matchingPinnedDriveRevisions(
        file: DriveFileState,
        expectedSHA256: Data,
        manager: any DriveRevisionManaging,
        afterMutation: Bool
    ) throws -> [FolderSyncDriveRevisionReference] {
        let revisions: [DriveRevisionState]
        do {
            revisions = try manager.revisions(fileID: file.id)
        } catch {
            throw mapDriveAPIError(error, afterMutation: afterMutation)
        }
        var matches: [FolderSyncDriveRevisionReference] = []
        for revision in revisions where revision.keepForever {
            if file.headRevisionID == revision.id,
               file.sha256 == expectedSHA256,
               file.byteSize == revision.byteSize {
                matches.append(
                    FolderSyncDriveRevisionReference(
                        fileID: file.id,
                        revisionID: revision.id,
                        sha256: expectedSHA256,
                        byteSize: revision.byteSize,
                        keepForeverVerified: true
                    )
                )
                continue
            }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhotoArchiveKit-drive-revision-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                try manager.downloadRevision(
                    fileID: file.id,
                    revisionID: revision.id,
                    to: temporary
                )
            } catch {
                throw mapDriveAPIError(error, afterMutation: afterMutation)
            }
            guard FileManager.default.fileExists(atPath: temporary.path) else {
                throw afterMutation
                    ? FolderSyncConnectionError.recoveryRequired
                    : FolderSyncConnectionError.connectionCheckRequired
            }
            let values = try temporary.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(values.fileSize ?? 0)
            guard size == revision.byteSize else {
                throw afterMutation
                    ? FolderSyncConnectionError.recoveryRequired
                    : FolderSyncConnectionError.confirmationRequired
            }
            let hash = try FileHasher.sha256(url: temporary)
            if hash == expectedSHA256 {
                matches.append(
                    FolderSyncDriveRevisionReference(
                        fileID: file.id,
                        revisionID: revision.id,
                        sha256: hash,
                        byteSize: size,
                        keepForeverVerified: true
                    )
                )
            }
        }
        return matches
    }

    private func verifiedPinnedDriveReference(
        _ reference: FolderSyncDriveRevisionReference,
        relativePath: String,
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        kind: FolderSyncDriveRecoveryKind,
        journal: inout FolderSyncJournal,
        afterMutation: Bool
    ) throws -> FolderSyncDriveRevisionReference {
        let revision: DriveRevisionState?
        do {
            revision = try manager.revision(
                fileID: reference.fileID,
                revisionID: reference.revisionID
            )
        } catch {
            throw mapDriveAPIError(error, afterMutation: afterMutation)
        }
        guard let revision, revision.byteSize == reference.byteSize else {
            throw afterMutation
                ? FolderSyncConnectionError.recoveryRequired
                : FolderSyncConnectionError.confirmationRequired
        }
        var value = reference
        if !revision.keepForever || !value.keepForeverVerified {
            value = try pinObservedDriveReference(
                value,
                relativePath: relativePath,
                manager: manager,
                afterMutation: afterMutation,
                invokeCrashHook: false
            )
        }
        try savePinnedDriveRecovery(
            reference: value,
            relativePath: relativePath,
            kind: kind,
            connection: connection
        )
        return value
    }

    private func verifyDriveDestinationOverwrites(
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        root _: RegisteredRootReport? = nil,
        relativePaths: Set<String>,
        journal: inout FolderSyncJournal,
        afterMutation: Bool
    ) throws -> DriveDestinationProtectionResult {
        var result = DriveDestinationProtectionResult()
        for relativePath in relativePaths.sorted() {
            guard var preservation = drivePreservation(
                in: journal,
                relativePath: relativePath
            ), var baseline = preservation.baseline,
            let expectedSourceHash = preservation.expectedSourceSHA256,
            let recoveryRunID = preservation.recoveryRunID else {
                throw FolderSyncConnectionError.recoveryRequired
            }

            baseline = try verifiedPinnedDriveReference(
                baseline,
                relativePath: relativePath,
                manager: manager,
                connection: connection,
                kind: .baseline,
                journal: &journal,
                afterMutation: afterMutation
            )
            try updateDrivePreservation(in: &journal, relativePath: relativePath) {
                $0.baseline = baseline
            }

            let oldFile: DriveFileState
            do {
                guard let loaded = try manager.file(id: baseline.fileID) else {
                    throw DriveRevisionAPIError.notFound
                }
                oldFile = loaded
            } catch {
                throw mapDriveAPIError(error, afterMutation: true)
            }

            if !oldFile.trashed {
                let recoveryBase = connection.remoteRecoveryPath
                    + "/" + recoveryRunID + "/path2"
                let recoveryParentID = try driveParentFolderID(
                    manager: manager,
                    basePath: recoveryBase,
                    relativePath: relativePath
                )
                guard oldFile.parentIDs.contains(recoveryParentID) else {
                    throw FolderSyncConnectionError.recoveryRequired
                }
            }

            if oldFile.headRevisionID != baseline.revisionID
                || oldFile.sha256 != baseline.sha256 {
                _ = try captureDriveConflictHead(
                    file: oldFile,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal,
                    afterMutation: true
                )
                result.conflictPaths.insert(relativePath)
            }

            let allNamed = try driveFiles(
                manager: manager,
                connection: connection,
                relativePath: relativePath,
                includeTrashed: true
            ).filter { $0.mimeType != "application/vnd.google-apps.folder" }
            let live = allNamed.filter { !$0.trashed }
            guard !live.isEmpty else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            if live.count > 1 {
                preservation.observedDuplicateFileIDs = live.map(\.id).sorted()
                result.conflictPaths.insert(relativePath)
            }

            for file in allNamed {
                if file.id == baseline.fileID { continue }
                if file.sha256 != expectedSourceHash {
                    _ = try captureDriveConflictHead(
                        file: file,
                        relativePath: relativePath,
                        manager: manager,
                        connection: connection,
                        journal: &journal,
                        afterMutation: true
                    )
                    result.conflictPaths.insert(relativePath)
                }
            }

            var appMatches = [FolderSyncDriveRevisionReference]()
            for file in allNamed where file.id != baseline.fileID {
                if file.sha256 == expectedSourceHash,
                   let current = try? observedDriveHeadReference(
                    file: file,
                    manager: manager,
                    afterMutation: true
                   ) {
                    let pinned = try pinObservedDriveReference(
                        current,
                        relativePath: relativePath,
                        manager: manager,
                        afterMutation: true,
                        invokeCrashHook: false
                    )
                    appMatches.append(pinned)
                }
                appMatches.append(
                    contentsOf: try matchingPinnedDriveRevisions(
                        file: file,
                        expectedSHA256: expectedSourceHash,
                        manager: manager,
                        afterMutation: true
                    )
                )
            }
            let uniqueMatches = Dictionary(
                grouping: appMatches,
                by: { $0.fileID + ":" + $0.revisionID }
            ).compactMap { $0.value.first }
            guard uniqueMatches.count == 1, let appVersion = uniqueMatches.first else {
                if uniqueMatches.count > 1 || live.count > 1 {
                    result.conflictPaths.insert(relativePath)
                    journal.phase = .confirmationRequired
                    try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                        value.observedDuplicateFileIDs = live.map(\.id).sorted()
                    }
                    try FolderSyncJournalStore.save(journal, connection: connection)
                    throw FolderSyncConnectionError.confirmationRequired
                }
                throw FolderSyncConnectionError.recoveryRequired
            }

            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                value.baseline = baseline
                value.appVersion = appVersion
                value.observedDuplicateFileIDs = live.count > 1 ? live.map(\.id).sorted() : []
            }
            try savePinnedDriveRecovery(
                reference: appVersion,
                relativePath: relativePath,
                kind: .appVersion,
                connection: connection
            )

            if let appFile = allNamed.first(where: { $0.id == appVersion.fileID }) {
                if appFile.trashed
                    || appFile.headRevisionID != appVersion.revisionID
                    || appFile.sha256 != appVersion.sha256 {
                    result.conflictPaths.insert(relativePath)
                    if !appFile.trashed,
                       appFile.headRevisionID != appVersion.revisionID
                            || appFile.sha256 != appVersion.sha256 {
                        _ = try captureDriveConflictHead(
                            file: appFile,
                            relativePath: relativePath,
                            manager: manager,
                            connection: connection,
                            journal: &journal,
                            afterMutation: true
                        )
                    }
                }
            } else {
                throw FolderSyncConnectionError.recoveryRequired
            }

            result.protectedPaths.insert(relativePath)
            try FolderSyncJournalStore.save(journal, connection: connection)
        }
        return result
    }

    private func reconcileInterruptedDriveProtection(
        manager: any DriveRevisionManaging,
        executable _: URL,
        connection: FolderSyncConnection,
        journal: inout FolderSyncJournal
    ) throws {
        let paths = Set(
            journal.items.flatMap { item in
                item.resources.compactMap { resource in
                    resource.drivePreservation?.baseline == nil ? nil : resource.relativePath
                }
            }
        )
        guard !paths.isEmpty else { return }

        for relativePath in paths.sorted() {
            guard var preservation = drivePreservation(in: journal, relativePath: relativePath),
                  var baseline = preservation.baseline else { continue }
            baseline = try verifiedPinnedDriveReference(
                baseline,
                relativePath: relativePath,
                manager: manager,
                connection: connection,
                kind: .baseline,
                journal: &journal,
                afterMutation: true
            )
            preservation.baseline = baseline
            if var app = preservation.appVersion {
                app = try verifiedPinnedDriveReference(
                    app,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    kind: .appVersion,
                    journal: &journal,
                    afterMutation: true
                )
                preservation.appVersion = app
            }
            var reconciledConflicts: [FolderSyncDriveRevisionReference] = []
            for conflict in preservation.conflicts {
                reconciledConflicts.append(
                    try verifiedPinnedDriveReference(
                        conflict,
                        relativePath: relativePath,
                        manager: manager,
                        connection: connection,
                        kind: .conflict,
                        journal: &journal,
                        afterMutation: true
                    )
                )
            }
            preservation.conflicts = reconciledConflicts
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { $0 = preservation }
            try FolderSyncJournalStore.save(journal, connection: connection)

            let live = try driveLiveFiles(
                manager: manager,
                connection: connection,
                relativePath: relativePath
            )
            if live.count == 1,
               let only = live.first,
               only.id == baseline.fileID,
               only.headRevisionID == baseline.revisionID,
               only.sha256 == baseline.sha256,
               preservation.appVersion == nil {
                // The process stopped after pinning but before rclone moved the
                // target. The durable baseline is sufficient; the next attempt
                // may proceed with a new recovery run ID.
                continue
            }

            _ = try verifyDriveDestinationOverwrites(
                manager: manager,
                connection: connection,
                relativePaths: [relativePath],
                journal: &journal,
                afterMutation: true
            )
        }
        try FolderSyncJournalStore.save(journal, connection: connection)
    }

    private func preapplyLocalDestinationOverwrites(
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        analysis: BisyncDryRunAnalysis,
        items: [FolderSyncJournalItem],
        runPaths: RunPaths,
        applyStarted: inout Bool
    ) throws -> LocalDestinationPreapplyResult {
        let renamePaths = analysis.renameSourcePaths
            .union(analysis.renameDestinationBySource.values)
        let candidates = analysis.candidatePaths.filter { path in
            analysis.sourceSidesByPath[path] == Set([BisyncSide.path2])
                && !analysis.deletionPaths.contains(path)
                && !analysis.conflictPaths.contains(path)
                && !analysis.metadataUpdatePaths.contains(path)
                && !renamePaths.contains(path)
        }.sorted()
        guard !candidates.isEmpty else { return LocalDestinationPreapplyResult() }

        let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let stagingDirectory = rootURL
            .appendingPathComponent(".photoarchive", isDirectory: true)
            .appendingPathComponent("sync-staging", isDirectory: true)
            .appendingPathComponent(runPaths.runID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        defer {
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: stagingDirectory,
                includingPropertiesForKeys: nil
            ), contents.isEmpty {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }

        var result = LocalDestinationPreapplyResult()
        for relativePath in candidates {
            guard let destination = try localResourceURL(
                rootPath: root.canonicalPath,
                relativePath: relativePath
            ) else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            guard let safeRelativePath = BisyncDryRunAnalysis.safeRelativePath(relativePath) else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            guard let expectedSourceHash = try remoteSHA256(
                executable: executable,
                connection: connection,
                relativePath: relativePath
            ) else {
                throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
            }

            let destinationExists = FileManager.default.fileExists(atPath: destination.path)
            if destinationExists {
                let destinationValues = try destination.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ])
                guard destinationValues.isRegularFile == true,
                      destinationValues.isSymbolicLink != true
                else {
                    throw FolderSyncConnectionError.connectionCheckRequired
                }

                let baselineDestinationHash = try FileHasher.sha256(url: destination)
                let baselineRecovery = runPaths.localBackupDirectory
                    .appendingPathComponent(relativePath, isDirectory: false)
                try snapshotLocalDestination(
                    source: destination,
                    expectedHash: baselineDestinationHash,
                    recovery: baselineRecovery
                )

                let stage = stagingDirectory.appendingPathComponent(safeRelativePath, isDirectory: false)
                try FileManager.default.createDirectory(
                    at: stage.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let copy = try runSmall(
                    executable: executable,
                    arguments: [
                        "copyto",
                        remoteSpec(connection) + "/" + relativePath,
                        stage.path,
                        "--drive-skip-gdocs"
                    ]
                )
                guard copy.exitCode == 0,
                      FileManager.default.fileExists(atPath: stage.path),
                      try FileHasher.sha256(url: stage) == expectedSourceHash,
                      try remoteSHA256(
                        executable: executable,
                        connection: connection,
                        relativePath: relativePath
                      ) == expectedSourceHash
                else {
                    try? FileManager.default.removeItem(at: stage)
                    throw FolderSyncConnectionError.confirmationRequired
                }

                try beforeLocalDestinationSwapHook?(relativePath)
                guard FileManager.default.fileExists(atPath: destination.path) else {
                    try? FileManager.default.removeItem(at: stage)
                    throw FolderSyncConnectionError.confirmationRequired
                }

                let swapErrorCode: Int32?
                if let injected = testingLocalSwapErrorCode {
                    swapErrorCode = injected
                } else {
                    let swapResult = stage.path.withCString { stagePath in
                        destination.path.withCString { destinationPath in
                            renameatx_np(
                                AT_FDCWD,
                                stagePath,
                                AT_FDCWD,
                                destinationPath,
                                UInt32(RENAME_SWAP)
                            )
                        }
                    }
                    swapErrorCode = swapResult == 0 ? nil : errno
                }
                if let code = swapErrorCode {
                    try? FileManager.default.removeItem(at: stage)
                    if code == ENOENT {
                        throw FolderSyncConnectionError.confirmationRequired
                    }
                    if code == EXDEV || code == ENOTSUP || code == EINVAL {
                        throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
                    }
                    throw FolderSyncConnectionError.recoveryRequired
                }
                applyStarted = true
                try afterLocalDestinationSwapHook?(relativePath)

                let preservedHash = try FileHasher.sha256(url: stage)
                result.appliedPaths.insert(relativePath)
                if preservedHash != baselineDestinationHash {
                    let conflictRecovery = runPaths.localBackupDirectory
                        .deletingLastPathComponent()
                        .appendingPathComponent("path1-conflicts", isDirectory: true)
                        .appendingPathComponent(relativePath, isDirectory: false)
                    try preserveSwappedLocalDestination(
                        stage: stage,
                        recovery: conflictRecovery
                    )
                    result.concurrentlyChangedPaths.insert(relativePath)
                } else {
                    try FileManager.default.removeItem(at: stage)
                }
            } else {
                let stage = stagingDirectory.appendingPathComponent(safeRelativePath, isDirectory: false)
                try FileManager.default.createDirectory(
                    at: stage.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let copy = try runSmall(
                    executable: executable,
                    arguments: [
                        "copyto",
                        remoteSpec(connection) + "/" + relativePath,
                        stage.path,
                        "--drive-skip-gdocs"
                    ]
                )
                guard copy.exitCode == 0,
                      FileManager.default.fileExists(atPath: stage.path),
                      try FileHasher.sha256(url: stage) == expectedSourceHash,
                      try remoteSHA256(
                        executable: executable,
                        connection: connection,
                        relativePath: relativePath
                      ) == expectedSourceHash
                else {
                    try? FileManager.default.removeItem(at: stage)
                    throw FolderSyncConnectionError.confirmationRequired
                }

                try beforeLocalDestinationSwapHook?(relativePath)
                if FileManager.default.fileExists(atPath: destination.path) {
                    let conflictRecovery = runPaths.localBackupDirectory
                        .deletingLastPathComponent()
                        .appendingPathComponent("path1-conflicts", isDirectory: true)
                        .appendingPathComponent(relativePath, isDirectory: false)
                    try? preserveSwappedLocalDestination(
                        stage: stage,
                        recovery: conflictRecovery
                    )
                    result.concurrentlyChangedPaths.insert(relativePath)
                    throw FolderSyncConnectionError.confirmationRequired
                }

                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let exclErrorCode: Int32?
                if let injected = testingLocalSwapErrorCode {
                    exclErrorCode = injected
                } else {
                    let exclResult = stage.path.withCString { stagePath in
                        destination.path.withCString { destinationPath in
                            renameatx_np(
                                AT_FDCWD,
                                stagePath,
                                AT_FDCWD,
                                destinationPath,
                                UInt32(RENAME_EXCL)
                            )
                        }
                    }
                    exclErrorCode = exclResult == 0 ? nil : errno
                }
                if let code = exclErrorCode {
                    if code == EEXIST {
                        let conflictRecovery = runPaths.localBackupDirectory
                            .deletingLastPathComponent()
                            .appendingPathComponent("path1-conflicts", isDirectory: true)
                            .appendingPathComponent(relativePath, isDirectory: false)
                        try? preserveSwappedLocalDestination(
                            stage: stage,
                            recovery: conflictRecovery
                        )
                        result.concurrentlyChangedPaths.insert(relativePath)
                        throw FolderSyncConnectionError.confirmationRequired
                    }
                    try? FileManager.default.removeItem(at: stage)
                    if code == EXDEV || code == ENOTSUP || code == EINVAL {
                        throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
                    }
                    throw FolderSyncConnectionError.recoveryRequired
                }
                applyStarted = true
                result.appliedPaths.insert(relativePath)
                try afterLocalDestinationSwapHook?(relativePath)
            }
        }
        return result
    }

    private func recoverInterruptedLocalSwapArtifacts(
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport
    ) throws {
        let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let stagingRoot = rootURL
            .appendingPathComponent(".photoarchive", isDirectory: true)
            .appendingPathComponent("sync-staging", isDirectory: true)
        guard FileManager.default.fileExists(atPath: stagingRoot.path) else { return }
        let rootPrefix = stagingRoot.path.hasSuffix("/") ? stagingRoot.path : stagingRoot.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: stagingRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let stage as URL in enumerator {
            let values = try stage.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true else { continue }
            guard values.isSymbolicLink != true else { throw FolderSyncConnectionError.recoveryRequired }
            let resolved = stage.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(rootPrefix) else { throw FolderSyncConnectionError.recoveryRequired }
            let raw = String(resolved.path.dropFirst(rootPrefix.count))
            let components = raw.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count >= 2 else { throw FolderSyncConnectionError.recoveryRequired }
            let runID = String(components[0])
            let relativePath = components.dropFirst().joined(separator: "/")
            guard let safe = BisyncDryRunAnalysis.safeRelativePath(relativePath),
                  let destination = try localResourceURL(rootPath: root.canonicalPath, relativePath: safe),
                  FileManager.default.fileExists(atPath: destination.path)
            else { throw FolderSyncConnectionError.recoveryRequired }

            let baseline = URL(fileURLWithPath: connection.localRecoveryDirectoryPath, isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
                .appendingPathComponent("path1", isDirectory: true)
                .appendingPathComponent(safe, isDirectory: false)
            guard FileManager.default.fileExists(atPath: baseline.path) else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            let stageHash = try FileHasher.sha256(url: stage)
            let baselineHash = try FileHasher.sha256(url: baseline)
            let destinationHash = try FileHasher.sha256(url: destination)

            if stageHash == baselineHash {
                try FileManager.default.removeItem(at: stage)
                continue
            }

            if destinationHash == baselineHash,
               let remoteHash = try remoteSHA256(
                    executable: executable,
                    connection: connection,
                    relativePath: safe
               ), remoteHash == stageHash {
                // Crash happened before the swap. The staged object is still
                // available from the source, while the verified baseline is
                // already preserved in recovery.
                try FileManager.default.removeItem(at: stage)
                continue
            }

            let conflictRecovery = URL(fileURLWithPath: connection.localRecoveryDirectoryPath, isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
                .appendingPathComponent("path1-conflicts", isDirectory: true)
                .appendingPathComponent(safe, isDirectory: false)
            if FileManager.default.fileExists(atPath: conflictRecovery.path) {
                guard try FileHasher.sha256(url: conflictRecovery) == stageHash else {
                    throw FolderSyncConnectionError.recoveryRequired
                }
                try FileManager.default.removeItem(at: stage)
            } else {
                try preserveSwappedLocalDestination(stage: stage, recovery: conflictRecovery)
            }
        }
    }

    private func snapshotLocalDestination(
        source: URL,
        expectedHash: Data,
        recovery: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: recovery.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: recovery.path) else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        let temporary = recovery.deletingLastPathComponent()
            .appendingPathComponent(".photoarchive-baseline-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        guard try FileHasher.sha256(url: temporary) == expectedHash,
              try FileHasher.sha256(url: source) == expectedHash
        else {
            throw FolderSyncConnectionError.confirmationRequired
        }
        try FileManager.default.moveItem(at: temporary, to: recovery)
    }

    private func preserveSwappedLocalDestination(
        stage: URL,
        recovery: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: recovery.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: recovery.path) else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        do {
            try FileManager.default.moveItem(at: stage, to: recovery)
            return
        } catch {
            // An external drive and the app-managed recovery store can be on
            // different volumes. Fall back to a verified snapshot copy. If the
            // swapped-out file changes while that copy is being made, leave the
            // source in the excluded staging area and fail closed instead of
            // deleting the only remaining version.
            let temporary = recovery.deletingLastPathComponent()
                .appendingPathComponent(".photoarchive-recovery-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: stage, to: temporary)
            let sourceBeforeRemoval = try FileHasher.sha256(url: stage)
            let copiedHash = try FileHasher.sha256(url: temporary)
            guard sourceBeforeRemoval == copiedHash else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            try FileManager.default.moveItem(at: temporary, to: recovery)
            guard try FileHasher.sha256(url: stage) == copiedHash else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            try FileManager.default.removeItem(at: stage)
        }
    }

    private func identicalLocalRemotePaths(
        _ paths: Set<String>,
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport
    ) throws -> Set<String> {
        var identical = Set<String>()
        for relativePath in paths.sorted() {
            guard let local = try localResourceURL(
                rootPath: root.canonicalPath,
                relativePath: relativePath
            ), FileManager.default.fileExists(atPath: local.path),
            let remoteHash = try remoteSHA256(
                executable: executable,
                connection: connection,
                relativePath: relativePath
            ) else { continue }
            if try FileHasher.sha256(url: local) == remoteHash {
                identical.insert(relativePath)
            }
        }
        return identical
    }

    private func inspectRecoveryChanges(
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport
    ) throws -> BisyncDryRunAnalysis {
        let inspectionID = "recovery-inspection-" + Self.runIdentifier(Date())
        let paths = try runPaths(connection: connection, runID: inspectionID)
        defer { try? FileManager.default.removeItem(at: paths.logDirectory) }
        var arguments = commonBisyncArguments(
            connection: connection,
            localRootPath: root.canonicalPath,
            runPaths: paths
        )
        arguments.append(contentsOf: ["--dry-run", "--use-json-log", "--log-level", "NOTICE"])
        let result = try runToFiles(
            executable: executable,
            arguments: arguments,
            logDirectory: paths.logDirectory,
            basename: "recovery-inspection"
        )
        guard result.exitCode == 0 else {
            throw classifyFailure(logURL: result.stderrURL)
        }
        return try Self.parseAnalysis(url: result.stderrURL)
    }

    private struct RunPaths {
        let runID: String
        let logDirectory: URL
        let localBackupDirectory: URL
        let remoteBackupSpec: String
        let livePhotoProbeDirectory: URL
    }

    private func runPaths(connection: FolderSyncConnection, runID: String) throws -> RunPaths {
        let logDirectory = URL(fileURLWithPath: connection.workDirectoryPath, isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        let localBackup = URL(fileURLWithPath: connection.localRecoveryDirectoryPath, isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("path1", isDirectory: true)
        let liveProbe = logDirectory.appendingPathComponent("live-photo-preflight", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localBackup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: liveProbe, withIntermediateDirectories: true)
        let remoteBackup = "\(connection.remoteName):\(connection.remoteRecoveryPath)/\(runID)/path2"
        return RunPaths(
            runID: runID,
            logDirectory: logDirectory,
            localBackupDirectory: localBackup,
            remoteBackupSpec: remoteBackup,
            livePhotoProbeDirectory: liveProbe
        )
    }

    private func commonBisyncArguments(
        connection: FolderSyncConnection,
        localRootPath: String,
        runPaths: RunPaths
    ) -> [String] {
        [
            "bisync",
            localRootPath,
            remoteSpec(connection),
            "--workdir", connection.workDirectoryPath,
            "--filters-file", filterFileURL(connection).path,
            "--check-access",
            "--check-filename", accessFileName(connection),
            "--compare", "size,modtime,checksum",
            "--slow-hash-sync-only",
            "--conflict-resolve", "none",
            "--conflict-loser", "num",
            "--max-delete", "100",
            "--track-renames",
            "--recover",
            "--check-sync", "true",
            "--create-empty-src-dirs",
            "--backup-dir1", runPaths.localBackupDirectory.path,
            "--backup-dir2", runPaths.remoteBackupSpec,
            "--drive-skip-gdocs"
        ]
    }

    private func prepareLocalState(connection: FolderSyncConnection) throws {
        let workDirectory = URL(fileURLWithPath: connection.workDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let filterURL = filterFileURL(connection)
        let contents = [
            "- /.photoarchive-root",
            "- /.photoarchive/**",
            "- /.DS_Store",
            "- /._*"
        ].joined(separator: "\n") + "\n"
        if FileManager.default.fileExists(atPath: filterURL.path) {
            let existing = try String(contentsOf: filterURL, encoding: .utf8)
            guard existing == contents else { throw FolderSyncConnectionError.recoveryRequired }
        } else {
            try contents.write(to: filterURL, atomically: true, encoding: .utf8)
        }
    }

    private func prepareInitialAccessMarker(
        executable: URL,
        connection: FolderSyncConnection,
        localRootPath: String
    ) throws {
        let localProbe = URL(fileURLWithPath: localRootPath, isDirectory: true)
            .appendingPathComponent(accessFileName(connection))
        if !FileManager.default.fileExists(atPath: localProbe.path) {
            try "PhotoArchiveKit sync access check\n".write(
                to: localProbe,
                atomically: true,
                encoding: .utf8
            )
        }
        let mkdir = try runSmall(
            executable: executable,
            arguments: ["mkdir", remoteSpec(connection)]
        )
        guard mkdir.exitCode == 0 else { throw FolderSyncConnectionError.connectionCheckRequired }
        let remoteProbe = remoteSpec(connection) + "/" + accessFileName(connection)
        let copy = try runSmall(
            executable: executable,
            arguments: ["copyto", localProbe.path, remoteProbe]
        )
        guard copy.exitCode == 0 else { throw FolderSyncConnectionError.connectionCheckRequired }
    }

    private func verifyInitialMergeIsNonDestructive(
        executable: URL,
        connection: FolderSyncConnection,
        localRootPath: String
    ) throws {
        let directory = URL(fileURLWithPath: connection.workDirectoryPath, isDirectory: true)
            .appendingPathComponent("initial-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let combinedURL = directory.appendingPathComponent("combined.txt", isDirectory: false)
        let result = try runToFiles(
            executable: executable,
            arguments: [
                "check",
                localRootPath,
                remoteSpec(connection),
                "--download",
                "--combined", combinedURL.path,
                "--filter-from", filterFileURL(connection).path,
                "--drive-skip-gdocs"
            ],
            logDirectory: directory,
            basename: "check"
        )

        guard FileManager.default.fileExists(atPath: combinedURL.path),
              let text = try? String(contentsOf: combinedURL, encoding: .utf8)
        else {
            throw FolderSyncConnectionError.connectionCheckRequired
        }

        var sawComparableFile = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard line.count >= 3,
                  let marker = line.first,
                  line[line.index(after: line.startIndex)] == " "
            else {
                throw FolderSyncConnectionError.unsupportedBisyncLog
            }
            let path = String(line.dropFirst(2))
            guard BisyncDryRunAnalysis.safeRelativePath(path) != nil else {
                throw FolderSyncConnectionError.unsupportedBisyncLog
            }
            sawComparableFile = true
            switch marker {
            case "=", "+", "-":
                continue
            case "*":
                throw FolderSyncConnectionError.initialConflict
            case "!":
                throw FolderSyncConnectionError.connectionCheckRequired
            default:
                throw FolderSyncConnectionError.unsupportedBisyncLog
            }
        }

        // `rclone check` returns non-zero for expected + / - differences. The
        // unique per-connection access file guarantees at least one comparable
        // object when both ends are reachable; no report means a real check
        // failure rather than an empty, safe merge.
        guard sawComparableFile else {
            throw FolderSyncConnectionError.connectionCheckRequired
        }
        if result.exitCode != 0 {
            let reportOnlyContainsMergeableDifferences = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .allSatisfy { line in
                    line.first == "=" || line.first == "+" || line.first == "-"
                }
            guard reportOnlyContainsMergeableDifferences else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
        }
    }

    private func verifyInitialMergeCompleted(
        executable: URL,
        connection: FolderSyncConnection,
        localRootPath: String
    ) throws {
        let directory = URL(fileURLWithPath: connection.workDirectoryPath, isDirectory: true)
            .appendingPathComponent("initial-final-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let combinedURL = directory.appendingPathComponent("combined.txt", isDirectory: false)
        let result = try runToFiles(
            executable: executable,
            arguments: [
                "check",
                localRootPath,
                remoteSpec(connection),
                "--download",
                "--combined", combinedURL.path,
                "--filter-from", filterFileURL(connection).path,
                "--drive-skip-gdocs"
            ],
            logDirectory: directory,
            basename: "check"
        )
        guard result.exitCode == 0,
              FileManager.default.fileExists(atPath: combinedURL.path),
              let text = try? String(contentsOf: combinedURL, encoding: .utf8)
        else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty,
              lines.allSatisfy({ line in
                  line.count >= 3
                      && line.first == "="
                      && line[line.index(after: line.startIndex)] == " "
                      && BisyncDryRunAnalysis.safeRelativePath(String(line.dropFirst(2))) != nil
              })
        else {
            throw FolderSyncConnectionError.recoveryRequired
        }
    }

    private struct LivePhotoProbeEvidence {
        let relativePath: String
        let role: ResourceRole
        let identifier: String
        let timedStatus: LivePhotoTimedMetadataStatus
        let exactHash: Data
    }

    private struct LivePhotoPlanningResult {
        let items: [FolderSyncJournalItem]
        let preconditions: [LivePhotoResourcePrecondition]
        let requiresConfirmation: Bool
    }

    private struct LivePhotoResourcePrecondition {
        let relativePath: String
        let side: BisyncSide
        let exactHash: Data
    }

    private struct JournalVerificationResult {
        let items: [FolderSyncJournalItem]
        let sourcePreconditionChanged: Bool
        let recoveryArtifactsVerified: Bool
    }

    private func makeLivePhotoPlan(
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        analysis: BisyncDryRunAnalysis,
        benignRecoveryConflicts: Set<String>,
        temporaryDirectory: URL
    ) async throws -> LivePhotoPlanningResult {
        struct Accumulator {
            var resourcesByPath: [String: ResourceRole] = [:]
            var sourceSides = Set<BisyncSide>()
            var deletionPaths = Set<String>()
            var deletionSides = Set<BisyncSide>()
            var requiresConfirmation = false
            var note: String?
        }

        var accumulators: [String: Accumulator] = [:]
        var preconditionsByKey: [String: LivePhotoResourcePrecondition] = [:]
        var directoryCache: [String: [LivePhotoProbeEvidence]] = [:]

        for relativePath in analysis.candidatePaths
            .subtracting(analysis.renameSourcePaths)
            .sorted() {
            let typeURL = URL(fileURLWithPath: relativePath)
            guard let type = SupportedFileTypes.classify(url: typeURL),
                  type.isPotentialLivePhotoStill || type.isPotentialLivePhotoVideo
            else { continue }

            let sides = analysis.sourceSidesByPath[relativePath] ?? []
            guard !sides.isEmpty else {
                throw FolderSyncConnectionError.unsupportedBisyncLog
            }
            let isBenignRecoveryConflict = benignRecoveryConflicts.contains(relativePath)
            let probeSides: Set<BisyncSide> = isBenignRecoveryConflict ? [.path1] : sides
            for side in probeSides {
                let directory = (relativePath as NSString).deletingLastPathComponent
                let cacheKey = "\(side == .path1 ? "1" : "2"):\(directory)"
                let evidence: LivePhotoProbeEvidence
                let directoryEvidence: [LivePhotoProbeEvidence]
                if let cached = directoryCache[cacheKey] {
                    guard let cachedEvidence = cached.first(where: {
                        $0.relativePath == relativePath
                    }) else {
                        continue
                    }
                    evidence = cachedEvidence
                    directoryEvidence = cached
                } else {
                    guard let probedEvidence = try await probeLivePhotoEvidence(
                        executable: executable,
                        connection: connection,
                        root: root,
                        side: side,
                        relativePath: relativePath,
                        temporaryDirectory: temporaryDirectory
                    ) else {
                        continue
                    }
                    evidence = probedEvidence
                    let loaded = try await livePhotoDirectoryEvidence(
                        executable: executable,
                        connection: connection,
                        root: root,
                        side: side,
                        directory: directory,
                        temporaryDirectory: temporaryDirectory,
                        knownEvidenceByPath: [relativePath: probedEvidence]
                    )
                    directoryCache[cacheKey] = loaded
                    directoryEvidence = loaded
                }
                preconditionsByKey[
                    "\(side == .path1 ? "1" : "2"):\(relativePath)"
                ] = LivePhotoResourcePrecondition(
                    relativePath: relativePath,
                    side: side,
                    exactHash: evidence.exactHash
                )

                let matches = directoryEvidence.filter { $0.identifier == evidence.identifier }
                let stills = matches.filter { $0.role == .photo }
                let videos = matches.filter { $0.role == .pairedVideo }
                var accumulator = accumulators[evidence.identifier] ?? Accumulator()
                if !isBenignRecoveryConflict {
                    accumulator.sourceSides.insert(side)
                }
                for match in matches {
                    accumulator.resourcesByPath[match.relativePath] = match.role
                }

                let completePair = stills.count == 1
                    && videos.count == 1
                    && videos[0].timedStatus == .valid
                if !completePair {
                    accumulator.requiresConfirmation = true
                    accumulator.note = "live_photo_pair_incomplete_or_ambiguous"
                }
                if analysis.effectiveDeletionPaths.contains(relativePath) {
                    accumulator.deletionPaths.insert(relativePath)
                    if let deletedFrom = analysis.deletedFromSideByPath[relativePath] {
                        accumulator.deletionSides.insert(deletedFrom)
                    }
                }
                if analysis.conflictPaths.contains(relativePath), !isBenignRecoveryConflict {
                    accumulator.requiresConfirmation = true
                    accumulator.note = "live_photo_file_conflict"
                }
                accumulators[evidence.identifier] = accumulator
            }
        }

        var items: [FolderSyncJournalItem] = []
        var requiresConfirmation = false
        for (_, var accumulator) in accumulators {
            if accumulator.sourceSides.count > 1 {
                accumulator.requiresConfirmation = true
                accumulator.note = "live_photo_changed_on_both_sides"
            }
            if !accumulator.deletionPaths.isEmpty {
                let resourcePaths = Set(accumulator.resourcesByPath.keys)
                let completePairDeletedOnOneSide = accumulator.deletionPaths == resourcePaths
                    && accumulator.deletionSides.count == 1
                    && resourcePaths.count == 2
                if !completePairDeletedOnOneSide {
                    accumulator.requiresConfirmation = true
                    accumulator.note = "one_sided_live_photo_delete"
                }
            }
            requiresConfirmation = requiresConfirmation || accumulator.requiresConfirmation
            let resources = accumulator.resourcesByPath
                .map { path, role in
                    FolderSyncJournalResource(relativePath: path, role: role)
                }
                .sorted { lhs, rhs in
                    (lhs.role.rawValue, lhs.relativePath) < (rhs.role.rawValue, rhs.relativePath)
                }
            guard !resources.isEmpty else { continue }
            items.append(
                FolderSyncJournalItem(
                    state: accumulator.requiresConfirmation ? .confirmationRequired : .planned,
                    resources: resources,
                    note: accumulator.note
                )
            )
        }
        return LivePhotoPlanningResult(
            items: items.sorted { lhs, rhs in
                (lhs.resources.first?.relativePath ?? "") < (rhs.resources.first?.relativePath ?? "")
            },
            preconditions: preconditionsByKey.values.sorted { lhs, rhs in
                let lhsSide = lhs.side == .path1 ? 1 : 2
                let rhsSide = rhs.side == .path1 ? 1 : 2
                return (lhsSide, lhs.relativePath) < (rhsSide, rhs.relativePath)
            },
            requiresConfirmation: requiresConfirmation
        )
    }

    private func livePhotoPreconditionsStillMatch(
        _ preconditions: [LivePhotoResourcePrecondition],
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        temporaryDirectory: URL
    ) async -> Bool {
        for precondition in preconditions {
            do {
                guard let current = try await probeLivePhotoEvidence(
                    executable: executable,
                    connection: connection,
                    root: root,
                    side: precondition.side,
                    relativePath: precondition.relativePath,
                    temporaryDirectory: temporaryDirectory
                ), current.exactHash == precondition.exactHash
                else {
                    return false
                }
            } catch {
                return false
            }
        }
        return true
    }

    private static func mergingLivePhotoItems(
        defaultItems: [FolderSyncJournalItem],
        livePhotoItems: [FolderSyncJournalItem]
    ) -> [FolderSyncJournalItem] {
        let livePaths = Set(livePhotoItems.flatMap { $0.resources.map(\.relativePath) })
        return defaultItems.filter { item in
            item.resources.allSatisfy { !livePaths.contains($0.relativePath) }
        } + livePhotoItems
    }

    private func livePhotoDirectoryEvidence(
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        side: BisyncSide,
        directory: String,
        temporaryDirectory: URL,
        knownEvidenceByPath: [String: LivePhotoProbeEvidence] = [:]
    ) async throws -> [LivePhotoProbeEvidence] {
        let paths: [String]
        switch side {
        case .path1:
            let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
            let directoryURL = directory.isEmpty
                ? rootURL
                : rootURL.appendingPathComponent(directory, isDirectory: true).standardizedFileURL
            let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            guard directoryURL == rootURL || directoryURL.path.hasPrefix(rootPrefix) else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            let contents = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            paths = try contents.compactMap { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                let relative = directory.isEmpty
                    ? url.lastPathComponent
                    : directory + "/" + url.lastPathComponent
                return BisyncDryRunAnalysis.safeRelativePath(relative)
            }
        case .path2:
            let spec = directory.isEmpty
                ? remoteSpec(connection)
                : remoteSpec(connection) + "/" + directory
            let result = try runSmall(
                executable: executable,
                arguments: ["lsjson", spec, "--files-only", "--max-depth", "1", "--drive-skip-gdocs"]
            )
            guard result.exitCode == 0 else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            let entries = try JSONDecoder().decode([RcloneListEntry].self, from: result.stdout)
            paths = entries.compactMap { entry in
                guard entry.IsDir != true,
                      let name = entry.Path ?? entry.Name,
                      !name.isEmpty
                else { return nil }
                let relative = directory.isEmpty ? name : directory + "/" + name
                return BisyncDryRunAnalysis.safeRelativePath(relative)
            }
        }

        var evidence: [LivePhotoProbeEvidence] = []
        for path in paths.sorted() {
            let url = URL(fileURLWithPath: path)
            guard let type = SupportedFileTypes.classify(url: url),
                  type.isPotentialLivePhotoStill || type.isPotentialLivePhotoVideo
            else { continue }
            if let known = knownEvidenceByPath[path] {
                evidence.append(known)
                continue
            }
            if let value = try await probeLivePhotoEvidence(
                executable: executable,
                connection: connection,
                root: root,
                side: side,
                relativePath: path,
                temporaryDirectory: temporaryDirectory
            ) {
                evidence.append(value)
            }
        }
        return evidence
    }

    private func probeLivePhotoEvidence(
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        side: BisyncSide,
        relativePath: String,
        temporaryDirectory: URL
    ) async throws -> LivePhotoProbeEvidence? {
        let typeURL = URL(fileURLWithPath: relativePath)
        guard let type = SupportedFileTypes.classify(url: typeURL),
              type.isPotentialLivePhotoStill || type.isPotentialLivePhotoVideo
        else { return nil }

        let url: URL
        var removeAfterProbe = false
        switch side {
        case .path1:
            guard let local = try localResourceURL(
                rootPath: root.canonicalPath,
                relativePath: relativePath
            ), FileManager.default.fileExists(atPath: local.path)
            else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            url = local
        case .path2:
            let destination = temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
                .appendingPathExtension(typeURL.pathExtension)
            let result = try runSmall(
                executable: executable,
                arguments: [
                    "copyto",
                    remoteSpec(connection) + "/" + relativePath,
                    destination.path,
                    "--drive-skip-gdocs"
                ]
            )
            guard result.exitCode == 0 else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            url = destination
            removeAfterProbe = true
        }
        defer {
            if removeAfterProbe { try? FileManager.default.removeItem(at: url) }
        }

        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize
        else {
            throw FolderSyncConnectionError.connectionCheckRequired
        }
        let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
        let descriptor = RootDescriptor(
            id: root.rootID,
            label: root.label,
            kind: root.kind,
            usageRole: root.usageRole,
            provenance: root.provenance,
            url: rootURL,
            markerKey: nil
        )
        let pending = PendingFile(
            root: descriptor,
            url: url,
            relativePath: relativePath,
            type: type,
            byteSize: Int64(size),
            modifiedAt: values.contentModificationDate,
            createdAt: values.creationDate,
            addedAt: nil,
            fileSystemIdentifier: nil
        )
        let probed = await MetadataProbe.probe(pending)
        testingMetrics?.recordMetadataProbe(
            remoteDownloadBytes: side == .path2 ? Int64(size) : nil
        )
        if probed.metadataProbeFailed {
            throw FolderSyncConnectionError.livePhotoMutationBlocked
        }
        guard let identifier = probed.rawLivePhotoIdentifier else { return nil }
        let role: ResourceRole = type.mediaKind == .image ? .photo : .pairedVideo
        testingMetrics?.recordFullHash(bytes: Int64(size))
        return LivePhotoProbeEvidence(
            relativePath: relativePath,
            role: role,
            identifier: identifier,
            timedStatus: probed.livePhotoTimedMetadataStatus,
            exactHash: try FileHasher.sha256(url: url)
        )
    }

    private func verifyJournalItems(
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        items: [FolderSyncJournalItem],
        analysis: BisyncDryRunAnalysis,
        preconditions: [LivePhotoResourcePrecondition],
        deletionPlan: FolderSyncDeletionPlan?,
        runPaths: RunPaths,
        temporaryDirectory: URL
    ) async throws -> JournalVerificationResult {
        var verified: [FolderSyncJournalItem] = []
        var sourcePreconditionChanged = false
        var verifiedDeletionItemIDs = Set<String>()
        let preconditionsByKey = Dictionary(
            uniqueKeysWithValues: preconditions.map {
                ("\($0.side == .path1 ? "1" : "2"):\($0.relativePath)", $0.exactHash)
            }
        )
        for item in items {
            let itemPaths = Set(item.resources.map(\.relativePath))
            if let deletionItem = deletionPlan?.items.first(where: {
                Set($0.relativePaths) == itemPaths
            }) {
                var deleted = item
                deleted.state = .verified
                deleted.resources = try item.resources.map { resource in
                    guard try localActiveObjectExists(
                        root: root,
                        relativePath: resource.relativePath
                    ) == false,
                    try remoteObjectExists(
                        executable: executable,
                        spec: remoteSpec(connection) + "/" + resource.relativePath
                    ) == false,
                    let expected = deletionItem.expectedTargetSHA256ByPath[resource.relativePath]
                    else {
                        throw FolderSyncConnectionError.recoveryRequired
                    }
                    let recoveryHash = try recoveryObjectSHA256(
                        executable: executable,
                        connection: connection,
                        deletionItem: deletionItem,
                        relativePath: resource.relativePath,
                        runPaths: runPaths,
                        temporaryDirectory: temporaryDirectory
                    )
                    guard recoveryHash == expected else {
                        throw FolderSyncConnectionError.recoveryRequired
                    }
                    var value = resource
                    value.path1Verified = true
                    value.path2Verified = true
                    return value
                }
                verifiedDeletionItemIDs.insert(deletionItem.id)
                verified.append(deleted)
                continue
            }

            let roles = Set(item.resources.map(\.role))
            guard roles == Set([ResourceRole.photo, ResourceRole.pairedVideo]),
                  item.resources.count == 2
            else {
                var ordinary = item
                ordinary.state = .verified
                ordinary.resources = try ordinary.resources.map { resource in
                    if analysis.renameSourcePaths.contains(resource.relativePath) {
                        guard try localActiveObjectExists(
                            root: root,
                            relativePath: resource.relativePath
                        ) == false,
                        try remoteObjectExists(
                            executable: executable,
                            spec: remoteSpec(connection) + "/" + resource.relativePath
                        ) == false else {
                            throw FolderSyncConnectionError.recoveryRequired
                        }
                    } else {
                        guard let local = try localResourceURL(
                            rootPath: root.canonicalPath,
                            relativePath: resource.relativePath
                        ), FileManager.default.fileExists(atPath: local.path) else {
                            throw FolderSyncConnectionError.recoveryRequired
                        }
                        let values = try local.resourceValues(forKeys: [
                            .isDirectoryKey,
                            .isRegularFileKey,
                            .isSymbolicLinkKey
                        ])
                        guard values.isSymbolicLink != true else {
                            throw FolderSyncConnectionError.recoveryRequired
                        }
                        if values.isDirectory == true {
                            guard try remoteObjectIsDirectory(
                                executable: executable,
                                spec: remoteSpec(connection) + "/" + resource.relativePath
                            ) else {
                                throw FolderSyncConnectionError.recoveryRequired
                            }
                        } else {
                            guard values.isRegularFile == true,
                                  let remoteHash = try remoteSHA256(
                                    executable: executable,
                                    connection: connection,
                                    relativePath: resource.relativePath
                                  ), try FileHasher.sha256(url: local) == remoteHash else {
                                throw FolderSyncConnectionError.recoveryRequired
                            }
                        }
                    }
                    var value = resource
                    value.path1Verified = true
                    value.path2Verified = true
                    return value
                }
                verified.append(ordinary)
                continue
            }

            var identifiers = Set<String>()
            var updatedResources: [FolderSyncJournalResource] = []
            for resource in item.resources {
                guard let local = try await probeLivePhotoEvidence(
                    executable: executable,
                    connection: connection,
                    root: root,
                    side: .path1,
                    relativePath: resource.relativePath,
                    temporaryDirectory: temporaryDirectory
                ), local.role == resource.role
                else {
                    throw FolderSyncConnectionError.recoveryRequired
                }
                let remoteHash: Data
                if let hash = try remoteSHA256(
                    executable: executable,
                    connection: connection,
                    relativePath: resource.relativePath
                ) {
                    remoteHash = hash
                } else if let remote = try await probeLivePhotoEvidence(
                    executable: executable,
                    connection: connection,
                    root: root,
                    side: .path2,
                    relativePath: resource.relativePath,
                    temporaryDirectory: temporaryDirectory
                ) {
                    remoteHash = remote.exactHash
                } else {
                    throw FolderSyncConnectionError.recoveryRequired
                }
                guard local.exactHash == remoteHash else {
                    throw FolderSyncConnectionError.recoveryRequired
                }
                if resource.role == .pairedVideo,
                   local.timedStatus != .valid {
                    throw FolderSyncConnectionError.recoveryRequired
                }
                identifiers.insert(local.identifier)
                if let expected = preconditionsByKey["1:\(resource.relativePath)"],
                   local.exactHash != expected {
                    sourcePreconditionChanged = true
                }
                if let expected = preconditionsByKey["2:\(resource.relativePath)"],
                   remoteHash != expected {
                    sourcePreconditionChanged = true
                }
                var value = resource
                value.path1Verified = true
                value.path2Verified = true
                updatedResources.append(value)
            }
            guard identifiers.count == 1 else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            var value = item
            value.state = .verified
            value.resources = updatedResources
            verified.append(value)
        }
        let expectedDeletionItemIDs = Set(deletionPlan?.items.map(\.id) ?? [])
        return JournalVerificationResult(
            items: verified,
            sourcePreconditionChanged: sourcePreconditionChanged,
            recoveryArtifactsVerified: expectedDeletionItemIDs == verifiedDeletionItemIDs
        )
    }

    private func localActiveObjectExists(
        root: RegisteredRootReport,
        relativePath: String
    ) throws -> Bool {
        guard let url = try localResourceURL(
            rootPath: root.canonicalPath,
            relativePath: relativePath
        ) else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func remoteObjectExists(
        executable: URL,
        spec: String
    ) throws -> Bool {
        let result = try runSmall(
            executable: executable,
            arguments: ["lsjson", spec, "--stat", "--drive-skip-gdocs"]
        )
        if result.exitCode == 0 { return true }
        let message = String(data: result.stderr, encoding: .utf8)?.lowercased() ?? ""
        if message.contains("not found")
            || message.contains("doesn't exist")
            || message.contains("does not exist")
            || message.contains("directory not found") {
            return false
        }
        throw FolderSyncConnectionError.connectionCheckRequired
    }

    private func remoteObjectIsDirectory(
        executable: URL,
        spec: String
    ) throws -> Bool {
        let result = try runSmall(
            executable: executable,
            arguments: ["lsjson", spec, "--stat", "--drive-skip-gdocs"]
        )
        if result.exitCode == 0 {
            guard let entry = try? JSONDecoder().decode(RcloneListEntry.self, from: result.stdout) else {
                throw FolderSyncConnectionError.connectionCheckRequired
            }
            return entry.IsDir == true
        }
        let message = String(data: result.stderr, encoding: .utf8)?.lowercased() ?? ""
        if message.contains("not found")
            || message.contains("doesn't exist")
            || message.contains("does not exist")
            || message.contains("directory not found") {
            return false
        }
        throw FolderSyncConnectionError.connectionCheckRequired
    }

    private func recoveryObjectSHA256(
        executable: URL,
        connection: FolderSyncConnection,
        deletionItem: FolderSyncDeletionItem,
        relativePath: String,
        runPaths: RunPaths,
        temporaryDirectory: URL
    ) throws -> Data {
        switch deletionItem.location {
        case .externalDrive:
            let recoveryRoot = runPaths.localBackupDirectory
                .resolvingSymlinksInPath().standardizedFileURL
            guard let safe = BisyncDryRunAnalysis.safeRelativePath(relativePath) else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            let url = recoveryRoot.appendingPathComponent(safe).standardizedFileURL
            let prefix = recoveryRoot.path.hasSuffix("/") ? recoveryRoot.path : recoveryRoot.path + "/"
            guard url.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: url.path) else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            return try FileHasher.sha256(url: url)
        case .googleDrive:
            let spec = runPaths.remoteBackupSpec + "/" + relativePath
            if let hash = try remoteObjectSHA256(executable: executable, spec: spec) {
                return hash
            }
            let destination = temporaryDirectory
                .appendingPathComponent("recovery-verify-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            let result = try runSmall(
                executable: executable,
                arguments: ["copyto", spec, destination.path, "--drive-skip-gdocs"]
            )
            guard result.exitCode == 0,
                  FileManager.default.fileExists(atPath: destination.path)
            else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            return try FileHasher.sha256(url: destination)
        }
    }

    private func remoteSHA256(
        executable: URL,
        connection: FolderSyncConnection,
        relativePath: String
    ) throws -> Data? {
        testingMetrics?.recordRemoteHashQuery()
        return try remoteObjectSHA256(
            executable: executable,
            spec: remoteSpec(connection) + "/" + relativePath
        )
    }

    private func remoteObjectSHA256(
        executable: URL,
        spec: String
    ) throws -> Data? {
        let result = try runSmall(
            executable: executable,
            arguments: [
                "hashsum", "SHA-256",
                spec,
                "--drive-skip-gdocs"
            ]
        )
        guard result.exitCode == 0,
              let text = String(data: result.stdout, encoding: .utf8),
              let line = text.split(separator: "\n", omittingEmptySubsequences: true).first,
              let token = line.split(whereSeparator: { $0.isWhitespace }).first
        else { return nil }
        return Self.decodeHex(String(token))
    }

    private static func decodeHex(_ value: String) -> Data? {
        guard value.count == 64 else { return nil }
        var data = Data()
        data.reserveCapacity(32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private func localResourceURL(rootPath: String, relativePath: String) throws -> URL? {
        guard let safe = BisyncDryRunAnalysis.safeRelativePath(relativePath) else { return nil }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(safe).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate
    }

    private func classifyFailure(logURL: URL) -> Error {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let lower = text.lowercased()
        if lower.contains("run --resync to recover")
            || lower.contains("must run --resync")
            || lower.contains("prior lock file found")
            || lower.contains("missing prior path")
            || lower.contains("cannot find prior path1")
            || lower.contains("critical error on prior run") {
            return FolderSyncConnectionError.recoveryRequired
        }
        if lower.contains("access test failed")
            || lower.contains("directory not found")
            || lower.contains("failed to create file system") {
            return FolderSyncConnectionError.connectionCheckRequired
        }
        return FolderSyncConnectionError.connectionCheckRequired
    }

    private func status(for error: Error) -> FolderSyncStatus {
        guard let error = error as? FolderSyncConnectionError else { return .failed }
        switch error {
        case .rootUnavailable:
            return .driveUnavailable
        case .rootIdentityChanged, .connectionCheckRequired, .invalidRemoteName, .invalidRemotePath,
             .remoteRootNotAllowed, .localStateOverlapsRoot, .rcloneNotInstalled, .unsupportedRclone:
            return .connectionCheckRequired
        case .livePhotoMutationBlocked:
            return .livePhotoBlocked
        case .concurrentMutationSafetyUnavailable:
            return .safetyUnavailable
        case .confirmationRequired:
            return .confirmationRequired
        case .initialConflict:
            return .initialConflict
        case .unsupportedBisyncLog:
            return .connectionCheckRequired
        case .recoveryRequired:
            return .recoveryRequired
        case .restoreDestinationExists, .recoveryItemChanged, .insufficientRecoverySpace:
            return .recoveryRequired
        case .operationAlreadyRunning:
            return .failed
        case .initialConfirmationRequired:
            return .setupRequired
        case .readOnlyRoot, .rootNotFound, .connectionAlreadyExists:
            return .failed
        }
    }

    private func filterFileURL(_ connection: FolderSyncConnection) -> URL {
        URL(fileURLWithPath: connection.workDirectoryPath, isDirectory: true)
            .appendingPathComponent("filters.txt", isDirectory: false)
    }

    private func remoteSpec(_ connection: FolderSyncConnection) -> String {
        "\(connection.remoteName):\(connection.remotePath)"
    }

    private func accessFileName(_ connection: FolderSyncConnection) -> String {
        Self.accessFilePrefix + connection.id
    }

    private func validateCapabilities(executable: URL) throws -> String {
        let version = try runSmall(executable: executable, arguments: ["version"])
        guard version.exitCode == 0,
              let firstLine = String(data: version.stdout, encoding: .utf8)?
                .split(separator: "\n").first
        else {
            throw FolderSyncConnectionError.rcloneNotInstalled
        }
        let versionText = String(firstLine)
        // The safety parser below is intentionally tied to the JSON NOTICE
        // format verified against this exact rclone release. A future rclone
        // update must be re-qualified rather than accepted because flags happen
        // to have the same names.
        guard versionText == "rclone v1.75.0" else {
            throw FolderSyncConnectionError.unsupportedRclone(versionText)
        }
        let bisyncHelp = try runSmall(executable: executable, arguments: ["bisync", "--help"])
        let flagsHelp = try runSmall(executable: executable, arguments: ["help", "flags"])
        let help = String(data: bisyncHelp.stdout + bisyncHelp.stderr, encoding: .utf8) ?? ""
        let global = String(data: flagsHelp.stdout + flagsHelp.stderr, encoding: .utf8) ?? ""
        let required = [
            "--backup-dir1", "--backup-dir2", "--check-access", "--conflict-resolve",
            "--recover", "--resync-mode", "--track-renames", "--workdir"
        ]
        guard bisyncHelp.exitCode == 0,
              required.allSatisfy(help.contains),
              global.contains("--use-json-log"),
              (!usesDriveRevisionProtection || global.contains("--drive-keep-revision-forever"))
        else {
            throw FolderSyncConnectionError.unsupportedRclone(versionText)
        }
        return versionText
    }

    private func resolvedExecutableURL() throws -> URL {
        if let executableURL {
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw FolderSyncConnectionError.rcloneNotInstalled
            }
            return executableURL
        }
        var candidates = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/rclone" })
        }
        guard let value = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw FolderSyncConnectionError.rcloneNotInstalled
        }
        return URL(fileURLWithPath: value)
    }

    private struct SmallProcessResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    private struct FileProcessResult {
        let exitCode: Int32
        let stdoutURL: URL
        let stderrURL: URL
    }

    private struct RcloneDriveAuthConfig {
        let accessToken: String
        let rootFolderID: String?
        let sharedDriveID: String?
    }

    private var usesDriveRevisionProtection: Bool {
        remoteTypeFilter == "drive" || testingUseDriveRevisionProtection
    }

    private var usesDirectDriveMutationAPI: Bool {
        remoteTypeFilter == "drive" || testingDriveRevisionManager != nil
    }

    private func unsupportedDirectMutationPaths(
        analysis: BisyncDryRunAnalysis,
        benignRecoveryConflicts: Set<String>
    ) -> Set<String> {
        var supported = benignRecoveryConflicts
        let renameSources = Set(analysis.renameDestinationBySource.keys)
        let renameDestinations = Set(analysis.renameDestinationBySource.values)

        for path in analysis.candidatePaths {
            if analysis.metadataUpdatePaths.contains(path) {
                continue
            }
            if analysis.effectiveDeletionPaths.contains(path) {
                if analysis.deletedFromSideByPath[path] == .path1 {
                    supported.insert(path)
                }
                continue
            }
            if renameSources.contains(path) {
                if analysis.sourceSidesByPath[path] == Set([BisyncSide.path2]),
                   let destination = analysis.renameDestinationBySource[path] {
                    supported.insert(path)
                    supported.insert(destination)
                }
                continue
            }
            if renameDestinations.contains(path) {
                continue
            }
            let sides = analysis.sourceSidesByPath[path] ?? []
            if sides == Set([BisyncSide.path1]) || sides == Set([BisyncSide.path2]) {
                supported.insert(path)
            }
        }
        return analysis.candidatePaths.subtracting(supported)
    }

    private func driveRevisionManager(
        executable: URL,
        connection: FolderSyncConnection
    ) throws -> any DriveRevisionManaging {
        if let testingDriveRevisionManager {
            return testingDriveRevisionManager
        }
        guard remoteTypeFilter == "drive" else {
            throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
        }

        // Let rclone refresh its OAuth token using its own established auth
        // path. `about` reads quota metadata only and does not enumerate user
        // files. The token itself is read only into memory below.
        let refresh = try runSmall(
            executable: executable,
            arguments: ["about", "\(connection.remoteName):", "--json"]
        )
        guard refresh.exitCode == 0 else {
            throw FolderSyncConnectionError.connectionCheckRequired
        }
        let config = try loadRcloneDriveAuthConfig(
            executable: executable,
            remoteName: connection.remoteName
        )
        return GoogleDriveRevisionAPI(
            accessToken: config.accessToken,
            configuredRootFolderID: config.rootFolderID,
            sharedDriveID: config.sharedDriveID
        )
    }

    private func loadRcloneDriveAuthConfig(
        executable: URL,
        remoteName: String
    ) throws -> RcloneDriveAuthConfig {
        let result = try runSensitiveSmall(
            executable: executable,
            arguments: ["config", "show", remoteName]
        )
        guard result.exitCode == 0,
              let text = String(data: result.stdout, encoding: .utf8)
        else {
            throw FolderSyncConnectionError.connectionCheckRequired
        }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: equal)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }
        guard values["type"] == "drive",
              let tokenText = values["token"],
              let tokenData = tokenText.data(using: .utf8),
              let tokenObject = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let accessToken = tokenObject["access_token"] as? String,
              !accessToken.isEmpty
        else {
            throw FolderSyncConnectionError.connectionCheckRequired
        }
        return RcloneDriveAuthConfig(
            accessToken: accessToken,
            rootFolderID: values["root_folder_id"].flatMap { $0.isEmpty ? nil : $0 },
            sharedDriveID: values["team_drive"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private func runSensitiveSmall(
        executable: URL,
        arguments: [String]
    ) throws -> SmallProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in environmentOverrides { environment[key] = value }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        processLock.lock()
        guard currentProcess == nil else {
            processLock.unlock()
            throw FolderSyncConnectionError.operationAlreadyRunning
        }
        currentProcess = process
        processLock.unlock()
        defer {
            processLock.lock()
            if currentProcess === process { currentProcess = nil }
            processLock.unlock()
        }

        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return SmallProcessResult(
            exitCode: process.terminationStatus,
            stdout: outData,
            stderr: errData
        )
    }

    private func mapDriveAPIError(_ error: Error, afterMutation: Bool) -> FolderSyncConnectionError {
        guard let error = error as? DriveRevisionAPIError else {
            return afterMutation ? .recoveryRequired : .connectionCheckRequired
        }
        switch error {
        case .authentication, .permission:
            return afterMutation ? .recoveryRequired : .connectionCheckRequired
        case .revisionLimit:
            // Never delete old pinned revisions automatically to make room.
            return afterMutation ? .recoveryRequired : .concurrentMutationSafetyUnavailable
        case .notFound, .conflict:
            return afterMutation ? .recoveryRequired : .confirmationRequired
        case .invalidResponse, .transport:
            return afterMutation ? .recoveryRequired : .connectionCheckRequired
        }
    }

    private func runSmall(executable: URL, arguments: [String]) throws -> SmallProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoArchiveKit-rclone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try runToFiles(
            executable: executable,
            arguments: arguments,
            logDirectory: directory,
            basename: "command"
        )
        return SmallProcessResult(
            exitCode: result.exitCode,
            stdout: (try? Data(contentsOf: result.stdoutURL)) ?? Data(),
            stderr: (try? Data(contentsOf: result.stderrURL)) ?? Data()
        )
    }

    private func runToFiles(
        executable: URL,
        arguments: [String],
        logDirectory: URL,
        basename: String
    ) throws -> FileProcessResult {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let stdoutURL = logDirectory.appendingPathComponent("\(basename).stdout")
        let stderrURL = logDirectory.appendingPathComponent("\(basename).jsonl")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in environmentOverrides { environment[key] = value }
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr

        processLock.lock()
        guard currentProcess == nil else {
            processLock.unlock()
            throw FolderSyncConnectionError.operationAlreadyRunning
        }
        currentProcess = process
        processLock.unlock()
        defer {
            processLock.lock()
            if currentProcess === process { currentProcess = nil }
            processLock.unlock()
        }

        try process.run()
        process.waitUntilExit()
        return FileProcessResult(
            exitCode: process.terminationStatus,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL
        )
    }

    private func resetCancellation() {
        processLock.lock()
        cancelRequested = false
        processLock.unlock()
    }

    private func clearCancellation() {
        processLock.lock()
        cancelRequested = false
        processLock.unlock()
    }

    private func isCancellationRequested() -> Bool {
        processLock.lock()
        let cancelled = cancelRequested
        processLock.unlock()
        return cancelled
    }

    private func ensureNotCancelled() throws {
        if isCancellationRequested() { throw CancellationError() }
    }

    private static func runIdentifier(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "-")
            + "-" + UUID().uuidString.prefix(8)
    }

    package static func parseDryRunLog(url: URL) throws -> BisyncLogSummary {
        let analysis = try parseAnalysis(url: url)
        return BisyncLogSummary(
            candidatePaths: analysis.candidatePaths.sorted(),
            conflictPreserved: analysis.conflictPreserved
        )
    }

    private static func lastStats(url: URL) -> RcloneStats? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        var result: RcloneStats?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = rawLine.data(using: .utf8),
                  let line = try? decoder.decode(RcloneLogLine.self, from: data),
                  let stats = line.stats
            else { continue }
            result = stats
        }
        return result
    }

    private static func parseAnalysis(url: URL) throws -> BisyncDryRunAnalysis {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseAnalysis(text: text)
    }

    private static func parseAnalysis(text: String) throws -> BisyncDryRunAnalysis {
        var result = BisyncDryRunAnalysis()
        var resyncSource: BisyncSide?
        let decoder = JSONDecoder()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = rawLine.data(using: .utf8),
                  let line = try? decoder.decode(RcloneLogLine.self, from: data)
            else {
                throw FolderSyncConnectionError.unsupportedBisyncLog
            }
            let message = stripANSI(line.msg ?? "")

            if let change = try parseDeltaChange(message: message, source: line.source) {
                if change.wasDeleted {
                    result.deletionPaths.insert(change.path)
                    result.deletedFromSideByPath[change.path] = change.side
                    // A deletion on one side would mutate the surviving file on
                    // the opposite side, so probe the surviving content.
                    result.add(
                        path: change.path,
                        source: change.side == .path1 ? .path2 : .path1
                    )
                } else {
                    result.nonDeletionChangeSidesByPath[change.path, default: []].insert(change.side)
                    result.add(path: change.path, source: change.side)
                }
            }

            if let conflictPath = try parseConflictPath(message: message, source: line.source) {
                result.conflictPreserved = true
                result.conflictPaths.insert(conflictPath)
                result.add(path: conflictPath, source: .path1)
                result.add(path: conflictPath, source: .path2)
            }

            if let sourceSide = try parseResyncSource(message: message, source: line.source) {
                resyncSource = sourceSide
            }

            if let object = line.object,
               let skipped = line.skipped,
               skipped.hasPrefix("move to ") {
                guard let sourcePath = BisyncDryRunAnalysis.safeRelativePath(object),
                      let destinationPath = BisyncDryRunAnalysis.safeRelativePath(
                        String(skipped.dropFirst("move to ".count))
                      )
                else {
                    throw FolderSyncConnectionError.unsupportedBisyncLog
                }
                result.renameSourcePaths.insert(sourcePath)
                result.renameDestinationBySource[sourcePath] = destinationPath
            }

            if let object = line.object,
               let skipped = line.skipped,
               isMutationSkip(skipped) {
                guard let normalized = BisyncDryRunAnalysis.safeRelativePath(object) else {
                    throw FolderSyncConnectionError.unsupportedBisyncLog
                }
                if let resyncSource {
                    result.add(path: normalized, source: resyncSource)
                } else if !result.candidatePaths.contains(normalized) {
                    // Normal bisync should already have emitted a directional
                    // deltas.go line. A mutation object without that evidence
                    // cannot be safely assigned to a side.
                    throw FolderSyncConnectionError.unsupportedBisyncLog
                }
            }
            if let object = line.object,
               line.skipped == "update modification time" {
                guard let normalized = BisyncDryRunAnalysis.safeRelativePath(object) else {
                    throw FolderSyncConnectionError.unsupportedBisyncLog
                }
                result.metadataUpdatePaths.insert(normalized)
            }
        }
        return result
    }

    private struct ParsedDeltaChange {
        let side: BisyncSide
        let path: String
        let wasDeleted: Bool
    }

    private static func parseDeltaChange(
        message: String,
        source: String?
    ) throws -> ParsedDeltaChange? {
        let side: BisyncSide
        let prefix: String
        if message.hasPrefix("- Path1") {
            side = .path1
            prefix = "- Path1"
        } else if message.hasPrefix("- Path2") {
            side = .path2
            prefix = "- Path2"
        } else {
            if message.contains("File changed")
                || message.contains("File was deleted")
                || message.contains("File is new")
                || message.contains("File is newer")
                || message.contains("File is older") {
                throw FolderSyncConnectionError.unsupportedBisyncLog
            }
            return nil
        }

        var remainder = String(message.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        let changePrefixes = [
            "File was deleted",
            "File is new",
            "File is newer",
            "File is older",
            "File changed:"
        ]
        guard changePrefixes.contains(where: remainder.hasPrefix) else {
            // Other Path1/Path2 NOTICE messages (queue/copy phases) are not
            // change evidence. Only fail closed when they look like a file
            // delta that this version parser should understand.
            if remainder.hasPrefix("File ") {
                throw FolderSyncConnectionError.unsupportedBisyncLog
            }
            return nil
        }
        guard source?.hasPrefix("bisync/deltas.go:") == true,
              let separator = remainder.range(of: " - ")
        else {
            throw FolderSyncConnectionError.unsupportedBisyncLog
        }
        let action = String(remainder[..<separator.lowerBound])
        remainder = String(remainder[separator.upperBound...])
        guard let displayedPath = try decodeDisplayedPath(remainder),
              let path = BisyncDryRunAnalysis.safeRelativePath(displayedPath)
        else {
            throw FolderSyncConnectionError.unsupportedBisyncLog
        }
        return ParsedDeltaChange(
            side: side,
            path: path,
            wasDeleted: action.hasPrefix("File was deleted")
        )
    }

    private static func parseConflictPath(
        message: String,
        source: String?
    ) throws -> String? {
        guard message.hasPrefix("- WARNING") else {
            if message.contains("New or changed in both paths") {
                throw FolderSyncConnectionError.unsupportedBisyncLog
            }
            return nil
        }
        let remainder = String(message.dropFirst("- WARNING".count))
            .trimmingCharacters(in: .whitespaces)
        guard remainder.hasPrefix("New or changed in both paths") else { return nil }
        guard source?.hasPrefix("bisync/deltas.go:") == true,
              let separator = remainder.range(of: " - ")
        else {
            throw FolderSyncConnectionError.unsupportedBisyncLog
        }
        let pathText = String(remainder[separator.upperBound...])
        guard let displayedPath = try decodeDisplayedPath(pathText),
              let path = BisyncDryRunAnalysis.safeRelativePath(displayedPath)
        else {
            throw FolderSyncConnectionError.unsupportedBisyncLog
        }
        return path
    }

    private static func parseResyncSource(
        message: String,
        source: String?
    ) throws -> BisyncSide? {
        guard message.contains("Resync is copying files to") else { return nil }
        guard source?.hasPrefix("bisync/resync.go:") == true else {
            throw FolderSyncConnectionError.unsupportedBisyncLog
        }
        let from: BisyncSide
        let prefix: String
        if message.hasPrefix("- Path1") {
            from = .path1
            prefix = "- Path1"
        } else if message.hasPrefix("- Path2") {
            from = .path2
            prefix = "- Path2"
        } else {
            throw FolderSyncConnectionError.unsupportedBisyncLog
        }
        let remainder = String(message.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard let separator = remainder.range(of: " - "),
              remainder[..<separator.lowerBound]
                .trimmingCharacters(in: .whitespaces) == "Resync is copying files to"
        else {
            throw FolderSyncConnectionError.unsupportedBisyncLog
        }
        let destination = remainder[separator.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        guard (from == .path1 && destination == "Path2")
                || (from == .path2 && destination == "Path1")
        else {
            throw FolderSyncConnectionError.unsupportedBisyncLog
        }
        return from
    }

    private static func isMutationSkip(_ value: String) -> Bool {
        value == "copy"
            || value == "move"
            || value.hasPrefix("move to ")
            || value == "delete"
            || value == "rename"
            || value == "move into backup dir"
    }

    private static func decodeDisplayedPath(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.first == "\"" else { return trimmed }
        guard trimmed.last == "\"",
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data)
        else {
            throw FolderSyncConnectionError.unsupportedBisyncLog
        }
        return decoded
    }

    private func verifyAllDeletionTargetsUnchanged(
        analysis: BisyncDryRunAnalysis,
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        deletionPlan: FolderSyncDeletionPlan?,
        temporaryDirectory: URL
    ) throws -> Bool {
        for path in analysis.effectiveDeletionPaths {
            guard let deletedFrom = analysis.deletedFromSideByPath[path] else { continue }
            let location: FolderSyncLocation = deletedFrom == .path1 ? .googleDrive : .externalDrive
            if let planItem = deletionPlan?.items.first(where: { $0.location == location && $0.relativePaths.contains(path) }),
               let expectedHash = planItem.expectedTargetSHA256ByPath[path] {
                do {
                    let current = try exactHashForDeletionTarget(
                        location: location,
                        relativePath: path,
                        executable: executable,
                        connection: connection,
                        root: root,
                        temporaryDirectory: temporaryDirectory
                    )
                    guard current == expectedHash else { return false }
                } catch {
                    return false
                }
            } else {
                if location == .externalDrive {
                    guard let localURL = try localResourceURL(rootPath: root.canonicalPath, relativePath: path),
                          FileManager.default.fileExists(atPath: localURL.path)
                    else { return false }
                } else {
                    let spec = "\(connection.remoteName):\(connection.remotePath)/\(path)"
                    let stat = try runSmall(
                        executable: executable,
                        arguments: ["lsjson", spec, "--stat", "--drive-skip-gdocs"]
                    )
                    guard stat.exitCode == 0 else { return false }
                }
            }
        }
        return true
    }

    private func verifyRenameMovePreconditions(
        analysis: BisyncDryRunAnalysis,
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport
    ) throws -> Bool {
        for (sourcePath, destinationPath) in analysis.renameDestinationBySource {
            guard let survivingSides = analysis.sourceSidesByPath[sourcePath],
                  survivingSides.count == 1,
                  let mutationSide = survivingSides.first
            else {
                return false
            }
            if mutationSide == .path2 {
                // Path1 already contains the renamed destination; Path2 still
                // has the old source and is the side rclone will mutate.
                let destSpec = "\(connection.remoteName):\(connection.remotePath)/\(destinationPath)"
                let destStat = try runSmall(
                    executable: executable,
                    arguments: ["lsjson", destSpec, "--stat", "--drive-skip-gdocs"]
                )
                if destStat.exitCode == 0 {
                    return false
                }
                let sourceSpec = "\(connection.remoteName):\(connection.remotePath)/\(sourcePath)"
                let sourceStat = try runSmall(
                    executable: executable,
                    arguments: ["lsjson", sourceSpec, "--stat", "--drive-skip-gdocs"]
                )
                guard sourceStat.exitCode == 0,
                      let localDestination = try localResourceURL(
                        rootPath: root.canonicalPath,
                        relativePath: destinationPath
                      ), FileManager.default.fileExists(atPath: localDestination.path)
                else {
                    return false
                }
            } else {
                // Path2 already contains the renamed destination; Path1 still
                // has the old source and is the side rclone will mutate.
                guard let localDest = try localResourceURL(rootPath: root.canonicalPath, relativePath: destinationPath)
                else {
                    return false
                }
                if FileManager.default.fileExists(atPath: localDest.path) {
                    return false
                }
                guard let localSource = try localResourceURL(
                    rootPath: root.canonicalPath,
                    relativePath: sourcePath
                ), FileManager.default.fileExists(atPath: localSource.path)
                else {
                    return false
                }
                let destinationSpec = "\(connection.remoteName):\(connection.remotePath)/\(destinationPath)"
                let destinationStat = try runSmall(
                    executable: executable,
                    arguments: ["lsjson", destinationSpec, "--stat", "--drive-skip-gdocs"]
                )
                if destinationStat.exitCode != 0 {
                    return false
                }
            }
        }
        return true
    }

    public func conflictItems(
        connection: FolderSyncConnection,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> [FolderSyncConflictItem] {
        guard let journal = try FolderSyncJournalStore.load(connection: connection),
              journal.phase == .confirmationRequired
        else {
            return []
        }
        let root = try FolderSyncConnectionManager.verifyLocalRoot(connection, catalogURL: catalogURL)
        let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let executable = try resolvedExecutableURL()
        _ = try validateCapabilities(executable: executable)
        let probeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoArchiveKit-conflict-probe-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probeDirectory) }

        var items: [FolderSyncConflictItem] = []
        for journalItem in journal.items where journalItem.state == .confirmationRequired {
            guard journalItem.note == "both_sides_modified"
                    || journalItem.note == "delete_modify_conflict"
            else {
                // Other confirmation states (for example a changed deletion
                // target or an unsupported move destination) need their own
                // review flow. Never present them as if a conflict choice can
                // safely resolve them.
                continue
            }
            let paths = journalItem.resources.map(\.relativePath).sorted()
            let isLivePhoto = journalItem.resources.count > 1
                || journalItem.resources.contains { $0.role == .photo || $0.role == .pairedVideo }
            let isDeleteModify = journalItem.note == "delete_modify_conflict"
            let conflictKind: FolderSyncConflictKind = isDeleteModify ? .deleteModify : .bothModified

            var localDescriptions: [String] = []
            var remoteDescriptions: [String] = []
            var fingerprintComponents: [String] = []

            for path in paths {
                let localURL = rootURL.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: localURL.path),
                   let values = try? localURL.resourceValues(forKeys: [
                    .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
                   ]),
                   values.isRegularFile == true,
                   values.isSymbolicLink != true,
                   let size = values.fileSize {
                    let hash = try FileHasher.sha256(url: localURL)
                    let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                    localDescriptions.append("\(URL(fileURLWithPath: path).lastPathComponent): \(sizeStr)")
                    fingerprintComponents.append("local:\(path):\(hash.lowercaseHexString)")
                } else {
                    localDescriptions.append("\(URL(fileURLWithPath: path).lastPathComponent): 없음 (삭제됨)")
                    fingerprintComponents.append("local:\(path):deleted")
                }

                let spec = "\(connection.remoteName):\(connection.remotePath)/\(path)"
                let stat = try runSmall(
                    executable: executable,
                    arguments: ["lsjson", spec, "--stat", "--drive-skip-gdocs"]
                )
                if stat.exitCode == 0 {
                    let entry = try JSONDecoder().decode(RcloneListEntry.self, from: stat.stdout)
                    guard entry.IsDir != true else {
                        throw FolderSyncConnectionError.confirmationRequired
                    }
                    let size = entry.Size ?? 0
                    let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                    remoteDescriptions.append("\(URL(fileURLWithPath: path).lastPathComponent): \(sizeStr)")
                    let hash: Data
                    if let directHash = try remoteSHA256(
                        executable: executable,
                        connection: connection,
                        relativePath: path
                    ) {
                        hash = directHash
                    } else {
                        hash = try exactHashForDeletionTarget(
                            location: .googleDrive,
                            relativePath: path,
                            executable: executable,
                            connection: connection,
                            root: root,
                            temporaryDirectory: probeDirectory
                        )
                    }
                    fingerprintComponents.append("remote:\(path):\(hash.lowercaseHexString)")
                } else {
                    let message = String(data: stat.stderr, encoding: .utf8)?.lowercased() ?? ""
                    guard message.contains("not found")
                            || message.contains("doesn't exist")
                            || message.contains("does not exist")
                            || message.contains("directory not found")
                    else {
                        throw FolderSyncConnectionError.connectionCheckRequired
                    }
                    remoteDescriptions.append("\(URL(fileURLWithPath: path).lastPathComponent): 없음 (삭제됨)")
                    fingerprintComponents.append("remote:\(path):deleted")
                }
            }

            let fingerprintData = Data(fingerprintComponents.joined(separator: "|").utf8)
            let fingerprint = SHA256.hash(data: fingerprintData)
                .map { String(format: "%02x", $0) }
                .joined()

            let availableChoices: [FolderSyncConflictChoice] = isDeleteModify
                ? [.keepModified, .deleteBoth]
                : [.keepBoth, .useExternalDrive, .useGoogleDrive]

            items.append(
                FolderSyncConflictItem(
                    id: journalItem.id,
                    relativePaths: paths,
                    isLivePhoto: isLivePhoto,
                    conflictKind: conflictKind,
                    note: journalItem.note,
                    expectedFingerprint: fingerprint,
                    externalDriveDescription: localDescriptions.joined(separator: ", "),
                    googleDriveDescription: remoteDescriptions.joined(separator: ", "),
                    availableChoices: availableChoices
                )
            )
        }
        return items
    }

    public func resolveConflict(
        connection: FolderSyncConnection,
        itemID: String,
        choice: FolderSyncConflictChoice,
        expectedFingerprint: String,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL,
        storeURL: URL = FolderSyncConnectionStore.defaultURL
    ) async throws {
        guard executionPolicy != .blockedForConcurrentMutationSafety else {
            throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
        }
        let operationLock: PhotoArchiveOperationLock
        do {
            operationLock = try PhotoArchiveOperationLock.acquire(catalogURL: catalogURL)
        } catch {
            throw FolderSyncConnectionError.operationAlreadyRunning
        }
        defer { operationLock.release() }

        guard var journal = try FolderSyncJournalStore.load(connection: connection),
              journal.phase == .confirmationRequired
        else {
            throw FolderSyncConnectionError.recoveryRequired
        }

        guard let itemIndex = journal.items.firstIndex(where: { $0.id == itemID }),
              journal.items[itemIndex].state == .confirmationRequired
        else {
            throw FolderSyncConnectionError.recoveryRequired
        }

        let root = try FolderSyncConnectionManager.verifyLocalRoot(connection, catalogURL: catalogURL)
        let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let executable = try resolvedExecutableURL()
        _ = try validateCapabilities(executable: executable)
        let manager = try driveRevisionManager(executable: executable, connection: connection)

        if journal.items[itemIndex].conflictResolution == nil {
            let currentConflicts = try conflictItems(connection: connection, catalogURL: catalogURL)
            guard let currentItem = currentConflicts.first(where: { $0.id == itemID }),
                  currentItem.expectedFingerprint == expectedFingerprint,
                  currentItem.availableChoices.contains(choice)
            else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            guard usesDirectDriveMutationAPI else {
                throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
            }
            let paths = journal.items[itemIndex].resources.map(\.relativePath).sorted()
            let snapshots = try conflictResolutionSnapshots(
                paths: paths,
                rootURL: rootURL,
                manager: manager,
                connection: connection
            )
            guard conflictResolutionFingerprint(paths: paths, snapshots: snapshots) == expectedFingerprint else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            let copyPaths = choice == .keepBoth
                ? try uniqueKeepBothCopyPaths(
                    paths: paths,
                    itemID: itemID,
                    rootURL: rootURL,
                    manager: manager,
                    connection: connection
                )
                : [:]
            journal.items[itemIndex].resolutionChoice = choice
            journal.items[itemIndex].conflictResolution = FolderSyncConflictResolutionProgress(
                choice: choice,
                expectedFingerprint: expectedFingerprint,
                resources: paths.map { path in
                    let snapshot = snapshots[path]!
                    return FolderSyncConflictResolutionResource(
                        relativePath: path,
                        copyRelativePath: copyPaths[path],
                        localExpectedSHA256: snapshot.localHash,
                        remoteExpectedSHA256: snapshot.remoteHash
                    )
                }
            )
            journal.updatedAt = Date()
            try FolderSyncJournalStore.save(journal, connection: connection)
        } else {
            guard usesDirectDriveMutationAPI,
                  journal.items[itemIndex].conflictResolution?.choice == choice,
                  journal.items[itemIndex].conflictResolution?.expectedFingerprint == expectedFingerprint else {
                throw FolderSyncConnectionError.confirmationRequired
            }
        }

        try preserveConflictResolutionSources(
            itemIndex: itemIndex,
            connection: connection,
            rootURL: rootURL,
            manager: manager,
            journal: &journal
        )

        guard var progress = journal.items[itemIndex].conflictResolution else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        if progress.stage != .completed {
            progress.stage = .applying
            journal.items[itemIndex].conflictResolution = progress
            journal.updatedAt = Date()
            try FolderSyncJournalStore.save(journal, connection: connection)
        }

        for resourceIndex in progress.resources.indices where !progress.resources[resourceIndex].applied {
            try applyConflictResolutionResource(
                choice: choice,
                itemID: itemID,
                itemIndex: itemIndex,
                resourceIndex: resourceIndex,
                connection: connection,
                rootURL: rootURL,
                manager: manager,
                journal: &journal
            )
            guard var updated = journal.items[itemIndex].conflictResolution else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            updated.resources[resourceIndex].applied = true
            journal.items[itemIndex].conflictResolution = updated
            journal.updatedAt = Date()
            try FolderSyncJournalStore.save(journal, connection: connection)
            try afterConflictResolutionStepHook?("applied:" + updated.resources[resourceIndex].relativePath)
            progress = updated
        }

        progress.stage = .verifying
        journal.items[itemIndex].conflictResolution = progress
        journal.updatedAt = Date()
        try FolderSyncJournalStore.save(journal, connection: connection)

        for resourceIndex in progress.resources.indices {
            try verifyConflictResolutionResource(
                choice: choice,
                resource: progress.resources[resourceIndex],
                rootURL: rootURL,
                manager: manager,
                connection: connection
            )
            progress.resources[resourceIndex].verified = true
            journal.items[itemIndex].conflictResolution = progress
            journal.updatedAt = Date()
            try FolderSyncJournalStore.save(journal, connection: connection)
        }

        let unresolvedOtherItems = journal.items.indices.filter {
            $0 != itemIndex && journal.items[$0].state == .confirmationRequired
        }
        if unresolvedOtherItems.isEmpty {
            try reconcileConflictResolutionHistory(
                executable: executable,
                connection: connection,
                root: root,
                rootURL: rootURL,
                manager: manager,
                currentItemIndex: itemIndex,
                currentProgress: progress,
                journal: journal
            )
        }

        progress.stage = .completed
        journal.items[itemIndex].conflictResolution = progress
        journal.items[itemIndex].state = .resolved
        journal.items[itemIndex].resolutionChoice = choice
        journal.updatedAt = Date()
        try FolderSyncJournalStore.save(journal, connection: connection)

        let remainingCount = journal.items.count { $0.state == .confirmationRequired }
        var updatedConnection = connection
        if remainingCount == 0 {
            journal.phase = .completed
            updatedConnection.status = RcloneBisyncService.productionApplyAvailable ? .ready : .safetyUnavailable
            try? FolderSyncJournalStore.remove(connection: connection)
        } else {
            try FolderSyncJournalStore.save(journal, connection: connection)
        }
        try FolderSyncConnectionStore.upsert(updatedConnection, url: storeURL)
    }

    private func reconcileConflictResolutionHistory(
        executable: URL,
        connection: FolderSyncConnection,
        root: RegisteredRootReport,
        rootURL: URL,
        manager: any DriveRevisionManaging,
        currentItemIndex: Int,
        currentProgress: FolderSyncConflictResolutionProgress,
        journal: FolderSyncJournal
    ) throws {
        var resolutions: [(choice: FolderSyncConflictChoice, resource: FolderSyncConflictResolutionResource)] = []
        for index in journal.items.indices {
            if index == currentItemIndex {
                resolutions.append(contentsOf: currentProgress.resources.map {
                    (choice: currentProgress.choice, resource: $0)
                })
                continue
            }
            guard journal.items[index].state == .resolved else { continue }
            guard let prior = journal.items[index].conflictResolution,
                  prior.stage == .completed else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            resolutions.append(contentsOf: prior.resources.map {
                (choice: prior.choice, resource: $0)
            })
        }

        let expectedPaths = Set(
            resolutions.flatMap { resolution in
                [resolution.resource.relativePath, resolution.resource.copyRelativePath]
                    .compactMap { $0 }
            }
        )
        guard !expectedPaths.isEmpty else {
            throw FolderSyncConnectionError.recoveryRequired
        }

        let checkpointID = "conflict-history-" + journal.items[currentItemIndex].id
        if FolderSyncHistoryCheckpoint.exists(connection: connection, attemptID: checkpointID) {
            try FolderSyncHistoryCheckpoint.restore(connection: connection, attemptID: checkpointID)
            try FolderSyncHistoryCheckpoint.remove(connection: connection, attemptID: checkpointID)
        }
        try FolderSyncHistoryCheckpoint.create(connection: connection, attemptID: checkpointID)
        var checkpointActive = true
        do {
            try removeBisyncDryHistoryArtifacts(connection: connection)

            let runID = "conflict-history-" + Self.runIdentifier(Date())
            let paths = try runPaths(connection: connection, runID: runID)
            defer {
                try? FileManager.default.removeItem(at: paths.logDirectory)
                try? FileManager.default.removeItem(at: paths.localBackupDirectory.deletingLastPathComponent())
            }
            var arguments = commonBisyncArguments(
                connection: connection,
                localRootPath: root.canonicalPath,
                runPaths: paths
            )
            arguments.append(contentsOf: ["--dry-run", "--use-json-log", "--log-level", "NOTICE"])
            let result = try runToFiles(
                executable: executable,
                arguments: arguments,
                logDirectory: paths.logDirectory,
                basename: "conflict-history"
            )
            guard result.exitCode == 0 else {
                throw classifyFailure(logURL: result.stderrURL)
            }
            let analysis = try Self.parseAnalysis(url: result.stderrURL)
            guard analysis.candidatePaths.subtracting(expectedPaths).isEmpty else {
                throw FolderSyncConnectionError.confirmationRequired
            }

            for resolution in resolutions {
                try verifyConflictResolutionResource(
                    choice: resolution.choice,
                    resource: resolution.resource,
                    rootURL: rootURL,
                    manager: manager,
                    connection: connection
                )
            }

            try promoteBisyncDryHistory(connection: connection)

            let postPromotion = try inspectRecoveryChanges(
                executable: executable,
                connection: connection,
                root: root
            )
            guard postPromotion.candidatePaths.isEmpty else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            for resolution in resolutions {
                try verifyConflictResolutionResource(
                    choice: resolution.choice,
                    resource: resolution.resource,
                    rootURL: rootURL,
                    manager: manager,
                    connection: connection
                )
            }

            try FolderSyncHistoryCheckpoint.remove(connection: connection, attemptID: checkpointID)
            checkpointActive = false
        } catch {
            if checkpointActive {
                try? FolderSyncHistoryCheckpoint.restore(connection: connection, attemptID: checkpointID)
                try? FolderSyncHistoryCheckpoint.remove(connection: connection, attemptID: checkpointID)
            }
            throw error
        }
    }

    private func removeBisyncDryHistoryArtifacts(connection: FolderSyncConnection) throws {
        let directory = URL(fileURLWithPath: connection.workDirectoryPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        for child in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) where child.lastPathComponent.hasSuffix(".lst-dry")
            || child.lastPathComponent.hasSuffix(".lst-dry-old") {
            let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            try FileManager.default.removeItem(at: child)
        }
    }

    private func promoteBisyncDryHistory(
        connection: FolderSyncConnection,
        allowCreatingMain: Bool = false
    ) throws {
        let directory = URL(fileURLWithPath: connection.workDirectoryPath, isDirectory: true)
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        let path1Dry = children.filter { $0.lastPathComponent.hasSuffix(".path1.lst-dry") }
        let path2Dry = children.filter { $0.lastPathComponent.hasSuffix(".path2.lst-dry") }
        guard path1Dry.count == 1, path2Dry.count == 1 else {
            throw FolderSyncConnectionError.recoveryRequired
        }

        for dryURL in [path1Dry[0], path2Dry[0]] {
            let dryValues = try dryURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard dryValues.isRegularFile == true, dryValues.isSymbolicLink != true else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            let dryName = dryURL.lastPathComponent
            guard dryName.hasSuffix("-dry") else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            let mainName = String(dryName.dropLast(4))
            let mainURL = directory.appendingPathComponent(mainName, isDirectory: false)
            if FileManager.default.fileExists(atPath: mainURL.path) {
                let mainValues = try mainURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard mainValues.isRegularFile == true, mainValues.isSymbolicLink != true else {
                    throw FolderSyncConnectionError.recoveryRequired
                }
            } else if !allowCreatingMain {
                throw FolderSyncConnectionError.recoveryRequired
            }
            let data = try Data(contentsOf: dryURL)
            guard let text = String(data: data, encoding: .utf8),
                  text.hasPrefix("# bisync listing v1 from ") else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            try data.write(to: mainURL, options: .atomic)
        }
    }

    private func conflictResolutionSnapshots(
        paths: [String],
        rootURL: URL,
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection
    ) throws -> [String: ConflictResolutionSnapshot] {
        var result: [String: ConflictResolutionSnapshot] = [:]
        for path in paths {
            let localHash = try currentLocalConflictHash(rootURL: rootURL, relativePath: path)
            let remoteFiles = try driveLiveFiles(
                manager: manager,
                connection: connection,
                relativePath: path
            )
            guard remoteFiles.count <= 1 else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            let remoteFile = remoteFiles.first
            if let remoteFile, remoteFile.mimeType == "application/vnd.google-apps.folder" {
                throw FolderSyncConnectionError.confirmationRequired
            }
            if let remoteFile, remoteFile.sha256 == nil {
                throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
            }
            result[path] = ConflictResolutionSnapshot(
                localHash: localHash,
                remoteHash: remoteFile?.sha256,
                remoteFile: remoteFile
            )
        }
        return result
    }

    private func conflictResolutionFingerprint(
        paths: [String],
        snapshots: [String: ConflictResolutionSnapshot]
    ) -> String {
        var components: [String] = []
        for path in paths {
            let snapshot = snapshots[path]!
            if let localHash = snapshot.localHash {
                components.append("local:\(path):\(localHash.lowercaseHexString)")
            } else {
                components.append("local:\(path):deleted")
            }
            if let remoteHash = snapshot.remoteHash {
                components.append("remote:\(path):\(remoteHash.lowercaseHexString)")
            } else {
                components.append("remote:\(path):deleted")
            }
        }
        let data = Data(components.joined(separator: "|").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func uniqueKeepBothCopyPaths(
        paths: [String],
        itemID: String,
        rootURL: URL,
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection
    ) throws -> [String: String] {
        let token = String(itemID.suffix(6))
        for attempt in 0..<100 {
            let suffix = attempt == 0
                ? " (Google Drive \(token))"
                : " (Google Drive \(token)-\(attempt + 1))"
            var candidates: [String: String] = [:]
            var available = true
            for path in paths {
                let pathValue = path as NSString
                let ext = pathValue.pathExtension
                let base = (pathValue.lastPathComponent as NSString).deletingPathExtension
                let directory = pathValue.deletingLastPathComponent
                let fileName = ext.isEmpty ? base + suffix : base + suffix + "." + ext
                let candidate = (directory.isEmpty || directory == ".")
                    ? fileName
                    : directory + "/" + fileName
                guard let safe = BisyncDryRunAnalysis.safeRelativePath(candidate) else {
                    throw FolderSyncConnectionError.confirmationRequired
                }
                if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(safe).path) {
                    available = false
                    break
                }
                let remote = try driveLiveFiles(
                    manager: manager,
                    connection: connection,
                    relativePath: safe
                )
                if !remote.isEmpty {
                    available = false
                    break
                }
                candidates[path] = safe
            }
            if available { return candidates }
        }
        throw FolderSyncConnectionError.confirmationRequired
    }

    private func preserveConflictResolutionSources(
        itemIndex: Int,
        connection: FolderSyncConnection,
        rootURL: URL,
        manager: any DriveRevisionManaging,
        journal: inout FolderSyncJournal
    ) throws {
        guard var progress = journal.items[itemIndex].conflictResolution else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        if progress.stage == .completed || progress.stage == .applied || progress.stage == .verifying {
            return
        }
        progress.stage = .preserving
        journal.items[itemIndex].conflictResolution = progress
        journal.updatedAt = Date()
        try FolderSyncJournalStore.save(journal, connection: connection)

        for resourceIndex in progress.resources.indices where !progress.resources[resourceIndex].sourcePreserved {
            let resource = progress.resources[resourceIndex]
            try assertConflictResolutionResourceStillMatches(
                resource,
                rootURL: rootURL,
                manager: manager,
                connection: connection,
                journal: journal
            )

            if let expectedLocal = resource.localExpectedSHA256 {
                guard let localURL = try localResourceURL(
                    rootPath: rootURL.path,
                    relativePath: resource.relativePath
                ), FileManager.default.fileExists(atPath: localURL.path) else {
                    throw FolderSyncConnectionError.confirmationRequired
                }
                let recovery = conflictLocalRecoveryURL(
                    connection: connection,
                    itemID: journal.items[itemIndex].id,
                    relativePath: resource.relativePath
                )
                if FileManager.default.fileExists(atPath: recovery.path) {
                    guard try FileHasher.sha256(url: recovery) == expectedLocal else {
                        throw FolderSyncConnectionError.recoveryRequired
                    }
                } else {
                    try snapshotLocalDestination(
                        source: localURL,
                        expectedHash: expectedLocal,
                        recovery: recovery
                    )
                }
            }

            if let expectedRemote = resource.remoteExpectedSHA256 {
                let files = try driveLiveFiles(
                    manager: manager,
                    connection: connection,
                    relativePath: resource.relativePath
                )
                guard files.count == 1, let file = files.first, file.sha256 == expectedRemote else {
                    throw FolderSyncConnectionError.confirmationRequired
                }
                var reference = try observedDriveHeadReference(
                    file: file,
                    manager: manager,
                    afterMutation: false
                )
                reference = try pinObservedDriveReference(
                    reference,
                    relativePath: resource.relativePath,
                    manager: manager,
                    afterMutation: false,
                    invokeCrashHook: false
                )
                let revisionIDs: [String]
                do {
                    revisionIDs = try manager.revisions(fileID: file.id).map(\.id).sorted()
                } catch {
                    throw mapDriveAPIError(error, afterMutation: false)
                }
                let resolutionItemID = journal.items[itemIndex].id
                try updateDrivePreservation(
                    in: &journal,
                    relativePath: resource.relativePath
                ) { value in
                    value.baseline = reference
                    value.knownRevisionIDsBeforeMutation = revisionIDs
                    value.recoveryRunID = resolutionItemID
                }
                try savePinnedDriveRecovery(
                    reference: reference,
                    relativePath: resource.relativePath,
                    kind: .baseline,
                    connection: connection
                )
            }

            guard var updated = journal.items[itemIndex].conflictResolution else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            updated.resources[resourceIndex].sourcePreserved = true
            journal.items[itemIndex].conflictResolution = updated
            journal.updatedAt = Date()
            try FolderSyncJournalStore.save(journal, connection: connection)
            progress = updated
        }

        progress.stage = .preserved
        journal.items[itemIndex].conflictResolution = progress
        journal.updatedAt = Date()
        try FolderSyncJournalStore.save(journal, connection: connection)
    }

    private func assertConflictResolutionResourceStillMatches(
        _ resource: FolderSyncConflictResolutionResource,
        rootURL: URL,
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        journal: FolderSyncJournal
    ) throws {
        guard try currentLocalConflictHash(
            rootURL: rootURL,
            relativePath: resource.relativePath
        ) == resource.localExpectedSHA256 else {
            throw FolderSyncConnectionError.confirmationRequired
        }
        let remote = try driveLiveFiles(
            manager: manager,
            connection: connection,
            relativePath: resource.relativePath
        )
        if let expected = resource.remoteExpectedSHA256 {
            guard remote.count == 1, let file = remote.first, file.sha256 == expected else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            if let baseline = drivePreservation(
                in: journal,
                relativePath: resource.relativePath
            )?.baseline {
                guard file.id == baseline.fileID,
                      file.headRevisionID == baseline.revisionID else {
                    throw FolderSyncConnectionError.confirmationRequired
                }
            }
        } else if !remote.isEmpty {
            throw FolderSyncConnectionError.confirmationRequired
        }
    }

    private func currentLocalConflictHash(
        rootURL: URL,
        relativePath: String
    ) throws -> Data? {
        guard let local = try localResourceURL(
            rootPath: rootURL.path,
            relativePath: relativePath
        ) else {
            throw FolderSyncConnectionError.rootIdentityChanged
        }
        guard FileManager.default.fileExists(atPath: local.path) else { return nil }
        let values = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw FolderSyncConnectionError.confirmationRequired
        }
        return try FileHasher.sha256(url: local)
    }

    private func conflictLocalRecoveryURL(
        connection: FolderSyncConnection,
        itemID: String,
        relativePath: String
    ) -> URL {
        URL(fileURLWithPath: connection.localRecoveryDirectoryPath, isDirectory: true)
            .appendingPathComponent("conflict-" + itemID, isDirectory: true)
            .appendingPathComponent("path1", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
    }

    private func applyConflictResolutionResource(
        choice: FolderSyncConflictChoice,
        itemID: String,
        itemIndex: Int,
        resourceIndex: Int,
        connection: FolderSyncConnection,
        rootURL: URL,
        manager: any DriveRevisionManaging,
        journal: inout FolderSyncJournal
    ) throws {
        guard let progress = journal.items[itemIndex].conflictResolution,
              progress.resources.indices.contains(resourceIndex) else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        let resource = progress.resources[resourceIndex]
        let localURL = rootURL.appendingPathComponent(resource.relativePath)

        switch choice {
        case .keepBoth:
            guard let localHash = resource.localExpectedSHA256,
                  let remoteHash = resource.remoteExpectedSHA256,
                  let copyPath = resource.copyRelativePath,
                  try currentLocalConflictHash(
                    rootURL: rootURL,
                    relativePath: resource.relativePath
                  ) == localHash else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            let remoteStage = try pinnedConflictRemoteStage(
                itemID: itemID,
                originalRelativePath: resource.relativePath,
                expectedHash: remoteHash,
                rootURL: rootURL,
                manager: manager,
                journal: journal
            )
            try applyConflictDriveCopy(
                source: remoteStage,
                desiredHash: remoteHash,
                copyRelativePath: copyPath,
                itemIndex: itemIndex,
                resourceIndex: resourceIndex,
                manager: manager,
                connection: connection,
                journal: &journal
            )
            try applyConflictLocalStage(
                source: remoteStage,
                destinationRelativePath: copyPath,
                expectedCurrentHash: nil,
                desiredHash: remoteHash,
                itemID: itemID,
                connection: connection,
                rootURL: rootURL
            )
            try applyConflictDriveFromLocal(
                source: localURL,
                desiredHash: localHash,
                expectedRemoteHash: remoteHash,
                relativePath: resource.relativePath,
                itemID: itemID,
                manager: manager,
                connection: connection,
                journal: &journal
            )

        case .useExternalDrive:
            guard let localHash = resource.localExpectedSHA256,
                  try currentLocalConflictHash(
                    rootURL: rootURL,
                    relativePath: resource.relativePath
                  ) == localHash else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            try applyConflictDriveFromLocal(
                source: localURL,
                desiredHash: localHash,
                expectedRemoteHash: resource.remoteExpectedSHA256,
                relativePath: resource.relativePath,
                itemID: itemID,
                manager: manager,
                connection: connection,
                journal: &journal
            )

        case .useGoogleDrive:
            guard let remoteHash = resource.remoteExpectedSHA256 else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            let remoteStage = try pinnedConflictRemoteStage(
                itemID: itemID,
                originalRelativePath: resource.relativePath,
                expectedHash: remoteHash,
                rootURL: rootURL,
                manager: manager,
                journal: journal
            )
            try applyConflictLocalStage(
                source: remoteStage,
                destinationRelativePath: resource.relativePath,
                expectedCurrentHash: resource.localExpectedSHA256,
                desiredHash: remoteHash,
                itemID: itemID,
                connection: connection,
                rootURL: rootURL
            )

        case .keepModified:
            if let localHash = resource.localExpectedSHA256,
               resource.remoteExpectedSHA256 == nil {
                guard try currentLocalConflictHash(
                    rootURL: rootURL,
                    relativePath: resource.relativePath
                ) == localHash else {
                    throw FolderSyncConnectionError.confirmationRequired
                }
                try applyConflictDriveFromLocal(
                    source: localURL,
                    desiredHash: localHash,
                    expectedRemoteHash: nil,
                    relativePath: resource.relativePath,
                    itemID: itemID,
                    manager: manager,
                    connection: connection,
                    journal: &journal
                )
            } else if resource.localExpectedSHA256 == nil,
                      let remoteHash = resource.remoteExpectedSHA256 {
                let remoteStage = try pinnedConflictRemoteStage(
                    itemID: itemID,
                    originalRelativePath: resource.relativePath,
                    expectedHash: remoteHash,
                    rootURL: rootURL,
                    manager: manager,
                    journal: journal
                )
                try applyConflictLocalStage(
                    source: remoteStage,
                    destinationRelativePath: resource.relativePath,
                    expectedCurrentHash: nil,
                    desiredHash: remoteHash,
                    itemID: itemID,
                    connection: connection,
                    rootURL: rootURL
                )
            } else {
                throw FolderSyncConnectionError.confirmationRequired
            }

        case .deleteBoth:
            if let localHash = resource.localExpectedSHA256 {
                try applyConflictLocalDelete(
                    relativePath: resource.relativePath,
                    expectedHash: localHash,
                    itemID: itemID,
                    connection: connection,
                    rootURL: rootURL
                )
            }
            if let remoteHash = resource.remoteExpectedSHA256 {
                try applyConflictDriveDelete(
                    relativePath: resource.relativePath,
                    expectedHash: remoteHash,
                    itemID: itemID,
                    manager: manager,
                    connection: connection,
                    journal: &journal
                )
            }
        }
    }

    private func applyConflictDriveFromLocal(
        source: URL,
        desiredHash: Data,
        expectedRemoteHash: Data?,
        relativePath: String,
        itemID: String,
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        journal: inout FolderSyncJournal
    ) throws {
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              try FileHasher.sha256(url: source) == desiredHash else {
            throw FolderSyncConnectionError.confirmationRequired
        }
        let live = try driveLiveFiles(
            manager: manager,
            connection: connection,
            relativePath: relativePath
        )
        let preservation = drivePreservation(in: journal, relativePath: relativePath)
            ?? FolderSyncDrivePreservation()

        if let expectedRemoteHash {
            guard let baseline = preservation.baseline else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            if live.count == 1, let current = live.first,
               current.id == baseline.fileID,
               current.sha256 == desiredHash {
                let app = try pinDriveMutationHead(
                    current,
                    expectedHash: desiredHash,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal
                )
                let raced = try preserveDriveRevisionsCreatedDuringMutation(
                    fileID: current.id,
                    appRevisionID: app.revisionID,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal
                )
                guard !raced else { throw FolderSyncConnectionError.confirmationRequired }
                try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                    value.appVersion = app
                    value.expectedSourceSHA256 = desiredHash
                    value.mutation = FolderSyncDriveMutationProgress(
                        kind: .overwrite,
                        destinationRelativePath: relativePath,
                        mutatedFileID: current.id,
                        applied: true,
                        verified: true
                    )
                }
                try FolderSyncJournalStore.save(journal, connection: connection)
                return
            }
            guard live.count == 1, let current = live.first,
                  current.id == baseline.fileID,
                  current.headRevisionID == baseline.revisionID,
                  current.sha256 == expectedRemoteHash else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                value.expectedSourceSHA256 = desiredHash
                value.mutation = FolderSyncDriveMutationProgress(
                    kind: .overwrite,
                    destinationRelativePath: relativePath,
                    mutatedFileID: baseline.fileID
                )
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
            let updated: DriveFileState
            do {
                updated = try manager.updateFile(fileID: baseline.fileID, source: source)
            } catch {
                throw mapDriveAPIError(error, afterMutation: true)
            }
            let app = try pinDriveMutationHead(
                updated,
                expectedHash: desiredHash,
                relativePath: relativePath,
                manager: manager,
                connection: connection,
                journal: &journal
            )
            let raced = try preserveDriveRevisionsCreatedDuringMutation(
                fileID: baseline.fileID,
                appRevisionID: app.revisionID,
                relativePath: relativePath,
                manager: manager,
                connection: connection,
                journal: &journal
            )
            guard !raced else { throw FolderSyncConnectionError.confirmationRequired }
            let verify = try driveLiveFiles(
                manager: manager,
                connection: connection,
                relativePath: relativePath
            )
            guard verify.count == 1,
                  verify.first?.id == baseline.fileID,
                  verify.first?.sha256 == desiredHash else {
                for file in verify where file.id != baseline.fileID
                    && file.mimeType != "application/vnd.google-apps.folder" {
                    _ = try captureDriveConflictHead(
                        file: file,
                        relativePath: relativePath,
                        manager: manager,
                        connection: connection,
                        journal: &journal,
                        afterMutation: true
                    )
                }
                throw FolderSyncConnectionError.confirmationRequired
            }
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                value.appVersion = app
                value.mutation?.applied = true
                value.mutation?.verified = true
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
            return
        }

        var mutation = preservation.mutation
        let ownedFileID = mutation?.kind == .create ? mutation?.mutatedFileID : nil
        let canResumeOwnedCreate = ownedFileID.map { fileID in
            live.count == 1 && live.first?.id == fileID
        } ?? false
        guard live.isEmpty || canResumeOwnedCreate else {
            for file in live where file.mimeType != "application/vnd.google-apps.folder" {
                _ = try captureDriveConflictHead(
                    file: file,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal,
                    afterMutation: false
                )
            }
            try markDriveMutationConfirmation(
                relativePaths: [relativePath],
                note: "incomplete_drive_create_changed_externally",
                connection: connection,
                journal: &journal
            )
            throw FolderSyncConnectionError.confirmationRequired
        }
        let parentID = try driveEnsureParentFolderID(
            manager: manager,
            basePath: connection.remotePath,
            relativePath: relativePath,
            afterMutation: false
        )
        if mutation?.kind != .create || mutation?.mutatedFileID == nil {
            let fileID: String
            do {
                fileID = try manager.generateFileID()
            } catch {
                throw mapDriveAPIError(error, afterMutation: false)
            }
            mutation = FolderSyncDriveMutationProgress(
                kind: .create,
                destinationRelativePath: relativePath,
                mutatedFileID: fileID,
                creationStage: .planned
            )
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                value.expectedSourceSHA256 = desiredHash
                value.recoveryRunID = itemID
                value.mutation = mutation
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
        }
        guard let fileID = mutation?.mutatedFileID else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        let name = URL(fileURLWithPath: relativePath).lastPathComponent
        var current = try manager.file(id: fileID)
        if current == nil {
            guard mutation?.creationStage != .contentUploaded,
                  mutation?.creationStage != .verified else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            do {
                current = try manager.createEmptyFile(
                    id: fileID,
                    parentID: parentID,
                    name: name
                )
            } catch {
                if let existing = try? manager.file(id: fileID) {
                    current = existing
                } else {
                    throw mapDriveAPIError(error, afterMutation: true)
                }
            }
        }
        guard var created = current else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        if created.sha256 == desiredHash {
            guard Self.isOwnedUploadedDriveFile(
                created,
                fileID: fileID,
                parentID: parentID,
                name: name,
                expectedHash: desiredHash,
                recordedRevisionID: mutation?.contentRevisionID
            ) else {
                _ = try captureDriveConflictHead(
                    file: created,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal,
                    afterMutation: false
                )
                try markDriveMutationConfirmation(
                    relativePaths: [relativePath],
                    note: "incomplete_drive_create_changed_externally",
                    connection: connection,
                    journal: &journal
                )
                throw FolderSyncConnectionError.confirmationRequired
            }
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                if value.mutation?.creationStage != .verified {
                    value.mutation?.creationStage = .contentUploaded
                }
                value.mutation?.applied = true
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
        } else {
            guard Self.isOwnedEmptyDrivePlaceholder(
                created,
                fileID: fileID,
                parentID: parentID,
                name: name,
                recordedRevisionID: mutation?.emptyObjectRevisionID
            ) else {
                _ = try captureDriveConflictHead(
                    file: created,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal,
                    afterMutation: false
                )
                try markDriveMutationConfirmation(
                    relativePaths: [relativePath],
                    note: "incomplete_drive_create_changed_externally",
                    connection: connection,
                    journal: &journal
                )
                throw FolderSyncConnectionError.confirmationRequired
            }
            guard mutation?.creationStage != .contentUploaded,
                  mutation?.creationStage != .verified else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                value.mutation?.creationStage = .emptyObjectCreated
                value.mutation?.emptyObjectRevisionID = created.headRevisionID
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
            try afterDriveEmptyObjectJournaledBeforeUploadHook?(relativePath)
            do {
                created = try manager.updateFile(fileID: fileID, source: source)
            } catch {
                throw mapDriveAPIError(error, afterMutation: true)
            }
            guard let contentRevisionID = created.headRevisionID else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
                value.mutation?.creationStage = .contentUploaded
                value.mutation?.contentRevisionID = contentRevisionID
                value.mutation?.applied = true
            }
            try FolderSyncJournalStore.save(journal, connection: connection)
        }
        let app = try pinDriveMutationHead(
            created,
            expectedHash: desiredHash,
            relativePath: relativePath,
            manager: manager,
            connection: connection,
            journal: &journal
        )
        let verify = try driveLiveFiles(
            manager: manager,
            connection: connection,
            relativePath: relativePath
        )
        guard verify.count == 1, verify.first?.id == fileID, verify.first?.sha256 == desiredHash else {
            throw FolderSyncConnectionError.confirmationRequired
        }
        try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
            value.appVersion = app
            value.mutation?.applied = true
            value.mutation?.verified = true
            value.mutation?.creationStage = .verified
        }
        try FolderSyncJournalStore.save(journal, connection: connection)
    }

    private func applyConflictDriveCopy(
        source: URL,
        desiredHash: Data,
        copyRelativePath: String,
        itemIndex: Int,
        resourceIndex: Int,
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        journal: inout FolderSyncJournal
    ) throws {
        guard try FileHasher.sha256(url: source) == desiredHash,
              var progress = journal.items[itemIndex].conflictResolution else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        var mutation = progress.resources[resourceIndex].copyDriveMutation
        var fileID = mutation?.mutatedFileID ?? progress.resources[resourceIndex].copyDriveFileID
        let live = try driveLiveFiles(
            manager: manager,
            connection: connection,
            relativePath: copyRelativePath
        )
        if fileID == nil {
            guard live.isEmpty else { throw FolderSyncConnectionError.confirmationRequired }
            do {
                fileID = try manager.generateFileID()
            } catch {
                throw mapDriveAPIError(error, afterMutation: false)
            }
            progress.resources[resourceIndex].copyDriveFileID = fileID
            mutation = FolderSyncDriveMutationProgress(
                kind: .create,
                destinationRelativePath: copyRelativePath,
                mutatedFileID: fileID,
                creationStage: .planned
            )
            progress.resources[resourceIndex].copyDriveMutation = mutation
            journal.items[itemIndex].conflictResolution = progress
            journal.updatedAt = Date()
            try FolderSyncJournalStore.save(journal, connection: connection)
        } else if mutation == nil {
            mutation = FolderSyncDriveMutationProgress(
                kind: .create,
                destinationRelativePath: copyRelativePath,
                mutatedFileID: fileID,
                creationStage: .planned
            )
            progress.resources[resourceIndex].copyDriveMutation = mutation
            journal.items[itemIndex].conflictResolution = progress
            journal.updatedAt = Date()
            try FolderSyncJournalStore.save(journal, connection: connection)
        }
        guard let fileID else { throw FolderSyncConnectionError.recoveryRequired }
        if !live.isEmpty {
            guard live.count == 1, live.first?.id == fileID else {
                for file in live where file.mimeType != "application/vnd.google-apps.folder" {
                    var reference = try observedDriveHeadReference(
                        file: file,
                        manager: manager,
                        afterMutation: false
                    )
                    reference = try pinObservedDriveReference(
                        reference,
                        relativePath: copyRelativePath,
                        manager: manager,
                        afterMutation: false,
                        invokeCrashHook: false
                    )
                    try savePinnedDriveRecovery(
                        reference: reference,
                        relativePath: copyRelativePath,
                        kind: .conflict,
                        connection: connection
                    )
                }
                journal.phase = .confirmationRequired
                journal.items[itemIndex].state = .confirmationRequired
                journal.items[itemIndex].note = "incomplete_drive_create_changed_externally"
                journal.updatedAt = Date()
                try FolderSyncJournalStore.save(journal, connection: connection)
                throw FolderSyncConnectionError.confirmationRequired
            }
        }
        let parentID = try driveEnsureParentFolderID(
            manager: manager,
            basePath: connection.remotePath,
            relativePath: copyRelativePath,
            afterMutation: false
        )
        let name = URL(fileURLWithPath: copyRelativePath).lastPathComponent
        var current = try manager.file(id: fileID)
        if current == nil {
            guard mutation?.creationStage != .contentUploaded,
                  mutation?.creationStage != .verified else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            do {
                current = try manager.createEmptyFile(
                    id: fileID,
                    parentID: parentID,
                    name: name
                )
            } catch {
                if let existing = try? manager.file(id: fileID) {
                    current = existing
                } else {
                    throw mapDriveAPIError(error, afterMutation: true)
                }
            }
        }
        guard var file = current else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        if file.sha256 == desiredHash {
            guard Self.isOwnedUploadedDriveFile(
                file,
                fileID: fileID,
                parentID: parentID,
                name: name,
                expectedHash: desiredHash,
                recordedRevisionID: mutation?.contentRevisionID
            ) else {
                var reference = try observedDriveHeadReference(
                    file: file,
                    manager: manager,
                    afterMutation: false
                )
                reference = try pinObservedDriveReference(
                    reference,
                    relativePath: copyRelativePath,
                    manager: manager,
                    afterMutation: false,
                    invokeCrashHook: false
                )
                try savePinnedDriveRecovery(
                    reference: reference,
                    relativePath: copyRelativePath,
                    kind: .conflict,
                    connection: connection
                )
                journal.phase = .confirmationRequired
                journal.items[itemIndex].state = .confirmationRequired
                journal.items[itemIndex].note = "incomplete_drive_create_changed_externally"
                journal.updatedAt = Date()
                try FolderSyncJournalStore.save(journal, connection: connection)
                throw FolderSyncConnectionError.confirmationRequired
            }
            if mutation?.creationStage != .verified {
                mutation?.creationStage = .contentUploaded
            }
            mutation?.applied = true
            progress.resources[resourceIndex].copyDriveMutation = mutation
            journal.items[itemIndex].conflictResolution = progress
            journal.updatedAt = Date()
            try FolderSyncJournalStore.save(journal, connection: connection)
        } else {
            guard Self.isOwnedEmptyDrivePlaceholder(
                file,
                fileID: fileID,
                parentID: parentID,
                name: name,
                recordedRevisionID: mutation?.emptyObjectRevisionID
            ) else {
                var reference = try observedDriveHeadReference(
                    file: file,
                    manager: manager,
                    afterMutation: false
                )
                reference = try pinObservedDriveReference(
                    reference,
                    relativePath: copyRelativePath,
                    manager: manager,
                    afterMutation: false,
                    invokeCrashHook: false
                )
                try savePinnedDriveRecovery(
                    reference: reference,
                    relativePath: copyRelativePath,
                    kind: .conflict,
                    connection: connection
                )
                journal.phase = .confirmationRequired
                journal.items[itemIndex].state = .confirmationRequired
                journal.items[itemIndex].note = "incomplete_drive_create_changed_externally"
                journal.updatedAt = Date()
                try FolderSyncJournalStore.save(journal, connection: connection)
                throw FolderSyncConnectionError.confirmationRequired
            }
            guard mutation?.creationStage != .contentUploaded,
                  mutation?.creationStage != .verified else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            mutation?.creationStage = .emptyObjectCreated
            mutation?.emptyObjectRevisionID = file.headRevisionID
            progress.resources[resourceIndex].copyDriveMutation = mutation
            journal.items[itemIndex].conflictResolution = progress
            journal.updatedAt = Date()
            try FolderSyncJournalStore.save(journal, connection: connection)
            try afterDriveEmptyObjectJournaledBeforeUploadHook?(copyRelativePath)
            do {
                file = try manager.updateFile(fileID: fileID, source: source)
            } catch {
                throw mapDriveAPIError(error, afterMutation: true)
            }
            guard let contentRevisionID = file.headRevisionID else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            mutation?.creationStage = .contentUploaded
            mutation?.contentRevisionID = contentRevisionID
            mutation?.applied = true
            progress.resources[resourceIndex].copyDriveMutation = mutation
            journal.items[itemIndex].conflictResolution = progress
            journal.updatedAt = Date()
            try FolderSyncJournalStore.save(journal, connection: connection)
        }
        var reference = try observedDriveHeadReference(
            file: file,
            manager: manager,
            afterMutation: true
        )
        reference = try pinObservedDriveReference(
            reference,
            relativePath: copyRelativePath,
            manager: manager,
            afterMutation: true,
            invokeCrashHook: false
        )
        try savePinnedDriveRecovery(
            reference: reference,
            relativePath: copyRelativePath,
            kind: .appVersion,
            connection: connection
        )
        let verify = try driveLiveFiles(
            manager: manager,
            connection: connection,
            relativePath: copyRelativePath
        )
        guard verify.count == 1, verify.first?.id == fileID, verify.first?.sha256 == desiredHash else {
            throw FolderSyncConnectionError.confirmationRequired
        }
        mutation?.applied = true
        mutation?.verified = true
        mutation?.creationStage = .verified
        progress.resources[resourceIndex].copyDriveMutation = mutation
        journal.items[itemIndex].conflictResolution = progress
        journal.updatedAt = Date()
        try FolderSyncJournalStore.save(journal, connection: connection)
    }

    private func pinnedConflictRemoteStage(
        itemID: String,
        originalRelativePath: String,
        expectedHash: Data,
        rootURL: URL,
        manager: any DriveRevisionManaging,
        journal: FolderSyncJournal
    ) throws -> URL {
        guard let baseline = drivePreservation(
            in: journal,
            relativePath: originalRelativePath
        )?.baseline,
              baseline.keepForeverVerified,
              baseline.sha256 == expectedHash else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        let stage = rootURL
            .appendingPathComponent(".photoarchive", isDirectory: true)
            .appendingPathComponent("conflict-resolution", isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
            .appendingPathComponent("remote-source", isDirectory: true)
            .appendingPathComponent(originalRelativePath, isDirectory: false)
        if FileManager.default.fileExists(atPath: stage.path) {
            guard try FileHasher.sha256(url: stage) == expectedHash else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            return stage
        }
        try FileManager.default.createDirectory(
            at: stage.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try manager.downloadRevision(
                fileID: baseline.fileID,
                revisionID: baseline.revisionID,
                to: stage
            )
        } catch {
            throw mapDriveAPIError(error, afterMutation: false)
        }
        guard FileManager.default.fileExists(atPath: stage.path),
              try FileHasher.sha256(url: stage) == expectedHash else {
            try? FileManager.default.removeItem(at: stage)
            throw FolderSyncConnectionError.recoveryRequired
        }
        return stage
    }

    private func applyConflictLocalStage(
        source: URL,
        destinationRelativePath: String,
        expectedCurrentHash: Data?,
        desiredHash: Data,
        itemID: String,
        connection: FolderSyncConnection,
        rootURL: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: source.path),
              try FileHasher.sha256(url: source) == desiredHash,
              let destination = try localResourceURL(
                rootPath: rootURL.path,
                relativePath: destinationRelativePath
              ) else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        let currentHash = try currentLocalConflictHash(
            rootURL: rootURL,
            relativePath: destinationRelativePath
        )
        if currentHash == desiredHash {
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.removeItem(at: source)
            }
            return
        }
        guard currentHash == expectedCurrentHash else {
            throw FolderSyncConnectionError.confirmationRequired
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try beforeLocalDestinationSwapHook?(destinationRelativePath)

        if let expectedCurrentHash {
            guard FileManager.default.fileExists(atPath: destination.path) else {
                throw FolderSyncConnectionError.confirmationRequired
            }
            let swapErrorCode: Int32?
            if let injected = testingLocalSwapErrorCode {
                swapErrorCode = injected
            } else {
                let result = source.path.withCString { sourcePath in
                    destination.path.withCString { destinationPath in
                        renameatx_np(
                            AT_FDCWD,
                            sourcePath,
                            AT_FDCWD,
                            destinationPath,
                            UInt32(RENAME_SWAP)
                        )
                    }
                }
                swapErrorCode = result == 0 ? nil : errno
            }
            if let code = swapErrorCode {
                if code == ENOENT { throw FolderSyncConnectionError.confirmationRequired }
                if code == EXDEV || code == ENOTSUP || code == EINVAL {
                    throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
                }
                throw FolderSyncConnectionError.recoveryRequired
            }
            try afterLocalDestinationSwapHook?(destinationRelativePath)
            let swappedHash = try FileHasher.sha256(url: source)
            if swappedHash != expectedCurrentHash {
                let conflictRecovery = URL(
                    fileURLWithPath: connection.localRecoveryDirectoryPath,
                    isDirectory: true
                )
                .appendingPathComponent("conflict-" + itemID, isDirectory: true)
                .appendingPathComponent("path1-conflicts", isDirectory: true)
                .appendingPathComponent(destinationRelativePath, isDirectory: false)
                try preserveSwappedLocalDestination(stage: source, recovery: conflictRecovery)
                throw FolderSyncConnectionError.confirmationRequired
            }
            try FileManager.default.removeItem(at: source)
        } else {
            let exclErrorCode: Int32?
            if let injected = testingLocalSwapErrorCode {
                exclErrorCode = injected
            } else {
                let result = source.path.withCString { sourcePath in
                    destination.path.withCString { destinationPath in
                        renameatx_np(
                            AT_FDCWD,
                            sourcePath,
                            AT_FDCWD,
                            destinationPath,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                exclErrorCode = result == 0 ? nil : errno
            }
            if let code = exclErrorCode {
                if code == EEXIST { throw FolderSyncConnectionError.confirmationRequired }
                if code == EXDEV || code == ENOTSUP || code == EINVAL {
                    throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
                }
                throw FolderSyncConnectionError.recoveryRequired
            }
            try afterLocalDestinationSwapHook?(destinationRelativePath)
        }
        guard try currentLocalConflictHash(
            rootURL: rootURL,
            relativePath: destinationRelativePath
        ) == desiredHash else {
            throw FolderSyncConnectionError.recoveryRequired
        }
    }

    private func applyConflictLocalDelete(
        relativePath: String,
        expectedHash: Data,
        itemID: String,
        connection: FolderSyncConnection,
        rootURL: URL
    ) throws {
        guard let source = try localResourceURL(
            rootPath: rootURL.path,
            relativePath: relativePath
        ) else {
            throw FolderSyncConnectionError.rootIdentityChanged
        }
        let recovery = conflictLocalRecoveryURL(
            connection: connection,
            itemID: itemID,
            relativePath: relativePath
        )
        guard FileManager.default.fileExists(atPath: recovery.path),
              try FileHasher.sha256(url: recovery) == expectedHash else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        let tombstone = rootURL
            .appendingPathComponent(".photoarchive", isDirectory: true)
            .appendingPathComponent("conflict-resolution", isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
            .appendingPathComponent("deleted", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: tombstone.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: tombstone.path) {
            guard try FileHasher.sha256(url: tombstone) == expectedHash else {
                throw FolderSyncConnectionError.recoveryRequired
            }
            if FileManager.default.fileExists(atPath: source.path),
               try FileHasher.sha256(url: source) != expectedHash {
                try FileManager.default.removeItem(at: tombstone)
                throw FolderSyncConnectionError.confirmationRequired
            }
            try FileManager.default.removeItem(at: tombstone)
        }

        guard FileManager.default.fileExists(atPath: source.path) else { return }
        guard try FileHasher.sha256(url: source) == expectedHash else {
            throw FolderSyncConnectionError.confirmationRequired
        }
        try beforeLocalDestinationSwapHook?(relativePath)
        let errorCode: Int32?
        if let injected = testingLocalSwapErrorCode {
            errorCode = injected
        } else {
            let result = source.path.withCString { sourcePath in
                tombstone.path.withCString { tombstonePath in
                    renameatx_np(
                        AT_FDCWD,
                        sourcePath,
                        AT_FDCWD,
                        tombstonePath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            errorCode = result == 0 ? nil : errno
        }
        if let code = errorCode {
            if code == EEXIST || code == ENOENT {
                throw FolderSyncConnectionError.confirmationRequired
            }
            if code == EXDEV || code == ENOTSUP || code == EINVAL {
                throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
            }
            throw FolderSyncConnectionError.recoveryRequired
        }
        try afterLocalDestinationSwapHook?(relativePath)
        guard try FileHasher.sha256(url: tombstone) == expectedHash else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        try FileManager.default.removeItem(at: tombstone)
        if FileManager.default.fileExists(atPath: source.path) {
            // A writer recreated the active path after the atomic move. Keep
            // that new file in place and invalidate the old approval.
            throw FolderSyncConnectionError.confirmationRequired
        }
    }

    private func applyConflictDriveDelete(
        relativePath: String,
        expectedHash: Data,
        itemID: String,
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection,
        journal: inout FolderSyncJournal
    ) throws {
        guard let baseline = drivePreservation(
            in: journal,
            relativePath: relativePath
        )?.baseline else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        let live = try driveLiveFiles(
            manager: manager,
            connection: connection,
            relativePath: relativePath
        )
        if live.isEmpty {
            return
        }
        guard live.count == 1, let current = live.first,
              current.id == baseline.fileID,
              current.headRevisionID == baseline.revisionID,
              current.sha256 == expectedHash else {
            throw FolderSyncConnectionError.confirmationRequired
        }
        try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
            value.mutation = FolderSyncDriveMutationProgress(
                kind: .delete,
                sourceRelativePath: relativePath,
                destinationRelativePath: relativePath,
                mutatedFileID: baseline.fileID
            )
        }
        try FolderSyncJournalStore.save(journal, connection: connection)
        let moved = try moveDriveFileToRecovery(
            manager: manager,
            connection: connection,
            runID: "conflict-" + itemID,
            relativePath: relativePath,
            fileID: baseline.fileID
        )
        if moved.headRevisionID != baseline.revisionID || moved.sha256 != expectedHash {
            _ = try captureDriveConflictHead(
                file: moved,
                relativePath: relativePath,
                manager: manager,
                connection: connection,
                journal: &journal,
                afterMutation: true
            )
            let originalParent = try driveParentFolderID(
                manager: manager,
                basePath: connection.remotePath,
                relativePath: relativePath
            )
            do {
                _ = try manager.moveFile(
                    fileID: baseline.fileID,
                    parentID: originalParent,
                    name: URL(fileURLWithPath: relativePath).lastPathComponent
                )
            } catch {
                throw mapDriveAPIError(error, afterMutation: true)
            }
            throw FolderSyncConnectionError.confirmationRequired
        }
        let remaining = try driveLiveFiles(
            manager: manager,
            connection: connection,
            relativePath: relativePath
        )
        if !remaining.isEmpty {
            for file in remaining where file.mimeType != "application/vnd.google-apps.folder" {
                _ = try captureDriveConflictHead(
                    file: file,
                    relativePath: relativePath,
                    manager: manager,
                    connection: connection,
                    journal: &journal,
                    afterMutation: true
                )
            }
            throw FolderSyncConnectionError.confirmationRequired
        }
        try updateDrivePreservation(in: &journal, relativePath: relativePath) { value in
            value.mutation?.applied = true
            value.mutation?.verified = true
        }
        try FolderSyncJournalStore.save(journal, connection: connection)
    }

    private func verifyConflictResolutionResource(
        choice: FolderSyncConflictChoice,
        resource: FolderSyncConflictResolutionResource,
        rootURL: URL,
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection
    ) throws {
        let local = try currentLocalConflictHash(
            rootURL: rootURL,
            relativePath: resource.relativePath
        )
        let remote = try currentDriveConflictHash(
            relativePath: resource.relativePath,
            manager: manager,
            connection: connection
        )
        switch choice {
        case .keepBoth:
            guard let localExpected = resource.localExpectedSHA256,
                  let remoteExpected = resource.remoteExpectedSHA256,
                  let copyPath = resource.copyRelativePath,
                  local == localExpected,
                  remote == localExpected,
                  try currentLocalConflictHash(
                    rootURL: rootURL,
                    relativePath: copyPath
                  ) == remoteExpected,
                  try currentDriveConflictHash(
                    relativePath: copyPath,
                    manager: manager,
                    connection: connection
                  ) == remoteExpected else {
                throw FolderSyncConnectionError.recoveryRequired
            }
        case .useExternalDrive:
            guard let desired = resource.localExpectedSHA256,
                  local == desired,
                  remote == desired else {
                throw FolderSyncConnectionError.recoveryRequired
            }
        case .useGoogleDrive:
            guard let desired = resource.remoteExpectedSHA256,
                  local == desired,
                  remote == desired else {
                throw FolderSyncConnectionError.recoveryRequired
            }
        case .keepModified:
            guard let desired = resource.localExpectedSHA256 ?? resource.remoteExpectedSHA256,
                  local == desired,
                  remote == desired else {
                throw FolderSyncConnectionError.recoveryRequired
            }
        case .deleteBoth:
            guard local == nil, remote == nil else {
                throw FolderSyncConnectionError.recoveryRequired
            }
        }
    }

    private func currentDriveConflictHash(
        relativePath: String,
        manager: any DriveRevisionManaging,
        connection: FolderSyncConnection
    ) throws -> Data? {
        let files = try driveLiveFiles(
            manager: manager,
            connection: connection,
            relativePath: relativePath
        )
        guard files.count <= 1 else {
            throw FolderSyncConnectionError.confirmationRequired
        }
        guard let file = files.first else { return nil }
        guard file.mimeType != "application/vnd.google-apps.folder",
              let hash = file.sha256 else {
            throw FolderSyncConnectionError.concurrentMutationSafetyUnavailable
        }
        return hash
    }

    private static func stripANSI(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "\\u001B\\[[0-9;]*m") else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }
}

public struct BisyncLogSummary: Sendable, Equatable {
    public let candidatePaths: [String]
    public let conflictPreserved: Bool

    public init(candidatePaths: [String], conflictPreserved: Bool) {
        self.candidatePaths = candidatePaths
        self.conflictPreserved = conflictPreserved
    }
}
