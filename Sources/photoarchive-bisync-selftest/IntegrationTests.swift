import Darwin
import Foundation
import PhotoArchiveCore

enum BisyncServiceIntegrationTests {
    static func run() async throws {
        guard let rcloneURL = executableURL("rclone") else {
            print("SKIP: rclone is not installed; bisync service adapter is optional.")
            return
        }

        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("pbs-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        try parserRegression(parent: temporary)
        try deletionApprovalPolicy()
        try await productionSafetyBoundary(parent: temporary, rcloneURL: rcloneURL)
        try await protectedDirectHistoryRejectsLateUnplannedChanges(
            parent: temporary,
            rcloneURL: rcloneURL
        )
        try await newLocalDestinationAppearsAtMutationBoundary(parent: temporary, rcloneURL: rcloneURL)
        try await destinationConcurrentWriteCapabilityGuard(parent: temporary, rcloneURL: rcloneURL)
        try await localDestinationConcurrentWritePreserved(parent: temporary, rcloneURL: rcloneURL)
        try await localDestinationSwapCrashRecovery(parent: temporary, rcloneURL: rcloneURL)
        try await unsupportedLocalSwapFailsClosed(parent: temporary, rcloneURL: rcloneURL)
        try await driveRevisionOverwriteSuccess(parent: temporary, rcloneURL: rcloneURL)
        try await driveRevisionExternalBeforeApply(parent: temporary, rcloneURL: rcloneURL)
        try await driveRevisionRaceBetweenHeadAndRevisionList(parent: temporary, rcloneURL: rcloneURL)
        try await driveRevisionDuplicateAndPinFailures(parent: temporary, rcloneURL: rcloneURL)
        try await driveEmptyCreateCrashRecovery(parent: temporary, rcloneURL: rcloneURL)
        try await driveKeepBothEmptyCreateCrashRecovery(parent: temporary, rcloneURL: rcloneURL)
        try await initialUniqueMerge(parent: temporary, rcloneURL: rcloneURL)
        try await initialEqualContentDifferentModtime(parent: temporary, rcloneURL: rcloneURL)
        try await initialConflict(parent: temporary, rcloneURL: rcloneURL)
        try await initialConcurrentExistingChange(parent: temporary, rcloneURL: rcloneURL)
        try await initialPostPreflightAdd(parent: temporary, rcloneURL: rcloneURL)
        try await initialPostPreflightDelete(parent: temporary, rcloneURL: rcloneURL)
        try await ordinaryMedia(parent: temporary, rcloneURL: rcloneURL)
        try await ordinaryRenameMove(parent: temporary, rcloneURL: rcloneURL)
        try await ordinaryBothModifiedConflict(parent: temporary, rcloneURL: rcloneURL)
        try await ordinaryDeleteModifyConflict(parent: temporary, rcloneURL: rcloneURL)
        try await conflictChoiceTargetChangeInvalidatesApproval(parent: temporary, rcloneURL: rcloneURL)
        try await deletionApprovalAndPlanChange(parent: temporary, rcloneURL: rcloneURL)
        try await approvedDeletionTargetChangesBeforeApply(parent: temporary, rcloneURL: rcloneURL)
        try await entireFolderDeletionApproval(parent: temporary, rcloneURL: rcloneURL)
        try await recoveryRestoreAndCollision(parent: temporary, rcloneURL: rcloneURL)
        try await incrementalEfficiency(parent: temporary, rcloneURL: rcloneURL)
        try await localLivePhotoStill(parent: temporary, rcloneURL: rcloneURL)
        try await remoteLivePhotoVideo(parent: temporary, rcloneURL: rcloneURL)
        try await livePhotoDeletion(parent: temporary, rcloneURL: rcloneURL)
        try await localLivePhotoVideoDeletion(parent: temporary, rcloneURL: rcloneURL)
        try await remoteLivePhotoDeletion(parent: temporary, rcloneURL: rcloneURL)
        try await remoteLivePhotoVideoDeletion(parent: temporary, rcloneURL: rcloneURL)
        try await completeLivePhotoDeletion(parent: temporary, rcloneURL: rcloneURL)
        try await livePhotoConflict(parent: temporary, rcloneURL: rcloneURL)
        try await splitLivePhotoChange(parent: temporary, rcloneURL: rcloneURL)
        try await livePhotoDeleteModifyConflict(parent: temporary, rcloneURL: rcloneURL)
        try await metadataFailure(parent: temporary, rcloneURL: rcloneURL)
        try await journalCorruption(parent: temporary, rcloneURL: rcloneURL)
        try await cancellationBeforeApply(parent: temporary, rcloneURL: rcloneURL)
        try await rootUnavailableAfterPreflight(parent: temporary, rcloneURL: rcloneURL)
        try await sourceUnreadableAfterPreflight(parent: temporary, rcloneURL: rcloneURL)
        try await recoveryCapacityGuard(parent: temporary, rcloneURL: rcloneURL)
        try await toctouAdd(parent: temporary, rcloneURL: rcloneURL)
        try await toctouRemoteAdd(parent: temporary, rcloneURL: rcloneURL)
        try await toctouReplace(parent: temporary, rcloneURL: rcloneURL)
        try await toctouDelete(parent: temporary, rcloneURL: rcloneURL)
        try await partialInitializedOrdinaryRetry(parent: temporary, rcloneURL: rcloneURL)
        try await plannedPartialLivePhotoRetry(parent: temporary, rcloneURL: rcloneURL, videoFirst: false)
        try await plannedPartialLivePhotoRetry(parent: temporary, rcloneURL: rcloneURL, videoFirst: true)
        try await partialLivePhotoApply(parent: temporary, rcloneURL: rcloneURL)
        try await partialFirstSync(parent: temporary, rcloneURL: rcloneURL)
        try await duplicateService(parent: temporary, rcloneURL: rcloneURL)
    }

    private static func fixture(parent: URL, rcloneURL: URL) throws -> BisyncServiceFixture {
        try BisyncServiceFixture.make(parentURL: parent, rcloneURL: rcloneURL)
    }

    private static func parserRegression(parent: URL) throws {
        print("bisync-service: parser regression")
        let logURL = parent.appendingPathComponent("parser.jsonl")
        let log = """
        {"level":"notice","msg":"- Path1    File changed: size (larger) - album/공백 - IMG_0001 \\"사진\\".HEIC","source":"bisync/deltas.go:232"}
        {"level":"notice","msg":"- WARNING    New or changed in both paths - conflict - 사진.jpg","source":"bisync/deltas.go:391"}
        {"level":"notice","msg":"Skipped copy as --dry-run is set","skipped":"copy","object":"album/공백 - IMG_0001 \\"사진\\".HEIC","source":"operations/operations.go:2631"}
        """
        try log.write(to: logURL, atomically: true, encoding: .utf8)
        let summary = try RcloneBisyncService.parseDryRunLog(url: logURL)
        try require(
            summary.candidatePaths == [
                "album/공백 - IMG_0001 \"사진\".HEIC",
                "conflict - 사진.jpg"
            ] && summary.conflictPreserved,
            "rclone NOTICE JSON parser should preserve spaces, Korean text, quotes and ' - ' inside filenames"
        )
    }

    private static func deletionApprovalPolicy() throws {
        print("bisync-service: deletion approval policy")
        let nine = (0..<9).map {
            FolderSyncDeletionItem(
                location: .googleDrive,
                relativePaths: ["nine/\($0).txt"],
                isLivePhoto: false
            )
        }
        try require(
            !FolderSyncDeletionPlan(
                items: nine,
                previousCompletedLogicalItemCountLowerBound: 40,
                emptiedNonEmptyDirectories: []
            ).requiresConfirmation,
            "fewer than ten deletion items should not require percentage confirmation by count alone"
        )
        let ten = (0..<10).map {
            FolderSyncDeletionItem(
                location: .googleDrive,
                relativePaths: ["ten/\($0).txt"],
                isLivePhoto: false
            )
        }
        let threshold = FolderSyncDeletionPlan(
            items: ten,
            previousCompletedLogicalItemCountLowerBound: 50,
            emptiedNonEmptyDirectories: []
        )
        try require(
            threshold.requiresConfirmation,
            "ten deletions at twenty percent of the previous logical-item lower bound must require confirmation"
        )
        let emptied = FolderSyncDeletionPlan(
            items: [ten[0]],
            previousCompletedLogicalItemCountLowerBound: 50,
            emptiedNonEmptyDirectories: ["google_drive:album"]
        )
        try require(
            emptied.requiresConfirmation,
            "removing all contents of a previously non-empty directory must require confirmation"
        )
        let changed = FolderSyncDeletionPlan(
            items: ten + [
                FolderSyncDeletionItem(
                    location: .googleDrive,
                    relativePaths: ["ten/extra.txt"],
                    isLivePhoto: false
                )
            ],
            previousCompletedLogicalItemCountLowerBound: 50,
            emptiedNonEmptyDirectories: []
        )
        try require(
            threshold.id != changed.id,
            "deletion approval fingerprint must change when the displayed action list changes"
        )
    }

    private static func productionSafetyBoundary(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: production safety boundary")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try Data("local-only".utf8).write(to: fixture.localRoot.appendingPathComponent("local.txt"))

        do {
            _ = try await RcloneBisyncService().synchronize(
                connection: fixture.connection,
                confirmInitialSync: true,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("production bisync apply must stay disabled while destination concurrency safety is unresolved")
        } catch FolderSyncConnectionError.concurrentMutationSafetyUnavailable {
            // Expected.
        }
        try require(
            try visibleUserFiles(in: fixture.remoteRoot).isEmpty,
            "production safety block must happen before remote access markers or media are written"
        )
        try require(
            try fixture.savedConnection().status == .safetyUnavailable,
            "production safety block should persist a distinct safety state"
        )
    }

    private static func protectedDirectHistoryRejectsLateUnplannedChanges(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        for mode in ["add", "replace", "delete"] {
            print("bisync-service: protected direct history late unplanned \(mode)")
            let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
            let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
            try Data("anchor".utf8).write(to: anchor)
            try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))

            let path = "late-\(mode).txt"
            let local = fixture.localRoot.appendingPathComponent(path)
            let remote = fixture.remoteRoot.appendingPathComponent(path)
            let baseline = Data("baseline-\(mode)".utf8)
            if mode != "add" {
                try baseline.write(to: local)
                try copyReplacing(local, to: remote)
            }
            let connection = try await initialize(fixture)
            let drive = FakeDriveRevisionManager()

            let service = fixture.service(
                testingDriveRevisionManager: drive,
                testingUseDriveRevisionProtection: true,
                testingUseProtectedDirectHistoryReconcile: true,
                beforeDriveApply: {
                    switch mode {
                    case "add":
                        try Data("late-add".utf8).write(to: local, options: .atomic)
                    case "replace":
                        try Data("late-replace".utf8).write(to: local, options: .atomic)
                    case "delete":
                        try FileManager.default.removeItem(at: local)
                    default:
                        break
                    }
                }
            )
            do {
                _ = try await service.synchronize(
                    connection: connection,
                    confirmInitialSync: false,
                    catalogURL: fixture.catalogURL,
                    storeURL: fixture.storeURL
                )
                throw BisyncSelfTestFailure("late unplanned \(mode) must stop before any unrestricted bisync mutation")
            } catch FolderSyncConnectionError.confirmationRequired {
                // Expected: the dry history reconciliation observes the late path.
            }

            switch mode {
            case "add":
                try require(
                    FileManager.default.fileExists(atPath: local.path)
                        && !FileManager.default.fileExists(atPath: remote.path),
                    "late add must not be copied by history reconciliation"
                )
            case "replace":
                try require(
                    try Data(contentsOf: local) == Data("late-replace".utf8)
                        && Data(contentsOf: remote) == baseline,
                    "late replacement must not overwrite the opposite side"
                )
            case "delete":
                try require(
                    !FileManager.default.fileExists(atPath: local.path)
                        && Data(contentsOf: remote) == baseline,
                    "late deletion must not delete the opposite side"
                )
            default:
                break
            }

            let firstJournal = try FolderSyncJournalStore.load(connection: connection)
            try require(
                firstJournal?.phase == .confirmationRequired
                    && firstJournal?.unplannedObservedPaths.contains(path) == true,
                "late unplanned \(mode) must be recorded before history promotion"
            )

            let inspectionService = fixture.service(
                testingUseProtectedDirectHistoryReconcile: true
            )
            do {
                _ = try await inspectionService.synchronize(
                    connection: try fixture.savedConnection(),
                    confirmInitialSync: false,
                    catalogURL: fixture.catalogURL,
                    storeURL: fixture.storeURL
                )
                throw BisyncSelfTestFailure("the next inspection must still see late \(mode)")
            } catch FolderSyncConnectionError.recoveryRequired {
                // Expected: this test intentionally omits a direct Drive writer
                // on the second run, so verification cannot complete.
            } catch FolderSyncConnectionError.confirmationRequired {
                // Also acceptable when the fresh preflight itself classifies
                // the late change as requiring confirmation.
            }
            let secondJournal = try FolderSyncJournalStore.load(connection: connection)
            try require(
                secondJournal?.preflightCandidatePaths.contains(path) == true,
                "the unchanged history must make late \(mode) visible to the next preflight"
            )
        }
    }

    private static func newLocalDestinationAppearsAtMutationBoundary(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        print("bisync-service: new local destination appears at mutation boundary")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)

        let local = fixture.localRoot.appendingPathComponent("new-race.bin")
        let remote = fixture.remoteRoot.appendingPathComponent("new-race.bin")
        let remoteBytes = Data("verified remote new file".utf8)
        let externalBytes = Data("external file created at final mutation boundary".utf8)
        try remoteBytes.write(to: remote, options: .atomic)

        let service = fixture.service(beforeLocalDestinationSwap: { path in
            guard path == "new-race.bin" else { return }
            try externalBytes.write(to: local, options: .atomic)
        })
        do {
            _ = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("a destination created immediately before RENAME_EXCL must stop the run")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }

