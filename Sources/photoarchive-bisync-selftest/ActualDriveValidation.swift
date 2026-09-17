import CryptoKit
import Darwin
import Foundation
import PhotoArchiveCore

private struct ActualRcloneEntry: Decodable {
    let Path: String?
    let Name: String?
    let ID: String?
    let IsDir: Bool?
}

private struct ActualProcessResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

private final class ActualWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var errorMessage: String?
    private var didFinish = false

    func start(_ work: @escaping @Sendable () throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work()
            } catch {
                self.lock.lock()
                self.errorMessage = error.localizedDescription
                self.lock.unlock()
            }
            self.lock.lock()
            self.didFinish = true
            self.lock.unlock()
            self.finished.signal()
        }
    }

    func wait(seconds: Double) throws {
        guard finished.wait(timeout: .now() + seconds) == .success else {
            throw BisyncSelfTestFailure("actual Drive concurrent-writer watcher timed out")
        }
        lock.lock()
        let message = errorMessage
        let done = didFinish
        lock.unlock()
        guard done else { throw BisyncSelfTestFailure("actual Drive watcher did not finish") }
        if let message { throw BisyncSelfTestFailure(message) }
    }
}

private struct ActualDriveFixture: Sendable {
    let base: URL
    let localRoot: URL
    let catalogURL: URL
    let storeURL: URL
    let rcloneURL: URL
    let remotePath: String
    let connection: FolderSyncConnection

    static func make(
        parent: URL,
        rcloneURL: URL,
        remotePath: String
    ) throws -> ActualDriveFixture {
        let base = parent.appendingPathComponent(
            "fixture-" + UUID().uuidString.prefix(8),
            isDirectory: true
        )
        let localRoot = base.appendingPathComponent("local", isDirectory: true)
        let catalogURL = base.appendingPathComponent("catalog.sqlite3")
        let storeURL = base.appendingPathComponent("sync-connections.json")
        let stateURL = base.appendingPathComponent("state", isDirectory: true)
        let recoveryURL = base.appendingPathComponent("recovery", isDirectory: true)
        for directory in [base, localRoot, stateURL, recoveryURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let mkdir = try ActualDriveValidation.runRclone(
            rcloneURL,
            ["mkdir", "gdrive:\(remotePath)"]
        )
        guard mkdir.exitCode == 0 else {
            throw BisyncSelfTestFailure("could not create the authorized synthetic Drive target")
        }
        let root = try RootRegistry.add(
            url: localRoot,
            kind: .inbox,
            provenance: .localLibrary,
            usageRole: .staging,
            catalogURL: catalogURL
        )
        let connection = try FolderSyncConnectionManager.create(
            rootID: root.rootID,
            remoteName: "gdrive",
            remoteDisplayName: "Synthetic implementation validation",
            remotePath: remotePath,
            catalogURL: catalogURL,
            storeURL: storeURL,
            stateDirectoryURL: stateURL,
            recoveryDirectoryURL: recoveryURL
        )
        return ActualDriveFixture(
            base: base,
            localRoot: localRoot,
            catalogURL: catalogURL,
            storeURL: storeURL,
            rcloneURL: rcloneURL,
            remotePath: remotePath,
            connection: connection
        )
    }

    func service(
        additionalApplyArguments: [String] = [],
        afterPreflight: (@Sendable () async throws -> Void)? = nil,
        afterDriveRevisionPinnedBeforeJournal: (@Sendable (String) throws -> Void)? = nil,
        beforeDriveApply: (@Sendable () throws -> Void)? = nil,
        afterDriveApplyBeforeJournal: (@Sendable () throws -> Void)? = nil,
        beforeDriveMutation: (@Sendable (FolderSyncDriveMutationKind, String, String) throws -> Void)? = nil,
        afterConflictResolutionStep: (@Sendable (String) throws -> Void)? = nil
    ) -> RcloneBisyncService {
        RcloneBisyncService(
            syntheticTestingExecutableURL: rcloneURL,
            remoteTypeFilter: "drive",
            allowBisyncApply: true,
            additionalApplyArguments: additionalApplyArguments,
            afterPreflight: afterPreflight,
            afterDriveRevisionPinnedBeforeJournal: afterDriveRevisionPinnedBeforeJournal,
            beforeDriveApply: beforeDriveApply,
            afterDriveApplyBeforeJournal: afterDriveApplyBeforeJournal,
            beforeDriveMutation: beforeDriveMutation,
            afterConflictResolutionStep: afterConflictResolutionStep
        )
    }

    func productionService() -> RcloneBisyncService {
        // Deliberately use the public initializer here. This catches a
        // production policy regression that synthetic-test injection would
        // otherwise bypass.
        RcloneBisyncService()
    }
}

enum ActualDriveValidation {
    static let allowedScopePath = "PhotoArchiveKit-DriveSync-Test-20260913-132926-B384774308/scope"
    static let allowedScopeFolderID = "172nn2K9gOF_nM2lhcdEV97qBw2joOj2O"

