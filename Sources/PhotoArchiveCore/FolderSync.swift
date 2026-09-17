import Darwin
import Foundation

public enum FolderSyncStatus: String, Codable, Sendable, Equatable {
    case setupRequired = "setup_required"
    case ready
    case running
    case success
    case failed
    case incomplete
    case confirmationRequired = "confirmation_required"
    case conflict
    case initialConflict = "initial_conflict"
    case recoveryRequired = "recovery_required"
    case driveUnavailable = "drive_unavailable"
    case connectionCheckRequired = "connection_check_required"
    case livePhotoBlocked = "live_photo_blocked"
    case safetyUnavailable = "safety_unavailable"
    case cancelled
}

public struct FolderSyncConnection: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let rootID: String
    public let rootMarkerKey: String
    public let remoteName: String
    public let remoteDisplayName: String?
    public let remotePath: String
    public let workDirectoryPath: String
    public let localRecoveryDirectoryPath: String
    public let remoteRecoveryPath: String
    public var isInitialized: Bool
    public var initialSyncStartedAt: Date?
    public var status: FolderSyncStatus
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?

    public init(
        id: String,
        rootID: String,
        rootMarkerKey: String,
        remoteName: String,
        remoteDisplayName: String? = nil,
        remotePath: String,
        workDirectoryPath: String,
        localRecoveryDirectoryPath: String,
        remoteRecoveryPath: String,
        isInitialized: Bool = false,
        initialSyncStartedAt: Date? = nil,
        status: FolderSyncStatus = .setupRequired,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil
    ) {
        self.id = id
        self.rootID = rootID
        self.rootMarkerKey = rootMarkerKey
        self.remoteName = remoteName
        self.remoteDisplayName = remoteDisplayName
        self.remotePath = remotePath
        self.workDirectoryPath = workDirectoryPath
        self.localRecoveryDirectoryPath = localRecoveryDirectoryPath
        self.remoteRecoveryPath = remoteRecoveryPath
        self.isInitialized = isInitialized
        self.initialSyncStartedAt = initialSyncStartedAt
        self.status = status
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
    }
}

public struct RcloneDriveRemote: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let type: String
    public let description: String?

    public var id: String { name }
    public var displayName: String {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? name : trimmed
    }
}

public enum FolderSyncConnectionError: LocalizedError {
    case rootNotFound
    case rootUnavailable
    case readOnlyRoot
    case rootIdentityChanged
    case connectionAlreadyExists
    case invalidRemoteName
    case invalidRemotePath
    case remoteRootNotAllowed
    case localStateOverlapsRoot
    case connectionCheckRequired
    case unsupportedRclone(String)
    case rcloneNotInstalled
    case livePhotoMutationBlocked
    case concurrentMutationSafetyUnavailable
    case confirmationRequired
    case initialConflict
    case unsupportedBisyncLog
    case initialConfirmationRequired
    case recoveryRequired
    case operationAlreadyRunning
    case restoreDestinationExists
    case recoveryItemChanged
    case insufficientRecoverySpace

