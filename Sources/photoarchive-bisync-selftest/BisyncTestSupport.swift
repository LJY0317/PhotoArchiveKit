import Darwin
import Foundation
import PhotoArchiveCore

struct BisyncSelfTestFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw BisyncSelfTestFailure(message)
    }
}

func executableURL(_ name: String) -> URL? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for directory in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] {
        if FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
    }
    return nil
}

struct BisyncServiceFixture: Sendable {
    let localRoot: URL
    let remoteRoot: URL
    let catalogURL: URL
    let storeURL: URL
    let configURL: URL
    let rcloneURL: URL
    let connection: FolderSyncConnection

    static func make(parentURL: URL, rcloneURL: URL) throws -> BisyncServiceFixture {
        // rclone derives bisync listing filenames from both endpoints. Keep the
        // synthetic paths short so macOS's per-filename limit is not the test.
        let base = parentURL.appendingPathComponent(
            "f-\(UUID().uuidString.prefix(6))",
            isDirectory: true
        )
        let localRoot = base.appendingPathComponent("local", isDirectory: true)
        let remoteBase = base.appendingPathComponent("remote", isDirectory: true)
        let remoteRoot = remoteBase.appendingPathComponent("camera", isDirectory: true)
        let catalogURL = base.appendingPathComponent("catalog.sqlite3")
        let storeURL = base.appendingPathComponent("sync-connections.json")
        let stateURL = base.appendingPathComponent("state", isDirectory: true)
        let recoveryURL = base.appendingPathComponent("recovery", isDirectory: true)
        let configURL = base.appendingPathComponent("rclone.conf")

        for directory in [localRoot, remoteRoot, stateURL, recoveryURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try """
        [synthetic-drive]
        type = alias
        remote = \(remoteBase.path)
        description = Synthetic Google Drive
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let root = try RootRegistry.add(
            url: localRoot,
            kind: .inbox,
            provenance: .localLibrary,
            usageRole: .staging,
            catalogURL: catalogURL
        )
        let connection = try FolderSyncConnectionManager.create(
            rootID: root.rootID,
            remoteName: "synthetic-drive",
            remoteDisplayName: "Synthetic Google Drive",
            remotePath: "camera",
            catalogURL: catalogURL,
            storeURL: storeURL,
            stateDirectoryURL: stateURL,
            recoveryDirectoryURL: recoveryURL
        )
        return BisyncServiceFixture(
            localRoot: localRoot,
            remoteRoot: remoteRoot,
            catalogURL: catalogURL,
            storeURL: storeURL,
            configURL: configURL,
            rcloneURL: rcloneURL,
            connection: connection
        )
    }

    func service(
        allowApply: Bool = true,
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
    ) -> RcloneBisyncService {
        RcloneBisyncService(
            syntheticTestingExecutableURL: rcloneURL,
            environment: ["RCLONE_CONFIG": configURL.path],
            remoteTypeFilter: "alias",
            allowBisyncApply: allowApply,
            additionalApplyArguments: additionalApplyArguments,
            afterPreflight: afterPreflight,
            beforeLocalDestinationSwap: beforeLocalDestinationSwap,
            afterLocalDestinationSwap: afterLocalDestinationSwap,
            testingLocalSwapErrorCode: testingLocalSwapErrorCode,
            testingMetrics: testingMetrics,
            testingLocalRecoveryFreeBytes: testingLocalRecoveryFreeBytes,
            testingRemoteRecoveryFreeBytes: testingRemoteRecoveryFreeBytes,
            testingLocalRecoveryTrashDirectory: testingLocalRecoveryTrashDirectory,
            testingDriveRevisionManager: testingDriveRevisionManager,
            testingUseDriveRevisionProtection: testingUseDriveRevisionProtection,
            testingUseProtectedDirectHistoryReconcile: testingUseProtectedDirectHistoryReconcile,
            afterDriveRevisionPinnedBeforeJournal: afterDriveRevisionPinnedBeforeJournal,
            afterDriveBaselineHeadVerifiedBeforeRevisionList: afterDriveBaselineHeadVerifiedBeforeRevisionList,
            afterDriveEmptyObjectJournaledBeforeUpload: afterDriveEmptyObjectJournaledBeforeUpload,
            beforeDriveApply: beforeDriveApply,
            afterDriveApplyBeforeJournal: afterDriveApplyBeforeJournal,
            beforeDriveMutation: beforeDriveMutation,
            afterConflictResolutionStep: afterConflictResolutionStep
        )
    }

    func savedConnection() throws -> FolderSyncConnection {
        guard let value = try FolderSyncConnectionStore.load(url: storeURL)
            .first(where: { $0.id == connection.id })
        else {
            throw BisyncSelfTestFailure("synthetic sync connection state is missing")
        }
        return value
    }
}

actor BisyncHookGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

func initialize(_ fixture: BisyncServiceFixture) async throws -> FolderSyncConnection {
    try await fixture.service().synchronize(
        connection: fixture.connection,
        confirmInitialSync: true,
        catalogURL: fixture.catalogURL,
        storeURL: fixture.storeURL
    ).connection
}

func requireLivePhotoBlock(
    fixture: BisyncServiceFixture,
    connection: FolderSyncConnection
) async throws {
    do {
        _ = try await fixture.service().synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        throw BisyncSelfTestFailure("actual Live Photo metadata change should be blocked before bisync apply")
    } catch FolderSyncConnectionError.livePhotoMutationBlocked {
        try require(
            try fixture.savedConnection().status == .livePhotoBlocked,
            "Live Photo safety rejection should persist a distinct blocked state"
        )
    } catch {
        if let journal = try? FolderSyncJournalStore.load(connection: connection) {
            print("--- synthetic journal ---")
            print("phase=\(journal.phase.rawValue) unplanned=\(journal.unplannedObservedPaths)")
            for item in journal.items {
                let resources = item.resources
                    .map { "\($0.role.rawValue):\($0.relativePath)" }
                    .joined(separator: ",")
                print("item state=\(item.state.rawValue) note=\(item.note ?? "nil") resources=[\(resources)]")
            }
        }
        printSyntheticRunLogs(workDirectoryPath: fixture.connection.workDirectoryPath)
        throw error
    }
}

func requireConfirmationRequired(
    fixture: BisyncServiceFixture,
    connection: FolderSyncConnection
) async throws {
    do {
        _ = try await fixture.service().synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        throw BisyncSelfTestFailure("ambiguous Live Photo change must require confirmation before apply")
    } catch FolderSyncConnectionError.confirmationRequired {
        try require(
            try fixture.savedConnection().status == .confirmationRequired,
            "ambiguous Live Photo change should persist confirmation-required"
        )
        let journal = try FolderSyncJournalStore.load(connection: connection)
        try require(
            journal?.phase == .confirmationRequired
                && (journal?.incompleteItemCount ?? 0) > 0,
            "confirmation-required Live Photo work must remain journaled"
        )
    } catch {
        printSyntheticRunLogs(workDirectoryPath: fixture.connection.workDirectoryPath)
        throw error
    }
}

func seedLivePair(_ fixture: BisyncServiceFixture, identifier: String) async throws {
    let still = fixture.localRoot.appendingPathComponent("IMG_0001.JPG")
    let movie = fixture.localRoot.appendingPathComponent("IMG_0001.MOV")
    try writeSyntheticJPEG(to: still, contentIdentifier: identifier, pixelValue: 100)
    try await writeSyntheticTimedMetadataMovie(
        to: movie,
        markerValues: [0],
        contentIdentifier: identifier
    )
    try copyReplacing(still, to: fixture.remoteRoot.appendingPathComponent("IMG_0001.JPG"))
    try copyReplacing(movie, to: fixture.remoteRoot.appendingPathComponent("IMG_0001.MOV"))

    // Keep one deletion below the service's 25% bulk-delete guard so this
    // fixture reaches the Live Photo safety gate instead of stopping earlier.
    for index in 0..<4 {
        let name = "anchor-\(index).txt"
        let local = fixture.localRoot.appendingPathComponent(name)
        try Data("anchor-\(index)".utf8).write(to: local)
        try copyReplacing(local, to: fixture.remoteRoot.appendingPathComponent(name))
    }
}

func copyReplacing(_ source: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: source, to: destination)
}

func visibleUserFiles(in root: URL) throws -> [URL] {
    let accessPrefix = RcloneBisyncService.accessFilePrefix
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return try enumerator.compactMap { item -> URL? in
        guard let url = item as? URL,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              !url.lastPathComponent.hasPrefix(accessPrefix),
              url.lastPathComponent != RootMarkerStore.fileName
        else { return nil }
        return url
    }
}

func recursiveRegularFiles(in root: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: root.path),
          let enumerator = FileManager.default.enumerator(
              at: root,
              includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
              options: [.skipsHiddenFiles]
          )
    else { return [] }
    return try enumerator.compactMap { item -> URL? in
        guard let url = item as? URL else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true ? url : nil
    }
}

func fileInode(_ url: URL) throws -> UInt64 {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
        throw BisyncSelfTestFailure("could not stat synthetic file: \(url.lastPathComponent)")
    }
    return UInt64(info.st_ino)
}

func persistedRawSyncStatus(url: URL) throws -> String? {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let dictionary = object as? [String: Any],
          let connections = dictionary["connections"] as? [[String: Any]]
    else { return nil }
    return connections.first?["status"] as? String
}

func printSyntheticRunLogs(workDirectoryPath: String) {
    let root = URL(fileURLWithPath: workDirectoryPath, isDirectory: true)
        .appendingPathComponent("runs", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        return
    }
    for case let url as URL in enumerator {
        guard (url.pathExtension == "jsonl" || url.pathExtension == "stdout"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty
        else { continue }
        print("--- synthetic log \(url.lastPathComponent) ---")
        print(text)
    }
}
