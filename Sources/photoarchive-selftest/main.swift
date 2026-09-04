import CryptoKit
import Foundation
import PhotoArchiveCore

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

private struct SelfTestFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
