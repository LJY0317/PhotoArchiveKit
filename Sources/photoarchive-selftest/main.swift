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
        let rootAMarker = try RootMarkerStore.create(at: rootA)
        let rootBMarker = try RootMarkerStore.create(at: rootB)
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
        let progressRecorder = ProgressRecorder()
        let first = try await scanner.scan(
            roots: roots,
            options: ScanOptions(progressHandler: { progress in
                progressRecorder.record(progress)
            })
        )
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
        let progressEvents = progressRecorder.snapshot()
        try require(
            progressEvents.contains {
                $0.stage == .metadata
                    && $0.completedUnitCount == 2
                    && $0.totalUnitCount == 2
            },
            "scan progress should expose determinate metadata completion counts"
        )
        try require(
            progressEvents.contains {
                $0.stage == .hashingDuplicates
                    && $0.completedUnitCount == 2
                    && $0.totalUnitCount == 2
            },
            "scan progress should expose determinate hash completion counts"
        )
        try require(
            progressEvents.last == ScanProgress(
                stage: .finalizing,
                completedUnitCount: 1,
                totalUnitCount: 1
            ),
            "scan progress should end with finalizing completion"
        )
        try require(
            second.summary.reusedExactHashCount == 2,
            "unchanged exact-duplicate resources should reuse the local SQLite hash cache"
        )

        let initialCoverage = ArchiveCoverageBuilder.makeReport(from: first)
        try require(initialCoverage.roots.count == 2, "coverage should report both scanned roots")
        try require(
            initialCoverage.roots.allSatisfy {
                $0.exactCoveredElsewhereResourceCount == 1
                    && $0.exactUniqueToRootResourceCount == 0
            },
            "each synthetic exact copy should be covered by the other root"
        )
        try require(
            initialCoverage.pairwiseExact.count == 1
                && initialCoverage.pairwiseExact[0].sharedExactGroupCount == 1,
            "coverage should expose one cross-root exact group"
        )
        let initialCoverageAgentJSON = String(
            decoding: try JSONEncoder().encode(AgentSafeArchiveCoverageReport(report: initialCoverage)),
            as: UTF8.self
        )
        try require(!initialCoverageAgentJSON.contains(rootA.path), "agent-safe coverage exposed root A path")
        try require(!initialCoverageAgentJSON.contains(rootB.path), "agent-safe coverage exposed root B path")
        try require(!initialCoverageAgentJSON.contains("one.jpg"), "agent-safe coverage exposed a filename")

        let rootC = temporary.appendingPathComponent("C", isDirectory: true)
        try fileManager.createDirectory(at: rootC, withIntermediateDirectories: true)
        _ = try RootMarkerStore.create(at: rootC)
        let fileC = rootC.appendingPathComponent("third-copy.jpg")
        try bytes.write(to: fileC)
        let staleMembershipCatalog = temporary.appendingPathComponent("stale-membership.sqlite3")
        let staleMembershipScanner = try ArchiveScanner(catalogURL: staleMembershipCatalog)
        let staleMembershipFirstScan = try await staleMembershipScanner.scan(roots: roots)
        let replacementMembershipScan = try await staleMembershipScanner.scan(roots: [
            ScanRoot(url: rootA, kind: .reference, provenance: .localLibrary),
            ScanRoot(url: rootC, kind: .reference, provenance: .unknown)
        ])
        try require(
            replacementMembershipScan.exactDuplicateGroups.first?.groupID
                == staleMembershipFirstScan.exactDuplicateGroups.first?.groupID,
            "the same exact hash should retain its opaque duplicate group ID"
        )
        guard let replacementGroupID = replacementMembershipScan.exactDuplicateGroups.first?.groupID else {
            throw SelfTestFailure("replacement duplicate scan did not contain a group")
        }
        try require(
            try sqliteInt(
                databaseURL: staleMembershipCatalog,
                sql: "SELECT COUNT(*) FROM exact_duplicate_members WHERE group_id = '\(replacementGroupID)'"
            ) == 2,
            "a newly observed duplicate group must replace stale members from older roots"
        )

        let userArchiveRoot = temporary.appendingPathComponent("UserArchive", isDirectory: true)
        let tripFolder = userArchiveRoot
            .appendingPathComponent("Trips", isDirectory: true)
            .appendingPathComponent("Japan", isDirectory: true)
        let familyFolder = userArchiveRoot.appendingPathComponent("Family", isDirectory: true)
        try fileManager.createDirectory(at: tripFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: familyFolder, withIntermediateDirectories: true)
        _ = try RootMarkerStore.create(at: userArchiveRoot)
        let tripPhoto = tripFolder.appendingPathComponent("trip.jpg")
        let familyPhoto = familyFolder.appendingPathComponent("family.jpg")
        try Data("synthetic-user-archive-trip".utf8).write(to: tripPhoto)
        try Data("synthetic-user-archive-family".utf8).write(to: familyPhoto)

        let archiveCatalog = temporary.appendingPathComponent("archive-catalog.sqlite3")
        let archiveIndex = try await ArchiveRootIndexer.run(
            rootURL: userArchiveRoot,
            catalogURL: archiveCatalog,
            writeSnapshot: true,
            maxConcurrentProbes: 1
        )
        try require(archiveIndex.resourceCount == 2, "archive index should include both media resources")
        try require(archiveIndex.folderCount == 3, "archive index should preserve the nested user folder hierarchy")
        try require(archiveIndex.exactHashResourceCount == 2, "archive index should hash every media resource")
        try require(archiveIndex.snapshotWritten, "archive index apply should write a portable inventory")
        try require(!archiveIndex.mediaFilesModified, "archive inventory write must not report media mutation")
        try require(
            fileManager.fileExists(atPath: archiveIndex.inventoryPath),
            "portable archive inventory file should exist"
        )
        try require(
            try sqliteInt(
                databaseURL: archiveCatalog,
                sql: "SELECT COUNT(*) FROM collections WHERE collection_type = 'user_archive_folder'"
            ) == 3,
            "archive folder hierarchy should be persisted as user-authored collections"
        )
        try require(
            try sqliteInt(
                databaseURL: archiveCatalog,
                sql: "SELECT COUNT(*) FROM memberships WHERE membership_origin = 'user_archive_folder'"
            ) == 2,
            "archive media assets should retain their leaf-folder memberships"
        )

        let inventoryURL = URL(fileURLWithPath: archiveIndex.inventoryPath)
        let inventoryBefore = try Data(contentsOf: inventoryURL)
        let freshComputerCatalog = temporary.appendingPathComponent("fresh-computer-catalog.sqlite3")
        let freshComputerIndex = try await ArchiveRootIndexer.run(
            rootURL: userArchiveRoot,
            catalogURL: freshComputerCatalog,
            writeSnapshot: false,
            maxConcurrentProbes: 1
        )
        try require(
            freshComputerIndex.reusedExactHashCount == 2,
            "a fresh local catalog should reuse exact hashes from the portable archive inventory"
        )
        try require(!freshComputerIndex.mediaFilesModified, "archive index must remain media-read-only")
        try require(
            try Data(contentsOf: inventoryURL) == inventoryBefore,
            "archive-index without --apply must not rewrite the portable inventory"
        )
        let archiveIndexAgentJSON = String(
            decoding: try JSONEncoder().encode(AgentSafeArchiveRootInventoryReport(report: freshComputerIndex)),
            as: UTF8.self
        )
        try require(!archiveIndexAgentJSON.contains(userArchiveRoot.path), "agent-safe archive index report exposed a root path")
        try require(!archiveIndexAgentJSON.contains("trip.jpg"), "agent-safe archive index report exposed a filename")
        let freshIntegrityIndex = try await ArchiveRootIndexer.run(
            rootURL: userArchiveRoot,
            catalogURL: freshComputerCatalog,
            writeSnapshot: false,
            reuseHashCache: false,
            maxConcurrentProbes: 1
        )
        try require(
            freshIntegrityIndex.reusedExactHashCount == 0,
            "archive-index fresh mode should bypass both local and portable hash caches"
        )

        let movedTripPhoto = familyFolder.appendingPathComponent("trip.jpg")
        try fileManager.moveItem(at: tripPhoto, to: movedTripPhoto)
        let postMoveIndex = try await ArchiveRootIndexer.run(
            rootURL: userArchiveRoot,
            catalogURL: archiveCatalog,
            writeSnapshot: false,
            maxConcurrentProbes: 1
        )
        try require(
            postMoveIndex.reusedExactHashCount == 2,
            "same-volume manual moves should reuse cached hashes through filesystem identity"
        )
        try require(
            postMoveIndex.folderCount == 1,
            "archive index should reflect the current user-managed folder structure after a manual move"
        )
        try require(
            try sqliteInt(
                databaseURL: archiveCatalog,
                sql: "SELECT COUNT(*) FROM collections WHERE collection_type = 'user_archive_folder'"
            ) == 1,
            "stale user-archive folder collections should be pruned after a manual move"
        )
        try require(
            try sqliteText(
                databaseURL: archiveCatalog,
                sql: "SELECT name FROM collections WHERE collection_type = 'user_archive_folder' LIMIT 1"
            ) == "Family",
            "the remaining user-archive collection should match the current folder"
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

        let archiveReport = try await scanner.scan(roots: roots)

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
        try require(!agentJSON.contains(rootAMarker.markerKey), "agent-safe report exposed a root marker key")
        try require(!agentJSON.contains(rootBMarker.markerKey), "agent-safe report exposed a root marker key")

        let archiveDestination = temporary.appendingPathComponent("ArchiveDestination", isDirectory: true)
        try fileManager.createDirectory(at: archiveDestination, withIntermediateDirectories: true)
        let archiveDestinationMarker = try RootMarkerStore.create(at: archiveDestination)
        let archivePlan = try scanner.makeArchivePlan(
            from: archiveReport,
            destinationURL: archiveDestination
        )
        try require(archivePlan.schemaVersion == 2, "archive plan should use replay schema v2")
        try require(archivePlan.mediaFilesModified == false, "archive planning must not modify media")
        try require(archivePlan.summary.automaticItemCount == 1, "expected one canonical archive item")
        try require(archivePlan.summary.automaticResourceCount == 1, "expected one canonical archive resource")
        try require(archivePlan.summary.reviewItemCount == 0, "exact standalone copies should not require archive review")
        guard let archivedResource = archivePlan.items.first?.resources.first else {
            throw SelfTestFailure("archive plan did not contain a canonical resource")
        }
        try require(
            archivedResource.sourceRootID == archiveReport.resources.first(where: { $0.relativePath == "one.jpg" })?.rootID,
            "archive planner should prefer the non-Takeout canonical copy"
        )
        try require(
            archivedResource.expectedSHA256 == rawHash,
            "archive plan should freeze a fresh full-file SHA-256 precondition"
        )
        try require(
            archivedResource.destinationRelativePath == "Media/Undated/one.jpg",
            "archive plan should use the deterministic undated fallback folder"
        )
        let archivePlanURL = temporary.appendingPathComponent("archive-plan.json")
        try ArchivePlanStore.write(archivePlan, to: archivePlanURL)
        try require(
            try ArchivePlanStore.read(from: archivePlanURL) == archivePlan,
            "archive plan should round-trip without changing immutable preconditions"
        )
        do {
            try ArchivePlanStore.write(archivePlan, to: archivePlanURL)
            throw SelfTestFailure("archive plan store overwrote an existing plan")
        } catch ArchivePlanError.planOutputExists {
            // Expected: immutable plans are never overwritten in place.
        }
        let archiveAgentJSON = String(
            decoding: try encoder.encode(AgentSafeArchivePlan(plan: archivePlan)),
            as: UTF8.self
        )
        try require(!archiveAgentJSON.contains(rawHash), "agent-safe archive plan exposed SHA-256")
        try require(!archiveAgentJSON.contains(rootA.path), "agent-safe archive plan exposed a source path")
        try require(!archiveAgentJSON.contains(archiveDestination.path), "agent-safe archive plan exposed destination path")
        try require(!archiveAgentJSON.contains("one.jpg"), "agent-safe archive plan exposed a filename")
        try require(
            !archiveAgentJSON.contains(archiveReport.catalogPath),
            "agent-safe archive plan exposed a catalog path"
        )
        try require(
            !archiveAgentJSON.contains(archiveDestinationMarker.markerKey),
            "agent-safe archive plan exposed a destination marker key"
        )

        let archiveCopySourceA = temporary.appendingPathComponent("ArchiveCopySourceA", isDirectory: true)
        let archiveCopySourceB = temporary.appendingPathComponent("ArchiveCopySourceB", isDirectory: true)
        try fileManager.createDirectory(at: archiveCopySourceA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: archiveCopySourceB, withIntermediateDirectories: true)
        _ = try RootMarkerStore.create(at: archiveCopySourceA)
        _ = try RootMarkerStore.create(at: archiveCopySourceB)
        let archiveCopySourceFileA = archiveCopySourceA.appendingPathComponent("one.jpg")
        let archiveCopySourceFileB = archiveCopySourceB.appendingPathComponent("copy.jpg")
        try bytes.write(to: archiveCopySourceFileA)
        try bytes.write(to: archiveCopySourceFileB)
        let archiveCopyCatalogURL = temporary.appendingPathComponent("archive-copy-catalog.sqlite3")
        let archiveCopyScanner = try ArchiveScanner(catalogURL: archiveCopyCatalogURL)
        let archiveCopyReport = try await archiveCopyScanner.scan(roots: [
            ScanRoot(url: archiveCopySourceA, kind: .reference, provenance: .localLibrary),
            ScanRoot(url: archiveCopySourceB, kind: .reference, provenance: .googleTakeout)
        ])

        let archiveCopyDestination = temporary.appendingPathComponent("ArchiveCopyDestination", isDirectory: true)
        try fileManager.createDirectory(at: archiveCopyDestination, withIntermediateDirectories: true)
        let archiveCopyDestinationMarker = try RootMarkerStore.create(at: archiveCopyDestination)
        let archiveCopyPlan = try archiveCopyScanner.makeArchivePlan(
            from: archiveCopyReport,
            destinationURL: archiveCopyDestination
        )
        let archiveCopyPlanURL = temporary.appendingPathComponent("archive-copy-plan.json")
        try ArchivePlanStore.write(archiveCopyPlan, to: archiveCopyPlanURL)
        let archiveCopyDryRun = try ArchiveCopyExecutor.preflight(planURL: archiveCopyPlanURL)
        try require(archiveCopyDryRun.dryRun, "archive-copy should default to dry-run")
        try require(
            archiveCopyDryRun.copyRequiredResourceCount == 1
                && archiveCopyDryRun.automaticResourceCount == 1,
            "archive-copy dry-run should require exactly one canonical synthetic resource"
        )
        let archiveDryRunSourceA = try Data(contentsOf: archiveCopySourceFileA)
        let archiveDryRunSourceB = try Data(contentsOf: archiveCopySourceFileB)
        try require(
            archiveDryRunSourceA == beforeA && archiveDryRunSourceB == beforeB,
            "archive-copy dry-run modified source media"
        )
        let archiveCopyAgentJSON = String(
            decoding: try encoder.encode(AgentSafeArchiveCopyReport(report: archiveCopyDryRun)),
            as: UTF8.self
        )
        try require(
            !archiveCopyAgentJSON.contains(archiveCopySourceA.path),
            "agent-safe archive-copy exposed a source path"
        )
        try require(
            !archiveCopyAgentJSON.contains(archiveCopyDestination.path),
            "agent-safe archive-copy exposed a destination path"
        )
        try require(!archiveCopyAgentJSON.contains("one.jpg"), "agent-safe archive-copy exposed a filename")
        try require(!archiveCopyAgentJSON.contains(rawHash), "agent-safe archive-copy exposed SHA-256")
        try require(
            !archiveCopyAgentJSON.contains(archiveCopyDestinationMarker.markerKey),
            "agent-safe archive-copy exposed a destination marker key"
        )

        let archiveCopyApplied = try await ArchiveCopyExecutor.apply(planURL: archiveCopyPlanURL)
        try require(archiveCopyApplied.filesModified, "archive-copy apply should create verified archive files")
        try require(archiveCopyApplied.catalogCommitted, "archive-copy should commit the destination scan to catalog")
        try require(archiveCopyApplied.snapshotWritten, "archive-copy should write a portable catalog snapshot")
        guard let copiedRelativePath = archiveCopyPlan.items.first?.resources.first?.destinationRelativePath else {
            throw SelfTestFailure("archive-copy plan is missing its destination")
        }
        let copiedURL = archiveCopyDestination.appendingPathComponent(copiedRelativePath)
        try require(fileManager.fileExists(atPath: copiedURL.path), "archive-copy final resource is missing")
        try require(try Data(contentsOf: copiedURL) == beforeA, "archive-copy changed canonical source bytes")
        let archiveAppliedSourceA = try Data(contentsOf: archiveCopySourceFileA)
        let archiveAppliedSourceB = try Data(contentsOf: archiveCopySourceFileB)
        try require(
            archiveAppliedSourceA == beforeA && archiveAppliedSourceB == beforeB,
            "archive-copy apply moved or changed source media"
        )
        try require(
            fileManager.fileExists(atPath: archiveCopyApplied.manifestPath),
            "archive-copy complete manifest is missing"
        )
        try require(
            fileManager.fileExists(atPath: archiveCopyApplied.snapshotPath),
            "archive-copy portable catalog snapshot is missing"
        )
        try require(
            try sqliteInt(
                databaseURL: archiveCopyCatalogURL,
                sql: "SELECT COUNT(*) FROM source_roots WHERE kind = 'archive'"
            ) == 1,
            "archive-copy destination scan should register one archive root"
        )
        try require(
            try sqliteInt(
                databaseURL: archiveCopyCatalogURL,
                sql: "SELECT COUNT(*) FROM resources r JOIN source_roots sr ON sr.id = r.root_id WHERE sr.kind = 'archive' AND r.relative_path = '\(copiedRelativePath)'"
            ) == 1,
            "archive-copy destination resource was not committed to the catalog"
        )

        let archiveCopyReplay = try await ArchiveCopyExecutor.apply(planURL: archiveCopyPlanURL)
        try require(!archiveCopyReplay.filesModified, "completed archive-copy replay should be idempotent")
        try require(
            archiveCopyReplay.alreadyFinalResourceCount == 1
                && archiveCopyReplay.copyRequiredResourceCount == 0,
            "completed archive-copy replay should reuse the verified final resource"
        )

        let archiveSnapshotBytes = try Data(contentsOf: URL(fileURLWithPath: archiveCopyReplay.snapshotPath))
        try Data("tampered-archive-snapshot".utf8)
            .write(to: URL(fileURLWithPath: archiveCopyReplay.snapshotPath))
        do {
            _ = try ArchiveCopyExecutor.preflight(planURL: archiveCopyPlanURL)
            throw SelfTestFailure("archive-copy accepted a changed completed catalog snapshot")
        } catch ArchiveCopyError.snapshotConflict {
            // Expected: completed operation checkpoints re-verify their snapshot hash.
        }
        try archiveSnapshotBytes.write(to: URL(fileURLWithPath: archiveCopyReplay.snapshotPath))

        let archiveCopyTamperDestination = temporary
            .appendingPathComponent("ArchiveCopyTamperDestination", isDirectory: true)
        try fileManager.createDirectory(at: archiveCopyTamperDestination, withIntermediateDirectories: true)
        _ = try RootMarkerStore.create(at: archiveCopyTamperDestination)
        let archiveCopyTamperPlan = try archiveCopyScanner.makeArchivePlan(
            from: archiveCopyReport,
            destinationURL: archiveCopyTamperDestination
        )
        let archiveCopyTamperPlanURL = temporary.appendingPathComponent("archive-copy-tamper-plan.json")
        try ArchivePlanStore.write(archiveCopyTamperPlan, to: archiveCopyTamperPlanURL)
        let archiveCopySameSizeTamper = Data(repeating: 0x5A, count: beforeA.count)
        try archiveCopySameSizeTamper.write(to: archiveCopySourceFileA)
        do {
            _ = try ArchiveCopyExecutor.preflight(planURL: archiveCopyTamperPlanURL)
            throw SelfTestFailure("archive-copy accepted source bytes changed after immutable planning")
        } catch ArchiveCopyError.sourcePreconditionFailed {
            // Expected: apply independently verifies the planned source bytes.
        }
        try bytes.write(to: archiveCopySourceFileA)

        let archiveCopyPlanObject = try JSONSerialization.jsonObject(
            with: Data(contentsOf: archiveCopyTamperPlanURL)
        )
        guard var archiveCopyPlanDictionary = archiveCopyPlanObject as? [String: Any],
              var archiveCopyItems = archiveCopyPlanDictionary["items"] as? [[String: Any]],
              !archiveCopyItems.isEmpty
        else {
            throw SelfTestFailure("could not decode archive-copy plan for tamper regression")
        }
        archiveCopyItems[0]["assetID"] = "A-TAMPERED"
        archiveCopyPlanDictionary["items"] = archiveCopyItems
        let catalogTamperedPlanURL = temporary.appendingPathComponent("archive-copy-catalog-tampered.json")
        try JSONSerialization.data(withJSONObject: archiveCopyPlanDictionary, options: [.sortedKeys])
            .write(to: catalogTamperedPlanURL)
        do {
            _ = try ArchiveCopyExecutor.preflight(planURL: catalogTamperedPlanURL)
            throw SelfTestFailure("archive-copy accepted plan semantics that no longer match catalog evidence")
        } catch ArchiveCopyError.catalogEvidenceMismatch {
            // Expected: plan bytes alone are not sufficient authority for copying.
        }

        var nonAtomicPlanDictionary = archiveCopyPlanDictionary
        var nonAtomicItems = archiveCopyItems
        nonAtomicItems[0]["assetID"] = archiveCopyTamperPlan.items[0].assetID
        nonAtomicItems[0]["kind"] = "live_photo"
        nonAtomicPlanDictionary["items"] = nonAtomicItems
        let nonAtomicPlanURL = temporary.appendingPathComponent("archive-copy-non-atomic.json")
        try JSONSerialization.data(withJSONObject: nonAtomicPlanDictionary, options: [.sortedKeys])
            .write(to: nonAtomicPlanURL)
        do {
            _ = try ArchiveCopyExecutor.preflight(planURL: nonAtomicPlanURL)
            throw SelfTestFailure("archive-copy accepted a one-resource Live Photo item")
        } catch ArchiveCopyError.invalidPlan {
            // Expected: Live Photo copy authority always covers both roles.
        }

        let sameSizeTamper = Data(repeating: 0x5A, count: beforeA.count)
        try sameSizeTamper.write(to: fileA)
        do {
            _ = try scanner.makeArchivePlan(from: archiveReport, destinationURL: archiveDestination)
            throw SelfTestFailure("archive planning accepted source bytes changed after the scan")
        } catch ArchivePlanError.sourceChanged {
            // Expected: immutable copy authority must be anchored to scan/catalog exact evidence.
        }
        try beforeA.write(to: fileA)

        let occupiedArchiveFolder = archiveDestination
            .appendingPathComponent("Media/Undated", isDirectory: true)
        try fileManager.createDirectory(at: occupiedArchiveFolder, withIntermediateDirectories: true)
        try Data("existing-archive-entry".utf8).write(
            to: occupiedArchiveFolder.appendingPathComponent("one.jpg")
        )
        let collisionPlan = try scanner.makeArchivePlan(
            from: archiveReport,
            destinationURL: archiveDestination
        )
        try require(
            collisionPlan.items.first?.resources.first?.destinationRelativePath == "Media/Undated/one_01.jpg",
            "archive planning should deterministically avoid an existing destination path"
        )

        let unmarkedRoot = temporary.appendingPathComponent("UnmarkedSource", isDirectory: true)
        try fileManager.createDirectory(at: unmarkedRoot, withIntermediateDirectories: true)
        try Data("unmarked-source-media".utf8).write(to: unmarkedRoot.appendingPathComponent("plain.jpg"))
        let unmarkedScanner = try ArchiveScanner(
            catalogURL: temporary.appendingPathComponent("unmarked-catalog.sqlite3")
        )
        let unmarkedReport = try await unmarkedScanner.scan(roots: [
            ScanRoot(url: unmarkedRoot, kind: .reference, provenance: .localLibrary)
        ])
        let unmarkedPlan = try unmarkedScanner.makeArchivePlan(
            from: unmarkedReport,
            destinationURL: archiveDestination
        )
        try require(unmarkedPlan.summary.automaticItemCount == 0, "unmarked source must not receive replay authority")
        try require(unmarkedPlan.summary.reviewItemCount == 1, "unmarked source should remain review-only")
        try require(
            unmarkedPlan.items.first?.reason == .sourceRootMarkerMissing,
            "unmarked source should report the stable-marker blocker"
        )

        let liveArchiveSource = temporary.appendingPathComponent("ArchiveLiveSource", isDirectory: true)
        let liveArchiveDestination = temporary.appendingPathComponent("ArchiveLiveDestination", isDirectory: true)
        try fileManager.createDirectory(
            at: liveArchiveSource.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: liveArchiveSource.appendingPathComponent("other", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: liveArchiveDestination, withIntermediateDirectories: true)
        let liveArchiveSourceMarker = try RootMarkerStore.create(at: liveArchiveSource)
        _ = try RootMarkerStore.create(at: liveArchiveDestination)
        let liveArchiveBytes: [String: Data] = [
            "FORG1": Data(repeating: 0x11, count: 100),
            "FORG2": Data(repeating: 0x22, count: 200),
            "FORG3": Data(repeating: 0x33, count: 80),
            "FORG4": Data(repeating: 0x44, count: 70)
        ]
        try liveArchiveBytes["FORG1"]!.write(
            to: liveArchiveSource.appendingPathComponent("nested/IMG_1234.HEIC")
        )
        try liveArchiveBytes["FORG2"]!.write(
            to: liveArchiveSource.appendingPathComponent("nested/IMG_1234.MOV")
        )
        try liveArchiveBytes["FORG3"]!.write(
            to: liveArchiveSource.appendingPathComponent("other/IMG_5678.JPG")
        )
        try liveArchiveBytes["FORG4"]!.write(
            to: liveArchiveSource.appendingPathComponent("other/ZIIl652B 2.jpg")
        )
        let liveArchiveReport = syntheticOrganizationReport(
            localPath: liveArchiveSource.path,
            stableMarkerKey: liveArchiveSourceMarker.markerKey
        )
        let liveArchiveHashes = liveArchiveBytes.mapValues { Data(SHA256.hash(data: $0)) }
        let liveArchivePlan = try ArchivePlanner.makePlan(
            from: liveArchiveReport,
            destinationURL: liveArchiveDestination,
            expectedHashForResource: { liveArchiveHashes[$0] }
        )
        try require(
            liveArchivePlan.summary.automaticItemCount == 3
                && liveArchivePlan.summary.automaticResourceCount == 4,
            "archive planner should select one complete Live Photo pair plus two standalone resources"
        )
        guard let liveArchiveItem = liveArchivePlan.items.first(where: { $0.kind == .livePhoto }) else {
            throw SelfTestFailure("archive plan is missing the synthetic Live Photo")
        }
        try require(
            liveArchiveItem.decision == .automatic && liveArchiveItem.resources.count == 2,
            "complete Live Photo archive planning must stay atomic"
        )
        let liveArchiveStems = Set(liveArchiveItem.resources.map {
            ($0.destinationRelativePath as NSString).deletingPathExtension
        })
        try require(
            liveArchiveStems.count == 1,
            "Live Photo archive resources must share one destination basename"
        )
        try require(
            liveArchiveItem.resources.allSatisfy { $0.destinationRelativePath.hasPrefix("Media/2026/") },
            "archive planner should place the synthetic Live Photo in its capture-year folder"
        )

        guard let rootAID = first.resources.first(where: { $0.relativePath == "one.jpg" })?.rootID,
              let rootBID = first.resources.first(where: { $0.relativePath == "copy.jpg" })?.rootID,
              let originalAssetID = first.resources.first?.assetID
        else {
            throw SelfTestFailure("snapshot fixture is missing stable root/asset IDs")
        }
        let originalResourceIDs = Set(first.resources.map(\.resourceID))
        let snapshotURL = temporary.appendingPathComponent("catalog-snapshot.jsonl")
        let snapshotExport = try CatalogSnapshotExporter.export(
            catalogURL: temporary.appendingPathComponent("catalog.sqlite3"),
            outputURL: snapshotURL
        )
        try require(snapshotExport.filesModified, "snapshot export should create the JSONL file")
        try require(snapshotExport.rootCount == 2, "snapshot should contain both roots")
        try require(snapshotExport.resourceCount == 2, "snapshot should contain both resources")
        let snapshotText = try String(contentsOf: snapshotURL, encoding: .utf8)
        try require(!snapshotText.contains(rawHash), "portable snapshot exposed a raw exact hash")
        try require(!snapshotText.contains(rootA.path), "portable snapshot exposed an absolute root path")
        try require(!snapshotText.contains(rootB.path), "portable snapshot exposed an absolute root path")
        try require(
            !snapshotText.contains("synthetic-not-a-real-photo"),
            "portable snapshot exposed media bytes"
        )
        do {
            _ = try CatalogSnapshotExporter.export(
                catalogURL: temporary.appendingPathComponent("catalog.sqlite3"),
                outputURL: snapshotURL
            )
            throw SelfTestFailure("snapshot export overwrote an existing output")
        } catch CatalogSnapshotError.outputExists {
            // Expected: portable snapshots are append-by-new-file, never overwrite-in-place.
        }
        let snapshotAgentJSON = String(
            decoding: try encoder.encode(AgentSafeCatalogSnapshotReport(report: snapshotExport)),
            as: UTF8.self
        )
        try require(!snapshotAgentJSON.contains(snapshotURL.path), "agent-safe snapshot report exposed snapshot path")
        try require(!snapshotAgentJSON.contains(rootA.path), "agent-safe snapshot report exposed a root path")

        let restoredCatalogURL = temporary.appendingPathComponent("restored-catalog.sqlite3")
        let snapshotBindings = [
            CatalogRootBinding(rootID: rootAID, url: rootA),
            CatalogRootBinding(rootID: rootBID, url: rootB)
        ]
        let catalogRestoreDryRun = try CatalogSnapshotRestorer.preflight(
            snapshotURL: snapshotURL,
            destinationCatalogURL: restoredCatalogURL,
            rootBindings: snapshotBindings
        )
        try require(catalogRestoreDryRun.dryRun, "catalog restore should default to a dry run")
        try require(!fileManager.fileExists(atPath: restoredCatalogURL.path), "restore dry run created a catalog")
        try require(catalogRestoreDryRun.unboundRootCount == 0, "all synthetic snapshot roots should be bound")

        let restoreApplied = try CatalogSnapshotRestorer.apply(
            snapshotURL: snapshotURL,
            destinationCatalogURL: restoredCatalogURL,
            rootBindings: snapshotBindings
        )
        try require(restoreApplied.filesModified, "catalog restore apply should create a new catalog")
        try require(fileManager.fileExists(atPath: restoredCatalogURL.path), "restored catalog is missing")
        do {
            _ = try CatalogSnapshotRestorer.preflight(
                snapshotURL: snapshotURL,
                destinationCatalogURL: restoredCatalogURL,
                rootBindings: snapshotBindings
            )
            throw SelfTestFailure("catalog restore accepted an existing destination catalog")
        } catch CatalogSnapshotError.destinationExists {
            // Expected: restore never merges into or overwrites an existing catalog.
        }

        let restoredScanner = try ArchiveScanner(catalogURL: restoredCatalogURL)
        let restoredReport = try await restoredScanner.scan(roots: roots)
        try require(
            Set(restoredReport.roots.map(\.rootID)) == Set([rootAID, rootBID]),
            "restored roots should retain their opaque IDs after a fresh scan"
        )
        try require(
            Set(restoredReport.resources.map(\.resourceID)) == originalResourceIDs,
            "restored resources should retain their opaque IDs after a fresh scan"
        )
        try require(
            Set(restoredReport.resources.compactMap(\.assetID)) == Set([originalAssetID]),
            "fresh evidence should rebind restored resources to the original opaque asset ID"
        )
        try require(
            restoredReport.summary.exactDuplicateGroupCount == 1,
            "restored catalog should rebuild exact duplicate evidence from media"
        )

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
        let singletonLeafPlan = OrganizationPlanner.cleanSingletonLeafPlan(
            from: organizationApplyPlan,
            report: organizationApplyScan
        )
        try require(
            singletonLeafPlan.summary.automaticItemCount == 1,
            "singleton-leaf organization should select only the isolated Live Photo directory"
        )
        try require(
            singletonLeafPlan.summary.automaticResourceCount == 2,
            "singleton-leaf organization should keep the Live Photo pair atomic"
        )
        try require(
            singletonLeafPlan.items.first?.kind == .livePhoto,
            "singleton-leaf organization should exclude a directory containing another media asset"
        )
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

        let distinctNameOccurrence = LivePhotoOccurrenceReport(
            rootID: "RNOTICE",
            rootLabel: "NoticeRoot",
            status: .complete,
            stillCount: 1,
            videoCount: 1,
            resources: [
                ResourceReference(
                    rootID: "RNOTICE",
                    rootLabel: "NoticeRoot",
                    relativePath: "album/verified-still.HEIC",
                    role: .photo,
                    byteSize: 100
                ),
                ResourceReference(
                    rootID: "RNOTICE",
                    rootLabel: "NoticeRoot",
                    relativePath: "album/verified-motion.MOV",
                    role: .pairedVideo,
                    byteSize: 200
                )
            ]
        )
        guard let distinctNameNotice = LivePhotoNamingDiagnostics.notice(for: distinctNameOccurrence) else {
            throw SelfTestFailure("verified Live Photo components with distinct basenames should emit a notice")
        }
        try require(
            distinctNameNotice.code == LivePhotoNamingDiagnostics.distinctComponentBasenamesCode,
            "verified distinct-component Live Photo notice should use the stable diagnostic code"
        )
        let matchingNameOccurrence = LivePhotoOccurrenceReport(
            rootID: "RNOTICE",
            rootLabel: "NoticeRoot",
            status: .complete,
            stillCount: 1,
            videoCount: 1,
            resources: [
                ResourceReference(rootID: "RNOTICE", rootLabel: "NoticeRoot", relativePath: "album/IMG_0001.HEIC", role: .photo, byteSize: 100),
                ResourceReference(rootID: "RNOTICE", rootLabel: "NoticeRoot", relativePath: "album/IMG_0001.MOV", role: .pairedVideo, byteSize: 200)
            ]
        )
        try require(
            LivePhotoNamingDiagnostics.notice(for: matchingNameOccurrence) == nil,
            "matching Live Photo component basenames should not emit the naming notice"
        )

        let coverageReport = syntheticCanonicalCoverageReport()
        let coverageReportWithNotice = ScanReport(
            schemaVersion: coverageReport.schemaVersion,
            sessionID: coverageReport.sessionID,
            startedAt: coverageReport.startedAt,
            completedAt: coverageReport.completedAt,
            catalogPath: coverageReport.catalogPath,
            summary: coverageReport.summary,
            roots: coverageReport.roots,
            resources: coverageReport.resources,
            livePhotos: coverageReport.livePhotos,
            exactDuplicateGroups: coverageReport.exactDuplicateGroups,
            eventSuggestions: coverageReport.eventSuggestions,
            notices: [distinctNameNotice],
            warnings: coverageReport.warnings,
            filesModified: coverageReport.filesModified
        )
        let noticeAgentJSON = String(
            decoding: try encoder.encode(AgentSafeScanReport(report: coverageReportWithNotice)),
            as: UTF8.self
        )
        try require(
            noticeAgentJSON.contains(LivePhotoNamingDiagnostics.distinctComponentBasenamesCode),
            "agent-safe scan output should expose the verified distinct-component naming notice code"
        )
        try require(
            !noticeAgentJSON.contains("verified-still") && !noticeAgentJSON.contains("verified-motion"),
            "agent-safe naming notice must not expose component filenames"
        )
        let coverageNoticeAgentJSON = String(
            decoding: try encoder.encode(AgentSafeArchiveCoverageReport(
                report: ArchiveCoverageBuilder.makeReport(from: coverageReportWithNotice)
            )),
            as: UTF8.self
        )
        try require(
            coverageNoticeAgentJSON.contains(LivePhotoNamingDiagnostics.distinctComponentBasenamesCode),
            "agent-safe archive coverage should carry the verified distinct-component naming notice"
        )
        let archiveCoverageReport = ArchiveCoverageBuilder.makeReport(from: coverageReport)
        guard let localLiveCoverage = archiveCoverageReport.roots.first(where: { $0.rootID == "RLOCAL" }) else {
            throw SelfTestFailure("archive coverage is missing the synthetic local root")
        }
        guard let takeoutLiveCoverage = archiveCoverageReport.roots.first(where: { $0.rootID == "RTAKEOUT" }) else {
            throw SelfTestFailure("archive coverage is missing the synthetic Takeout root")
        }
        try require(
            localLiveCoverage.livePhotos.splitOrAmbiguousElsewhere == 1,
            "an ambiguous repeated Takeout Live Photo must not be reported as a complete peer"
        )
        try require(
            takeoutLiveCoverage.livePhotos.completeElsewhere == 1,
            "a Takeout Live Photo occurrence should report a complete local counterpart"
        )
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

        let semanticsCatalogURL = temporary.appendingPathComponent("semantics-catalog.sqlite3")
        let originalCollectionCount = try sqliteInt(
            databaseURL: semanticsCatalogURL,
            sql: "SELECT COUNT(*) FROM collections"
        )
        let originalMembershipCount = try sqliteInt(
            databaseURL: semanticsCatalogURL,
            sql: "SELECT COUNT(*) FROM memberships"
        )
        let semanticsSnapshotURL = temporary.appendingPathComponent("semantics-snapshot.jsonl")
        _ = try CatalogSnapshotExporter.export(
            catalogURL: semanticsCatalogURL,
            outputURL: semanticsSnapshotURL
        )
        let semanticsSnapshotText = try String(contentsOf: semanticsSnapshotURL, encoding: .utf8)
        try require(
            !semanticsSnapshotText.contains(takeoutSemanticsRoot.path),
            "portable semantics snapshot exposed an absolute root path"
        )

        guard let semanticsRootID = semanticsReport.roots.first?.rootID else {
            throw SelfTestFailure("Takeout semantics root ID is missing")
        }
        let restoredSemanticsCatalogURL = temporary.appendingPathComponent("restored-semantics.sqlite3")
        _ = try CatalogSnapshotRestorer.apply(
            snapshotURL: semanticsSnapshotURL,
            destinationCatalogURL: restoredSemanticsCatalogURL,
            rootBindings: [CatalogRootBinding(rootID: semanticsRootID, url: takeoutSemanticsRoot)]
        )
        try require(
            try sqliteInt(databaseURL: restoredSemanticsCatalogURL, sql: "SELECT COUNT(*) FROM collections")
                == originalCollectionCount,
            "catalog snapshot restore did not preserve collection hierarchy"
        )
        try require(
            try sqliteInt(databaseURL: restoredSemanticsCatalogURL, sql: "SELECT COUNT(*) FROM memberships")
                == originalMembershipCount,
            "catalog snapshot restore did not preserve collection memberships"
        )

        let restoredSemanticsScanner = try ArchiveScanner(catalogURL: restoredSemanticsCatalogURL)
        _ = try await restoredSemanticsScanner.scan(roots: [
            ScanRoot(
                url: takeoutSemanticsRoot,
                kind: .importSource,
                provenance: .googleTakeout
            )
        ])
        try require(
            try sqliteInt(databaseURL: restoredSemanticsCatalogURL, sql: "SELECT COUNT(*) FROM collections")
                == originalCollectionCount,
            "fresh scan after snapshot restore duplicated source collections"
        )
        try require(
            try sqliteInt(databaseURL: restoredSemanticsCatalogURL, sql: "SELECT COUNT(*) FROM memberships")
                == originalMembershipCount,
            "fresh scan after snapshot restore changed source collection memberships"
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
    stableMarkerKey: String? = nil,
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
                stableMarkerKey: stableMarkerKey,
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

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ScanProgress] = []

    func record(_ progress: ScanProgress) {
        lock.lock()
        events.append(progress)
        lock.unlock()
    }

    func snapshot() -> [ScanProgress] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