    static func run(arguments: [String]) async throws {
        if arguments.count == 2, arguments[1] == "live-photo-only" {
            try await runLivePhotoOnly(evidencePath: arguments[0])
            return
        }
        if arguments.count == 2, arguments[1] == "conflict-restart-only" {
            try await runConflictRestartOnly(evidencePath: arguments[0])
            return
        }
        guard arguments.count == 1 else {
            throw BisyncSelfTestFailure("actual Drive validation arguments are incomplete")
        }
        let scopePath = allowedScopePath
        let scopeFolderID = allowedScopeFolderID
        let evidenceURL = URL(fileURLWithPath: arguments[0], isDirectory: true)
        guard let rcloneURL = executableURL("rclone") else {
            throw BisyncSelfTestFailure("rclone is required for actual Drive validation")
        }
        try FileManager.default.createDirectory(at: evidenceURL, withIntermediateDirectories: true)
        try verifyAllowedScope(rcloneURL: rcloneURL, scopePath: scopePath, folderID: scopeFolderID)

        let runName = "i-" + runIdentifier()
        let runRoot = scopePath + "/" + runName
        let localRoot = URL(
            fileURLWithPath: "/tmp/pakd-" + String(UUID().uuidString.prefix(6)),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        let create = try runRclone(rcloneURL, ["mkdir", "gdrive:\(runRoot)"])
        guard create.exitCode == 0 else {
            throw BisyncSelfTestFailure("could not create the implementation validation folder")
        }

        var results: [String: String] = [
            "approved_scope_path": scopePath,
            "approved_scope_folder_id": scopeFolderID,
            "run_remote_path": "gdrive:" + runRoot,
            "production_apply_available": RcloneBisyncService.productionApplyAvailable.description
        ]
        results["basic_overwrite_restore"] = try await basicOverwriteAndRestore(
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot + "/basic"
        )
        results["ordinary_create_move_delete"] = try await ordinaryCreateMoveAndDelete(
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot + "/ordinary-file-lifecycle"
        )
        results["live_photo_still_overwrite"] = try await livePhotoStillOverwrite(
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot + "/live-photo-overwrite"
        )
        results["external_before"] = try await externalBefore(
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot + "/external-before"
        )
        results["external_after"] = try await externalAfter(
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot + "/external-after"
        )
        results["external_during"] = try await externalDuring(
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot + "/external-during"
        )
        results["recovery_trashed"] = try await recoveryTrashed(
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot + "/recovery-trashed"
        )
        results["pin_crash_restart"] = try await crashRestart(
            phase: "pin",
            expectedExit: 87,
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot + "/crash-pin"
        )
        results["upload_crash_restart"] = try await crashRestart(
            phase: "upload",
            expectedExit: 88,
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot + "/crash-upload"
        )

        let data = try JSONSerialization.data(
            withJSONObject: results,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let summaryURL = evidenceURL.appendingPathComponent(
            "actual-drive-implementation-validation.json",
            isDirectory: false
        )
        try data.write(to: summaryURL, options: .atomic)
        print("actual-drive-validation: passed")
        print("actual-drive-validation: remote=\(results["run_remote_path"] ?? "")")
        print("actual-drive-validation: evidence=\(summaryURL.path)")
    }

    /// A focused rerun for a newly added Live Photo scenario. It deliberately
    /// avoids repeating the long overwrite/crash suite once that suite has
    /// already passed unchanged.
    private static func runLivePhotoOnly(evidencePath: String) async throws {
        let evidenceURL = URL(fileURLWithPath: evidencePath, isDirectory: true)
        guard let rcloneURL = executableURL("rclone") else {
            throw BisyncSelfTestFailure("rclone is required for actual Drive validation")
        }
        try FileManager.default.createDirectory(at: evidenceURL, withIntermediateDirectories: true)
        try verifyAllowedScope(
            rcloneURL: rcloneURL,
            scopePath: allowedScopePath,
            folderID: allowedScopeFolderID
        )
        let runRoot = allowedScopePath + "/live-" + runIdentifier()
        let localRoot = URL(
            fileURLWithPath: "/tmp/pakd-live-" + String(UUID().uuidString.prefix(6)),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        let create = try runRclone(rcloneURL, ["mkdir", "gdrive:\(runRoot)"])
        guard create.exitCode == 0 else {
            throw BisyncSelfTestFailure("could not create the focused Live Photo validation folder")
        }
        let result = try await livePhotoStillOverwrite(
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot
        )
        let productionResult = try await productionManualExecution(
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot + "/production-manual"
        )
        let values: [String: String] = [
            "approved_scope_path": allowedScopePath,
            "approved_scope_folder_id": allowedScopeFolderID,
            "run_remote_path": "gdrive:" + runRoot,
            "live_photo_still_overwrite": result,
            "production_manual_execution": productionResult
        ]
        let data = try JSONSerialization.data(
            withJSONObject: values,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let summaryURL = evidenceURL.appendingPathComponent(
            "actual-drive-live-photo-validation.json",
            isDirectory: false
        )
        try data.write(to: summaryURL, options: .atomic)
        print("actual-drive-live-photo-validation: passed")
        print("actual-drive-live-photo-validation: remote=\(values["run_remote_path"] ?? "")")
        print("actual-drive-live-photo-validation: evidence=\(summaryURL.path)")
    }

    /// Focused actual-Drive coverage for conflict-resolution persistence and
    /// child-process restart. This deliberately avoids rerunning the broader
    /// Drive mutation suite whose evidence is unchanged.
    private static func runConflictRestartOnly(evidencePath: String) async throws {
        let evidenceURL = URL(fileURLWithPath: evidencePath, isDirectory: true)
        guard let rcloneURL = executableURL("rclone") else {
            throw BisyncSelfTestFailure("rclone is required for actual Drive validation")
        }
        try FileManager.default.createDirectory(at: evidenceURL, withIntermediateDirectories: true)
        try verifyAllowedScope(
            rcloneURL: rcloneURL,
            scopePath: allowedScopePath,
            folderID: allowedScopeFolderID
        )
        let runRoot = allowedScopePath + "/conflict-" + runIdentifier()
        let localRoot = URL(
            fileURLWithPath: "/tmp/pakd-conflict-" + String(UUID().uuidString.prefix(6)),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        let create = try runRclone(rcloneURL, ["mkdir", "gdrive:\(runRoot)"])
        guard create.exitCode == 0 else {
            throw BisyncSelfTestFailure("could not create the focused conflict-restart validation folder")
        }
        let staleResult = try await conflictTargetChangeInvalidatesApproval(
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot + "/stale-approval"
        )
        let result = try await conflictCrashRestart(
            parent: localRoot,
            rcloneURL: rcloneURL,
            remotePath: runRoot + "/live-photo-restart"
        )
        let values: [String: String] = [
            "approved_scope_path": allowedScopePath,
            "approved_scope_folder_id": allowedScopeFolderID,
            "run_remote_path": "gdrive:" + runRoot,
            "conflict_stale_approval": staleResult,
            "conflict_keep_both_live_photo_crash_restart": result,
            "production_apply_available": RcloneBisyncService.productionApplyAvailable.description
        ]
        let data = try JSONSerialization.data(
            withJSONObject: values,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let summaryURL = evidenceURL.appendingPathComponent(
            "actual-drive-conflict-restart-validation.json",
            isDirectory: false
        )
        try data.write(to: summaryURL, options: .atomic)
        print("actual-drive-conflict-restart-validation: passed")
        print("actual-drive-conflict-restart-validation: remote=\(values["run_remote_path"] ?? "")")
        print("actual-drive-conflict-restart-validation: evidence=\(summaryURL.path)")
    }

    static func runCrashWorker(arguments: [String]) async throws {
        guard arguments.count == 6 else {
            throw BisyncSelfTestFailure("Drive crash worker arguments are incomplete")
        }
        let phase = arguments[0]
        let catalogURL = URL(fileURLWithPath: arguments[1])
        let storeURL = URL(fileURLWithPath: arguments[2])
        let rcloneURL = URL(fileURLWithPath: arguments[3])
        let connectionID = arguments[4]
        let expectedPath = arguments[5]
        guard let connection = try FolderSyncConnectionStore.load(url: storeURL)
            .first(where: { $0.id == connectionID }),
              connection.remoteName == "gdrive",
              connection.remotePath.hasPrefix(allowedScopePath + "/") else {
            throw BisyncSelfTestFailure("Drive crash worker connection is outside the approved scope")
        }
        let pinCrash: (@Sendable (String) throws -> Void)?
        if phase == "pin" {
            pinCrash = { @Sendable path in
                guard path == expectedPath else { return }
                _exit(87)
            }
        } else {
            pinCrash = nil
        }
        let uploadCrash: (@Sendable () throws -> Void)?
        if phase == "upload" {
            uploadCrash = { @Sendable in
                _exit(88)
            }
        } else {
            uploadCrash = nil
        }
        let service = RcloneBisyncService(
            syntheticTestingExecutableURL: rcloneURL,
            remoteTypeFilter: "drive",
            allowBisyncApply: true,
            afterDriveRevisionPinnedBeforeJournal: pinCrash,
            afterDriveApplyBeforeJournal: uploadCrash
        )
        _ = try await service.synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: catalogURL,
            storeURL: storeURL
        )
        throw BisyncSelfTestFailure("Drive crash worker did not reach the requested crash boundary")
    }

    static func runConflictCrashWorker(arguments: [String]) async throws {
        guard arguments.count == 7 else {
            throw BisyncSelfTestFailure("Drive conflict crash worker arguments are incomplete")
        }
        let catalogURL = URL(fileURLWithPath: arguments[0])
        let storeURL = URL(fileURLWithPath: arguments[1])
        let rcloneURL = URL(fileURLWithPath: arguments[2])
        let connectionID = arguments[3]
        let itemID = arguments[4]
        let expectedFingerprint = arguments[5]
        let crashAfterPath = arguments[6]
        guard let connection = try FolderSyncConnectionStore.load(url: storeURL)
            .first(where: { $0.id == connectionID }),
              connection.remoteName == "gdrive",
              connection.remotePath.hasPrefix(allowedScopePath + "/") else {
            throw BisyncSelfTestFailure("Drive conflict crash worker connection is outside the approved scope")
        }
        let service = RcloneBisyncService(
            syntheticTestingExecutableURL: rcloneURL,
            remoteTypeFilter: "drive",
            allowBisyncApply: true,
            afterConflictResolutionStep: { @Sendable step in
                guard step == "applied:" + crashAfterPath else { return }
                _exit(89)
            }
        )
        try await service.resolveConflict(
            connection: connection,
            itemID: itemID,
            choice: .keepBoth,
            expectedFingerprint: expectedFingerprint,
            catalogURL: catalogURL,
            storeURL: storeURL
        )
        throw BisyncSelfTestFailure("Drive conflict crash worker did not reach the requested crash boundary")
    }

    private static func fixtureWithBaseline(
        parent: URL,
        rcloneURL: URL,
        remotePath: String,
        fileName: String,
        baseline: Data
    ) async throws -> (ActualDriveFixture, FolderSyncConnection, URL) {
        let fixture = try ActualDriveFixture.make(
            parent: parent,
            rcloneURL: rcloneURL,
            remotePath: remotePath
        )
        let local = fixture.localRoot.appendingPathComponent(fileName)
        try baseline.write(to: local, options: .atomic)
        let initialized = try await fixture.service().synchronize(
            connection: fixture.connection,
            confirmInitialSync: true,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        ).connection
        return (fixture, initialized, local)
    }

    private static func basicOverwriteAndRestore(
        parent: URL,
        rcloneURL: URL,
        remotePath: String
    ) async throws -> String {
        let fileName = "basic-overwrite.bin"
        let baseline = Data("ACTUAL-BASELINE-basic-v1\n".utf8)
        let app = Data(repeating: 0x41, count: 256 * 1024)
        let (fixture, connection, local) = try await fixtureWithBaseline(
            parent: parent,
            rcloneURL: rcloneURL,
            remotePath: remotePath,
            fileName: fileName,
            baseline: baseline
        )
        try app.write(to: local, options: .atomic)
        let report = try await fixture.service().synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(report.connection.status == .success, "actual Drive overwrite should succeed")
        let items = try fixture.service().recoveryItems(connection: report.connection)
            .filter { $0.location == .googleDrive && $0.originalRelativePath == fileName }
        let baselineHash = sha256(baseline)
        let appHash = sha256(app)
        guard let baselineItem = items.first(where: { $0.expectedSHA256 == baselineHash }),
              items.contains(where: { $0.expectedSHA256 == appHash }) else {
            throw BisyncSelfTestFailure("actual overwrite did not expose pinned baseline and app revisions")
        }

        let movedName = "basic-app-version-kept.bin"
        let move = try runRclone(rcloneURL, [
            "moveto",
            "gdrive:\(remotePath)/\(fileName)",
            "gdrive:\(remotePath)/\(movedName)",
            "--drive-skip-gdocs"
        ])
        guard move.exitCode == 0 else {
            throw BisyncSelfTestFailure("actual app version could not be moved aside before revision restore")
        }
        try fixture.service().restoreRecoveryItem(
            baselineItem,
            connection: report.connection,
            catalogURL: fixture.catalogURL
        )
        let restored = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(fileName)",
            to: fixture.base.appendingPathComponent("restored-basic.bin")
        )
        let keptApp = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(movedName)",
            to: fixture.base.appendingPathComponent("kept-app-basic.bin")
        )
        try require(restored == baseline && keptApp == app, "actual revision restore bytes must match exactly")
        return "success: pinned baseline+app and exact baseline revision restored"
    }

    /// Exercises the normal, non-conflicting file lifecycle against the real
    /// Drive backend.  These paths are deliberately separate from overwrite
    /// protection: a new file, a move, and a one-sided delete must all remain
    /// usable without treating the change as a same-path overwrite.
    private static func ordinaryCreateMoveAndDelete(
        parent: URL,
        rcloneURL: URL,
        remotePath: String
    ) async throws -> String {
        let anchorName = "anchor.bin"
        let anchor = Data("ACTUAL-ORDINARY-ANCHOR-v1\n".utf8)
        let (fixture, connection, _) = try await fixtureWithBaseline(
            parent: parent,
            rcloneURL: rcloneURL,
            remotePath: remotePath,
            fileName: anchorName,
            baseline: anchor
        )

        let createdName = "created-local.bin"
        let createdBytes = Data("ACTUAL-CREATED-LOCAL-v1\n".utf8)
        let createdLocal = fixture.localRoot.appendingPathComponent(createdName)
        try createdBytes.write(to: createdLocal, options: .atomic)
        _ = try await fixture.service().synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        let createdRemote = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(createdName)",
            to: fixture.base.appendingPathComponent("ordinary-created-remote.bin")
        )
        try require(createdRemote == createdBytes, "actual Drive must receive a newly created local file")

        let movedRelativePath = "album/moved-local.bin"
        let movedLocal = fixture.localRoot.appendingPathComponent(movedRelativePath)
        try FileManager.default.createDirectory(
            at: movedLocal.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: createdLocal, to: movedLocal)
        _ = try await fixture.service().synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        let movedRemote = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(movedRelativePath)",
            to: fixture.base.appendingPathComponent("ordinary-moved-remote.bin")
        )
        try require(movedRemote == createdBytes, "actual Drive must receive a local rename or move")
        let oldRemote = try runRclone(rcloneURL, [
            "lsjson", "gdrive:\(remotePath)/\(createdName)", "--stat", "--drive-skip-gdocs"
        ])
        try require(oldRemote.exitCode != 0, "actual Drive must not retain the old path after a move")

        try FileManager.default.removeItem(at: movedLocal)
        let deletionReport: FolderSyncRunReport
        do {
            deletionReport = try await fixture.service().synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
        } catch FolderSyncConnectionError.confirmationRequired {
            // Removing the only file from `album` empties a directory that
            // previously held content. The product policy requires an
            // explicit approval for that deletion plan, so validate the same
            // replay that the consumer UI will perform.
            guard let plan = try FolderSyncJournalStore.load(connection: connection)?.pendingDeletionPlan,
                  plan.requiresConfirmation else {
                throw BisyncSelfTestFailure("actual Drive deletion did not persist its approval plan")
            }
            deletionReport = try await fixture.service().synchronize(
                connection: connection,
                confirmInitialSync: false,
                approvedDeletionPlanID: plan.id,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
        }
        let deletedRemote = try runRclone(rcloneURL, [
            "lsjson", "gdrive:\(remotePath)/\(movedRelativePath)", "--stat", "--drive-skip-gdocs"
        ])
        try require(deletedRemote.exitCode != 0, "actual Drive must apply a one-sided local deletion")
        let deletionRecovery = try fixture.service().recoveryItems(connection: deletionReport.connection)
        try require(
            deletionRecovery.contains(where: {
                $0.location == .googleDrive && $0.originalRelativePath == movedRelativePath
            }),
            "actual Drive deletion must retain a recoverable destination copy"
        )

        let remoteCreatedName = "created-remote.bin"
        let remoteCreatedBytes = Data("ACTUAL-CREATED-REMOTE-v1\n".utf8)
        let remoteSource = fixture.base.appendingPathComponent("ordinary-remote-source.bin")
        try remoteCreatedBytes.write(to: remoteSource, options: .atomic)
        let upload = try runRclone(rcloneURL, [
            "copyto", remoteSource.path, "gdrive:\(remotePath)/\(remoteCreatedName)", "--drive-skip-gdocs"
        ])
        guard upload.exitCode == 0 else {
            throw BisyncSelfTestFailure("could not create a synthetic remote-only file")
        }
        _ = try await fixture.service().synchronize(
            connection: deletionReport.connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        let downloadedLocal = fixture.localRoot.appendingPathComponent(remoteCreatedName)
        try require(
            FileManager.default.fileExists(atPath: downloadedLocal.path)
                && Data(contentsOf: downloadedLocal) == remoteCreatedBytes,
            "actual Drive must create a new local copy for a remote-only file"
        )
        return "success: local create/move/delete and remote create completed with recovery"
    }

    /// Live Photos are logical pairs, but a valid still-image update may be
    /// synchronized while its already-verified paired video remains intact.
    /// The Drive destination must still pin both the old and app still
    /// revisions before reporting the pair complete.
    private static func livePhotoStillOverwrite(
        parent: URL,
        rcloneURL: URL,
        remotePath: String
    ) async throws -> String {
        let fixture = try ActualDriveFixture.make(
            parent: parent,
            rcloneURL: rcloneURL,
            remotePath: remotePath
        )
        let identifier = "ACTUAL-LIVE-OVERWRITE"
        let stillName = "IMG_0001.JPG"
        let movieName = "IMG_0001.MOV"
        let still = fixture.localRoot.appendingPathComponent(stillName)
        let movie = fixture.localRoot.appendingPathComponent(movieName)
        try writeSyntheticJPEG(to: still, contentIdentifier: identifier, pixelValue: 80)
        try await writeSyntheticTimedMetadataMovie(
            to: movie,
            markerValues: [0],
            contentIdentifier: identifier
        )
        let baselineStill = try Data(contentsOf: still)
        let initialized = try await fixture.service().synchronize(
            connection: fixture.connection,
            confirmInitialSync: true,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        ).connection

        try writeSyntheticJPEGReplacing(
            still,
            contentIdentifier: identifier,
            pixelValue: 180
        )
        let appStill = try Data(contentsOf: still)
        let report = try await fixture.service().synchronize(
            connection: initialized,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(
            report.connection.status == .success,
            "actual Drive Live Photo still update must finish as a complete logical item"
        )
        let remoteStill = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(stillName)",
            to: fixture.base.appendingPathComponent("live-photo-remote-still.jpg")
        )
        let remoteMovie = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(movieName)",
            to: fixture.base.appendingPathComponent("live-photo-remote-movie.mov")
        )
        try require(
            remoteStill == appStill && remoteMovie == Data(contentsOf: movie),
            "actual Drive Live Photo pair must contain the updated still and the intact paired video"
        )
        let recovery = try fixture.service().recoveryItems(connection: report.connection)
            .filter { $0.location == .googleDrive && $0.originalRelativePath == stillName }
        try require(
            recovery.contains(where: { $0.expectedSHA256 == sha256(baselineStill) })
                && recovery.contains(where: { $0.expectedSHA256 == sha256(appStill) }),
            "actual Drive Live Photo still overwrite must retain pinned baseline and app revisions"
        )
        return "success: Live Photo still overwrite retained exact revisions and pair verification"
    }

    private static func productionManualExecution(
        parent: URL,
        rcloneURL: URL,
        remotePath: String
    ) async throws -> String {
        guard RcloneBisyncService.productionApplyAvailable else {
            throw BisyncSelfTestFailure("production sync gate is not enabled")
        }
        let fixture = try ActualDriveFixture.make(
            parent: parent,
            rcloneURL: rcloneURL,
            remotePath: remotePath
        )
        let name = "manual-production.bin"
        let baseline = Data("ACTUAL-PRODUCTION-MANUAL-v1\n".utf8)
        try baseline.write(to: fixture.localRoot.appendingPathComponent(name), options: .atomic)
        let initialized = try await fixture.productionService().synchronize(
            connection: fixture.connection,
            confirmInitialSync: true,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        ).connection
        let changed = Data("ACTUAL-PRODUCTION-MANUAL-v2\n".utf8)
        try changed.write(to: fixture.localRoot.appendingPathComponent(name), options: .atomic)
        let report = try await fixture.productionService().synchronize(
            connection: initialized,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(
            report.connection.status == .success,
            "public production service must complete a manual Drive sync"
        )
        let remote = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(name)",
            to: fixture.base.appendingPathComponent("production-manual-remote.bin")
        )
        try require(remote == changed, "public production service must write the current local version")
        return "success: public manual service initialized and updated a synthetic Drive file"
    }

    private static func externalBefore(
        parent: URL,
        rcloneURL: URL,
        remotePath: String
    ) async throws -> String {
        let fileName = "external-before.bin"
        let baseline = Data("ACTUAL-BASELINE-before-v1\n".utf8)
        let app = Data("ACTUAL-APP-before-v2\n".utf8)
        let external = Data("ACTUAL-EXTERNAL-before-v3\n".utf8)
        let (fixture, connection, local) = try await fixtureWithBaseline(
            parent: parent,
            rcloneURL: rcloneURL,
            remotePath: remotePath,
            fileName: fileName,
            baseline: baseline
        )
        try app.write(to: local, options: .atomic)
        let externalURL = fixture.base.appendingPathComponent("external-before-source.bin")
        try external.write(to: externalURL, options: .atomic)
        let service = fixture.service(afterPreflight: {
            let result = try runRclone(rcloneURL, [
                "copyto", externalURL.path,
                "gdrive:\(remotePath)/\(fileName)",
                "--drive-skip-gdocs"
            ])
            guard result.exitCode == 0 else {
                throw BisyncSelfTestFailure("external-before writer failed")
            }
        })
        do {
            _ = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("actual external-before race must require confirmation")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        let items = try service.recoveryItems(connection: connection)
            .filter { $0.location == .googleDrive && $0.originalRelativePath == fileName }
        try require(
            items.contains(where: { $0.expectedSHA256 == sha256(baseline) })
                && items.contains(where: { $0.expectedSHA256 == sha256(external) }),
            "actual external-before must pin both preflight baseline and observed external head"
        )
        let current = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(fileName)",
            to: fixture.base.appendingPathComponent("external-before-current.bin")
        )
        try require(current == external, "actual external-before destination must not be overwritten")
        return "confirmation: baseline and external head pinned"
    }

    private static func externalAfter(
        parent: URL,
        rcloneURL: URL,
        remotePath: String
    ) async throws -> String {
        let fileName = "external-after.bin"
        let baseline = Data("ACTUAL-BASELINE-after-v1\n".utf8)
        let app = Data(repeating: 0x52, count: 384 * 1024)
        let external = Data("ACTUAL-EXTERNAL-after-v3\n".utf8)
        let (fixture, connection, local) = try await fixtureWithBaseline(
            parent: parent,
            rcloneURL: rcloneURL,
            remotePath: remotePath,
            fileName: fileName,
            baseline: baseline
        )
        try app.write(to: local, options: .atomic)
        let externalURL = fixture.base.appendingPathComponent("external-after-source.bin")
        try external.write(to: externalURL, options: .atomic)
        let service = fixture.service(afterDriveApplyBeforeJournal: {
            let result = try runRclone(rcloneURL, [
                "copyto", externalURL.path,
                "gdrive:\(remotePath)/\(fileName)",
                "--drive-skip-gdocs"
            ])
            guard result.exitCode == 0 else {
                throw BisyncSelfTestFailure("external-after writer failed")
            }
        })
        let report = try await service.synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(report.connection.status == .conflict, "actual external-after must surface a conflict")
        let items = try service.recoveryItems(connection: report.connection)
            .filter { $0.location == .googleDrive && $0.originalRelativePath == fileName }
        guard let appItem = items.first(where: { $0.expectedSHA256 == sha256(app) }) else {
            throw BisyncSelfTestFailure("actual external-after lost the pinned app revision")
        }
        try require(
            items.contains(where: { $0.expectedSHA256 == sha256(baseline) })
                && items.contains(where: { $0.expectedSHA256 == sha256(external) }),
            "actual external-after must retain baseline and observed external head"
        )

        let move = try runRclone(rcloneURL, [
            "moveto", "gdrive:\(remotePath)/\(fileName)",
            "gdrive:\(remotePath)/external-after-current-kept.bin",
            "--drive-skip-gdocs"
        ])
        guard move.exitCode == 0 else { throw BisyncSelfTestFailure("could not move external-after current head") }
        try service.restoreRecoveryItem(
            appItem,
            connection: report.connection,
            catalogURL: fixture.catalogURL
        )
        let restoredApp = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(fileName)",
            to: fixture.base.appendingPathComponent("external-after-restored-app.bin")
        )
        try require(restoredApp == app, "historical pinned app revision restore must match actual bytes")
        return "conflict: baseline+app+external pinned; app historical revision restored"
    }

    private static func externalDuring(
        parent: URL,
        rcloneURL: URL,
        remotePath: String
    ) async throws -> String {
        let fileName = "external-during.bin"
        let baseline = Data("ACTUAL-BASELINE-during-v1\n".utf8)
        let app = Data(repeating: 0x63, count: 4 * 1024 * 1024)
        let external = Data("ACTUAL-EXTERNAL-during-v3\n".utf8)
        let (fixture, connection, local) = try await fixtureWithBaseline(
            parent: parent,
            rcloneURL: rcloneURL,
            remotePath: remotePath,
            fileName: fileName,
            baseline: baseline
        )
        try app.write(to: local, options: .atomic)
        let externalURL = fixture.base.appendingPathComponent("external-during-source.bin")
        try external.write(to: externalURL, options: .atomic)
        let watcher = ActualWatcher()
        let service = fixture.service(
            additionalApplyArguments: ["--bwlimit", "512K", "--transfers", "1"],
            beforeDriveApply: {
                guard let journal = try FolderSyncJournalStore.load(connection: connection),
                      let runID = journal.items.flatMap(\.resources)
                        .first(where: { $0.relativePath == fileName })?
                        .drivePreservation?.recoveryRunID else {
                    throw BisyncSelfTestFailure("actual external-during is missing recovery run ID")
                }
                let recoverySpec = "gdrive:\(connection.remoteRecoveryPath)/\(runID)/path2/\(fileName)"
                watcher.start {
                    let deadline = Date().addingTimeInterval(45)
                    while Date() < deadline {
                        let stat = try runRclone(rcloneURL, [
                            "lsjson", recoverySpec, "--stat", "--drive-skip-gdocs"
                        ])
                        if stat.exitCode == 0 {
                            let update = try runRclone(rcloneURL, [
                                "copyto", externalURL.path, recoverySpec, "--drive-skip-gdocs"
                            ])
                            guard update.exitCode == 0 else {
                                throw BisyncSelfTestFailure("actual external-during writer failed")
                            }
                            return
                        }
                        Thread.sleep(forTimeInterval: 0.2)
                    }
                    throw BisyncSelfTestFailure("actual external-during did not observe the recovery move")
                }
            },
            afterDriveApplyBeforeJournal: {
                // The writer is deliberately racing the recovery move.  Wait
                // for it here so destination verification observes the real
                // Drive state, rather than a later modification after the
                // service has already reported success.
                try watcher.wait(seconds: 50)
            }
        )
        let report = try await service.synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(report.connection.status == .conflict, "actual recovery-head modification must be a conflict")
        let items = try service.recoveryItems(connection: report.connection)
            .filter { $0.location == .googleDrive && $0.originalRelativePath == fileName }
        try require(
            items.contains(where: { $0.expectedSHA256 == sha256(baseline) })
                && items.contains(where: { $0.expectedSHA256 == sha256(app) })
                && items.contains(where: { $0.expectedSHA256 == sha256(external) }),
            "actual external-during must retain exact baseline, app and observed recovery-head revisions"
        )
        return "conflict: recovery ID modified during upload and exact external revision pinned"
    }

    private static func recoveryTrashed(
        parent: URL,
        rcloneURL: URL,
        remotePath: String
    ) async throws -> String {
        let fileName = "recovery-trashed.bin"
        let baseline = Data("ACTUAL-BASELINE-trash-v1\n".utf8)
        let app = Data(repeating: 0x74, count: 2 * 1024 * 1024)
        let (fixture, connection, local) = try await fixtureWithBaseline(
            parent: parent,
            rcloneURL: rcloneURL,
            remotePath: remotePath,
            fileName: fileName,
            baseline: baseline
        )
        try app.write(to: local, options: .atomic)
        let watcher = ActualWatcher()
        let service = fixture.service(
            additionalApplyArguments: ["--bwlimit", "512K", "--transfers", "1"],
            beforeDriveApply: {
                guard let journal = try FolderSyncJournalStore.load(connection: connection),
                      let runID = journal.items.flatMap(\.resources)
                        .first(where: { $0.relativePath == fileName })?
                        .drivePreservation?.recoveryRunID else {
                    throw BisyncSelfTestFailure("actual Trash race is missing recovery run ID")
                }
                let recoverySpec = "gdrive:\(connection.remoteRecoveryPath)/\(runID)/path2/\(fileName)"
                watcher.start {
                    let deadline = Date().addingTimeInterval(45)
                    while Date() < deadline {
                        let stat = try runRclone(rcloneURL, [
                            "lsjson", recoverySpec, "--stat", "--drive-skip-gdocs"
                        ])
                        if stat.exitCode == 0 {
                            let trash = try runRclone(rcloneURL, [
                                "deletefile", recoverySpec, "--drive-skip-gdocs"
                            ])
                            guard trash.exitCode == 0 else {
                                throw BisyncSelfTestFailure("actual recovery Trash writer failed")
                            }
                            return
                        }
                        Thread.sleep(forTimeInterval: 0.2)
                    }
                    throw BisyncSelfTestFailure("actual Trash race did not observe recovery move")
                }
            },
            afterDriveApplyBeforeJournal: {
                // As above, make the deliberate concurrent mutation part of
                // this run's observed state before the service verifies it.
                try watcher.wait(seconds: 50)
            }
        )
        let report = try await service.synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(report.connection.status == .success, "moving protected recovery ID to Trash must preserve success")
        let items = try service.recoveryItems(connection: report.connection)
            .filter { $0.location == .googleDrive && $0.originalRelativePath == fileName }
        guard let baselineItem = items.first(where: { $0.expectedSHA256 == sha256(baseline) }) else {
            throw BisyncSelfTestFailure("trashed recovery ID lost its pinned baseline revision")
        }
        let move = try runRclone(rcloneURL, [
            "moveto", "gdrive:\(remotePath)/\(fileName)",
            "gdrive:\(remotePath)/trash-app-version-kept.bin",
            "--drive-skip-gdocs"
        ])
        guard move.exitCode == 0 else { throw BisyncSelfTestFailure("could not move Trash scenario app final") }
        try service.restoreRecoveryItem(
            baselineItem,
            connection: report.connection,
            catalogURL: fixture.catalogURL
        )
        let restored = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(fileName)",
            to: fixture.base.appendingPathComponent("trash-restored-baseline.bin")
        )
        try require(restored == baseline, "pinned revision on a trashed old file ID must remain restorable")
        return "success: old recovery ID trashed; pinned baseline restored by revision ID"
    }