    public var errorDescription: String? {
        switch self {
        case .rootNotFound:
            return "등록된 폴더를 찾을 수 없습니다."
        case .rootUnavailable:
            return "드라이브가 연결되어 있지 않습니다. 폴더를 다시 연결한 뒤 시도해 주세요."
        case .readOnlyRoot:
            return "읽기 전용 폴더는 양방향 동기화할 수 없습니다."
        case .rootIdentityChanged:
            return "연결된 폴더가 이전에 설정한 위치와 일치하는지 확인이 필요합니다."
        case .connectionAlreadyExists:
            return "이 폴더에는 이미 동기화 연결이 있습니다."
        case .invalidRemoteName:
            return "Google Drive 연결을 다시 선택해 주세요."
        case .invalidRemotePath:
            return "Google Drive 폴더 이름을 확인해 주세요."
        case .remoteRootNotAllowed:
            return "Google Drive 전체를 동기화 대상으로 사용할 수 없습니다. 전용 폴더를 선택해 주세요."
        case .localStateOverlapsRoot:
            return "이 폴더는 PhotoArchiveKit의 동기화 상태 또는 복구 위치를 포함하므로 양방향 동기화할 수 없습니다. 더 구체적인 사진 폴더를 선택해 주세요."
        case .connectionCheckRequired:
            return "Google Drive 연결을 확인한 뒤 다시 시도해 주세요."
        case .unsupportedRclone:
            return "설치된 동기화 구성요소의 버전은 현재 지원되지 않습니다."
        case .rcloneNotInstalled:
            return "필요한 동기화 구성요소를 찾을 수 없습니다. 동기화 설정을 확인해 주세요."
        case .livePhotoMutationBlocked:
            return "Live Photo 파일 변경이 포함되어 있어 안전을 위해 동기화를 중단했습니다."
        case .concurrentMutationSafetyUnavailable:
            return "파일을 안전하게 반영하는 기능을 준비하고 있습니다. 현재는 동기화를 실행할 수 없습니다."
        case .confirmationRequired:
            return "동기화 확인 뒤 새로 생기거나 바뀐 항목을 찾았습니다. 완료로 처리하지 않고 확인을 기다립니다."
        case .initialConflict:
            return "첫 동기화 전에 양쪽의 동일한 위치에서 서로 다른 파일을 찾았습니다. 어느 쪽도 자동으로 덮어쓰지 않습니다."
        case .unsupportedBisyncLog:
            return "동기화 변경 사항을 안전하게 확인하지 못했습니다. 파일을 변경하지 않고 중단했습니다."
        case .initialConfirmationRequired:
            return "첫 동기화는 양쪽 폴더를 합치는 작업이므로 확인이 필요합니다."
        case .recoveryRequired:
            return "이전 동기화 상태를 신뢰할 수 없어 복구가 필요합니다. 자동으로 초기화하지 않습니다."
        case .operationAlreadyRunning:
            return "다른 PhotoArchiveKit 작업이 진행 중입니다. 끝난 뒤 다시 시도해 주세요."
        case .restoreDestinationExists:
            return "복원할 위치에 다른 파일이 있습니다. 기존 파일을 덮어쓰지 않았습니다."
        case .recoveryItemChanged:
            return "복구 사본이 마지막 확인 뒤 변경되어 정리하지 않았습니다. 다시 확인해 주세요."
        case .insufficientRecoverySpace:
            return "복구 사본을 안전하게 보관할 공간이 부족합니다. 기존 복구 사본은 삭제하지 않았습니다."
        }
    }
}

extension FolderSyncConnectionError {
    var isCleanPreApplySafetyFailure: Bool {
        switch self {
        case .concurrentMutationSafetyUnavailable, .connectionCheckRequired:
            return true
        default:
            return false
        }
    }
}

public enum FolderSyncConnectionStore {
    private struct FileContents: Codable {
        let schemaVersion: Int
        var connections: [FolderSyncConnection]
    }

    public static var defaultURL: URL {
        PhotoArchivePaths.applicationSupportDirectoryURL
            .appendingPathComponent("sync-connections.json", isDirectory: false)
    }

    public static var defaultStateDirectoryURL: URL {
        PhotoArchivePaths.applicationSupportDirectoryURL
            .appendingPathComponent("sync", isDirectory: true)
    }

    public static var defaultRecoveryDirectoryURL: URL {
        PhotoArchivePaths.applicationSupportDirectoryURL
            .appendingPathComponent("sync-recovery", isDirectory: true)
    }

