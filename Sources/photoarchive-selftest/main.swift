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
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() {
            throw SelfTestFailure(message)
        }
    }
}

private func executableExists(_ name: String) -> Bool {
    let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return environmentPath.split(separator: ":").contains { directory in
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: candidate)
    }
}

private func syntheticCanonicalCoverageReport() -> ScanReport {
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
            canonicalPath: "/synthetic/local",
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
            canonicalPath: "/synthetic/takeout",
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