    private static func crashRestart(
        phase: String,
        expectedExit: Int32,
        parent: URL,
        rcloneURL: URL,
        remotePath: String
    ) async throws -> String {
        let fileName = "crash-\(phase).bin"
        let baseline = Data("ACTUAL-BASELINE-crash-\(phase)-v1\n".utf8)
        let app = Data(repeating: phase == "pin" ? 0x70 : 0x71, count: 512 * 1024)
        let (fixture, connection, local) = try await fixtureWithBaseline(
            parent: parent,
            rcloneURL: rcloneURL,
            remotePath: remotePath,
            fileName: fileName,
            baseline: baseline
        )
        try app.write(to: local, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [
            "--drive-crash-worker", phase,
            fixture.catalogURL.path,
            fixture.storeURL.path,
            rcloneURL.path,
            connection.id,
            fileName
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try require(
            process.terminationReason == .exit && process.terminationStatus == expectedExit,
            "actual Drive crash worker did not stop at \(phase) boundary"
        )
        guard let recovered = try FolderSyncConnectionStore.loadRecoveringInterrupted(
            catalogURL: fixture.catalogURL,
            url: fixture.storeURL
        ).first(where: { $0.id == connection.id }) else {
            throw BisyncSelfTestFailure("actual Drive crash connection disappeared on restart")
        }
        let recoveredJournal = try FolderSyncJournalStore.load(connection: recovered)
        try require(
            recovered.status == .recoveryRequired
                && recoveredJournal?.phase == .recoveryRequired
                && recoveredJournal?.historyRestored == true,
            "actual Drive crash restart must restore the pre-apply bisync checkpoint"
        )
        let report = try await fixture.service().synchronize(
            connection: recovered,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(
            report.connection.status == .success,
            "actual Drive \(phase) crash retry should converge successfully"
        )
        let current = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(fileName)",
            to: fixture.base.appendingPathComponent("crash-\(phase)-final.bin")
        )
        try require(current == app, "actual Drive \(phase) crash retry must preserve final app bytes")
        let items = try fixture.service().recoveryItems(connection: report.connection)
            .filter { $0.location == .googleDrive && $0.originalRelativePath == fileName }
        try require(
            items.contains(where: { $0.expectedSHA256 == sha256(baseline) })
                && items.contains(where: { $0.expectedSHA256 == sha256(app) }),
            "actual Drive \(phase) crash retry must retain pinned baseline and app revisions"
        )
        return "success: process exit \(expectedExit) recovered and converged"
    }

    private static func conflictCrashRestart(
        parent: URL,
        rcloneURL: URL,
        remotePath: String
    ) async throws -> String {
        let fixture = try ActualDriveFixture.make(
            parent: parent,
            rcloneURL: rcloneURL,
            remotePath: remotePath
        )
        let identifier = "ACTUAL-CONFLICT-RESTART"
        let stillName = "IMG_0001.JPG"
        let movieName = "IMG_0001.MOV"
        let still = fixture.localRoot.appendingPathComponent(stillName)
        let movie = fixture.localRoot.appendingPathComponent(movieName)
        try writeSyntheticJPEG(to: still, contentIdentifier: identifier, pixelValue: 80)
        try await writeSyntheticTimedMetadataMovie(
            to: movie,
            markerValues: [0],
            contentIdentifier: identifier
        )
        let initialized = try await fixture.service().synchronize(
            connection: fixture.connection,
            confirmInitialSync: true,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        ).connection

        try writeSyntheticJPEGReplacing(
            still,
            contentIdentifier: identifier,
            pixelValue: 35
        )
        let localStill = try Data(contentsOf: still)
        let localMovie = try Data(contentsOf: movie)
        let remoteReplacement = fixture.base.appendingPathComponent("remote-conflict.jpg")
        try writeSyntheticJPEG(
            to: remoteReplacement,
            contentIdentifier: identifier,
            pixelValue: 220
        )
        let remoteStill = try Data(contentsOf: remoteReplacement)
        let replace = try runRclone(rcloneURL, [
            "copyto", remoteReplacement.path, "gdrive:\(remotePath)/\(stillName)", "--drive-skip-gdocs"
        ])
        guard replace.exitCode == 0 else {
            throw BisyncSelfTestFailure("could not create the actual Drive conflict source")
        }

        do {
            _ = try await fixture.service().synchronize(
                connection: initialized,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("actual Drive Live Photo both-modified conflict must require confirmation")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        guard let conflictConnection = try FolderSyncConnectionStore.load(url: fixture.storeURL)
            .first(where: { $0.id == initialized.id }) else {
            throw BisyncSelfTestFailure("actual Drive conflict connection disappeared")
        }
        let service = fixture.service()
        guard let item = try service.conflictItems(
            connection: conflictConnection,
            catalogURL: fixture.catalogURL
        ).first(where: {
            $0.isLivePhoto && Set($0.relativePaths) == Set([stillName, movieName])
        }) else {
            throw BisyncSelfTestFailure("actual Drive Live Photo conflict must expose the complete pair")
        }
        let crashAfterPath = item.relativePaths.sorted().first ?? stillName
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [
            "--drive-conflict-crash-worker",
            fixture.catalogURL.path,
            fixture.storeURL.path,
            rcloneURL.path,
            conflictConnection.id,
            item.id,
            item.expectedFingerprint,
            crashAfterPath
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try require(
            process.terminationReason == .exit && process.terminationStatus == 89,
            "actual Drive conflict worker did not stop after the first applied Live Photo resource"
        )

        guard let interruptedJournal = try FolderSyncJournalStore.load(connection: conflictConnection),
              let interruptedItem = interruptedJournal.items.first(where: { $0.id == item.id }),
              let interrupted = interruptedItem.conflictResolution else {
            throw BisyncSelfTestFailure("actual Drive conflict restart lost persisted resolution progress")
        }
        let applied = interrupted.resources.filter(\.applied)
        let pending = interrupted.resources.filter { !$0.applied }
        try require(
            interrupted.choice == .keepBoth
                && interrupted.expectedFingerprint == item.expectedFingerprint
                && interrupted.stage == .applying
                && applied.count == 1
                && pending.count == 1
                && interrupted.resources.allSatisfy(\.sourcePreserved)
                && interrupted.resources.allSatisfy { $0.copyRelativePath != nil },
            "actual Drive conflict restart must persist choice, fingerprint, pair copy names, preservation, and per-resource progress"
        )
        guard let firstApplied = applied.first,
              let firstCopyPath = firstApplied.copyRelativePath,
              let firstCopyID = try driveFileID(
                rcloneURL: rcloneURL,
                spec: "gdrive:\(remotePath)/\(firstCopyPath)"
              ) else {
            throw BisyncSelfTestFailure("actual Drive conflict restart must persist the first completed copy")
        }
        let copyPaths = interrupted.resources.compactMap(\.copyRelativePath)
        try require(
            Set(copyPaths).count == 2,
            "actual Drive Live Photo keep-both copy paths must be unique for the pair"
        )

        try await service.resolveConflict(
            connection: conflictConnection,
            itemID: item.id,
            choice: .keepBoth,
            expectedFingerprint: item.expectedFingerprint,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(
            try FolderSyncJournalStore.load(connection: conflictConnection) == nil,
            "completed actual Drive conflict resolution should clear its journal"
        )
        try require(
            try driveFileID(
                rcloneURL: rcloneURL,
                spec: "gdrive:\(remotePath)/\(firstCopyPath)"
            ) == firstCopyID,
            "actual Drive conflict restart must reuse the already completed copy instead of recreating it"
        )

        let finalOriginalStill = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(stillName)",
            to: fixture.base.appendingPathComponent("conflict-final-original.jpg")
        )
        let stillCopyPath = interrupted.resources.first(where: { $0.relativePath == stillName })?.copyRelativePath
        let movieCopyPath = interrupted.resources.first(where: { $0.relativePath == movieName })?.copyRelativePath
        guard let stillCopyPath, let movieCopyPath else {
            throw BisyncSelfTestFailure("actual Drive Live Photo keep-both copy paths disappeared")
        }
        let finalCopiedStill = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(stillCopyPath)",
            to: fixture.base.appendingPathComponent("conflict-final-copy.jpg")
        )
        let finalOriginalMovie = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(movieName)",
            to: fixture.base.appendingPathComponent("conflict-final-original.mov")
        )
        let finalCopiedMovie = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(movieCopyPath)",
            to: fixture.base.appendingPathComponent("conflict-final-copy.mov")
        )
        try require(
            finalOriginalStill == localStill
                && finalCopiedStill == remoteStill
                && finalOriginalMovie == localMovie
                && finalCopiedMovie == localMovie,
            "actual Drive Live Photo keep-both restart must preserve both complete pair versions"
        )
        try require(
            try visibleLocalFileNames(root: fixture.localRoot).count == 4
                && visibleDriveFileNames(rcloneURL: rcloneURL, remotePath: remotePath).count == 4,
            "actual Drive keep-both restart must create exactly one copy of each Live Photo resource"
        )

        guard let resolvedConnection = try FolderSyncConnectionStore.load(url: fixture.storeURL)
            .first(where: { $0.id == conflictConnection.id }) else {
            throw BisyncSelfTestFailure("actual Drive resolved connection disappeared")
        }
        let next = try await fixture.service().synchronize(
            connection: resolvedConnection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        let nextLocalFileCount = try visibleLocalFileNames(root: fixture.localRoot).count
        let nextDriveFileCount = try visibleDriveFileNames(
            rcloneURL: rcloneURL,
            remotePath: remotePath
        ).count
        try require(
            next.connection.status == .success
                && nextLocalFileCount == 4
                && nextDriveFileCount == 4,
            "the next normal sync must not repeat the resolved conflict or create another keep-both copy"
        )
        return "success: Live Photo keep-both resumed after exit 89, reused completed copy, and next sync converged"
    }

    private static func conflictTargetChangeInvalidatesApproval(
        parent: URL,
        rcloneURL: URL,
        remotePath: String
    ) async throws -> String {
        let fileName = "stale-choice.bin"
        let baseline = Data("00000000".utf8)
        let localChanged = Data("11111111".utf8)
        let remoteChanged = Data("22222222".utf8)
        let changedAgain = Data("33333333".utf8)
        let (fixture, initialized, local) = try await fixtureWithBaseline(
            parent: parent,
            rcloneURL: rcloneURL,
            remotePath: remotePath,
            fileName: fileName,
            baseline: baseline
        )
        try localChanged.write(to: local, options: .atomic)
        let remoteSource = fixture.base.appendingPathComponent("stale-remote.bin")
        try remoteChanged.write(to: remoteSource, options: .atomic)
        var replace = try runRclone(rcloneURL, [
            "copyto", remoteSource.path, "gdrive:\(remotePath)/\(fileName)", "--drive-skip-gdocs"
        ])
        guard replace.exitCode == 0 else {
            throw BisyncSelfTestFailure("could not create the actual Drive stale-approval conflict")
        }
        do {
            _ = try await fixture.service().synchronize(
                connection: initialized,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("actual Drive stale-approval setup must require confirmation")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        guard let conflictConnection = try FolderSyncConnectionStore.load(url: fixture.storeURL)
            .first(where: { $0.id == initialized.id }) else {
            throw BisyncSelfTestFailure("actual Drive stale-approval connection disappeared")
        }
        let service = fixture.service()
        guard let item = try service.conflictItems(
            connection: conflictConnection,
            catalogURL: fixture.catalogURL
        ).first(where: { $0.relativePaths == [fileName] }) else {
            throw BisyncSelfTestFailure("actual Drive stale-approval conflict item is missing")
        }

        try changedAgain.write(to: remoteSource, options: .atomic)
        replace = try runRclone(rcloneURL, [
            "copyto", remoteSource.path, "gdrive:\(remotePath)/\(fileName)", "--drive-skip-gdocs"
        ])
        guard replace.exitCode == 0 else {
            throw BisyncSelfTestFailure("could not mutate the actual Drive target after approval")
        }
        do {
            try await service.resolveConflict(
                connection: conflictConnection,
                itemID: item.id,
                choice: .useExternalDrive,
                expectedFingerprint: item.expectedFingerprint,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("actual Drive changed target must invalidate the saved conflict approval")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        let remoteFinal = try download(
            rcloneURL: rcloneURL,
            spec: "gdrive:\(remotePath)/\(fileName)",
            to: fixture.base.appendingPathComponent("stale-final.bin")
        )
        try require(
            try Data(contentsOf: local) == localChanged && remoteFinal == changedAgain,
            "stale actual Drive conflict approval must not mutate either side"
        )
        return "success: target changed after choice fingerprint; approval invalidated before mutation"
    }

    private static func verifyAllowedScope(
        rcloneURL: URL,
        scopePath: String,
        folderID: String
    ) throws {
        let path = scopePath as NSString
        let parent = path.deletingLastPathComponent
        let name = path.lastPathComponent
        let result = try runRclone(rcloneURL, [
            "lsjson", "gdrive:\(parent)",
            "--dirs-only", "--max-depth", "1", "--drive-skip-gdocs"
        ])
        guard result.exitCode == 0,
              let entries = try? JSONDecoder().decode([ActualRcloneEntry].self, from: result.stdout),
              entries.contains(where: {
                ($0.Path ?? $0.Name) == name && $0.ID == folderID && $0.IsDir == true
              }) else {
            throw BisyncSelfTestFailure("approved Drive scope ID could not be verified")
        }
    }

    private static func driveFileID(rcloneURL: URL, spec: String) throws -> String? {
        let result = try runRclone(rcloneURL, [
            "lsjson", spec, "--stat", "--drive-skip-gdocs"
        ])
        guard result.exitCode == 0 else { return nil }
        return try JSONDecoder().decode(ActualRcloneEntry.self, from: result.stdout).ID
    }

    private static func visibleDriveFileNames(rcloneURL: URL, remotePath: String) throws -> Set<String> {
        let result = try runRclone(rcloneURL, [
            "lsjson", "gdrive:\(remotePath)",
            "--files-only", "--max-depth", "1", "--drive-skip-gdocs"
        ])
        guard result.exitCode == 0 else {
            throw BisyncSelfTestFailure("actual Drive file listing failed")
        }
        let entries = try JSONDecoder().decode([ActualRcloneEntry].self, from: result.stdout)
        return Set(entries.compactMap { entry in
            guard let name = entry.Path ?? entry.Name,
                  !URL(fileURLWithPath: name).lastPathComponent.hasPrefix(".") else {
                return nil
            }
            return name
        })
    }

    private static func visibleLocalFileNames(root: URL) throws -> Set<String> {
        let values = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return Set(try values.compactMap { value in
            guard try value.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil
            }
            return value.lastPathComponent
        })
    }

    fileprivate static func runRclone(
        _ executable: URL,
        _ arguments: [String]
    ) throws -> ActualProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ActualProcessResult(
            exitCode: process.terminationStatus,
            stdout: out,
            stderr: err
        )
    }

    private static func download(
        rcloneURL: URL,
        spec: String,
        to destination: URL
    ) throws -> Data {
        try? FileManager.default.removeItem(at: destination)
        let result = try runRclone(rcloneURL, [
            "copyto", spec, destination.path, "--drive-skip-gdocs"
        ])
        guard result.exitCode == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw BisyncSelfTestFailure("actual Drive byte download failed")
        }
        return try Data(contentsOf: destination)
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func runIdentifier() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd-HHmmss"
        return formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4))
    }
}