    public static func load(url: URL = defaultURL) throws -> [FolderSyncConnection] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = try decoder.decode(FileContents.self, from: Data(contentsOf: url))
        guard contents.schemaVersion == 1 else {
            throw FolderSyncConnectionError.recoveryRequired
        }
        return contents.connections
    }

    public static func loadRecoveringInterrupted(
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL,
        url: URL = defaultURL
    ) throws -> [FolderSyncConnection] {
        var values = try load(url: url)
        var journalChanged = false
        for index in values.indices {
            do {
                guard let journal = try FolderSyncJournalStore.load(connection: values[index]) else {
                    continue
                }
                var recoveredJournal = journal
                let status: FolderSyncStatus?
                switch recoveredJournal.phase {
                case .incomplete:
                    status = .incomplete
                case .confirmationRequired:
                    status = .confirmationRequired
                case .recoveryRequired:
                    status = .recoveryRequired
                case .planning, .applying, .verifying:
                    recoveredJournal.phase = .recoveryRequired
                    recoveredJournal.updatedAt = Date()
                    recoveredJournal.items = recoveredJournal.items.map { item in
                        var value = item
                        if value.state != .verified {
                            value.state = .incomplete
                        }
                        return value
                    }
                    if recoveredJournal.historyCheckpointAvailable,
                       FolderSyncHistoryCheckpoint.exists(
                           connection: values[index],
                           attemptID: recoveredJournal.currentAttemptID
                       ) {
                        do {
                            try FolderSyncHistoryCheckpoint.restore(
                                connection: values[index],
                                attemptID: recoveredJournal.currentAttemptID
                            )
                            recoveredJournal.historyRestored = true
                        } catch {
                            recoveredJournal.historyRestored = false
                        }
                    } else {
                        recoveredJournal.historyRestored = false
                    }
                    try FolderSyncJournalStore.save(
                        recoveredJournal,
                        connection: values[index]
                    )
                    status = .recoveryRequired
                case .completed:
                    status = nil
                }
                if let status, values[index].status != status {
                    values[index].status = status
                    journalChanged = true
                }
            } catch {
                if values[index].status != .recoveryRequired {
                    values[index].status = .recoveryRequired
                    journalChanged = true
                }
            }
        }

        let hasInterruptedState = values.contains { connection in
            connection.status == .running
                || (!connection.isInitialized && connection.initialSyncStartedAt != nil
                    && connection.status != .recoveryRequired)
        }
        guard hasInterruptedState else {
            if journalChanged { try save(values, url: url) }
            return values
        }

        let operationLock: PhotoArchiveOperationLock
        do {
            operationLock = try PhotoArchiveOperationLock.acquire(catalogURL: catalogURL)
        } catch {
            // Another process still owns the filesystem-operation boundary.
            // Its `running` state is live, not interrupted recovery evidence.
            return values
        }
        defer { operationLock.release() }

        var changed = journalChanged
        for index in values.indices {
            let connection = values[index]
            let staleRunning = connection.status == .running
            let incompleteInitial = !connection.isInitialized
                && connection.initialSyncStartedAt != nil
                && connection.status != .recoveryRequired
            guard staleRunning || incompleteInitial else { continue }
            values[index].status = .recoveryRequired
            changed = true
        }
        if changed {
            try save(values, url: url)
        }
        return values
    }

    public static func save(
        _ connections: [FolderSyncConnection],
        url: URL = defaultURL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            FileContents(schemaVersion: 1, connections: connections)
        )
        try data.write(to: url, options: .atomic)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
    }

    public static func upsert(
        _ connection: FolderSyncConnection,
        url: URL = defaultURL
    ) throws {
        var values = try load(url: url)
        if let index = values.firstIndex(where: { $0.id == connection.id }) {
            values[index] = connection
        } else {
            values.append(connection)
        }
        try save(values, url: url)
    }

    public static func remove(
        connectionID: String,
        url: URL = defaultURL
    ) throws {
        var values = try load(url: url)
        values.removeAll { $0.id == connectionID }
        try save(values, url: url)
    }
}