        try require(
            try Data(contentsOf: local) == externalBytes
                && Data(contentsOf: remote) == remoteBytes,
            "RENAME_EXCL must preserve both the newly-created local destination and the verified remote source"
        )
        let saved = try fixture.savedConnection()
        let journal = try FolderSyncJournalStore.load(connection: saved)
        try require(
            saved.status == .confirmationRequired
                && journal?.phase == .confirmationRequired
                && journal?.items.contains(where: {
                    $0.note == "destination_changed_at_mutation_boundary"
                }) == true,
            "an exact-boundary destination collision must remain a stable confirmation after restart"
        )
        let restarted = try FolderSyncConnectionStore.loadRecoveringInterrupted(
            catalogURL: fixture.catalogURL,
            url: fixture.storeURL
        ).first(where: { $0.id == connection.id })
        try require(
            restarted?.status == .confirmationRequired,
            "restart must not misclassify a pre-mutation destination collision as an interrupted apply"
        )
    }

    private static func destinationConcurrentWriteCapabilityGuard(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        print("bisync-service: destination concurrent-write capability guard")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("race.bin")
        let remote = fixture.remoteRoot.appendingPathComponent("race.bin")
        let baseline = Data(repeating: 0x11, count: 256 * 1024)
        try baseline.write(to: local)
        try copyReplacing(local, to: remote)
        let connection = try await initialize(fixture)

        let source = Data(repeating: 0x22, count: 2 * 1024 * 1024)
        let concurrent = Data("external writer during destination gap".utf8)
        try source.write(to: local, options: .atomic)

        let service = fixture.service(additionalApplyArguments: [
            "--disable", "Copy",
            "--bwlimit", "512K",
            "--transfers", "1"
        ])
        let task = Task {
            try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
        }

        let remoteRecoveryRoot = fixture.remoteRoot.deletingLastPathComponent()
            .appendingPathComponent(connection.remoteRecoveryPath, isDirectory: true)
        let deadline = Date().addingTimeInterval(8)
        var injected = false
        while Date() < deadline {
            let backupExists = try recursiveRegularFiles(in: remoteRecoveryRoot)
                .contains { $0.lastPathComponent == remote.lastPathComponent }
            if backupExists && !FileManager.default.fileExists(atPath: remote.path) {
                try concurrent.write(to: remote, options: .atomic)
                injected = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard injected else {
            service.cancelCurrentRun()
            _ = try? await task.value
            throw BisyncSelfTestFailure(
                "could not reach the synthetic backup-to-finalize destination gap"
            )
        }

        let report = try? await task.value
        let saved = try fixture.savedConnection()
        let recoveryFiles = try recursiveRegularFiles(in: remoteRecoveryRoot)
        let concurrentPreserved = (try? Data(contentsOf: remote)) == concurrent
            || recoveryFiles.contains { (try? Data(contentsOf: $0)) == concurrent }
        try require(
            !concurrentPreserved,
            "this guard must keep reproducing the rclone destination gap until the backend provides a conditional-write or equivalent preservation primitive"
        )
        try require(
            report?.connection.status == .success || saved.status == .recoveryRequired,
            "the synthetic destination race must never be mistaken for a safely preserved concurrent edit"
        )
    }

    private static func localDestinationConcurrentWritePreserved(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        print("bisync-service: local destination concurrent write preserved")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("local-race.bin")
        let remote = fixture.remoteRoot.appendingPathComponent("local-race.bin")
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        let remoteAnchor = fixture.remoteRoot.appendingPathComponent("anchor.txt")
        let baseline = Data("baseline-before-local-replace".utf8)
        let concurrent = Data("external-writer-immediately-before-swap".utf8)
        let remoteNew = Data(repeating: 0x52, count: 512 * 1024)
        try baseline.write(to: local)
        try copyReplacing(local, to: remote)
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: remoteAnchor)
        let connection = try await initialize(fixture)
        try remoteNew.write(to: remote, options: .atomic)

        let service = fixture.service(beforeLocalDestinationSwap: { path in
            guard path == "local-race.bin" else { return }
            try concurrent.write(to: local, options: .atomic)
        })
        let report = try await service.synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(
            report.connection.status == .conflict && report.conflictPreserved,
            "a writer that replaces the local destination immediately before swap must be preserved and surfaced as a conflict"
        )
        try require(
            try Data(contentsOf: local) == remoteNew
                && Data(contentsOf: remote) == remoteNew,
            "the verified remote version must become the local final path without corrupting either side"
        )

        let recoveryItems = try fixture.service().recoveryItems(connection: report.connection)
            .filter {
                $0.location == .externalDrive
                    && $0.originalRelativePath == "local-race.bin"
            }
        let recoveryRoot = URL(
            fileURLWithPath: report.connection.localRecoveryDirectoryPath,
            isDirectory: true
        )
        let recoveryContents = recoveryItems.compactMap { item in
            try? Data(contentsOf: recoveryRoot.appendingPathComponent(item.recoveryRelativePath))
        }
        try require(
            recoveryContents.contains(baseline) && recoveryContents.contains(concurrent),
            "local replacement must preserve both the app-verified baseline and the writer version captured at the atomic swap"
        )

        let retry = try await fixture.service().synchronize(
            connection: report.connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        let retryLocalContents = try Data(contentsOf: local)
        let retryRecoveryCount = try fixture.service().recoveryItems(connection: retry.connection)
            .filter {
                $0.location == .externalDrive
                    && $0.originalRelativePath == "local-race.bin"
            }.count
        try require(
            retry.connection.status == .success
                && retryLocalContents == remoteNew
                && retryRecoveryCount >= 2,
            "a no-change retry must keep the preserved local recovery copies and must not replay the replacement"
        )
    }

    static func runAtomicSwapCrashWorker(arguments: [String]) async throws {
        guard arguments.count == 6 else {
            throw BisyncSelfTestFailure("atomic swap crash worker arguments are incomplete")
        }
        let phase = arguments[0]
        let catalogURL = URL(fileURLWithPath: arguments[1])
        let storeURL = URL(fileURLWithPath: arguments[2])
        let configURL = URL(fileURLWithPath: arguments[3])
        let rcloneURL = URL(fileURLWithPath: arguments[4])
        let connectionID = arguments[5]
        guard let connection = try FolderSyncConnectionStore.load(url: storeURL)
            .first(where: { $0.id == connectionID })
        else {
            throw BisyncSelfTestFailure("atomic swap crash worker connection is missing")
        }
        let crash: @Sendable (String) throws -> Void = { path in
            guard path == "crash.bin" else { return }
            _exit(86)
        }
        let service = RcloneBisyncService(
            syntheticTestingExecutableURL: rcloneURL,
            environment: ["RCLONE_CONFIG": configURL.path],
            remoteTypeFilter: "alias",
            allowBisyncApply: true,
            beforeLocalDestinationSwap: phase == "before" ? crash : nil,
            afterLocalDestinationSwap: phase == "after" ? crash : nil
        )
        _ = try await service.synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: catalogURL,
            storeURL: storeURL
        )
        throw BisyncSelfTestFailure("atomic swap crash worker did not reach the requested crash point")
    }

    static func runDriveEmptyCreateCrashWorker(arguments: [String]) async throws {
        guard arguments.count >= 7 else {
            throw BisyncSelfTestFailure("Drive empty-create crash worker arguments are incomplete")
        }
        let mode = arguments[0]
        let catalogURL = URL(fileURLWithPath: arguments[1])
        let storeURL = URL(fileURLWithPath: arguments[2])
        let configURL = URL(fileURLWithPath: arguments[3])
        let rcloneURL = URL(fileURLWithPath: arguments[4])
        let connectionID = arguments[5]
        let stateURL = URL(fileURLWithPath: arguments[6])
        guard let connection = try FolderSyncConnectionStore.load(url: storeURL)
            .first(where: { $0.id == connectionID })
        else {
            throw BisyncSelfTestFailure("Drive empty-create crash worker connection is missing")
        }
        let remoteRoot = configURL.deletingLastPathComponent()
            .appendingPathComponent("remote", isDirectory: true)
            .appendingPathComponent("camera", isDirectory: true)
        let drive = try PersistentDriveRevisionManager(stateURL: stateURL, mirrorRootURL: remoteRoot)
        let crash: @Sendable (String) throws -> Void = { _ in _exit(87) }
        let service = RcloneBisyncService(
            syntheticTestingExecutableURL: rcloneURL,
            environment: ["RCLONE_CONFIG": configURL.path],
            remoteTypeFilter: "alias",
            allowBisyncApply: true,
            testingDriveRevisionManager: drive,
            testingUseDriveRevisionProtection: true,
            testingUseProtectedDirectHistoryReconcile: true,
            afterDriveEmptyObjectJournaledBeforeUpload: crash
        )
        if mode == "create" {
            _ = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: catalogURL,
                storeURL: storeURL
            )
        } else if mode == "keep-both", arguments.count == 9 {
            try await service.resolveConflict(
                connection: connection,
                itemID: arguments[7],
                choice: .keepBoth,
                expectedFingerprint: arguments[8],
                catalogURL: catalogURL,
                storeURL: storeURL
            )
        } else {
            throw BisyncSelfTestFailure("Drive empty-create crash worker mode is invalid")
        }
        throw BisyncSelfTestFailure("Drive empty-create crash worker did not reach the pre-upload boundary")
    }

    private static func driveEmptyCreateCrashRecovery(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        print("bisync-service: Drive empty-create crash recovery")
        try await driveEmptyCreateCrashRecoveryCase(
            parent: parent,
            rcloneURL: rcloneURL,
            externallyModifyPlaceholder: false
        )
        print("bisync-service: Drive empty-create external placeholder mutation")
        try await driveEmptyCreateCrashRecoveryCase(
            parent: parent,
            rcloneURL: rcloneURL,
            externallyModifyPlaceholder: true
        )
    }

    private static func driveEmptyCreateCrashRecoveryCase(
        parent: URL,
        rcloneURL: URL,
        externallyModifyPlaceholder: Bool
    ) async throws {
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let path = externallyModifyPlaceholder ? "drive-create-external.bin" : "drive-create-restart.bin"
        let source = fixture.localRoot.appendingPathComponent(path)
        let expected = Data((externallyModifyPlaceholder ? "app-create-external" : "app-create-restart").utf8)
        let external = Data("external-placeholder-writer".utf8)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)
        try expected.write(to: source, options: .atomic)

        let stateURL = fixture.configURL.deletingLastPathComponent().appendingPathComponent("drive-state.json")
        _ = try PersistentDriveRevisionManager(stateURL: stateURL, mirrorRootURL: fixture.remoteRoot)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [
            "--drive-empty-create-crash-worker", "create",
            fixture.catalogURL.path,
            fixture.storeURL.path,
            fixture.configURL.path,
            rcloneURL.path,
            connection.id,
            stateURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try require(
            process.terminationReason == .exit && process.terminationStatus == 87,
            "Drive create crash worker must terminate after the empty object is journaled and before upload"
        )

        let crashedJournal = try FolderSyncJournalStore.load(connection: connection)
        guard let mutation = drivePreservation(crashedJournal, path: path)?.mutation,
              let fileID = mutation.mutatedFileID,
              let emptyRevisionID = mutation.emptyObjectRevisionID else {
            throw BisyncSelfTestFailure("Drive create crash must persist the owned placeholder identity and revision")
        }
        let crashedDrive = try PersistentDriveRevisionManager(stateURL: stateURL, mirrorRootURL: fixture.remoteRoot)
        let crashedObject = crashedDrive.snapshot(fileID: fileID)
        try require(
            mutation.kind == .create
                && mutation.creationStage == .emptyObjectCreated
                && mutation.applied == false
                && mutation.verified == false
                && mutation.contentRevisionID == nil
                && crashedObject?.headRevisionID == emptyRevisionID
                && crashedObject?.bytes.isEmpty == true
                && crashedDrive.liveFileIDs(path: path) == [fileID]
                && crashedDrive.updateCount(fileID: fileID) == 0,
            "pre-upload crash must leave exactly one journaled empty Drive object without recording a content upload"
        )

        if externallyModifyPlaceholder {
            _ = try crashedDrive.addRevision(fileID: fileID, bytes: external)
        }

        guard let recovered = try FolderSyncConnectionStore.loadRecoveringInterrupted(
            catalogURL: fixture.catalogURL,
            url: fixture.storeURL
        ).first(where: { $0.id == connection.id }) else {
            throw BisyncSelfTestFailure("crashed Drive create connection is missing after restart")
        }
        let restartedDrive = try PersistentDriveRevisionManager(stateURL: stateURL, mirrorRootURL: fixture.remoteRoot)
        let restartedService = fixture.service(
            testingDriveRevisionManager: restartedDrive,
            testingUseDriveRevisionProtection: true,
            testingUseProtectedDirectHistoryReconcile: true
        )

        if externallyModifyPlaceholder {
            do {
                _ = try await restartedService.synchronize(
                    connection: recovered,
                    confirmInitialSync: false,
                    catalogURL: fixture.catalogURL,
                    storeURL: fixture.storeURL
                )
                throw BisyncSelfTestFailure("externally modified Drive placeholder must not be overwritten on retry")
            } catch FolderSyncConnectionError.confirmationRequired {
                // Expected.
            }
            let finalObject = restartedDrive.snapshot(fileID: fileID)
            let journal = try FolderSyncJournalStore.load(connection: recovered)
            let preservation = drivePreservation(journal, path: path)
            try require(
                finalObject?.bytes == external
                    && restartedDrive.liveFileIDs(path: path) == [fileID]
                    && restartedDrive.updateCount(fileID: fileID) == 0
                    && journal?.phase == .confirmationRequired
                    && preservation?.conflicts.contains(where: {
                        $0.fileID == fileID && $0.revisionID == finalObject?.headRevisionID
                    }) == true,
                "retry must preserve and confirm an externally modified placeholder without uploading or duplicating it"
            )
            return
        }

        let report = try await restartedService.synchronize(
            connection: recovered,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        let completed = restartedDrive.snapshot(fileID: fileID)
        let liveIDs = restartedDrive.liveFileIDs(path: path)
        let updateCount = restartedDrive.updateCount(fileID: fileID)
        let remoteBytes = try Data(contentsOf: fixture.remoteRoot.appendingPathComponent(path))
        let remainingJournal = try FolderSyncJournalStore.load(connection: report.connection)
        try require(
            report.connection.status == .success
                && completed?.bytes == expected
                && liveIDs == [fileID]
                && updateCount == 1
                && remoteBytes == expected
                && remainingJournal == nil,
            "restart must resume the exact placeholder once, verify it, and avoid duplicate Drive objects "
                + "(status=\(report.connection.status), completed=\(completed?.bytes == expected), "
                + "liveIDs=\(liveIDs), updateCount=\(updateCount), remote=\(remoteBytes == expected), "
                + "journal=\(remainingJournal?.phase.rawValue ?? "nil"))"
        )
    }

    private static func driveKeepBothEmptyCreateCrashRecovery(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        print("bisync-service: Drive keep-both copy empty-create crash recovery")
        try await driveKeepBothEmptyCreateCrashRecoveryCase(
            parent: parent,
            rcloneURL: rcloneURL,
            externallyModifyPlaceholder: false
        )
        print("bisync-service: Drive keep-both external placeholder mutation")
        try await driveKeepBothEmptyCreateCrashRecoveryCase(
            parent: parent,
            rcloneURL: rcloneURL,
            externallyModifyPlaceholder: true
        )
    }

    private static func driveKeepBothEmptyCreateCrashRecoveryCase(
        parent: URL,
        rcloneURL: URL,
        externallyModifyPlaceholder: Bool
    ) async throws {
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let path = externallyModifyPlaceholder
            ? "drive-keep-both-external.bin"
            : "drive-keep-both.bin"
        let local = fixture.localRoot.appendingPathComponent(path)
        let remote = fixture.remoteRoot.appendingPathComponent(path)
        let baseline = Data("keep-both-baseline".utf8)
        let localChanged = Data("keep-both-local".utf8)
        let remoteChanged = Data("keep-both-remote".utf8)
        let external = Data("keep-both-external-placeholder-writer".utf8)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try baseline.write(to: local)
        try copyReplacing(local, to: remote)
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)
        try localChanged.write(to: local, options: .atomic)
        try remoteChanged.write(to: remote, options: .atomic)

        let stateURL = fixture.configURL.deletingLastPathComponent().appendingPathComponent("drive-state.json")
        let planningDrive = try PersistentDriveRevisionManager(stateURL: stateURL, mirrorRootURL: fixture.remoteRoot)
        _ = try planningDrive.seedFile(path: path, bytes: remoteChanged, fileID: "keep-both-source")
        let planningService = fixture.service(
            testingDriveRevisionManager: planningDrive,
            testingUseDriveRevisionProtection: true,
            testingUseProtectedDirectHistoryReconcile: true
        )
        do {
            _ = try await planningService.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("both-modified direct Drive conflict must require a user choice")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        let saved = try fixture.savedConnection()
        guard let item = try planningService.conflictItems(
            connection: saved,
            catalogURL: fixture.catalogURL
        ).first(where: { $0.relativePaths == [path] }) else {
            throw BisyncSelfTestFailure("direct Drive keep-both conflict item is missing")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [
            "--drive-empty-create-crash-worker", "keep-both",
            fixture.catalogURL.path,
            fixture.storeURL.path,
            fixture.configURL.path,
            rcloneURL.path,
            connection.id,
            stateURL.path,
            item.id,
            item.expectedFingerprint
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try require(
            process.terminationReason == .exit && process.terminationStatus == 87,
            "keep-both crash worker must terminate after its Drive copy placeholder is journaled"
        )

        let crashedJournal = try FolderSyncJournalStore.load(connection: saved)
        guard let crashedItem = crashedJournal?.items.first(where: { $0.id == item.id }),
              let resource = crashedItem.conflictResolution?.resources.first(where: { $0.relativePath == path }),
              let copyPath = resource.copyRelativePath,
              let mutation = resource.copyDriveMutation,
              let copyFileID = mutation.mutatedFileID,
              let emptyRevisionID = mutation.emptyObjectRevisionID else {
            throw BisyncSelfTestFailure("keep-both crash must persist the Drive copy placeholder identity")
        }
        let crashedDrive = try PersistentDriveRevisionManager(stateURL: stateURL, mirrorRootURL: fixture.remoteRoot)
        let placeholder = crashedDrive.snapshot(fileID: copyFileID)
        try require(
            mutation.creationStage == .emptyObjectCreated
                && mutation.applied == false
                && mutation.verified == false
                && mutation.contentRevisionID == nil
                && placeholder?.headRevisionID == emptyRevisionID
                && placeholder?.bytes.isEmpty == true
                && crashedDrive.liveFileIDs(path: copyPath) == [copyFileID]
                && crashedDrive.updateCount(fileID: copyFileID) == 0,
            "keep-both pre-upload crash must leave one exact journal-owned empty copy object"
        )

        if externallyModifyPlaceholder {
            _ = try crashedDrive.addRevision(fileID: copyFileID, bytes: external)
        }

        let restartedDrive = try PersistentDriveRevisionManager(stateURL: stateURL, mirrorRootURL: fixture.remoteRoot)
        let restartedService = fixture.service(
            testingDriveRevisionManager: restartedDrive,
            testingUseDriveRevisionProtection: true,
            testingUseProtectedDirectHistoryReconcile: true
        )
        if externallyModifyPlaceholder {
            do {
                try await restartedService.resolveConflict(
                    connection: try fixture.savedConnection(),
                    itemID: item.id,
                    choice: .keepBoth,
                    expectedFingerprint: item.expectedFingerprint,
                    catalogURL: fixture.catalogURL,
                    storeURL: fixture.storeURL
                )
                throw BisyncSelfTestFailure("externally modified keep-both placeholder must not be overwritten")
            } catch FolderSyncConnectionError.confirmationRequired {
                // Expected.
            }
            let finalObject = restartedDrive.snapshot(fileID: copyFileID)
            let journal = try FolderSyncJournalStore.load(connection: try fixture.savedConnection())
            let recovery = try restartedService.recoveryItems(connection: try fixture.savedConnection())
                .filter {
                    $0.location == .googleDrive
                        && $0.originalRelativePath == copyPath
                }
            try require(
                finalObject?.bytes == external
                    && restartedDrive.liveFileIDs(path: copyPath) == [copyFileID]
                    && restartedDrive.updateCount(fileID: copyFileID) == 0
                    && journal?.phase == .confirmationRequired
                    && !recovery.isEmpty,
                "retry must preserve and confirm an externally modified keep-both placeholder without uploading or duplicating it"
            )
            return
        }

        try await restartedService.resolveConflict(
            connection: try fixture.savedConnection(),
            itemID: item.id,
            choice: .keepBoth,
            expectedFingerprint: item.expectedFingerprint,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        let completedCopy = restartedDrive.snapshot(fileID: copyFileID)
        try require(
            completedCopy?.bytes == remoteChanged
                && restartedDrive.liveFileIDs(path: copyPath) == [copyFileID]
                && restartedDrive.updateCount(fileID: copyFileID) == 1
                && Data(contentsOf: fixture.localRoot.appendingPathComponent(copyPath)) == remoteChanged
                && Data(contentsOf: local) == localChanged
                && Data(contentsOf: remote) == localChanged
                && FolderSyncJournalStore.load(connection: try fixture.savedConnection()) == nil,
            "keep-both restart must reuse the same Drive copy ID exactly once and complete both preserved versions"
        )
    }

    private static func localDestinationSwapCrashRecovery(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        for phase in ["before", "after"] {
            print("bisync-service: local atomic swap crash recovery \(phase)")
            let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
            let local = fixture.localRoot.appendingPathComponent("crash.bin")
            let remote = fixture.remoteRoot.appendingPathComponent("crash.bin")
            let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
            let remoteAnchor = fixture.remoteRoot.appendingPathComponent("anchor.txt")
            let baseline = Data("crash-baseline".utf8)
            let remoteNew = Data(repeating: phase == "before" ? 0x61 : 0x62, count: 64 * 1024)
            try baseline.write(to: local)
            try copyReplacing(local, to: remote)
            try Data("anchor".utf8).write(to: anchor)
            try copyReplacing(anchor, to: remoteAnchor)
            let connection = try await initialize(fixture)
            try remoteNew.write(to: remote, options: .atomic)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [
                "--atomic-swap-crash-worker", phase,
                fixture.catalogURL.path,
                fixture.storeURL.path,
                fixture.configURL.path,
                rcloneURL.path,
                connection.id
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try require(
                process.terminationReason == .exit && process.terminationStatus == 86,
                "atomic swap crash worker must terminate at the requested \(phase)-swap boundary"
            )

            guard let recovered = try FolderSyncConnectionStore.loadRecoveringInterrupted(
                catalogURL: fixture.catalogURL,
                url: fixture.storeURL
            ).first(where: { $0.id == connection.id }) else {
                throw BisyncSelfTestFailure("crashed atomic swap connection is missing after restart")
            }
            let recoveredJournal = try FolderSyncJournalStore.load(connection: recovered)
            try require(
                recovered.status == .recoveryRequired
                    && recoveredJournal?.phase == .recoveryRequired
                    && recoveredJournal?.historyRestored == true,
                "restart must restore the pre-apply history checkpoint after a \(phase)-swap process death"
            )

            let inodeBeforeRetry = FileManager.default.fileExists(atPath: local.path)
                ? try fileInode(local) : 0
            let report = try await fixture.service().synchronize(
                connection: recovered,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            let recoveredLocal = try Data(contentsOf: local)
            let recoveredRemote = try Data(contentsOf: remote)
            try require(
                report.connection.status == .success
                    && recoveredLocal == remoteNew
                    && recoveredRemote == remoteNew,
                "restart after a \(phase)-swap process death must converge to the verified source version"
            )
            let baselineCopies = try fixture.service().recoveryItems(connection: report.connection)
                .filter { $0.location == .externalDrive && $0.originalRelativePath == "crash.bin" }
            try require(
                !baselineCopies.isEmpty,
                "restart after a \(phase)-swap process death must retain the verified pre-swap baseline"
            )
            let stagingRoot = fixture.localRoot
                .appendingPathComponent(".photoarchive", isDirectory: true)
                .appendingPathComponent("sync-staging", isDirectory: true)
            try require(
                try recursiveRegularFiles(in: stagingRoot).isEmpty,
                "restart after a \(phase)-swap process death must not leave an untracked staging copy"
            )
            if phase == "after" {
                try require(
                    try fileInode(local) == inodeBeforeRetry,
                    "bisync recovery must not rewrite a path already installed by the atomic swap before the crash"
                )
            }
        }
    }

    private static func unsupportedLocalSwapFailsClosed(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        print("bisync-service: unsupported local atomic swap fails closed")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("unsupported.bin")
        let remote = fixture.remoteRoot.appendingPathComponent("unsupported.bin")
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        let baseline = Data("unsupported-baseline".utf8)
        let remoteNew = Data("unsupported-remote-new".utf8)
        try baseline.write(to: local)
        try copyReplacing(local, to: remote)
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)
        try remoteNew.write(to: remote, options: .atomic)

        do {
            _ = try await fixture.service(testingLocalSwapErrorCode: ENOTSUP).synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("unsupported atomic swap must stop before replacing the destination")
        } catch FolderSyncConnectionError.concurrentMutationSafetyUnavailable {
            // Expected.
        }
        try require(
            try Data(contentsOf: local) == baseline && Data(contentsOf: remote) == remoteNew,
            "unsupported atomic swap must leave both user copies unchanged"
        )
        guard let reloaded = try FolderSyncConnectionStore.loadRecoveringInterrupted(
            catalogURL: fixture.catalogURL,
            url: fixture.storeURL
        ).first(where: { $0.id == connection.id }) else {
            throw BisyncSelfTestFailure("unsupported atomic swap connection disappeared")
        }
        try require(
            reloaded.status == .safetyUnavailable
                && (try FolderSyncJournalStore.load(connection: reloaded)) == nil,
            "unsupported atomic swap must stop as a clean capability limitation, not a false interrupted mutation"
        )
    }

    private static func drivePreservation(
        _ journal: FolderSyncJournal?,
        path: String
    ) -> FolderSyncDrivePreservation? {
        journal?.items
            .flatMap(\.resources)
            .first(where: { $0.relativePath == path })?
            .drivePreservation
    }

    private static func driveRevisionOverwriteSuccess(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        print("bisync-service: Drive revision overwrite success (mock identity)")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let path = "drive-overwrite.bin"
        let local = fixture.localRoot.appendingPathComponent(path)
        let remote = fixture.remoteRoot.appendingPathComponent(path)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        let baseline = Data("drive-baseline-v1".utf8)
        let app = Data(repeating: 0x44, count: 128 * 1024)
        try baseline.write(to: local)
        try copyReplacing(local, to: remote)
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)
        try app.write(to: local, options: .atomic)

        let drive = FakeDriveRevisionManager()
        let oldID = drive.seedFile(path: path, bytes: baseline, fileID: "old-drive-overwrite")
        let baselineRevisionID = drive.snapshot(fileID: oldID)!.headRevisionID
        let service = fixture.service(
            testingDriveRevisionManager: drive,
            testingUseDriveRevisionProtection: true,
            afterDriveApplyBeforeJournal: {
                guard let journal = try FolderSyncJournalStore.load(connection: connection),
                      let runID = drivePreservation(journal, path: path)?.recoveryRunID else {
                    throw BisyncSelfTestFailure("Drive overwrite mock is missing its recovery run ID")
                }
                drive.moveFile(
                    fileID: oldID,
                    toFolderPath: connection.remoteRecoveryPath + "/" + runID + "/path2"
                )
                _ = drive.seedFile(
                    path: path,
                    bytes: app,
                    fileID: "app-drive-overwrite",
                    keepForever: true
                )
            }
        )
        let report = try await service.synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(
            report.connection.status == .success && !report.conflictPreserved,
            "a protected Drive overwrite without a race should complete successfully"
        )
        try require(
            try Data(contentsOf: remote) == app,
            "the rclone apply path should install the app bytes in the synthetic destination"
        )
        let baselineSnapshot = drive.revisionSnapshot(
            fileID: oldID,
            revisionID: baselineRevisionID
        )
        let appSnapshot = drive.snapshot(fileID: "app-drive-overwrite")
        try require(
            baselineSnapshot?.bytes == baseline
                && baselineSnapshot?.keepForever == true
                && appSnapshot?.bytes == app
                && appSnapshot?.keepForever == true,
            "both the exact baseline revision and app head revision must be pinned"
        )
        let recovery = try service.recoveryItems(connection: report.connection)
            .filter { $0.location == .googleDrive && $0.originalRelativePath == path }
        try require(
            recovery.count == 2
                && recovery.allSatisfy {
                    $0.driveRevisionFileID != nil
                        && $0.driveRevisionID != nil
                        && $0.expectedSHA256 != nil
                },
            "successful overwrite must retain exact revision recovery records for baseline and app versions"
        )
    }

    private static func driveRevisionExternalBeforeApply(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        print("bisync-service: Drive external modification before apply (mock identity)")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let path = "drive-before.bin"
        let local = fixture.localRoot.appendingPathComponent(path)
        let remote = fixture.remoteRoot.appendingPathComponent(path)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        let baseline = Data("drive-before-baseline".utf8)
        let app = Data("drive-before-app".utf8)
        let external = Data("drive-before-external".utf8)
        try baseline.write(to: local)
        try copyReplacing(local, to: remote)
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)
        try app.write(to: local, options: .atomic)

        let drive = FakeDriveRevisionManager()
        let oldID = drive.seedFile(path: path, bytes: baseline, fileID: "old-drive-before")
        let baselineRevisionID = drive.snapshot(fileID: oldID)!.headRevisionID
        let service = fixture.service(
            afterPreflight: {
                try external.write(to: remote, options: .atomic)
                _ = drive.addRevision(fileID: oldID, bytes: external)
            },
            testingDriveRevisionManager: drive,
            testingUseDriveRevisionProtection: true
        )
        do {
            _ = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("a Drive head changed after preflight must not be overwritten")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        let journal = try FolderSyncJournalStore.load(connection: connection)
        let preservation = drivePreservation(journal, path: path)
        let head = drive.snapshot(fileID: oldID)
        try require(
            journal?.phase == .confirmationRequired
                && preservation?.baseline?.revisionID == baselineRevisionID
                && preservation?.baseline?.keepForeverVerified == true
                && preservation?.conflicts.count == 1
                && preservation?.conflicts.first?.revisionID == head?.headRevisionID
                && preservation?.conflicts.first?.keepForeverVerified == true,
            "preflight baseline and the externally changed head must be pinned as distinct exact revisions"
        )
        try require(
            try Data(contentsOf: remote) == external,
            "pre-apply external Drive content must remain untouched when confirmation is required"
        )
    }

    private static func driveRevisionRaceBetweenHeadAndRevisionList(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        print("bisync-service: Drive revision A/B/C race between head and revision list")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let path = "drive-revision-window.bin"
        let local = fixture.localRoot.appendingPathComponent(path)
        let remote = fixture.remoteRoot.appendingPathComponent(path)
        let bytesA = Data("revision-A".utf8)
        let bytesB = Data("revision-B-external".utf8)
        let bytesC = Data("revision-C-app".utf8)
        try bytesA.write(to: local)
        try copyReplacing(local, to: remote)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)
        try bytesC.write(to: local, options: .atomic)

        let drive = FakeDriveRevisionManager()
        let fileID = drive.seedFile(path: path, bytes: bytesA, fileID: "drive-revision-window")
        let revisionA = drive.snapshot(fileID: fileID)!.headRevisionID
        let service = fixture.service(
            testingDriveRevisionManager: drive,
            testingUseDriveRevisionProtection: true,
            afterDriveBaselineHeadVerifiedBeforeRevisionList: { relativePath in
                guard relativePath == path,
                      drive.snapshot(fileID: fileID)?.bytes == bytesA else { return }
                _ = drive.addRevision(fileID: fileID, bytes: bytesB)
            }
        )
        do {
            _ = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("external B inserted between head verification and revision listing must stop C")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }

        guard let revisionB = try drive.revisions(fileID: fileID).first(where: { revision in
            drive.revisionSnapshot(fileID: fileID, revisionID: revision.id)?.bytes == bytesB
        })?.id else {
            throw BisyncSelfTestFailure("A/B/C race hook did not create revision B")
        }
        let journal = try FolderSyncJournalStore.load(connection: connection)
        let preservation = drivePreservation(journal, path: path)
        let head = drive.snapshot(fileID: fileID)
        let savedB = drive.revisionSnapshot(fileID: fileID, revisionID: revisionB)
        let revisions = try drive.revisions(fileID: fileID)
        let containsC = revisions.contains { revision in
            drive.revisionSnapshot(fileID: fileID, revisionID: revision.id)?.bytes == bytesC
        }
        try require(
            journal?.phase == .confirmationRequired
                && preservation?.baseline?.revisionID == revisionA
                && preservation?.baseline?.keepForeverVerified == true
                && preservation?.conflicts.contains(where: {
                    $0.fileID == fileID
                        && $0.revisionID == revisionB
                        && $0.keepForeverVerified
                }) == true,
            "revision B must be preserved as a distinct pinned conflict, not classified as a safe preexisting revision"
        )
        try require(
            head?.headRevisionID == revisionB
                && head?.bytes == bytesB
                && savedB?.bytes == bytesB
                && savedB?.keepForever == true
                && !containsC,
            "A/B/C race must preserve exact B bytes and stop before app revision C is written"
        )

        let restarted = try FolderSyncConnectionStore.loadRecoveringInterrupted(
            catalogURL: fixture.catalogURL,
            url: fixture.storeURL
        ).first(where: { $0.id == connection.id })
        let restartedJournal = try FolderSyncJournalStore.load(connection: connection)
        let restartedPreservation = drivePreservation(restartedJournal, path: path)
        try require(
            restarted?.status == .confirmationRequired
                && restartedJournal?.phase == .confirmationRequired
                && restartedPreservation?.baseline?.revisionID == revisionA
                && restartedPreservation?.conflicts.contains(where: { $0.revisionID == revisionB }) == true,
            "restart must retain the same baseline-versus-conflict revision identity for A and B"
        )
    }

    private static func driveRevisionDuplicateAndPinFailures(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        print("bisync-service: Drive duplicate IDs and pin failures (mock identity)")
        do {
            let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
            let path = "drive-duplicate.bin"
            let local = fixture.localRoot.appendingPathComponent(path)
            let remote = fixture.remoteRoot.appendingPathComponent(path)
            let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
            let baseline = Data("drive-duplicate-baseline".utf8)
            let app = Data("drive-duplicate-app".utf8)
            try baseline.write(to: local)
            try copyReplacing(local, to: remote)
            try Data("anchor".utf8).write(to: anchor)
            try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
            let connection = try await initialize(fixture)
            try app.write(to: local, options: .atomic)
            let drive = FakeDriveRevisionManager()
            _ = drive.seedFile(path: path, bytes: baseline, fileID: "drive-duplicate-old")
            let service = fixture.service(
                afterPreflight: {
                    _ = drive.seedFile(
                        path: path,
                        bytes: Data("drive-duplicate-external".utf8),
                        fileID: "drive-duplicate-external"
                    )
                },
                testingDriveRevisionManager: drive,
                testingUseDriveRevisionProtection: true
            )
            do {
                _ = try await service.synchronize(
                    connection: connection,
                    confirmInitialSync: false,
                    catalogURL: fixture.catalogURL,
                    storeURL: fixture.storeURL
                )
                throw BisyncSelfTestFailure("same-name Drive IDs must not be selected arbitrarily")
            } catch FolderSyncConnectionError.confirmationRequired {
                // Expected.
            }
            let preservation = drivePreservation(
                try FolderSyncJournalStore.load(connection: connection),
                path: path
            )
            try require(
                preservation?.observedDuplicateFileIDs == [
                    "drive-duplicate-external", "drive-duplicate-old"
                ],
                "same-name Drive IDs must be persisted as an unresolved conflict set"
            )
        }

        for failure in [DriveRevisionAPIError.revisionLimit, .permission, .authentication] {
            let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
            let path = "drive-pin-failure-\(String(describing: failure)).bin"
            let local = fixture.localRoot.appendingPathComponent(path)
            let remote = fixture.remoteRoot.appendingPathComponent(path)
            let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
            let baseline = Data("pin-failure-baseline".utf8)
            let app = Data("pin-failure-app".utf8)
            try baseline.write(to: local)
            try copyReplacing(local, to: remote)
            try Data("anchor".utf8).write(to: anchor)
            try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
            let connection = try await initialize(fixture)
            try app.write(to: local, options: .atomic)
            let drive = FakeDriveRevisionManager()
            _ = drive.seedFile(path: path, bytes: baseline)
            drive.setPinFailure(failure)
            do {
                _ = try await fixture.service(
                    testingDriveRevisionManager: drive,
                    testingUseDriveRevisionProtection: true
                ).synchronize(
                    connection: connection,
                    confirmInitialSync: false,
                    catalogURL: fixture.catalogURL,
                    storeURL: fixture.storeURL
                )
                throw BisyncSelfTestFailure("Drive revision pin failure must stop before apply")
            } catch FolderSyncConnectionError.concurrentMutationSafetyUnavailable
                where failure == .revisionLimit {
                // Expected.
            } catch FolderSyncConnectionError.connectionCheckRequired
                where failure == .permission || failure == .authentication {
                // Expected.
            }
            try require(
                try Data(contentsOf: remote) == baseline,
                "pin failure must leave the Drive destination bytes unchanged"
            )
            let restarted = try FolderSyncConnectionStore.loadRecoveringInterrupted(
                catalogURL: fixture.catalogURL,
                url: fixture.storeURL
            ).first(where: { $0.id == connection.id })
            try require(
                restarted?.status != .recoveryRequired
                    && (try FolderSyncJournalStore.load(connection: connection)) == nil,
                "clean pre-apply pin failures must not become false interrupted recovery"
            )
        }
    }

    private enum DriveMockPostRace {
        case recoveryModified
        case appModified
        case duplicateCreated
        case recoveryTrashed
    }

    private static func driveRevisionPostApplyRaces(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        let cases: [(DriveMockPostRace, String)] = [
            (.recoveryModified, "recovery-modified"),
            (.appModified, "app-modified"),
            (.duplicateCreated, "duplicate-created"),
            (.recoveryTrashed, "recovery-trashed")
        ]
        for (race, label) in cases {
            print("bisync-service: Drive post-apply race \(label) (mock identity)")
            let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
            let path = "drive-post-\(label).bin"
            let local = fixture.localRoot.appendingPathComponent(path)
            let remote = fixture.remoteRoot.appendingPathComponent(path)
            let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
            let baseline = Data("drive-post-baseline-\(label)".utf8)
            let app = Data(repeating: 0x51, count: 96 * 1024)
            let external = Data("drive-post-external-\(label)".utf8)
            try baseline.write(to: local)
            try copyReplacing(local, to: remote)
            try Data("anchor".utf8).write(to: anchor)
            try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
            let connection = try await initialize(fixture)
            try app.write(to: local, options: .atomic)

            let drive = FakeDriveRevisionManager()
            let oldID = drive.seedFile(path: path, bytes: baseline, fileID: "old-\(label)")
            let appID = "app-\(label)"
            let service = fixture.service(
                testingDriveRevisionManager: drive,
                testingUseDriveRevisionProtection: true,
                afterDriveApplyBeforeJournal: {
                    guard let journal = try FolderSyncJournalStore.load(connection: connection),
                          let runID = drivePreservation(journal, path: path)?.recoveryRunID else {
                        throw BisyncSelfTestFailure("post-apply race is missing recovery run ID")
                    }
                    drive.moveFile(
                        fileID: oldID,
                        toFolderPath: connection.remoteRecoveryPath + "/" + runID + "/path2"
                    )
                    _ = drive.seedFile(
                        path: path,
                        bytes: app,
                        fileID: appID,
                        keepForever: true
                    )
                    switch race {
                    case .recoveryModified:
                        _ = drive.addRevision(fileID: oldID, bytes: external)
                    case .appModified:
                        _ = drive.addRevision(fileID: appID, bytes: external)
                    case .duplicateCreated:
                        _ = drive.seedFile(
                            path: path,
                            bytes: external,
                            fileID: "external-duplicate-\(label)"
                        )
                    case .recoveryTrashed:
                        drive.trashFile(fileID: oldID)
                    }
                }
            )
            let report = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            let expectsConflict = race != .recoveryTrashed
            try require(
                report.connection.status == (expectsConflict ? .conflict : .success)
                    && report.conflictPreserved == expectsConflict,
                "post-apply Drive race \(label) should report the correct preserved-conflict state"
            )
            let recovery = try service.recoveryItems(connection: report.connection)
                .filter { $0.location == .googleDrive && $0.originalRelativePath == path }
            try require(
                recovery.count >= (expectsConflict ? 3 : 2),
                "post-apply Drive race \(label) must retain baseline/app and any observed conflict revision"
            )
            if race == .recoveryModified {
                let head = drive.snapshot(fileID: oldID)
                try require(
                    head?.bytes == external && head?.keepForever == true,
                    "a changed recovery head must itself be pinned as an observed conflict revision"
                )
            }
            if race == .appModified {
                guard let head = drive.snapshot(fileID: appID) else {
                    throw BisyncSelfTestFailure("app-modified Drive file disappeared")
                }
                let revisions = try drive.revisions(fileID: appID)
                let pinnedApp = revisions.first(where: { revision in
                    guard revision.id != head.headRevisionID,
                          let snapshot = drive.revisionSnapshot(fileID: appID, revisionID: revision.id)
                    else { return false }
                    return snapshot.bytes == app && snapshot.keepForever
                })
                try require(
                    pinnedApp != nil && head.bytes == external && head.keepForever,
                    "external-after must preserve the pinned app revision and pin the observed external head"
                )
            }
            if race == .duplicateCreated {
                try require(
                    drive.liveFileIDs(path: path).count == 2,
                    "same-name Drive IDs must remain separate instead of being deduplicated"
                )
            }
            if race == .recoveryTrashed {
                try require(
                    drive.snapshot(fileID: oldID)?.trashed == true,
                    "a recovery file moved to Trash must remain addressable by its pinned revision identity"
                )
            }
        }
    }

    private static func initialUniqueMerge(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: initial unique merge")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let localName = "로컬 전용 - 사진.JPG"
        let remoteName = "원격 전용 - 사진.JPG"
        try writeSyntheticJPEG(to: fixture.localRoot.appendingPathComponent(localName), pixelValue: 40)
        try writeSyntheticJPEG(to: fixture.remoteRoot.appendingPathComponent(remoteName), pixelValue: 90)

        let report: FolderSyncRunReport
        do {
            report = try await fixture.service().synchronize(
                connection: fixture.connection,
                confirmInitialSync: true,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
        } catch {
            printSyntheticRunLogs(workDirectoryPath: fixture.connection.workDirectoryPath)
            throw error
        }
        try require(report.connection.isInitialized, "mergeable first sync should initialize the connection")
        try require(report.connection.initialSyncStartedAt == nil, "successful first sync should clear its initialization marker")
        try require(report.connection.lastSuccessAt != nil, "successful first sync should persist last success time")
        try require(
            FileManager.default.fileExists(atPath: fixture.remoteRoot.appendingPathComponent(localName).path)
                && FileManager.default.fileExists(atPath: fixture.localRoot.appendingPathComponent(remoteName).path),
            "first sync should merge files that exist on only one side"
        )
    }

    private static func initialConflict(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: initial conflict")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("same path.txt")
        let remote = fixture.remoteRoot.appendingPathComponent("same path.txt")
        try Data("left version".utf8).write(to: local)
        try Data("right version is different".utf8).write(to: remote)
        let beforeLocal = try Data(contentsOf: local)
        let beforeRemote = try Data(contentsOf: remote)

        do {
            _ = try await fixture.service().synchronize(
                connection: fixture.connection,
                confirmInitialSync: true,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("same-path first-sync mismatch must stop instead of selecting the newer copy")
        } catch FolderSyncConnectionError.initialConflict {
            // Expected.
        }
        try require(
            try Data(contentsOf: local) == beforeLocal && Data(contentsOf: remote) == beforeRemote,
            "first-sync conflict detection must not overwrite either user file"
        )
        try require(try fixture.savedConnection().status == .initialConflict, "first-sync mismatch should persist conflict state")
    }

    private static func initialEqualContentDifferentModtime(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: initial equal content with different modtime")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("same.txt")
        let remote = fixture.remoteRoot.appendingPathComponent("same.txt")
        let bytes = Data("same bytes".utf8)
        try bytes.write(to: local)
        try bytes.write(to: remote)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: local.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)],
            ofItemAtPath: remote.path
        )

        let report: FolderSyncRunReport
        do {
            report = try await fixture.service().synchronize(
                connection: fixture.connection,
                confirmInitialSync: true,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
        } catch {
            printSyntheticRunLogs(workDirectoryPath: fixture.connection.workDirectoryPath)
            throw error
        }
        let localBytes = try Data(contentsOf: local)
        let remoteBytes = try Data(contentsOf: remote)
        try require(
            report.connection.status == .success
                && localBytes == bytes
                && remoteBytes == bytes,
            "first-sync immutable protection should compare existing content rather than rejecting harmless modtime drift"
        )
    }

    private static func initialConcurrentExistingChange(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: initial concurrent existing-file change")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("same.txt")
        let remote = fixture.remoteRoot.appendingPathComponent("same.txt")
        let baseline = Data("baseline".utf8)
        let external = Data("changed on destination after preflight".utf8)
        try baseline.write(to: local)
        try baseline.write(to: remote)

        let service = fixture.service(afterPreflight: {
            try external.write(to: remote, options: .atomic)
        })
        do {
            _ = try await service.synchronize(
                connection: fixture.connection,
                confirmInitialSync: true,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("first sync must not overwrite an existing file changed after preflight")
        } catch FolderSyncConnectionError.initialConflict {
            // The apply-boundary has not opened yet. The important property is
            // that the just-before-apply content check rejected the changed
            // same-path file before the first resync could overwrite it.
        }

        try require(
            try Data(contentsOf: local) == baseline && Data(contentsOf: remote) == external,
            "first-sync pre-apply recheck must preserve a same-path destination change made after preflight"
        )
        let saved = try fixture.savedConnection()
        try require(
            !saved.isInitialized
                && saved.initialSyncStartedAt == nil
                && saved.status == .initialConflict,
            "first setup must stop before the apply boundary when an existing same-path file changes"
        )
    }

    private static func initialPostPreflightAdd(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: initial post-preflight add")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let localAnchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: localAnchor)
        let lateLocal = fixture.localRoot.appendingPathComponent("late.txt")
        let service = fixture.service(afterPreflight: {
            try Data("late addition".utf8).write(to: lateLocal)
        })
        let report = try await service.synchronize(
            connection: fixture.connection,
            confirmInitialSync: true,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        let lateRemote = fixture.remoteRoot.appendingPathComponent("late.txt")
        try require(
            report.connection.status == .success
                && report.connection.isInitialized
                && FileManager.default.fileExists(atPath: lateRemote.path)
                && Data(contentsOf: lateRemote) == Data(contentsOf: lateLocal),
            "a file added during first-connection planning must be merged before initialization is marked complete"
        )
    }

    private static func initialPostPreflightDelete(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: initial post-preflight delete")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("keep-on-first-sync.txt")
        let remote = fixture.remoteRoot.appendingPathComponent("keep-on-first-sync.txt")
        try Data("must survive first sync".utf8).write(to: local)
        try copyReplacing(local, to: remote)
        let service = fixture.service(afterPreflight: {
            try FileManager.default.removeItem(at: local)
        })
        let report = try await service.synchronize(
            connection: fixture.connection,
            confirmInitialSync: true,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(
            report.connection.status == .success
                && FileManager.default.fileExists(atPath: local.path)
                && FileManager.default.fileExists(atPath: remote.path)
                && Data(contentsOf: local) == Data(contentsOf: remote),
            "a first-connection disappearance must be treated as a mergeable one-sided file, not deletion authority"
        )
    }

    private static func ordinaryMedia(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: ordinary media")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let imageName = "공백 이름 - 따옴표 \"파일\".JPG"
        let movieName = "일반 동영상 - sample.MOV"
        let localImage = fixture.localRoot.appendingPathComponent(imageName)
        let localMovie = fixture.localRoot.appendingPathComponent(movieName)
        try writeSyntheticJPEG(to: localImage, pixelValue: 20)
        try await writeSyntheticTimedMetadataMovie(to: localMovie, markerValues: [])
        try copyReplacing(localImage, to: fixture.remoteRoot.appendingPathComponent(imageName))
        try copyReplacing(localMovie, to: fixture.remoteRoot.appendingPathComponent(movieName))
        let connection = try await initialize(fixture)

        try writeSyntheticJPEGReplacing(localImage, pixelValue: 180)
        try await writeSyntheticMovieReplacing(localMovie, markerValues: [0])
        let report: FolderSyncRunReport
        do {
            report = try await fixture.service().synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
        } catch {
            printSyntheticRunLogs(workDirectoryPath: fixture.connection.workDirectoryPath)
            throw error
        }
        try require(
            try Data(contentsOf: localImage) == Data(contentsOf: fixture.remoteRoot.appendingPathComponent(imageName)),
            "ordinary image changes should synchronize through the service"
        )
        try require(
            try Data(contentsOf: localMovie) == Data(contentsOf: fixture.remoteRoot.appendingPathComponent(movieName)),
            "ordinary video changes should synchronize through the service"
        )
        try require(report.connection.status == .success, "ordinary synthetic sync should finish successfully")
    }

    private static func ordinaryRenameMove(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: ordinary rename/move")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let oldLocal = fixture.localRoot.appendingPathComponent("old.txt")
        let oldRemote = fixture.remoteRoot.appendingPathComponent("old.txt")
        try Data("rename-me".utf8).write(to: oldLocal)
        try copyReplacing(oldLocal, to: oldRemote)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)

        let album = fixture.localRoot.appendingPathComponent("album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let newLocal = album.appendingPathComponent("new.txt")
        try FileManager.default.moveItem(at: oldLocal, to: newLocal)

        let report: FolderSyncRunReport
        do {
            report = try await fixture.service().synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
        } catch {
            printSyntheticRunLogs(workDirectoryPath: fixture.connection.workDirectoryPath)
            throw error
        }
        let newRemote = fixture.remoteRoot.appendingPathComponent("album/new.txt")
        try require(
            report.connection.status == .success
                && !FileManager.default.fileExists(atPath: oldRemote.path)
                && FileManager.default.fileExists(atPath: newRemote.path)
                && Data(contentsOf: newRemote) == Data(contentsOf: newLocal),
            "an exact-content rename/move should propagate without being treated as an approved deletion"
        )
    }

    private static func ordinaryBothModifiedConflict(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: ordinary both-modified conflict")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("conflict.txt")
        let remote = fixture.remoteRoot.appendingPathComponent("conflict.txt")
        try Data("baseline".utf8).write(to: local)
        try copyReplacing(local, to: remote)
        let connection = try await initialize(fixture)

        let localChanged = Data("external drive version".utf8)
        let remoteChanged = Data("google drive version".utf8)
        try localChanged.write(to: local, options: .atomic)
        try remoteChanged.write(to: remote, options: .atomic)

        do {
            _ = try await fixture.service().synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("both-modified ordinary files must wait for user confirmation")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        try require(
            try Data(contentsOf: local) == localChanged
                && Data(contentsOf: remote) == remoteChanged,
            "both-modified ordinary conflict must preserve both original versions before apply"
        )
        let journal = try FolderSyncJournalStore.load(connection: connection)
        try require(
            journal?.phase == .confirmationRequired
                && journal?.items.contains(where: {
                    $0.state == .confirmationRequired && $0.note == "both_sides_modified"
                }) == true,
            "both-modified ordinary conflict must persist an explicit confirmation item"
        )
    }

    private static func ordinaryDeleteModifyConflict(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: ordinary delete-modify conflict")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("delete-modify.txt")
        let remote = fixture.remoteRoot.appendingPathComponent("delete-modify.txt")
        try Data("baseline".utf8).write(to: local)
        try copyReplacing(local, to: remote)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)

        try FileManager.default.removeItem(at: local)
        let remoteChanged = Data("modified after the other side deleted".utf8)
        try remoteChanged.write(to: remote, options: .atomic)

        do {
            _ = try await fixture.service().synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("delete-vs-modify ordinary file must wait for user confirmation")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        try require(
            !FileManager.default.fileExists(atPath: local.path)
                && Data(contentsOf: remote) == remoteChanged,
            "delete-vs-modify conflict must preserve the deletion and modified version without auto-resolving"
        )
        let journal = try FolderSyncJournalStore.load(connection: connection)
        try require(
            journal?.phase == .confirmationRequired
                && journal?.items.contains(where: {
                    $0.state == .confirmationRequired && $0.note == "delete_modify_conflict"
                }) == true,
            "delete-vs-modify ordinary conflict must persist an explicit confirmation item"
        )
    }

    private static func conflictChoiceTargetChangeInvalidatesApproval(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        print("bisync-service: conflict choice target change invalidates approval")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("choice-race.bin")
        let remote = fixture.remoteRoot.appendingPathComponent("choice-race.bin")
        let baseline = Data("00000000".utf8)
        let localChanged = Data("11111111".utf8)
        let remoteChanged = Data("22222222".utf8)
        let changedAgain = Data("33333333".utf8)
        try baseline.write(to: local)
        try copyReplacing(local, to: remote)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)
        try localChanged.write(to: local, options: .atomic)
        try remoteChanged.write(to: remote, options: .atomic)

        let service = fixture.service()
        do {
            _ = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("both-modified conflict should require a user choice")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        guard let item = try service.conflictItems(
            connection: try fixture.savedConnection(),
            catalogURL: fixture.catalogURL
        ).first(where: { $0.relativePaths == ["choice-race.bin"] }) else {
            throw BisyncSelfTestFailure("both-modified conflict must expose a consumer choice item")
        }

        // Keep the byte size identical so a size/mtime-only approval would be
        // vulnerable. The content fingerprint must still invalidate it.
        try changedAgain.write(to: remote, options: .atomic)
        do {
            try await service.resolveConflict(
                connection: try fixture.savedConnection(),
                itemID: item.id,
                choice: .useExternalDrive,
                expectedFingerprint: item.expectedFingerprint,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("non-Drive conflict apply must fail closed before mutation")
        } catch FolderSyncConnectionError.concurrentMutationSafetyUnavailable {
            // Expected. Stale-fingerprint invalidation itself is exercised by
            // the focused actual-Drive validation where direct mutation is
            // available.
        }
        try require(
            try Data(contentsOf: local) == localChanged
                && Data(contentsOf: remote) == changedAgain,
            "stale conflict approval must not mutate either side"
        )

        do {
            try await RcloneBisyncService().resolveConflict(
                connection: try fixture.savedConnection(),
                itemID: item.id,
                choice: .useExternalDrive,
                expectedFingerprint: item.expectedFingerprint,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("public conflict resolution must remain production-blocked")
        } catch FolderSyncConnectionError.concurrentMutationSafetyUnavailable {
            // Expected.
        }
        try require(
            try Data(contentsOf: local) == localChanged
                && Data(contentsOf: remote) == changedAgain,
            "the public conflict-resolution gate must stop before user-file mutation"
        )
    }

    private static func deletionApprovalAndPlanChange(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: deletion approval and plan change")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        for index in 0..<50 {
            let name = String(format: "item-%02d.txt", index)
            let local = fixture.localRoot.appendingPathComponent(name)
            try Data("item-\(index)".utf8).write(to: local)
            try copyReplacing(local, to: fixture.remoteRoot.appendingPathComponent(name))
        }
        let connection = try await initialize(fixture)
        for index in 0..<10 {
            let name = String(format: "item-%02d.txt", index)
            try FileManager.default.removeItem(at: fixture.localRoot.appendingPathComponent(name))
        }

        do {
            _ = try await fixture.service().synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("ten-of-fifty deletion plan should require confirmation")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        guard let firstPlan = try FolderSyncJournalStore.load(connection: connection)?.pendingDeletionPlan else {
            throw BisyncSelfTestFailure("deletion confirmation must persist the exact displayed plan")
        }
        try require(
            firstPlan.requiresConfirmation && firstPlan.logicalItemCount == 10,
            "ten-of-fifty deletion plan should be persisted as confirmation-required"
        )
        for index in 0..<10 {
            let name = String(format: "item-%02d.txt", index)
            try require(
                FileManager.default.fileExists(atPath: fixture.remoteRoot.appendingPathComponent(name).path),
                "no destination deletion may happen before approval"
            )
        }

        try FileManager.default.removeItem(
            at: fixture.localRoot.appendingPathComponent("item-10.txt")
        )
        do {
            _ = try await fixture.service().synchronize(
                connection: try fixture.savedConnection(),
                confirmInitialSync: false,
                approvedDeletionPlanID: firstPlan.id,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("approval must not be reused when the deletion plan changes")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        guard let secondPlan = try FolderSyncJournalStore.load(connection: connection)?.pendingDeletionPlan else {
            throw BisyncSelfTestFailure("changed deletion plan must replace the stale approval plan")
        }
        try require(
            secondPlan.id != firstPlan.id && secondPlan.logicalItemCount == 11,
            "plan fingerprint must change after an additional deletion"
        )
        try require(
            FileManager.default.fileExists(atPath: fixture.remoteRoot.appendingPathComponent("item-10.txt").path),
            "stale approval must not delete newly added plan entries"
        )

        let report = try await fixture.service().synchronize(
            connection: try fixture.savedConnection(),
            confirmInitialSync: false,
            approvedDeletionPlanID: secondPlan.id,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(report.connection.status == .success, "approved unchanged deletion plan should complete")
        for index in 0..<11 {
            let name = String(format: "item-%02d.txt", index)
            try require(
                !FileManager.default.fileExists(atPath: fixture.remoteRoot.appendingPathComponent(name).path),
                "approved deletion plan should remove exactly its displayed destination items"
            )
        }
        let recovery = try fixture.service().recoveryItems(connection: report.connection)
        let recoveredNames = Set(
            recovery.filter { $0.location == .googleDrive }.map(\.originalRelativePath)
        )
        try require(
            (0..<11).allSatisfy { recoveredNames.contains(String(format: "item-%02d.txt", $0)) },
            "approved deletions must retain actual destination copies in the separated recovery area"
        )
    }

    private static func entireFolderDeletionApproval(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: entire-folder deletion approval")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        for name in ["album/a.txt", "album/b.txt"] {
            let local = fixture.localRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: local.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(name.utf8).write(to: local)
            try copyReplacing(local, to: fixture.remoteRoot.appendingPathComponent(name))
        }
        let connection = try await initialize(fixture)
        try FileManager.default.removeItem(at: fixture.localRoot.appendingPathComponent("album"))

        do {
            _ = try await fixture.service().synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("emptying a previously non-empty folder must require confirmation")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        let plan = try FolderSyncJournalStore.load(connection: connection)?.pendingDeletionPlan
        try require(
            plan?.requiresConfirmation == true
                && plan?.emptiedNonEmptyDirectories.contains("google_drive:album") == true,
            "folder-emptying confirmation must identify the affected destination folder"
        )
        try require(
            FileManager.default.fileExists(atPath: fixture.remoteRoot.appendingPathComponent("album/a.txt").path)
                && FileManager.default.fileExists(atPath: fixture.remoteRoot.appendingPathComponent("album/b.txt").path),
            "folder-emptying plan must not mutate before confirmation"
        )
    }

    private static func approvedDeletionTargetChangesBeforeApply(
        parent: URL,
        rcloneURL: URL
    ) async throws {
        print("bisync-service: approved deletion target changes before apply")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        for index in 0..<50 {
            let name = String(format: "item-%02d.txt", index)
            let local = fixture.localRoot.appendingPathComponent(name)
            try Data("baseline-\(index)".utf8).write(to: local)
            try copyReplacing(local, to: fixture.remoteRoot.appendingPathComponent(name))
        }
        let connection = try await initialize(fixture)
        for index in 0..<10 {
            try FileManager.default.removeItem(
                at: fixture.localRoot.appendingPathComponent(String(format: "item-%02d.txt", index))
            )
        }

        do {
            _ = try await fixture.service().synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("large deletion should first require approval")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        guard let plan = try FolderSyncJournalStore.load(connection: connection)?.pendingDeletionPlan else {
            throw BisyncSelfTestFailure("approved deletion test requires a persisted plan")
        }

        let changedRemote = fixture.remoteRoot.appendingPathComponent("item-00.txt")
        let changedBytes = Data("changed after approval preflight".utf8)
        let service = fixture.service(afterPreflight: {
            try changedBytes.write(to: changedRemote, options: .atomic)
        })
        do {
            _ = try await service.synchronize(
                connection: try fixture.savedConnection(),
                confirmInitialSync: false,
                approvedDeletionPlanID: plan.id,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("approved deletion must stop when the destination content changes before apply")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        try require(
            try Data(contentsOf: changedRemote) == changedBytes,
            "a changed deletion target must be preserved instead of being removed under stale approval"
        )
        try require(
            try FolderSyncJournalStore.load(connection: connection)?.items.contains(where: {
                $0.note == "deletion_target_changed_before_apply"
            }) == true,
            "changed deletion target must persist a distinct confirmation reason"
        )
    }

    private static func recoveryRestoreAndCollision(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: recovery restore and collision")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("restore-me.txt")
        let remote = fixture.remoteRoot.appendingPathComponent("restore-me.txt")
        let contents = Data("restore contents".utf8)
        try contents.write(to: local)
        try copyReplacing(local, to: remote)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)
        try FileManager.default.removeItem(at: remote)

        let report = try await fixture.service().synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(
            !FileManager.default.fileExists(atPath: local.path),
            "one-sided remote deletion should propagate after initialization"
        )
        let recovery = try fixture.service().recoveryItems(connection: report.connection)
        guard let item = recovery.first(where: {
            $0.location == .externalDrive && $0.originalRelativePath == "restore-me.txt"
        }) else {
            throw BisyncSelfTestFailure("local deletion must retain an actual external-drive recovery copy")
        }

        try fixture.service().restoreRecoveryItem(
            item,
            connection: report.connection,
            catalogURL: fixture.catalogURL
        )
        try require(
            FileManager.default.fileExists(atPath: local.path)
                && Data(contentsOf: local) == contents,
            "explicit recovery restore must recreate and verify the original file"
        )
        try require(
            try fixture.service().recoveryItems(connection: report.connection).contains(where: { $0.id == item.id }),
            "restoring must not automatically delete the retained recovery copy"
        )
        do {
            try fixture.service().restoreRecoveryItem(
                item,
                connection: report.connection,
                catalogURL: fixture.catalogURL
            )
            throw BisyncSelfTestFailure("restore must not overwrite an existing destination")
        } catch FolderSyncConnectionError.restoreDestinationExists {
            // Expected.
        }

        let syntheticTrash = fixture.localRoot.deletingLastPathComponent()
            .appendingPathComponent("synthetic-trash", isDirectory: true)
        try fixture.service(
            testingLocalRecoveryTrashDirectory: syntheticTrash
        ).discardRecoveryItem(
            item,
            connection: report.connection,
            catalogURL: fixture.catalogURL
        )
        try require(
            !(try fixture.service().recoveryItems(connection: report.connection).contains(where: {
                $0.id == item.id
            })),
            "explicit local recovery cleanup should remove only the selected retained copy"
        )
        try require(
            FileManager.default.fileExists(atPath: local.path)
                && Data(contentsOf: local) == contents,
            "cleaning a recovery copy must not remove the file restored to its original location"
        )

        let remoteFixture = try Self.fixture(parent: parent, rcloneURL: rcloneURL)
        let remoteLocal = remoteFixture.localRoot.appendingPathComponent("remote-recovery.txt")
        let remotePeer = remoteFixture.remoteRoot.appendingPathComponent("remote-recovery.txt")
        try Data("remote recovery contents".utf8).write(to: remoteLocal)
        try copyReplacing(remoteLocal, to: remotePeer)
        let remoteAnchor = remoteFixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: remoteAnchor)
        try copyReplacing(remoteAnchor, to: remoteFixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let remoteConnection = try await initialize(remoteFixture)
        try FileManager.default.removeItem(at: remoteLocal)
        let remoteReport = try await remoteFixture.service().synchronize(
            connection: remoteConnection,
            confirmInitialSync: false,
            catalogURL: remoteFixture.catalogURL,
            storeURL: remoteFixture.storeURL
        )
        let remoteRecovery = try remoteFixture.service().recoveryItems(
            connection: remoteReport.connection
        )
        guard let remoteItem = remoteRecovery.first(where: {
            $0.location == .googleDrive && $0.originalRelativePath == "remote-recovery.txt"
        }) else {
            throw BisyncSelfTestFailure("remote deletion must retain a Drive-side recovery copy")
        }
        try remoteFixture.service().discardRecoveryItem(
            remoteItem,
            connection: remoteReport.connection,
            catalogURL: remoteFixture.catalogURL
        )
        try require(
            !(try remoteFixture.service().recoveryItems(connection: remoteReport.connection).contains(where: {
                $0.id == remoteItem.id
            })),
            "explicit Drive recovery cleanup should remove only the selected recovery object"
        )
    }

    private static func incrementalEfficiency(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: incremental efficiency")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let name = "ordinary.JPG"
        let local = fixture.localRoot.appendingPathComponent(name)
        let remote = fixture.remoteRoot.appendingPathComponent(name)
        try writeSyntheticJPEG(to: local, pixelValue: 30)
        try copyReplacing(local, to: remote)
        let connection = try await initialize(fixture)

        let unchangedInode = try fileInode(remote)
        let unchangedMetrics = RcloneBisyncTestingMetricsRecorder()
        let unchanged = try await fixture.service(testingMetrics: unchangedMetrics).synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        let unchangedSnapshot = unchangedMetrics.snapshot()
        let unchangedInodeAfter = try fileInode(remote)
        try require(
            unchanged.changedObjectCount == 0
                && unchangedSnapshot.metadataProbeCount == 0
                && unchangedSnapshot.fullHashBytes == 0
                && unchangedSnapshot.remoteProbeDownloadBytes == 0
                && unchangedSnapshot.remoteHashQueryCount == 0
                && unchangedSnapshot.applyTransferredBytes == 0
                && unchangedSnapshot.applyTransferCount == 0
                && unchangedInodeAfter == unchangedInode,
            "an unchanged rerun must not re-probe, full-hash, download for probing, or rewrite ordinary media"
        )

        try writeSyntheticJPEGReplacing(local, pixelValue: 180)
        let changedMetrics = RcloneBisyncTestingMetricsRecorder()
        let changed = try await fixture.service(testingMetrics: changedMetrics).synchronize(
            connection: unchanged.connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        let changedSnapshot = changedMetrics.snapshot()
        try require(
            changed.changedObjectCount == 1
                && changedSnapshot.metadataProbeCount == 1
                && changedSnapshot.fullHashBytes == 0
                && changedSnapshot.remoteProbeDownloadBytes == 0
                && changedSnapshot.remoteHashQueryCount == 1
                && changedSnapshot.applyTransferredBytes > 0
                && changedSnapshot.applyTransferCount == 1,
            "one changed ordinary image should probe only that candidate, perform exactly one remote hash query for post-apply verification, and avoid Live Photo full-hash/download work "
                + "(changed=\(changed.changedObjectCount), probes=\(changedSnapshot.metadataProbeCount), "
                + "hashBytes=\(changedSnapshot.fullHashBytes), remoteProbeBytes=\(changedSnapshot.remoteProbeDownloadBytes), "
                + "remoteHashQueries=\(changedSnapshot.remoteHashQueryCount), transferBytes=\(changedSnapshot.applyTransferredBytes), "
                + "transfers=\(changedSnapshot.applyTransferCount))"
        )
        try require(
            try Data(contentsOf: local) == Data(contentsOf: remote),
            "the single changed ordinary image should still synchronize"
        )
        print(
            "bisync-metrics: unchanged candidates=\(unchanged.changedObjectCount) probes=\(unchangedSnapshot.metadataProbeCount) hashBytes=\(unchangedSnapshot.fullHashBytes) remoteProbeBytes=\(unchangedSnapshot.remoteProbeDownloadBytes) remoteHashQueries=\(unchangedSnapshot.remoteHashQueryCount) transferBytes=\(unchangedSnapshot.applyTransferredBytes) transfers=\(unchangedSnapshot.applyTransferCount); changed candidates=\(changed.changedObjectCount) probes=\(changedSnapshot.metadataProbeCount) hashBytes=\(changedSnapshot.fullHashBytes) remoteProbeBytes=\(changedSnapshot.remoteProbeDownloadBytes) remoteHashQueries=\(changedSnapshot.remoteHashQueryCount) transferBytes=\(changedSnapshot.applyTransferredBytes) transfers=\(changedSnapshot.applyTransferCount)"
        )
    }

    private static func localLivePhotoStill(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: local Live Photo still")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try await seedLivePair(fixture, identifier: "LIVE-LOCAL-STILL")
        let connection = try await initialize(fixture)
        let localStill = fixture.localRoot.appendingPathComponent("IMG_0001.JPG")
        let localMovie = fixture.localRoot.appendingPathComponent("IMG_0001.MOV")
        let remoteStill = fixture.remoteRoot.appendingPathComponent("IMG_0001.JPG")
        let remoteMovie = fixture.remoteRoot.appendingPathComponent("IMG_0001.MOV")
        let movieBefore = try Data(contentsOf: remoteMovie)
        try writeSyntheticJPEGReplacing(
            localStill,
            contentIdentifier: "LIVE-LOCAL-STILL",
            pixelValue: 210
        )
        let report = try await fixture.service().synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(
            try Data(contentsOf: localStill) == Data(contentsOf: remoteStill),
            "complete Live Photo still should synchronize"
        )
        try require(
            try Data(contentsOf: localMovie) == Data(contentsOf: remoteMovie)
                && Data(contentsOf: remoteMovie) == movieBefore,
            "unchanged paired video must remain intact"
        )
        try require(report.connection.status == .success, "verified complete Live Photo should finish successfully")
    }

    private static func remoteLivePhotoVideo(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: remote Live Photo video")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try await seedLivePair(fixture, identifier: "LIVE-REMOTE-VIDEO")
        let connection = try await initialize(fixture)
        let localMovie = fixture.localRoot.appendingPathComponent("IMG_0001.MOV")
        let remoteMovie = fixture.remoteRoot.appendingPathComponent("IMG_0001.MOV")
        try await writeSyntheticMovieReplacing(
            remoteMovie,
            markerValues: [1],
            contentIdentifier: "LIVE-REMOTE-VIDEO"
        )
        let report = try await fixture.service().synchronize(
            connection: connection,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(
            try Data(contentsOf: localMovie) == Data(contentsOf: remoteMovie),
            "complete remote Live Photo paired-video change should synchronize"
        )
        try require(report.connection.status == .success, "verified remote Live Photo update should complete")
    }

    private static func livePhotoDeletion(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: Live Photo deletion")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try await seedLivePair(fixture, identifier: "LIVE-DELETE")
        let connection = try await initialize(fixture)
        let remoteStill = fixture.remoteRoot.appendingPathComponent("IMG_0001.JPG")
        try FileManager.default.removeItem(at: fixture.localRoot.appendingPathComponent("IMG_0001.JPG"))
        try await requireConfirmationRequired(fixture: fixture, connection: connection)
        try require(FileManager.default.fileExists(atPath: remoteStill.path), "blocked Live Photo deletion must preserve counterpart")
    }

    private static func remoteLivePhotoDeletion(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: remote Live Photo deletion")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try await seedLivePair(fixture, identifier: "LIVE-REMOTE-DELETE")
        let connection = try await initialize(fixture)
        let localStill = fixture.localRoot.appendingPathComponent("IMG_0001.JPG")
        let localMovie = fixture.localRoot.appendingPathComponent("IMG_0001.MOV")
        try FileManager.default.removeItem(at: fixture.remoteRoot.appendingPathComponent("IMG_0001.JPG"))
        try await requireConfirmationRequired(fixture: fixture, connection: connection)
        try require(
            FileManager.default.fileExists(atPath: localStill.path)
                && FileManager.default.fileExists(atPath: localMovie.path),
            "a remote one-resource deletion must not expand into deleting the complete local Live Photo"
        )
    }

    private static func localLivePhotoVideoDeletion(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: local Live Photo video deletion")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try await seedLivePair(fixture, identifier: "LIVE-LOCAL-VIDEO-DELETE")
        let connection = try await initialize(fixture)
        let remoteStill = fixture.remoteRoot.appendingPathComponent("IMG_0001.JPG")
        let remoteMovie = fixture.remoteRoot.appendingPathComponent("IMG_0001.MOV")
        try FileManager.default.removeItem(at: fixture.localRoot.appendingPathComponent("IMG_0001.MOV"))
        try await requireConfirmationRequired(fixture: fixture, connection: connection)
        try require(
            FileManager.default.fileExists(atPath: remoteStill.path)
                && FileManager.default.fileExists(atPath: remoteMovie.path),
            "a local paired-video deletion must not expand into deleting the remote Live Photo"
        )
    }

    private static func remoteLivePhotoVideoDeletion(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: remote Live Photo video deletion")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try await seedLivePair(fixture, identifier: "LIVE-REMOTE-VIDEO-DELETE")
        let connection = try await initialize(fixture)
        let localStill = fixture.localRoot.appendingPathComponent("IMG_0001.JPG")
        let localMovie = fixture.localRoot.appendingPathComponent("IMG_0001.MOV")
        try FileManager.default.removeItem(at: fixture.remoteRoot.appendingPathComponent("IMG_0001.MOV"))
        try await requireConfirmationRequired(fixture: fixture, connection: connection)
        try require(
            FileManager.default.fileExists(atPath: localStill.path)
                && FileManager.default.fileExists(atPath: localMovie.path),
            "a remote paired-video deletion must not expand into deleting the complete local Live Photo"
        )
    }

    private static func completeLivePhotoDeletion(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: complete Live Photo deletion")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try await seedLivePair(fixture, identifier: "LIVE-COMPLETE-DELETE")
        let connection = try await initialize(fixture)
        let localStill = fixture.localRoot.appendingPathComponent("IMG_0001.JPG")
        let localMovie = fixture.localRoot.appendingPathComponent("IMG_0001.MOV")
        let remoteStill = fixture.remoteRoot.appendingPathComponent("IMG_0001.JPG")
        let remoteMovie = fixture.remoteRoot.appendingPathComponent("IMG_0001.MOV")
        try FileManager.default.removeItem(at: localStill)
        try FileManager.default.removeItem(at: localMovie)

        let report: FolderSyncRunReport
        do {
            report = try await fixture.service().synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
        } catch {
            printSyntheticRunLogs(workDirectoryPath: fixture.connection.workDirectoryPath)
            throw error
        }
        try require(
            report.connection.status == .success
                && !FileManager.default.fileExists(atPath: remoteStill.path)
                && !FileManager.default.fileExists(atPath: remoteMovie.path),
            "deleting both resources of one verified Live Photo on one side should propagate as one logical deletion"
        )
        let recovery = try fixture.service().recoveryItems(connection: report.connection)
        let remoteRecoveryPaths = Set(
            recovery.filter { $0.location == .googleDrive }.map(\.originalRelativePath)
        )
        try require(
            remoteRecoveryPaths.contains("IMG_0001.JPG")
                && remoteRecoveryPaths.contains("IMG_0001.MOV"),
            "complete Live Photo deletion must retain both destination resources in recovery"
        )
    }

    private static func livePhotoConflict(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: Live Photo conflict")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try await seedLivePair(fixture, identifier: "LIVE-CONFLICT")
        let connection = try await initialize(fixture)
        try writeSyntheticJPEGReplacing(
            fixture.localRoot.appendingPathComponent("IMG_0001.JPG"),
            contentIdentifier: "LIVE-CONFLICT-LEFT",
            pixelValue: 30
        )
        try writeSyntheticJPEGReplacing(
            fixture.remoteRoot.appendingPathComponent("IMG_0001.JPG"),
            contentIdentifier: "LIVE-CONFLICT-RIGHT",
            pixelValue: 220
        )
        try await requireConfirmationRequired(fixture: fixture, connection: connection)
        try require(
            try visibleUserFiles(in: fixture.localRoot).allSatisfy { !$0.lastPathComponent.contains("conflict") }
                && visibleUserFiles(in: fixture.remoteRoot).allSatisfy { !$0.lastPathComponent.contains("conflict") },
            "blocked Live Photo conflict must not create conflict-renamed user files"
        )
    }

    private static func splitLivePhotoChange(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: split Live Photo change")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try await seedLivePair(fixture, identifier: "LIVE-SPLIT-CHANGE")
        let connection = try await initialize(fixture)
        let remoteStill = fixture.remoteRoot.appendingPathComponent("IMG_0001.JPG")
        let localMovie = fixture.localRoot.appendingPathComponent("IMG_0001.MOV")
        let remoteStillBefore = try Data(contentsOf: remoteStill)
        let localMovieBefore = try Data(contentsOf: localMovie)

        try writeSyntheticJPEGReplacing(
            fixture.localRoot.appendingPathComponent("IMG_0001.JPG"),
            contentIdentifier: "LIVE-SPLIT-CHANGE",
            pixelValue: 35
        )
        try await writeSyntheticMovieReplacing(
            fixture.remoteRoot.appendingPathComponent("IMG_0001.MOV"),
            markerValues: [1],
            contentIdentifier: "LIVE-SPLIT-CHANGE"
        )
        try await requireConfirmationRequired(fixture: fixture, connection: connection)
        try require(
            try Data(contentsOf: remoteStill) == remoteStillBefore
                && Data(contentsOf: localMovie) == localMovieBefore,
            "different changes to opposite resources of one Live Photo must not be merged file-by-file"
        )
    }

    private static func livePhotoDeleteModifyConflict(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: Live Photo delete/modify conflict")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try await seedLivePair(fixture, identifier: "LIVE-DELETE-MODIFY")
        let connection = try await initialize(fixture)
        let localStill = fixture.localRoot.appendingPathComponent("IMG_0001.JPG")
        let localMovie = fixture.localRoot.appendingPathComponent("IMG_0001.MOV")
        let remoteStill = fixture.remoteRoot.appendingPathComponent("IMG_0001.JPG")
        let remoteMovie = fixture.remoteRoot.appendingPathComponent("IMG_0001.MOV")
        let localMovieBefore = try Data(contentsOf: localMovie)
        try FileManager.default.removeItem(at: localStill)
        try await writeSyntheticMovieReplacing(
            remoteMovie,
            markerValues: [1],
            contentIdentifier: "LIVE-DELETE-MODIFY"
        )
        try await requireConfirmationRequired(fixture: fixture, connection: connection)
        try require(
            !FileManager.default.fileExists(atPath: localStill.path)
                && FileManager.default.fileExists(atPath: remoteStill.path),
            "delete/modify conflict must not propagate the one-sided still deletion"
        )
        try require(
            try Data(contentsOf: localMovie) == localMovieBefore,
            "delete/modify conflict must not silently choose and apply the opposite-side movie change"
        )
    }

    private static func metadataFailure(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: metadata failure")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("broken.JPG")
        let remote = fixture.remoteRoot.appendingPathComponent("broken.JPG")
        try writeSyntheticJPEG(to: local, pixelValue: 50)
        try copyReplacing(local, to: remote)
        let connection = try await initialize(fixture)
        let before = try Data(contentsOf: remote)
        try Data("not an image anymore".utf8).write(to: local, options: .atomic)
        try await requireLivePhotoBlock(fixture: fixture, connection: connection)
        try require(try Data(contentsOf: remote) == before, "metadata probe failure must fail safe before transfer")
    }

    private static func journalCorruption(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: journal corruption")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("journal.txt")
        let remote = fixture.remoteRoot.appendingPathComponent("journal.txt")
        try Data("baseline".utf8).write(to: local)
        try copyReplacing(local, to: remote)
        let connection = try await initialize(fixture)
        let remoteBefore = try Data(contentsOf: remote)
        try Data("{not valid json".utf8).write(
            to: FolderSyncJournalStore.url(for: connection),
            options: .atomic
        )
        try Data("changed after corruption".utf8).write(to: local, options: .atomic)

        do {
            _ = try await fixture.service().synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("a corrupted completion journal must fail closed")
        } catch FolderSyncConnectionError.recoveryRequired {
            // Expected.
        }
        try require(
            try fixture.savedConnection().status == .recoveryRequired,
            "corrupted journal state must persist recovery-required"
        )
        try require(
            try Data(contentsOf: remote) == remoteBefore,
            "journal corruption must stop before any new file mutation"
        )
    }

    private static func cancellationBeforeApply(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: cancellation before apply")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("cancel.txt")
        let remote = fixture.remoteRoot.appendingPathComponent("cancel.txt")
        try Data("baseline".utf8).write(to: local)
        try copyReplacing(local, to: remote)
        let connection = try await initialize(fixture)
        try Data("changed but not applied yet".utf8).write(to: local, options: .atomic)
        let before = try Data(contentsOf: remote)
        let gate = BisyncHookGate()
        let service = fixture.service(afterPreflight: { await gate.enterAndWait() })
        let task = Task {
            try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
        }
        await gate.waitUntilEntered()
        service.cancelCurrentRun()
        await gate.release()
        do {
            _ = try await task.value
            throw BisyncSelfTestFailure("cancelled service run should not report success")
        } catch is CancellationError {
            // Expected.
        }
        try require(try fixture.savedConnection().status == .cancelled, "pre-apply cancellation should persist cancelled")
        try require(try Data(contentsOf: remote) == before, "pre-apply cancellation should not start transfer")
    }

    private static func rootUnavailableAfterPreflight(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: root unavailable after preflight")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("keep.txt")
        let remote = fixture.remoteRoot.appendingPathComponent("keep.txt")
        try Data("keep me".utf8).write(to: local)
        try copyReplacing(local, to: remote)
        let connection = try await initialize(fixture)
        let remoteBefore = try Data(contentsOf: remote)
        let detachedRoot = fixture.localRoot.deletingLastPathComponent()
            .appendingPathComponent("local-detached", isDirectory: true)
        let service = fixture.service(afterPreflight: {
            try FileManager.default.moveItem(at: fixture.localRoot, to: detachedRoot)
        })

        do {
            _ = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("a root disappearing after preflight must not report sync success")
        } catch {
            // The persisted recovery state and surviving remote copy are the
            // safety properties under test, independent of rclone's wording.
        }
        try require(
            try fixture.savedConnection().status == .recoveryRequired,
            "a root loss after the apply boundary opens must be recovery-required"
        )
        try require(
            FileManager.default.fileExists(atPath: remote.path)
                && Data(contentsOf: remote) == remoteBefore,
            "a disappearing local root must not become deletion authority for the remote copy"
        )
    }

    private static func sourceUnreadableAfterPreflight(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: source unreadable after preflight")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("read-error.txt")
        let remote = fixture.remoteRoot.appendingPathComponent("read-error.txt")
        try Data("baseline".utf8).write(to: local)
        try copyReplacing(local, to: remote)
        let connection = try await initialize(fixture)
        try Data("changed source that becomes unreadable".utf8).write(to: local, options: .atomic)
        let remoteBefore = try Data(contentsOf: remote)
        let service = fixture.service(afterPreflight: {
            guard chmod(local.path, 0) == 0 else {
                throw BisyncSelfTestFailure("could not make synthetic source unreadable")
            }
        })
        defer { _ = chmod(local.path, S_IRUSR | S_IWUSR) }

        do {
            _ = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("an unreadable source after preflight must not complete")
        } catch {
            // The persisted state and unchanged destination are the contract.
        }
        let remoteRecoveryRoot = fixture.remoteRoot.deletingLastPathComponent()
            .appendingPathComponent(connection.remoteRecoveryPath, isDirectory: true)
        let preservedCopies = try recursiveRegularFiles(in: remoteRecoveryRoot)
        let remoteStillAtPath = (try? Data(contentsOf: remote)) == remoteBefore
        let remotePreservedInRecovery = preservedCopies.contains {
            (try? Data(contentsOf: $0)) == remoteBefore
        }
        try require(
            remoteStillAtPath || remotePreservedInRecovery,
            "a source read failure must preserve the previous destination either in place or in the separated recovery location"
        )
        try require(
            try fixture.savedConnection().status == .recoveryRequired,
            "a read failure after the apply boundary opens must remain recovery-required"
        )
    }

    private static func recoveryCapacityGuard(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: recovery capacity guard")

        do {
            let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
            let local = fixture.localRoot.appendingPathComponent("remote-change.txt")
            let remote = fixture.remoteRoot.appendingPathComponent("remote-change.txt")
            try Data("baseline".utf8).write(to: local)
            try copyReplacing(local, to: remote)
            let connection = try await initialize(fixture)
            let localBefore = try Data(contentsOf: local)
            try Data("remote changed and needs a local recovery copy".utf8).write(to: remote, options: .atomic)
            do {
                _ = try await fixture.service(
                    testingLocalRecoveryFreeBytes: 0
                ).synchronize(
                    connection: connection,
                    confirmInitialSync: false,
                    catalogURL: fixture.catalogURL,
                    storeURL: fixture.storeURL
                )
                throw BisyncSelfTestFailure("insufficient local recovery space must stop before apply")
            } catch FolderSyncConnectionError.insufficientRecoverySpace {
                // Expected.
            }
            try require(
                try Data(contentsOf: local) == localBefore,
                "local recovery capacity failure must not replace the external-drive destination"
            )
        }

        do {
            let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
            let local = fixture.localRoot.appendingPathComponent("local-change.txt")
            let remote = fixture.remoteRoot.appendingPathComponent("local-change.txt")
            try Data("baseline".utf8).write(to: local)
            try copyReplacing(local, to: remote)
            let connection = try await initialize(fixture)
            let remoteBefore = try Data(contentsOf: remote)
            try Data("local changed and needs a Drive recovery copy".utf8).write(to: local, options: .atomic)
            do {
                _ = try await fixture.service(
                    testingRemoteRecoveryFreeBytes: 0
                ).synchronize(
                    connection: connection,
                    confirmInitialSync: false,
                    catalogURL: fixture.catalogURL,
                    storeURL: fixture.storeURL
                )
                throw BisyncSelfTestFailure("insufficient remote recovery space must stop before apply")
            } catch FolderSyncConnectionError.insufficientRecoverySpace {
                // Expected.
            }
            try require(
                try Data(contentsOf: remote) == remoteBefore,
                "remote recovery capacity failure must not replace the Drive destination"
            )
        }
    }

    private static func toctouAdd(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: TOCTOU add")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let localAnchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: localAnchor)
        try copyReplacing(localAnchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)
        let injected = fixture.localRoot.appendingPathComponent("late-live.JPG")
        let service = fixture.service(afterPreflight: {
            try writeSyntheticJPEG(to: injected, contentIdentifier: "LATE-ADD", pixelValue: 120)
        })
        do {
            _ = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("post-preflight addition must not be reported as a completed sync")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected: apply may have copied bytes, but completion is withheld.
        }
        try require(
            FileManager.default.fileExists(atPath: fixture.remoteRoot.appendingPathComponent("late-live.JPG").path),
            "post-preflight Live Photo addition may reach the destination before verification"
        )
        let journal = try FolderSyncJournalStore.load(connection: connection)
        try require(
            try fixture.savedConnection().status == .confirmationRequired
                && journal?.phase == .confirmationRequired
                && journal?.unplannedObservedPaths.contains("late-live.JPG") == true,
            "post-preflight addition must remain uncompleted and journaled for confirmation"
        )
    }

    private static func toctouRemoteAdd(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: TOCTOU remote add")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)
        let remoteInjected = fixture.remoteRoot.appendingPathComponent("late-remote-live.JPG")
        let service = fixture.service(afterPreflight: {
            try writeSyntheticJPEG(
                to: remoteInjected,
                contentIdentifier: "LATE-REMOTE-ADD",
                pixelValue: 145
            )
        })
        do {
            _ = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("post-preflight remote addition must not be reported as complete")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        try require(
            FileManager.default.fileExists(
                atPath: fixture.localRoot.appendingPathComponent("late-remote-live.JPG").path
            ),
            "a post-preflight remote Live Photo resource may arrive locally before verification"
        )
        try require(
            try fixture.savedConnection().status == .confirmationRequired
                && FolderSyncJournalStore.load(connection: connection)?
                    .unplannedObservedPaths.contains("late-remote-live.JPG") == true,
            "remote post-preflight additions must be journaled instead of becoming a false success"
        )
    }

    private static func toctouReplace(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: planned Live Photo replace after preflight")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try await seedLivePair(fixture, identifier: "PLANNED-LATE-REPLACE")
        let local = fixture.localRoot.appendingPathComponent("IMG_0001.JPG")
        let remote = fixture.remoteRoot.appendingPathComponent("IMG_0001.JPG")
        let connection = try await initialize(fixture)
        let remoteBefore = try Data(contentsOf: remote)
        try writeSyntheticJPEGReplacing(
            local,
            contentIdentifier: "PLANNED-LATE-REPLACE",
            pixelValue: 145
        )
        let service = fixture.service(afterPreflight: {
            try writeSyntheticJPEGReplacing(
                local,
                contentIdentifier: "PLANNED-LATE-REPLACE",
                pixelValue: 225
            )
        })
        do {
            _ = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("planned Live Photo replacement after preflight must not complete")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        try require(
            try Data(contentsOf: remote) == remoteBefore,
            "planned Live Photo source replacement must be detected before apply"
        )
        let journal = try FolderSyncJournalStore.load(connection: connection)
        try require(
            try fixture.savedConnection().status == .confirmationRequired
                && journal?.items.contains(where: {
                    $0.note == "live_photo_precondition_changed_before_apply"
                }) == true,
            "planned Live Photo replacement must stay journaled for confirmation"
        )
    }

    private static func toctouDelete(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: TOCTOU delete")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        try await seedLivePair(fixture, identifier: "LATE-DELETE")
        let connection = try await initialize(fixture)
        let localStill = fixture.localRoot.appendingPathComponent("IMG_0001.JPG")
        let remoteStill = fixture.remoteRoot.appendingPathComponent("IMG_0001.JPG")
        let remoteMovie = fixture.remoteRoot.appendingPathComponent("IMG_0001.MOV")
        let service = fixture.service(afterPreflight: {
            try FileManager.default.removeItem(at: localStill)
        })
        do {
            _ = try await service.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("post-preflight deletion must not be reported as complete")
        } catch FolderSyncConnectionError.confirmationRequired {
            // Expected.
        }
        try require(
            !FileManager.default.fileExists(atPath: remoteStill.path)
                && FileManager.default.fileExists(atPath: remoteMovie.path),
            "post-preflight deletion can temporarily expose a one-sided Live Photo"
        )
        try require(
            try fixture.savedConnection().status == .confirmationRequired
                && FolderSyncJournalStore.load(connection: connection)?
                    .unplannedObservedPaths.contains("IMG_0001.JPG") == true,
            "post-preflight deletion must not be mistaken for a completed logical item"
        )
    }

    private static func partialLivePhotoApply(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: partial Live Photo apply")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)

        let stagedDirectory = fixture.localRoot.deletingLastPathComponent()
            .appendingPathComponent("late-pair", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        let stagedStill = stagedDirectory.appendingPathComponent("A-live.JPG")
        let stagedMovie = stagedDirectory.appendingPathComponent("Z-live.MOV")
        try writeSyntheticJPEG(
            to: stagedStill,
            contentIdentifier: "LATE-PARTIAL-PAIR",
            pixelValue: 110
        )
        try await writeSyntheticTimedMetadataMovie(
            to: stagedMovie,
            markerValues: [0],
            contentIdentifier: "LATE-PARTIAL-PAIR"
        )
        let stillSize = try stagedStill.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try require(stillSize > 0, "synthetic Live Photo still must have a measurable size")

        let localStill = fixture.localRoot.appendingPathComponent(stagedStill.lastPathComponent)
        let localMovie = fixture.localRoot.appendingPathComponent(stagedMovie.lastPathComponent)
        let remoteStill = fixture.remoteRoot.appendingPathComponent(stagedStill.lastPathComponent)
        let remoteMovie = fixture.remoteRoot.appendingPathComponent(stagedMovie.lastPathComponent)
        let limited = fixture.service(
            additionalApplyArguments: [
                "--max-transfer", "\(stillSize)B",
                "--cutoff-mode", "hard",
                "--transfers", "1"
            ],
            afterPreflight: {
                try copyReplacing(stagedStill, to: localStill)
                try copyReplacing(stagedMovie, to: localMovie)
            }
        )
        do {
            _ = try await limited.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("hard transfer cutoff should interrupt the synthetic Live Photo apply")
        } catch {
            // Expected. Assertions below characterize the file-level boundary.
        }

        let remoteResourceCount = [remoteStill, remoteMovie]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .count
        try require(
            remoteResourceCount == 1,
            "file-level bisync can expose exactly one resource of a Live Photo when the second transfer fails"
        )
        try require(
            FileManager.default.fileExists(atPath: localStill.path)
                && FileManager.default.fileExists(atPath: localMovie.path),
            "a partial transfer must not destroy the complete source Live Photo"
        )
        try require(
            try fixture.savedConnection().status == .recoveryRequired,
            "a partial initialized apply must remain explicitly recovery-required"
        )
        let journal = try FolderSyncJournalStore.load(connection: connection)
        if (journal?.incompleteItemCount ?? 0) == 0 {
            printSyntheticRunLogs(workDirectoryPath: fixture.connection.workDirectoryPath)
        }
        try require(
            journal?.phase == .recoveryRequired
                && journal?.historyCheckpointAvailable == true
                && journal?.historyRestored == true
                && (journal?.incompleteItemCount ?? 0) > 0,
            "partial Live Photo apply must persist an incomplete journal and restore prior bisync history; phase=\(journal?.phase.rawValue ?? "nil") checkpoint=\(journal?.historyCheckpointAvailable.description ?? "nil") restored=\(journal?.historyRestored.description ?? "nil") incomplete=\(journal?.incompleteItemCount ?? -1)"
        )
        try require(
            try FolderSyncConnectionStore.loadRecoveringInterrupted(
                catalogURL: fixture.catalogURL,
                url: fixture.storeURL
            ).first?.status == .recoveryRequired,
            "an app restart must recover the persisted incomplete journal as recovery-required"
        )
    }

    private static func plannedPartialLivePhotoRetry(
        parent: URL,
        rcloneURL: URL,
        videoFirst: Bool
    ) async throws {
        print("bisync-service: planned partial Live Photo retry \(videoFirst ? "video-first" : "still-first")")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)

        let localStill = fixture.localRoot.appendingPathComponent(
            videoFirst ? "Z-planned-live.JPG" : "A-planned-live.JPG"
        )
        let localMovie = fixture.localRoot.appendingPathComponent(
            videoFirst ? "A-planned-live.MOV" : "Z-planned-live.MOV"
        )
        let remoteStill = fixture.remoteRoot.appendingPathComponent(localStill.lastPathComponent)
        let remoteMovie = fixture.remoteRoot.appendingPathComponent(localMovie.lastPathComponent)
        try writeSyntheticJPEG(
            to: localStill,
            contentIdentifier: "PLANNED-PARTIAL-LIVE",
            pixelValue: 95
        )
        try await writeSyntheticTimedMetadataMovie(
            to: localMovie,
            markerValues: [0],
            contentIdentifier: "PLANNED-PARTIAL-LIVE"
        )
        let completedSource = videoFirst ? localMovie : localStill
        let completedRemote = videoFirst ? remoteMovie : remoteStill
        try copyReplacing(completedSource, to: completedRemote)
        let completedSize = try completedSource.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try require(completedSize > 0, "injected completed Live Photo resource must have a measurable size")
        let completedInode = try fileInode(completedRemote)
        var interruptedJournal = FolderSyncJournal(
            connectionID: connection.id,
            operationID: "SO-INJECTED-PARTIAL",
            currentAttemptID: "SA-INJECTED-PARTIAL",
            startedAt: Date(),
            phase: .recoveryRequired,
            preflightCandidatePaths: [localStill.lastPathComponent, localMovie.lastPathComponent],
            items: [
                FolderSyncJournalItem(
                    state: .incomplete,
                    resources: [
                        FolderSyncJournalResource(
                            relativePath: localStill.lastPathComponent,
                            role: .photo,
                            path1Verified: true,
                            path2Verified: !videoFirst
                        ),
                        FolderSyncJournalResource(
                            relativePath: localMovie.lastPathComponent,
                            role: .pairedVideo,
                            path1Verified: true,
                            path2Verified: videoFirst
                        )
                    ],
                    note: "synthetic_partial_failure_after_one_verified_resource"
                )
            ]
        )
        interruptedJournal.historyRestored = true
        interruptedJournal.historyCheckpointAvailable = true
        try FolderSyncJournalStore.save(interruptedJournal, connection: connection)
        var interruptedConnection = connection
        interruptedConnection.status = .recoveryRequired
        try FolderSyncConnectionStore.upsert(interruptedConnection, url: fixture.storeURL)

        let restarted = try FolderSyncConnectionStore.loadRecoveringInterrupted(
            catalogURL: fixture.catalogURL,
            url: fixture.storeURL
        ).first(where: { $0.id == connection.id })
        guard let restarted else {
            throw BisyncSelfTestFailure("restarted connection is missing")
        }
        let retryMetrics = RcloneBisyncTestingMetricsRecorder()
        let report = try await fixture.service(testingMetrics: retryMetrics).synchronize(
            connection: restarted,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(report.connection.status == .success, "restarted Live Photo retry should finish successfully")
        try require(
            try Data(contentsOf: localStill) == Data(contentsOf: remoteStill)
                && Data(contentsOf: localMovie) == Data(contentsOf: remoteMovie),
            "restarted Live Photo retry must verify both resources"
        )
        try require(
            try fileInode(completedRemote) == completedInode,
            "retry should reuse the already completed identical Live Photo resource instead of rewriting it"
        )
        try require(
            try FolderSyncJournalStore.load(connection: report.connection) == nil,
            "verified Live Photo retry should clear its journal"
        )
        let retrySnapshot = retryMetrics.snapshot()
        let missingSize = Int64((try (videoFirst ? localStill : localMovie)
            .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        try require(
            retrySnapshot.remoteProbeDownloadBytes == 0
                && retrySnapshot.remoteHashQueryCount == 2
                && retrySnapshot.applyTransferCount == 1
                && retrySnapshot.applyTransferredBytes == missingSize,
            "verified Live Photo retry should use fresh remote hashes for both resources without downloading both files again when the backend exposes SHA-256"
        )
        print(
            "bisync-metrics: injected partial-live \(videoFirst ? "video-first" : "still-first") retry probes=\(retrySnapshot.metadataProbeCount) hashBytes=\(retrySnapshot.fullHashBytes) remoteProbeBytes=\(retrySnapshot.remoteProbeDownloadBytes) remoteHashQueries=\(retrySnapshot.remoteHashQueryCount) transferBytes=\(retrySnapshot.applyTransferredBytes) transfers=\(retrySnapshot.applyTransferCount) reusedBytes=\((try? completedRemote.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)"
        )
    }

    private static func partialInitializedOrdinaryRetry(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: partial initialized ordinary retry")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let anchor = fixture.localRoot.appendingPathComponent("anchor.txt")
        try Data("anchor".utf8).write(to: anchor)
        try copyReplacing(anchor, to: fixture.remoteRoot.appendingPathComponent("anchor.txt"))
        let connection = try await initialize(fixture)

        let first = fixture.localRoot.appendingPathComponent("a.txt")
        let second = fixture.localRoot.appendingPathComponent("b.txt")
        try Data("A".utf8).write(to: first)
        try Data("BBBB".utf8).write(to: second)
        let limited = fixture.service(additionalApplyArguments: [
            "--max-transfer", "1B",
            "--cutoff-mode", "hard",
            "--transfers", "1"
        ])
        do {
            _ = try await limited.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("hard transfer cutoff should interrupt an initialized ordinary sync")
        } catch {
            // The durable journal and retry below are the safety contract.
        }

        let interrupted = try fixture.savedConnection()
        try require(interrupted.status == .recoveryRequired, "partial ordinary apply should require recovery")
        let persisted = try FolderSyncJournalStore.load(connection: interrupted)
        try require(
            persisted?.phase == .recoveryRequired
                && persisted?.historyRestored == true
                && (persisted?.incompleteItemCount ?? 0) > 0,
            "partial ordinary apply should persist a restorable incomplete journal"
        )

        let reloaded = try FolderSyncConnectionStore.loadRecoveringInterrupted(
            catalogURL: fixture.catalogURL,
            url: fixture.storeURL
        ).first!
        let report = try await fixture.service().synchronize(
            connection: reloaded,
            confirmInitialSync: false,
            catalogURL: fixture.catalogURL,
            storeURL: fixture.storeURL
        )
        try require(
            report.connection.status == .success,
            "a new service instance should retry the interrupted ordinary sync; got \(report.connection.status.rawValue)"
        )
        try require(
            try Data(contentsOf: first) == Data(contentsOf: fixture.remoteRoot.appendingPathComponent("a.txt"))
                && Data(contentsOf: second) == Data(contentsOf: fixture.remoteRoot.appendingPathComponent("b.txt")),
            "retry should finish both ordinary files after restoring prior bisync history"
        )
        try require(
            try FolderSyncJournalStore.load(connection: report.connection) == nil,
            "a verified retry should clear its completion journal"
        )
    }

    private static func partialFirstSync(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: partial first sync")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        for name in ["a.txt", "b.txt", "c.txt", "d.txt"] {
            try Data("x".utf8).write(to: fixture.localRoot.appendingPathComponent(name))
        }
        let limited = fixture.service(additionalApplyArguments: [
            "--max-transfer", "1B",
            "--cutoff-mode", "hard",
            "--transfers", "1"
        ])
        do {
            _ = try await limited.synchronize(
                connection: fixture.connection,
                confirmInitialSync: true,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("hard transfer limit should interrupt the first synthetic resync")
        } catch {
            // Persisted state is the authority below.
        }

        let partialCount = try visibleUserFiles(in: fixture.remoteRoot)
            .filter { $0.pathExtension == "txt" }.count
        let interrupted = try fixture.savedConnection()
        try require(partialCount > 0 && partialCount < 4, "interrupted first sync should leave a demonstrably partial result")
        try require(
            !interrupted.isInitialized
                && interrupted.initialSyncStartedAt != nil
                && interrupted.status == .recoveryRequired,
            "partial first sync must persist recovery-required"
        )
        do {
            _ = try await fixture.service().synchronize(
                connection: interrupted,
                confirmInitialSync: true,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("partial initial sync must not automatically resync again")
        } catch FolderSyncConnectionError.recoveryRequired {
            // Expected.
        }
        let countAfterRetry = try visibleUserFiles(in: fixture.remoteRoot)
            .filter { $0.pathExtension == "txt" }.count
        try require(countAfterRetry == partialCount, "recovery-required retry must not continue mutation")
    }

    private static func duplicateService(parent: URL, rcloneURL: URL) async throws {
        print("bisync-service: duplicate service")
        let fixture = try fixture(parent: parent, rcloneURL: rcloneURL)
        let local = fixture.localRoot.appendingPathComponent("same.txt")
        try Data("same".utf8).write(to: local)
        try copyReplacing(local, to: fixture.remoteRoot.appendingPathComponent("same.txt"))
        let connection = try await initialize(fixture)
        let gate = BisyncHookGate()
        let firstService = fixture.service(afterPreflight: { await gate.enterAndWait() })
        let first = Task {
            try await firstService.synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
        }
        await gate.waitUntilEntered()
        try require(
            try FolderSyncConnectionStore.loadRecoveringInterrupted(
                catalogURL: fixture.catalogURL,
                url: fixture.storeURL
            ).first?.status == .running,
            "a live operation lock must keep readers from misclassifying the owner as interrupted"
        )
        do {
            _ = try await fixture.service().synchronize(
                connection: connection,
                confirmInitialSync: false,
                catalogURL: fixture.catalogURL,
                storeURL: fixture.storeURL
            )
            throw BisyncSelfTestFailure("overlapping app-service sync should be rejected")
        } catch FolderSyncConnectionError.operationAlreadyRunning {
            // Expected.
        }
        try require(
            try persistedRawSyncStatus(url: fixture.storeURL) == "running",
            "competing sync attempt must not overwrite the active owner's state"
        )
        await gate.release()
        _ = try await first.value
    }
}
