import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import PhotoArchiveCore
import SQLite3

@main
struct PhotoArchiveSelfTest {
    static func main() async {
        do {
            try await run()
            print("PhotoArchiveKit self-test passed.")
        } catch {
            FileHandle.standardError.write(Data("self-test failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("PhotoArchiveKitSelfTest-\(UUID().uuidString)", isDirectory: true)
        let rootA = temporary.appendingPathComponent("A", isDirectory: true)
        let rootB = temporary.appendingPathComponent("B", isDirectory: true)
        try fileManager.createDirectory(at: rootA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        let validTimedVideo = temporary.appendingPathComponent("valid-timed.mov")
        try await writeSyntheticTimedMetadataMovie(to: validTimedVideo, markerValues: [-1])
        let validTimedStatus = await LivePhotoTimedMetadataValidator.validateVideo(at: validTimedVideo)
        try require(
            validTimedStatus == .valid,
            "a single int8 still-image-time marker should validate regardless of marker payload"
        )

        let missingTimedVideo = temporary.appendingPathComponent("missing-timed.mov")
        try await writeSyntheticTimedMetadataMovie(to: missingTimedVideo, markerValues: [])
        let missingTimedStatus = await LivePhotoTimedMetadataValidator.validateVideo(at: missingTimedVideo)
        try require(
            missingTimedStatus == .missing,
            "a readable metadata track without still-image-time should be reported missing"
        )

        let invalidTimedVideo = temporary.appendingPathComponent("invalid-timed.mov")
        try await writeSyntheticTimedMetadataMovie(
            to: invalidTimedVideo,
            markerValues: [0],
            validDataType: false
        )
        let invalidTimedStatus = await LivePhotoTimedMetadataValidator.validateVideo(at: invalidTimedVideo)
        try require(
            invalidTimedStatus == .invalid,
            "a still-image-time marker with the wrong metadata datatype should be rejected"
        )

        let ambiguousTimedVideo = temporary.appendingPathComponent("ambiguous-timed.mov")
        try await writeSyntheticTimedMetadataMovie(to: ambiguousTimedVideo, markerValues: [0, 0])
        let ambiguousTimedStatus = await LivePhotoTimedMetadataValidator.validateVideo(at: ambiguousTimedVideo)
        try require(
            ambiguousTimedStatus == .invalid,
            "multiple still-image-time markers should be rejected as ambiguous"
        )

        let bytes = Data("synthetic-not-a-real-photo".utf8)
        let fileA = rootA.appendingPathComponent("one.jpg")
        let fileB = rootB.appendingPathComponent("copy.jpg")
        try bytes.write(to: fileA)
        try bytes.write(to: fileB)
        let beforeA = try Data(contentsOf: fileA)
        let beforeB = try Data(contentsOf: fileB)

        let scanner = try ArchiveScanner(
            catalogURL: temporary.appendingPathComponent("catalog.sqlite3")
        )
        let roots = [
            ScanRoot(url: rootA, kind: .reference, provenance: .localLibrary),
            ScanRoot(url: rootB, kind: .reference, provenance: .googleTakeout)
        ]
        let first = try await scanner.scan(roots: roots)
        let second = try await scanner.scan(roots: roots)

        try require(first.summary.exactDuplicateGroupCount == 1, "expected one duplicate group")
        try require(first.summary.logicalAssetCount == 1, "exact standalone copies should share one logical asset")
        try require(first.filesModified == false, "scan must remain read-only")
        try require(try Data(contentsOf: fileA) == beforeA, "first file changed")
        try require(try Data(contentsOf: fileB) == beforeB, "second file changed")
        try require(
            first.exactDuplicateGroups.first?.groupID == second.exactDuplicateGroups.first?.groupID,
            "opaque duplicate group ID should remain stable across scans"
        )

        if executableExists("czkawka_cli") {
            let czkawkaReport = try await scanner.scan(
                roots: roots,
                options: ScanOptions(exactDuplicateEngine: .czkawka)
            )
            try require(
                czkawkaReport.summary.exactDuplicateGroupCount == first.summary.exactDuplicateGroupCount,
                "Czkawka candidate discovery plus native verification should match native exact grouping"
            )
        }

        let encoder = JSONEncoder()
        let json = String(decoding: try encoder.encode(first), as: UTF8.self)
        let rawHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try require(!json.contains(rawHash), "local diagnostic report exposed a raw content hash")

        let agentJSON = String(
            decoding: try encoder.encode(AgentSafeScanReport(report: first)),
            as: UTF8.self
        )
        try require(!agentJSON.contains(rawHash), "agent-safe report exposed a raw content hash")
        try require(!agentJSON.contains(rootA.path), "agent-safe report exposed a root path")
        try require(!agentJSON.contains(rootB.path), "agent-safe report exposed a root path")
        try require(!agentJSON.contains("one.jpg"), "agent-safe report exposed a filename")
        try require(!agentJSON.contains("copy.jpg"), "agent-safe report exposed a filename")
        try require(!agentJSON.contains("catalog.sqlite3"), "agent-safe report exposed a catalog path")

        let standalonePlan = ReconciliationPlanner.makePlan(from: first)
        try require(
            standalonePlan.summary.automaticRedundantResourceCount == 1,
            "a Takeout standalone exact copy should be an automatic redundant candidate"
        )
        let standaloneAgentPlanJSON = String(
            decoding: try encoder.encode(AgentSafeReconciliationPlan(plan: standalonePlan)),
            as: UTF8.self
        )
        try require(
            !standaloneAgentPlanJSON.contains("copy.jpg"),
            "agent-safe reconciliation plan exposed a filename"
        )
        try require(
            !standaloneAgentPlanJSON.contains(rootB.path),
            "agent-safe reconciliation plan exposed a path"
        )

        let quarantineRoot = temporary.appendingPathComponent("Quarantine", isDirectory: true)
        try fileManager.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
        let quarantineDryRun = try QuarantineExecutor.preflight(
            report: first,
            plan: standalonePlan,
            targetURL: quarantineRoot
        )
        try require(quarantineDryRun.dryRun, "quarantine preflight should be a dry run")
        try require(quarantineDryRun.resourceCount == 1, "expected one synthetic quarantine candidate")
        try require(fileManager.fileExists(atPath: fileB.path), "dry run must not move the Takeout copy")

        let quarantineAgentJSON = String(
            decoding: try encoder.encode(AgentSafeQuarantineReport(report: quarantineDryRun)),
            as: UTF8.self
        )
        try require(!quarantineAgentJSON.contains(rootB.path), "agent-safe quarantine output exposed a path")
        try require(!quarantineAgentJSON.contains("copy.jpg"), "agent-safe quarantine output exposed a filename")

        let quarantineApplied = try QuarantineExecutor.apply(
            report: first,
            plan: standalonePlan,
            targetURL: quarantineRoot
        )
        try require(quarantineApplied.filesModified, "quarantine apply should report file modification")
        try require(fileManager.fileExists(atPath: fileA.path), "preferred local copy must remain in place")
        try require(!fileManager.fileExists(atPath: fileB.path), "redundant Takeout copy should move to quarantine")
        guard let movedDestination = quarantineApplied.moves.first?.destinationPath else {
            throw SelfTestFailure("quarantine apply did not record a destination")
        }
        try require(fileManager.fileExists(atPath: movedDestination), "quarantined copy is missing at its destination")
        try require(try Data(contentsOf: URL(fileURLWithPath: movedDestination)) == beforeB, "quarantined bytes changed")
        guard let manifestPath = quarantineApplied.manifestPath else {
            throw SelfTestFailure("quarantine apply did not create a restore manifest")
        }
        try require(fileManager.fileExists(atPath: manifestPath), "quarantine restore manifest is missing")

        let restoreDryRun = try QuarantineRestoreExecutor.preflight(
            manifestURL: URL(fileURLWithPath: manifestPath),
            catalogURL: temporary.appendingPathComponent("catalog.sqlite3")
        )
        try require(restoreDryRun.dryRun, "quarantine restore preflight must be a dry run")
        try require(restoreDryRun.resourceCount == 1, "restore preflight should contain one synthetic resource")
        try require(!fileManager.fileExists(atPath: fileB.path), "restore dry run must not move the quarantined resource")
        let restoreAgentJSON = String(
            decoding: try encoder.encode(AgentSafeQuarantineRestoreReport(report: restoreDryRun)),
            as: UTF8.self
        )
        try require(!restoreAgentJSON.contains(rootB.path), "agent-safe restore output exposed a source path")
        try require(!restoreAgentJSON.contains(manifestPath), "agent-safe restore output exposed a manifest path")
        try require(!restoreAgentJSON.contains("copy.jpg"), "agent-safe restore output exposed a filename")

        try Data("tampered-quarantine-resource".utf8).write(to: URL(fileURLWithPath: movedDestination))
        do {
            _ = try QuarantineRestoreExecutor.preflight(
                manifestURL: URL(fileURLWithPath: manifestPath),
                catalogURL: temporary.appendingPathComponent("catalog.sqlite3")
            )
            throw SelfTestFailure("restore preflight accepted a changed quarantine resource")
        } catch QuarantineRestoreError.quarantineResourceChanged {
            // Expected: restore must re-verify the local catalog's exact-file evidence.
        }
        try beforeB.write(to: URL(fileURLWithPath: movedDestination))

        let restored = try QuarantineRestoreExecutor.apply(
            manifestURL: URL(fileURLWithPath: manifestPath),
            catalogURL: temporary.appendingPathComponent("catalog.sqlite3")
        )
        try require(restored.filesModified, "restore apply should report file modification")
        try require(fileManager.fileExists(atPath: fileB.path), "restore apply did not return the resource to its source")
        try require(!fileManager.fileExists(atPath: movedDestination), "restore apply left the resource in quarantine")
        try require(try Data(contentsOf: fileB) == beforeB, "restored bytes changed")
        try require(restored.restoreStatePath != nil, "restore apply should write local restore state")

        let trackingRoot = temporary.appendingPathComponent("Tracking", isDirectory: true)
        let trackingMovedRoot = temporary.appendingPathComponent("TrackingMoved", isDirectory: true)
        let trackingCatalog = temporary.appendingPathComponent("tracking.sqlite3")
        try fileManager.createDirectory(at: trackingRoot, withIntermediateDirectories: true)
        let trackingOld = trackingRoot.appendingPathComponent("old-name.jpg")
        try Data("synthetic-tracking-file".utf8).write(to: trackingOld)
        _ = try RootMarkerStore.create(at: trackingRoot)
        let trackingScanner = try ArchiveScanner(catalogURL: trackingCatalog)
        let trackingFirst = try await trackingScanner.scan(roots: [
            ScanRoot(url: trackingRoot, kind: .reference, provenance: .localLibrary)
        ])
        let firstRootID = trackingFirst.roots[0].rootID
        guard let firstResourceID = try sqliteText(
            databaseURL: trackingCatalog,
            sql: "SELECT id FROM resources WHERE relative_path = 'old-name.jpg'"
        ) else {
            throw SelfTestFailure("tracking resource ID was not persisted")
        }

        let trackingNew = trackingRoot.appendingPathComponent("new-name.jpg")
        try fileManager.moveItem(at: trackingOld, to: trackingNew)
        _ = try await trackingScanner.scan(roots: [
            ScanRoot(url: trackingRoot, kind: .reference, provenance: .localLibrary)
        ])
        let renamedResourceID = try sqliteText(
            databaseURL: trackingCatalog,
            sql: "SELECT id FROM resources WHERE relative_path = 'new-name.jpg'"
        )
        try require(
            renamedResourceID == firstResourceID,
            "a same-volume rename should preserve the physical resource ID"
        )
        try require(
            try sqliteInt(
                databaseURL: trackingCatalog,
                sql: "SELECT COUNT(*) FROM resource_locations WHERE resource_id = '\(firstResourceID)'"
            ) == 2,
            "resource location history should retain both old and new paths"
        )

        try fileManager.moveItem(at: trackingRoot, to: trackingMovedRoot)
        let trackingMoved = try await trackingScanner.scan(roots: [
            ScanRoot(url: trackingMovedRoot, kind: .reference, provenance: .localLibrary)
        ])
        try require(
            trackingMoved.roots[0].rootID == firstRootID,
            "a marked root should preserve its root ID after the directory moves"
        )

        guard let trackedResource = trackingMoved.resources.first,
              let trackedAssetID = trackedResource.assetID
        else {
            throw SelfTestFailure("tracking scan did not expose a persisted resource/asset")
        }
        let catalogCommitPlanObject: [String: Any] = [
            "schemaVersion": 1,
            "policy": "selftest_catalog_commit",
            "sessionID": trackingMoved.sessionID,
            "summary": [
                "automaticItemCount": 1,
                "reviewItemCount": 0,
                "automaticResourceCount": 1,
                "reviewResourceCount": 0
            ],
            "items": [[
                "itemID": "O-CATALOG-COMMIT",
                "assetID": trackedAssetID,
                "kind": "standalone",
                "decision": "automatic",
                "reason": "camera_name_and_capture_wall_clock",
                "moves": [[
                    "resourceID": trackedResource.resourceID,
                    "rootID": trackedResource.rootID,
                    "role": trackedResource.role.rawValue,
                    "sourceRelativePath": trackedResource.relativePath,
                    "destinationRelativePath": "committed-name.jpg"
                ]]
            ]],
            "filesModified": false
        ]
        let catalogCommitPlan = try JSONDecoder().decode(
            OrganizationPlan.self,
            from: JSONSerialization.data(withJSONObject: catalogCommitPlanObject)
        )
        let catalogCommitOperations = temporary.appendingPathComponent("CatalogCommitOperations", isDirectory: true)
        _ = try OrganizationExecutor.apply(
            report: trackingMoved,
            plan: catalogCommitPlan,
            manifestDirectoryURL: catalogCommitOperations,
            commitCatalog: { try trackingScanner.commitAppliedOrganizationPlan(catalogCommitPlan) }
        )
        let committedPath = trackingMovedRoot.appendingPathComponent("committed-name.jpg")
        try require(fileManager.fileExists(atPath: committedPath.path), "catalog-committed organization move is missing")
        try require(
            try sqliteText(
                databaseURL: trackingCatalog,
                sql: "SELECT id FROM resources WHERE relative_path = 'committed-name.jpg'"
            ) == firstResourceID,
            "organization catalog commit must preserve the stable resource ID"
        )
        try require(
            try sqliteInt(
                databaseURL: trackingCatalog,
                sql: "SELECT COUNT(*) FROM resource_locations WHERE resource_id = '\(firstResourceID)'"
            ) == 3,
            "organization catalog commit should append the destination to location history without a full rescan"
        )

        let organizationReport = syntheticOrganizationReport()
        let organizationPlan = OrganizationPlanner.makePlan(from: organizationReport)
        try require(
            organizationPlan.summary.automaticItemCount == 2,
            "expected one Live Photo and one standalone automatic organization item"
        )
        try require(
            organizationPlan.summary.automaticResourceCount == 3,
            "organization plan should move three synthetic resources"
        )
        guard let organizationLive = organizationPlan.items.first(where: { $0.kind == .livePhoto }) else {
            throw SelfTestFailure("organization plan is missing the synthetic Live Photo")
        }
        try require(organizationLive.moves.count == 2, "Live Photo organization must contain both resources")
        let liveDestinationStems = Set(organizationLive.moves.map {
            ($0.destinationRelativePath as NSString).deletingPathExtension
        })
        try require(liveDestinationStems.count == 1, "Live Photo resources must receive the same destination basename")
        try require(
            organizationLive.moves.allSatisfy { ($0.destinationRelativePath as NSString).deletingLastPathComponent.isEmpty },
            "automatic organization destinations should be flat within the local root"
        )
        let alreadyOrganizedPlan = OrganizationPlanner.makePlan(
            from: syntheticOrganizationReport(alreadyOrganizedLivePhoto: true)
        )
        try require(
            !alreadyOrganizedPlan.items.contains { $0.assetID == "AORG1" },
            "an already flattened capture-time Live Photo should be treated as completed, not REVIEW"
        )
        try require(
            alreadyOrganizedPlan.summary.automaticItemCount == 1,
            "only the standalone camera file should remain automatic after the Live Photo is already organized"
        )

        let organizationAgentJSON = String(
            decoding: try encoder.encode(AgentSafeOrganizationPlan(plan: organizationPlan)),
            as: UTF8.self
        )
        try require(!organizationAgentJSON.contains("IMG_1234"), "agent-safe organization plan exposed an original filename")
        try require(!organizationAgentJSON.contains("2026-08-14"), "agent-safe organization plan exposed a capture-time filename")
        try require(!organizationAgentJSON.contains("ZIIl652B"), "agent-safe organization plan exposed a custom filename")

        let organizationApplyRoot = temporary.appendingPathComponent("OrganizationApply", isDirectory: true)
        let organizationOperations = temporary.appendingPathComponent("OrganizationOperations", isDirectory: true)
        try fileManager.createDirectory(
            at: organizationApplyRoot.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: organizationApplyRoot.appendingPathComponent("other", isDirectory: true),
            withIntermediateDirectories: true
        )
        let organizationSourcePhoto = organizationApplyRoot.appendingPathComponent("nested/IMG_1234.HEIC")
        let organizationSourceVideo = organizationApplyRoot.appendingPathComponent("nested/IMG_1234.MOV")
        let organizationSourceStandalone = organizationApplyRoot.appendingPathComponent("other/IMG_5678.JPG")
        let organizationCustom = organizationApplyRoot.appendingPathComponent("other/ZIIl652B 2.jpg")
        try Data(repeating: 1, count: 100).write(to: organizationSourcePhoto)
        try Data(repeating: 2, count: 200).write(to: organizationSourceVideo)
        try Data(repeating: 3, count: 80).write(to: organizationSourceStandalone)
        try Data(repeating: 4, count: 70).write(to: organizationCustom)
        _ = try RootMarkerStore.create(at: organizationApplyRoot)

        let organizationApplyScan = syntheticOrganizationReport(localPath: organizationApplyRoot.path)
        let organizationApplyPlan = OrganizationPlanner.makePlan(from: organizationApplyScan)
        let organizationPreflight = try OrganizationExecutor.preflight(
            report: organizationApplyScan,
            plan: organizationApplyPlan
        )
        try require(organizationPreflight.dryRun, "organization preflight must be a dry run")
        try require(organizationPreflight.resourceCount == 3, "organization preflight should contain three automatic resources")
        try require(fileManager.fileExists(atPath: organizationSourcePhoto.path), "organization dry run moved the Live Photo still")
        try require(fileManager.fileExists(atPath: organizationSourceVideo.path), "organization dry run moved the Live Photo video")

        do {
            _ = try OrganizationExecutor.apply(
                report: organizationApplyScan,
                plan: organizationApplyPlan,
                manifestDirectoryURL: organizationOperations,
                commitCatalog: { throw SelfTestFailure("synthetic catalog commit failure") }
            )
            throw SelfTestFailure("organization apply should rollback when catalog commit fails")
        } catch let error as SelfTestFailure where error.message == "synthetic catalog commit failure" {
            // Expected: the executor must roll filesystem moves back when catalog commit fails.
        }
        try require(fileManager.fileExists(atPath: organizationSourcePhoto.path), "catalog failure rollback lost the Live Photo still")
        try require(fileManager.fileExists(atPath: organizationSourceVideo.path), "catalog failure rollback lost the Live Photo video")
        try require(fileManager.fileExists(atPath: organizationSourceStandalone.path), "catalog failure rollback lost the standalone resource")

        let organizationApplied = try OrganizationExecutor.apply(
            report: organizationApplyScan,
            plan: organizationApplyPlan,
            manifestDirectoryURL: organizationOperations,
            commitCatalog: {}
        )
        try require(organizationApplied.filesModified, "organization apply should modify synthetic files")
        try require(organizationApplied.resourceCount == 3, "organization apply should move three resources")
        try require(!fileManager.fileExists(atPath: organizationSourcePhoto.path), "organization apply left the old Live Photo still path")
        try require(!fileManager.fileExists(atPath: organizationSourceVideo.path), "organization apply left the old Live Photo video path")
        try require(!fileManager.fileExists(atPath: organizationSourceStandalone.path), "organization apply left the old standalone path")
        try require(fileManager.fileExists(atPath: organizationCustom.path), "organization apply must preserve custom filenames")
        try require(
            organizationApplied.moves.allSatisfy { fileManager.fileExists(atPath: $0.destinationPath) },
            "an organization destination is missing"
        )
        guard let organizationManifest = organizationApplied.manifestPath else {
            throw SelfTestFailure("organization apply did not create a manifest")
        }
        try require(fileManager.fileExists(atPath: organizationManifest), "organization manifest is missing")
        let organizationApplyAgentJSON = String(
            decoding: try encoder.encode(AgentSafeOrganizationApplyReport(report: organizationApplied)),
            as: UTF8.self
        )
        try require(!organizationApplyAgentJSON.contains(organizationApplyRoot.path), "agent-safe organization apply output exposed a root path")
        try require(!organizationApplyAgentJSON.contains("IMG_1234"), "agent-safe organization apply output exposed a filename")

        let cleanupRoot = temporary.appendingPathComponent("CleanupRoot", isDirectory: true)
        let cleanupNested = cleanupRoot.appendingPathComponent("batch/inner", isDirectory: true)
        let cleanupKeep = cleanupRoot.appendingPathComponent("keep", isDirectory: true)
        try fileManager.createDirectory(at: cleanupNested, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cleanupKeep, withIntermediateDirectories: true)
        _ = try RootMarkerStore.create(at: cleanupRoot)
        let cleanupSourceA = cleanupNested.appendingPathComponent("IMG_0001.JPG")
        let cleanupSourceB = cleanupKeep.appendingPathComponent("IMG_0002.JPG")
        try Data("cleanup-a".utf8).write(to: cleanupSourceA)
        try Data("cleanup-b".utf8).write(to: cleanupSourceB)
        try Data("preserve-this-directory".utf8).write(to: cleanupKeep.appendingPathComponent("note.txt"))
        let cleanupCatalog = temporary.appendingPathComponent("cleanup.sqlite3")
        let cleanupScanner = try ArchiveScanner(catalogURL: cleanupCatalog)
        let cleanupScan = try await cleanupScanner.scan(roots: [
            ScanRoot(url: cleanupRoot, kind: .inbox, provenance: .localLibrary)
        ])
        guard let cleanupResourceA = cleanupScan.resources.first(where: { $0.relativePath == "batch/inner/IMG_0001.JPG" }),
              let cleanupResourceB = cleanupScan.resources.first(where: { $0.relativePath == "keep/IMG_0002.JPG" })
        else {
            throw SelfTestFailure("cleanup fixture resources were not scanned")
        }
        let cleanupDestinationA = cleanupRoot.appendingPathComponent("2026-01-01_00-00-01.jpg")
        let cleanupDestinationB = cleanupRoot.appendingPathComponent("2026-01-01_00-00-02.jpg")
        try fileManager.moveItem(at: cleanupSourceA, to: cleanupDestinationA)
        try fileManager.moveItem(at: cleanupSourceB, to: cleanupDestinationB)
        let cleanupOrganizationManifestURL = temporary.appendingPathComponent("cleanup-organization.json")
        let cleanupOrganizationManifest = OrganizationApplyManifest(
            schemaVersion: 1,
            sessionID: cleanupScan.sessionID,
            policy: "selftest_cleanup",
            createdAt: Date(),
            state: "complete",
            moves: [
                OrganizationApplyMoveRecord(
                    itemID: "O-CLEAN-A",
                    resourceID: cleanupResourceA.resourceID,
                    rootID: cleanupResourceA.rootID,
                    role: cleanupResourceA.role,
                    sourcePath: cleanupSourceA.path,
                    destinationPath: cleanupDestinationA.path,
                    byteSize: cleanupResourceA.byteSize
                ),
                OrganizationApplyMoveRecord(
                    itemID: "O-CLEAN-B",
                    resourceID: cleanupResourceB.resourceID,
                    rootID: cleanupResourceB.rootID,
                    role: cleanupResourceB.role,
                    sourcePath: cleanupSourceB.path,
                    destinationPath: cleanupDestinationB.path,
                    byteSize: cleanupResourceB.byteSize
                )
            ],
            filesModified: true
        )
        let cleanupEncoder = JSONEncoder()
        cleanupEncoder.dateEncodingStrategy = .iso8601
        try cleanupEncoder.encode(cleanupOrganizationManifest).write(to: cleanupOrganizationManifestURL)

        let cleanupDryRun = try EmptyDirectoryCleanupExecutor.preflight(
            organizationManifestURL: cleanupOrganizationManifestURL,
            catalogURL: cleanupCatalog
        )
        try require(cleanupDryRun.dryRun, "empty-directory cleanup preflight must be a dry run")
        try require(cleanupDryRun.directoryCount == 2, "cleanup should remove only the nested empty directory chain")
        try require(fileManager.fileExists(atPath: cleanupNested.path), "cleanup dry run removed an empty directory")
        let cleanupAgentJSON = String(
            decoding: try encoder.encode(AgentSafeEmptyDirectoryCleanupReport(report: cleanupDryRun)),
            as: UTF8.self
        )
        try require(!cleanupAgentJSON.contains(cleanupRoot.path), "agent-safe empty-directory cleanup exposed a path")
        try require(!cleanupAgentJSON.contains("batch"), "agent-safe empty-directory cleanup exposed a directory name")

        let cleanupApplied = try EmptyDirectoryCleanupExecutor.apply(
            organizationManifestURL: cleanupOrganizationManifestURL,
            catalogURL: cleanupCatalog
        )
        try require(cleanupApplied.directoryCount == 2, "empty-directory cleanup should remove two directories")
        try require(!fileManager.fileExists(atPath: cleanupNested.path), "nested empty directory was not removed")
        try require(!fileManager.fileExists(atPath: cleanupRoot.appendingPathComponent("batch").path), "empty parent directory was not removed")
        try require(fileManager.fileExists(atPath: cleanupKeep.path), "non-empty directory must be preserved")
        try require(cleanupApplied.cleanupManifestPath != nil, "empty-directory cleanup should record a local manifest")

        let coverageReport = syntheticCanonicalCoverageReport()
        let coveragePlan = ReconciliationPlanner.makePlan(from: coverageReport)
        try require(
            coveragePlan.summary.automaticRedundantResourceCount == 4,
            "canonical coverage should allow repeated exact Takeout Live Photo resources"
        )
        try require(
            coveragePlan.summary.reviewResourceCount == 0,
            "fully covered repeated Takeout Live Photo resources should not require review"
        )
        try require(
            coveragePlan.items.contains { $0.reason == .livePhotoCanonicalCoverage },
            "canonical coverage reason should be recorded in the plan"
        )

        let liveLocalRoot = temporary.appendingPathComponent("LiveLocal", isDirectory: true)
        let liveTakeoutRoot = temporary.appendingPathComponent("LiveTakeout", isDirectory: true)
        let liveQuarantineRoot = temporary.appendingPathComponent("LiveQuarantine", isDirectory: true)
        for directory in [
            liveLocalRoot.appendingPathComponent("local", isDirectory: true),
            liveTakeoutRoot.appendingPathComponent("year", isDirectory: true),
            liveTakeoutRoot.appendingPathComponent("album", isDirectory: true),
            liveQuarantineRoot
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let livePhotoBytes = Data(repeating: 0x2A, count: 100)
        let liveVideoBytes = Data(repeating: 0x7B, count: 200)
        for relativePath in ["local/IMG_0001.HEIC"] {
            try livePhotoBytes.write(to: liveLocalRoot.appendingPathComponent(relativePath))
        }
        for relativePath in ["local/IMG_0001.MOV"] {
            try liveVideoBytes.write(to: liveLocalRoot.appendingPathComponent(relativePath))
        }
        for relativePath in ["year/IMG_0001.HEIC", "album/IMG_0001.HEIC"] {
            try livePhotoBytes.write(to: liveTakeoutRoot.appendingPathComponent(relativePath))
        }
        for relativePath in ["year/IMG_0001.MOV", "album/IMG_0001.MOV"] {
            try liveVideoBytes.write(to: liveTakeoutRoot.appendingPathComponent(relativePath))
        }

        let liveCoverageReport = syntheticCanonicalCoverageReport(
            localPath: liveLocalRoot.path,
            takeoutPath: liveTakeoutRoot.path
        )
        let liveCoveragePlan = ReconciliationPlanner.makePlan(from: liveCoverageReport)
        let livePreflight = try QuarantineExecutor.preflight(
            report: liveCoverageReport,
            plan: liveCoveragePlan,
            targetURL: liveQuarantineRoot
        )
        try require(livePreflight.resourceCount == 4, "Live Photo quarantine must include every covered resource")

        var tamperedObject = try JSONSerialization.jsonObject(
            with: encoder.encode(liveCoveragePlan)
        ) as! [String: Any]
        var tamperedItems = tamperedObject["items"] as! [[String: Any]]
        let liveItemIndex = try requireIndex(
            in: tamperedItems,
            where: { ($0["kind"] as? String) == "live_photo_asset" },
            message: "expected a Live Photo plan item"
        )
        var tamperedItem = tamperedItems[liveItemIndex]
        var tamperedCandidates = tamperedItem["candidateResources"] as! [[String: Any]]
        tamperedCandidates.removeLast()
        tamperedItem["candidateResources"] = tamperedCandidates
        tamperedItems[liveItemIndex] = tamperedItem
        tamperedObject["items"] = tamperedItems
        let tamperedPlanData = try JSONSerialization.data(withJSONObject: tamperedObject)
        let tamperedPlan = try JSONDecoder().decode(ReconciliationPlan.self, from: tamperedPlanData)
        do {
            _ = try QuarantineExecutor.preflight(
                report: liveCoverageReport,
                plan: tamperedPlan,
                targetURL: liveQuarantineRoot
            )
            throw SelfTestFailure("partial Live Photo mutation should be rejected")
        } catch QuarantineError.livePhotoAtomicityViolation {
            // Expected: no partial Live Photo resource set may cross a mutation boundary.
        }

        let liveApplied = try QuarantineExecutor.apply(
            report: liveCoverageReport,
            plan: liveCoveragePlan,
            targetURL: liveQuarantineRoot
        )
        try require(liveApplied.resourceCount == 4, "Live Photo quarantine should move the entire covered resource set")
        try require(
            fileManager.fileExists(atPath: liveLocalRoot.appendingPathComponent("local/IMG_0001.HEIC").path)
                && fileManager.fileExists(atPath: liveLocalRoot.appendingPathComponent("local/IMG_0001.MOV").path),
            "preferred Live Photo still and paired video must remain together"
        )
        for relativePath in [
            "year/IMG_0001.HEIC",
            "year/IMG_0001.MOV",
            "album/IMG_0001.HEIC",
            "album/IMG_0001.MOV"
        ] {
            try require(
                !fileManager.fileExists(atPath: liveTakeoutRoot.appendingPathComponent(relativePath).path),
                "redundant Live Photo resources must move as one complete set"
            )
        }

        let parentRoot = temporary.appendingPathComponent("Pictures", isDirectory: true)
        let takeoutRoot = parentRoot.appendingPathComponent("Takeout", isDirectory: true)
        try fileManager.createDirectory(at: takeoutRoot, withIntermediateDirectories: true)
        try Data("preferred-local-file".utf8).write(
            to: parentRoot.appendingPathComponent("same-name.jpg")
        )
        try Data("different-takeout-file-with-same-name".utf8).write(
            to: takeoutRoot.appendingPathComponent("same-name.jpg")
        )
        try Data(
            "{\"title\":\"same-name.jpg\",\"photoTakenTime\":{\"timestamp\":\"1785510000\"}}".utf8
        ).write(to: takeoutRoot.appendingPathComponent("metadata.json"))

        let nestedScanner = try ArchiveScanner(
            catalogURL: temporary.appendingPathComponent("nested-catalog.sqlite3")
        )
        let nestedReport = try await nestedScanner.scan(roots: [
            ScanRoot(
                url: parentRoot,
                kind: .inbox,
                provenance: .localLibrary
            ),
            ScanRoot(
                url: takeoutRoot,
                kind: .importSource,
                provenance: .googleTakeout
            )
        ])

        try require(
            nestedReport.summary.resourceCount == 3,
            "a nested registered root must not be scanned again through its parent"
        )
        try require(
            nestedReport.roots.first { $0.provenance == .localLibrary }?.mediaFileCount == 1,
            "the parent local root should own only its direct media"
        )
        try require(
            nestedReport.roots.first { $0.provenance == .googleTakeout }?.mediaFileCount == 1,
            "the nested Takeout root should preserve its own provenance"
        )
        try require(
            nestedReport.warnings.contains { $0.code == "filename_collision" },
            "same filenames with different content must be reported as a collision"
        )
        try require(
            nestedReport.summary.eventSuggestionCount == 1,
            "a Google Takeout photoTakenTime sidecar should provide event-time evidence"
        )

        let nestedAgentJSON = String(
            decoding: try encoder.encode(AgentSafeScanReport(report: nestedReport)),
            as: UTF8.self
        )
        try require(
            !nestedAgentJSON.contains("same-name.jpg"),
            "agent-safe report exposed a nested filename"
        )
        try require(
            !nestedAgentJSON.contains(takeoutRoot.path),
            "agent-safe report exposed a nested source path"
        )

        let takeoutSemanticsRoot = temporary.appendingPathComponent("TakeoutSemantics", isDirectory: true)
        let yearFolder = takeoutSemanticsRoot.appendingPathComponent("YearBucket", isDirectory: true)
        let albumFolder = takeoutSemanticsRoot.appendingPathComponent("AlbumBucket", isDirectory: true)
        try fileManager.createDirectory(at: yearFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: albumFolder, withIntermediateDirectories: true)
        let repeatedBytes = Data("synthetic-takeout-folder-membership-copy".utf8)
        try repeatedBytes.write(to: yearFolder.appendingPathComponent("copy-a.jpg"))
        try repeatedBytes.write(to: albumFolder.appendingPathComponent("copy-b.jpg"))

        let semanticsScanner = try ArchiveScanner(
            catalogURL: temporary.appendingPathComponent("semantics-catalog.sqlite3")
        )
        let semanticsReport = try await semanticsScanner.scan(roots: [
            ScanRoot(
                url: takeoutSemanticsRoot,
                kind: .importSource,
                provenance: .googleTakeout
            )
        ])
        try require(
            semanticsReport.roots.first?.sourceFolderSemanticsCaptured == true,
            "Takeout source-folder semantics should be captured locally before physical collapse"
        )
        let semanticsPlan = ReconciliationPlanner.makePlan(from: semanticsReport)
        try require(
            semanticsPlan.summary.automaticRedundantResourceCount == 1,
            "captured Takeout source-folder memberships should allow one exact standalone copy to remain physical"
        )
        try require(
            semanticsPlan.items.contains { $0.reason == .takeoutSourceFolderSemanticsCaptured },
            "the planner should record source-folder semantic capture as the reason for Takeout-only collapse"
        )
        let semanticsAgentJSON = String(
            decoding: try encoder.encode(AgentSafeScanReport(report: semanticsReport)),
            as: UTF8.self
        )
        try require(
            !semanticsAgentJSON.contains("YearBucket") && !semanticsAgentJSON.contains("AlbumBucket"),
            "agent-safe report exposed Takeout collection names"
        )
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() {
            throw SelfTestFailure(message)
        }
    }

    private static func requireIndex<T>(
        in values: [T],
        where predicate: (T) -> Bool,
        message: String
    ) throws -> Int {
        guard let index = values.firstIndex(where: predicate) else {
            throw SelfTestFailure(message)
        }
        return index
    }
}

private func executableExists(_ name: String) -> Bool {
    let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return environmentPath.split(separator: ":").contains { directory in
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: candidate)
    }
}

private func writeSyntheticTimedMetadataMovie(
    to url: URL,
    markerValues: [Int8],
    validDataType: Bool = true
) async throws {
    let stillImageTimeIdentifier = "mdta/com.apple.quicktime.still-image-time"
    let unrelatedIdentifier = "mdta/com.example.photoarchive.synthetic"
    let metadataIdentifiers = markerValues.isEmpty
        ? [unrelatedIdentifier]
        : [stillImageTimeIdentifier]
    let dataType = validDataType
        ? (kCMMetadataBaseDataType_SInt8 as String)
        : (kCMMetadataBaseDataType_UTF8 as String)
    let specifications = metadataIdentifiers.map { identifier -> CFDictionary in
        [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: identifier,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: dataType
        ] as CFDictionary
    }

    var formatDescription: CMMetadataFormatDescription?
    let formatStatus = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: specifications as CFArray,
        formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, formatDescription != nil else {
        throw SelfTestFailure("could not create synthetic metadata format description")
    }

    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .metadata,
        outputSettings: nil,
        sourceFormatHint: formatDescription
    )
    guard writer.canAdd(input) else {
        throw SelfTestFailure("could not add synthetic metadata input")
    }
    writer.add(input)
    let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)

    guard writer.startWriting() else {
        throw SelfTestFailure("synthetic metadata writer did not start")
    }
    writer.startSession(atSourceTime: .zero)

    let values = markerValues.isEmpty ? [Int8(0)] : markerValues
    for (index, value) in values.enumerated() {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(
            rawValue: markerValues.isEmpty ? unrelatedIdentifier : stillImageTimeIdentifier
        )
        item.dataType = dataType
        item.value = validDataType ? NSNumber(value: value) : NSString(string: "invalid")
        let start = CMTime(value: CMTimeValue(index), timescale: 30)
        let group = AVTimedMetadataGroup(
            items: [item],
            timeRange: CMTimeRange(start: start, duration: CMTime(value: 1, timescale: 30))
        )
        guard adaptor.append(group) else {
            throw SelfTestFailure("could not append synthetic timed metadata")
        }
    }

    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw SelfTestFailure("synthetic metadata movie did not finish")
    }
}

private func syntheticOrganizationReport(
    localPath: String = "/synthetic/local",
    alreadyOrganizedLivePhoto: Bool = false
) -> ScanReport {
    let rootID = "RORG"
    let capture = CaptureTime(
        localTimestamp: "2026-08-14T17:42:31",
        utcOffset: "+09:00",
        instant: Date(timeIntervalSince1970: 1_776_000_000),
        source: .exifDateTimeOriginal,
        confidence: .trusted
    )
    let liveStem = "2026-08-14_17-42-31"
    let photoRelativePath = alreadyOrganizedLivePhoto ? "\(liveStem).HEIC" : "nested/IMG_1234.HEIC"
    let videoRelativePath = alreadyOrganizedLivePhoto ? "\(liveStem).MOV" : "nested/IMG_1234.MOV"
    let photoFileName = alreadyOrganizedLivePhoto ? "\(liveStem).HEIC" : "IMG_1234.HEIC"
    let videoFileName = alreadyOrganizedLivePhoto ? "\(liveStem).MOV" : "IMG_1234.MOV"
    let photo = ScannedResourceReport(
        resourceID: "FORG1",
        assetID: "AORG1",
        rootID: rootID,
        rootLabel: "Local",
        relativePath: photoRelativePath,
        fileName: photoFileName,
        mediaKind: .image,
        role: .photo,
        byteSize: 100,
        captureTime: capture
    )
    let video = ScannedResourceReport(
        resourceID: "FORG2",
        assetID: "AORG1",
        rootID: rootID,
        rootLabel: "Local",
        relativePath: videoRelativePath,
        fileName: videoFileName,
        mediaKind: .video,
        role: .pairedVideo,
        byteSize: 200,
        captureTime: capture
    )
    let standalone = ScannedResourceReport(
        resourceID: "FORG3",
        assetID: "AORG2",
        rootID: rootID,
        rootLabel: "Local",
        relativePath: "other/IMG_5678.JPG",
        fileName: "IMG_5678.JPG",
        mediaKind: .image,
        role: .standaloneImage,
        byteSize: 80,
        captureTime: capture
    )
    let custom = ScannedResourceReport(
        resourceID: "FORG4",
        assetID: "AORG3",
        rootID: rootID,
        rootLabel: "Local",
        relativePath: "other/ZIIl652B 2.jpg",
        fileName: "ZIIl652B 2.jpg",
        mediaKind: .image,
        role: .standaloneImage,
        byteSize: 70,
        captureTime: capture
    )
    let liveOccurrence = LivePhotoOccurrenceReport(
        rootID: rootID,
        rootLabel: "Local",
        status: .complete,
        stillCount: 1,
        videoCount: 1,
        resources: [
            ResourceReference(rootID: rootID, rootLabel: "Local", relativePath: photo.relativePath, role: .photo, byteSize: photo.byteSize),
            ResourceReference(rootID: rootID, rootLabel: "Local", relativePath: video.relativePath, role: .pairedVideo, byteSize: video.byteSize)
        ]
    )
    let now = Date(timeIntervalSince1970: 1)
    return ScanReport(
        sessionID: "SORG",
        startedAt: now,
        completedAt: now,
        catalogPath: "/synthetic/organization.sqlite3",
        summary: ScanSummary(
            rootCount: 1,
            resourceCount: 4,
            logicalAssetCount: 3,
            livePhotoAssetCount: 1,
            exactDuplicateGroupCount: 0,
            eventSuggestionCount: 0,
            warningCount: 0
        ),
        roots: [
            RootScanReport(
                rootID: rootID,
                label: "Local",
                kind: .inbox,
                provenance: .localLibrary,
                canonicalPath: localPath,
                mediaFileCount: 4,
                completeLivePhotos: 1,
                stillOnlyLiveResources: 0,
                videoOnlyLiveResources: 0,
                standaloneImages: 2,
                standaloneVideos: 0,
                sidecars: 0,
                metadataProbeFailures: 0
            )
        ],
        resources: [photo, video, standalone, custom],
        livePhotos: [
            LivePhotoAssetReport(
                assetID: "AORG1",
                occurrenceCount: 1,
                stillCopyCount: 1,
                videoCopyCount: 1,
                occurrences: [liveOccurrence]
            )
        ],
        exactDuplicateGroups: [],
        eventSuggestions: [],
        warnings: [],
        filesModified: false
    )
}

private func syntheticCanonicalCoverageReport(
    localPath: String = "/synthetic/local",
    takeoutPath: String = "/synthetic/takeout"
) -> ScanReport {
    let localRootID = "RLOCAL"
    let takeoutRootID = "RTAKEOUT"
    let localPhoto = ResourceReference(
        rootID: localRootID,
        rootLabel: "Local",
        relativePath: "local/IMG_0001.HEIC",
        role: .photo,
        byteSize: 100
    )
    let localVideo = ResourceReference(
        rootID: localRootID,
        rootLabel: "Local",
        relativePath: "local/IMG_0001.MOV",
        role: .pairedVideo,
        byteSize: 200
    )
    let takeoutPhotoA = ResourceReference(
        rootID: takeoutRootID,
        rootLabel: "Takeout",
        relativePath: "year/IMG_0001.HEIC",
        role: .photo,
        byteSize: 100
    )
    let takeoutPhotoB = ResourceReference(
        rootID: takeoutRootID,
        rootLabel: "Takeout",
        relativePath: "album/IMG_0001.HEIC",
        role: .photo,
        byteSize: 100
    )
    let takeoutVideoA = ResourceReference(
        rootID: takeoutRootID,
        rootLabel: "Takeout",
        relativePath: "year/IMG_0001.MOV",
        role: .pairedVideo,
        byteSize: 200
    )
    let takeoutVideoB = ResourceReference(
        rootID: takeoutRootID,
        rootLabel: "Takeout",
        relativePath: "album/IMG_0001.MOV",
        role: .pairedVideo,
        byteSize: 200
    )

    let roots = [
        RootScanReport(
            rootID: localRootID,
            label: "Local",
            kind: .inbox,
            provenance: .localLibrary,
            canonicalPath: localPath,
            mediaFileCount: 2,
            completeLivePhotos: 1,
            stillOnlyLiveResources: 0,
            videoOnlyLiveResources: 0,
            standaloneImages: 0,
            standaloneVideos: 0,
            sidecars: 0,
            metadataProbeFailures: 0
        ),
        RootScanReport(
            rootID: takeoutRootID,
            label: "Takeout",
            kind: .importSource,
            provenance: .googleTakeout,
            canonicalPath: takeoutPath,
            mediaFileCount: 4,
            completeLivePhotos: 0,
            stillOnlyLiveResources: 2,
            videoOnlyLiveResources: 0,
            standaloneImages: 0,
            standaloneVideos: 0,
            sidecars: 0,
            metadataProbeFailures: 0
        )
    ]
    let livePhoto = LivePhotoAssetReport(
        assetID: "ALIVE",
        occurrenceCount: 2,
        stillCopyCount: 3,
        videoCopyCount: 3,
        occurrences: [
            LivePhotoOccurrenceReport(
                rootID: localRootID,
                rootLabel: "Local",
                status: .complete,
                stillCount: 1,
                videoCount: 1,
                resources: [localPhoto, localVideo]
            ),
            LivePhotoOccurrenceReport(
                rootID: takeoutRootID,
                rootLabel: "Takeout",
                status: .multipleVariants,
                stillCount: 2,
                videoCount: 2,
                resources: [takeoutPhotoA, takeoutVideoA, takeoutPhotoB, takeoutVideoB]
            )
        ]
    )
    let duplicateGroups = [
        ExactDuplicateGroupReport(
            groupID: "DPHOTO",
            byteSize: 100,
            members: [localPhoto, takeoutPhotoA, takeoutPhotoB]
        ),
        ExactDuplicateGroupReport(
            groupID: "DVIDEO",
            byteSize: 200,
            members: [localVideo, takeoutVideoA, takeoutVideoB]
        )
    ]
    let now = Date(timeIntervalSince1970: 1)
    return ScanReport(
        sessionID: "SYNTHETIC",
        startedAt: now,
        completedAt: now,
        catalogPath: "/synthetic/catalog.sqlite3",
        summary: ScanSummary(
            rootCount: 2,
            resourceCount: 6,
            logicalAssetCount: 1,
            livePhotoAssetCount: 1,
            exactDuplicateGroupCount: 2,
            eventSuggestionCount: 0,
            warningCount: 0
        ),
        roots: roots,
        livePhotos: [livePhoto],
        exactDuplicateGroups: duplicateGroups,
        eventSuggestions: [],
        warnings: [],
        filesModified: false
    )
}

private func sqliteText(databaseURL: URL, sql: String) throws -> String? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw SelfTestFailure("could not open synthetic SQLite catalog")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw SelfTestFailure("could not prepare synthetic SQLite query")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    guard let value = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: value)
}

private func sqliteInt(databaseURL: URL, sql: String) throws -> Int64 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw SelfTestFailure("could not open synthetic SQLite catalog")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw SelfTestFailure("could not prepare synthetic SQLite query")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw SelfTestFailure("synthetic SQLite query returned no row")
    }
    return sqlite3_column_int64(statement, 0)
}

private struct SelfTestFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