public enum FolderSyncConnectionManager {
    public static func create(
        rootID: String,
        remoteName: String,
        remoteDisplayName: String? = nil,
        remotePath: String,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL,
        storeURL: URL = FolderSyncConnectionStore.defaultURL,
        stateDirectoryURL: URL = FolderSyncConnectionStore.defaultStateDirectoryURL,
        recoveryDirectoryURL: URL = FolderSyncConnectionStore.defaultRecoveryDirectoryURL
    ) throws -> FolderSyncConnection {
        guard let root = try RootRegistry.list(catalogURL: catalogURL, includeHistory: true)
            .first(where: { $0.rootID == rootID && $0.state != .removed })
        else {
            throw FolderSyncConnectionError.rootNotFound
        }
        guard root.isAvailable else { throw FolderSyncConnectionError.rootUnavailable }
        guard root.usageRole.userPurpose != .readOnly else {
            throw FolderSyncConnectionError.readOnlyRoot
        }
        guard !(try FolderSyncConnectionStore.load(url: storeURL)).contains(where: { $0.rootID == rootID }) else {
            throw FolderSyncConnectionError.connectionAlreadyExists
        }

        let normalizedRemoteName = try validateRemoteName(remoteName)
        let normalizedRemotePath = try normalizeRemotePath(remotePath)
        let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedStateDirectory = stateDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRecoveryDirectory = recoveryDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        guard !pathsOverlap(rootURL, resolvedStateDirectory),
              !pathsOverlap(rootURL, resolvedRecoveryDirectory)
        else {
            throw FolderSyncConnectionError.localStateOverlapsRoot
        }
        let marker = try RootMarkerStore.readIfPresent(at: rootURL) ?? RootMarkerStore.create(at: rootURL)

        let id = "SC" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let workDirectory = stateDirectoryURL
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("bisync", isDirectory: true)
        let localRecovery = recoveryDirectoryURL.appendingPathComponent(id, isDirectory: true)
        let remoteComponents = normalizedRemotePath.split(separator: "/").map(String.init)
        let remoteParent = remoteComponents.dropLast().joined(separator: "/")
        let recoveryRelativePath = ".photoarchivekit-recovery/\(id)"
        let remoteRecovery = remoteParent.isEmpty
            ? recoveryRelativePath
            : "\(remoteParent)/\(recoveryRelativePath)"
        let connection = FolderSyncConnection(
            id: id,
            rootID: rootID,
            rootMarkerKey: marker.markerKey,
            remoteName: normalizedRemoteName,
            remoteDisplayName: remoteDisplayName,
            remotePath: normalizedRemotePath,
            workDirectoryPath: workDirectory.path,
            localRecoveryDirectoryPath: localRecovery.path,
            remoteRecoveryPath: remoteRecovery
        )
        try FolderSyncConnectionStore.upsert(connection, url: storeURL)
        return connection
    }

    public static func verifyLocalRoot(
        _ connection: FolderSyncConnection,
        catalogURL: URL = PhotoArchivePaths.defaultCatalogURL
    ) throws -> RegisteredRootReport {
        guard let root = try RootRegistry.list(catalogURL: catalogURL, includeHistory: true)
            .first(where: { $0.rootID == connection.rootID && $0.state != .removed })
        else {
            throw FolderSyncConnectionError.rootNotFound
        }
        guard root.isAvailable else { throw FolderSyncConnectionError.rootUnavailable }
        guard root.usageRole.userPurpose != .readOnly else {
            throw FolderSyncConnectionError.readOnlyRoot
        }
        let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let marker = try RootMarkerStore.readIfPresent(at: rootURL),
              marker.markerKey == connection.rootMarkerKey
        else {
            throw FolderSyncConnectionError.rootIdentityChanged
        }
        return root
    }

    static func validateRemoteName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              !trimmed.contains(":"),
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw FolderSyncConnectionError.invalidRemoteName
        }
        return trimmed
    }

    package static func normalizeRemotePath(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { throw FolderSyncConnectionError.remoteRootNotAllowed }
        guard !normalized.contains(":"), !normalized.hasPrefix("~") else {
            throw FolderSyncConnectionError.invalidRemotePath
        }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !parts.contains(".photoarchivekit-recovery"),
              normalized.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw FolderSyncConnectionError.invalidRemotePath
        }
        return parts.joined(separator: "/")
    }

    private static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.path.hasSuffix("/") ? lhs.path : lhs.path + "/"
        let right = rhs.path.hasSuffix("/") ? rhs.path : rhs.path + "/"
        return left.hasPrefix(right) || right.hasPrefix(left)
    }
}
