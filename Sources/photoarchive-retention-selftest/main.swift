import Foundation
import PhotoArchiveCore

private struct RetentionSelfTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct PhotoArchiveRetentionSelfTest {
    static func main() {
        do {
            try testPrunesOnlyCompletedManagedDirectories()
            try testCountPressureIgnoresRecoveryDirectories()
            try testBytePressurePreservesCurrentOperation()
            try testHiddenEvidenceAndSymlinkRootFailSafe()
            print("PhotoArchiveKit retention self-test passed.")
        } catch {
            FileHandle.standardError.write(Data("retention self-test failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func testPrunesOnlyCompletedManagedDirectories() throws {
        let fileManager = FileManager.default
        let root = temporaryDirectory("OperationRetention")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let encoder = makeEncoder()
        try writeOperation("old-complete", root: root, createdAt: now.addingTimeInterval(-200), encoder: encoder)
        try writeOperation("recent-a", root: root, createdAt: now.addingTimeInterval(-10), encoder: encoder)
        try writeOperation("recent-b", root: root, createdAt: now.addingTimeInterval(-9), encoder: encoder)
        try writeOperation("current", root: root, createdAt: now.addingTimeInterval(-8), encoder: encoder)
        try writeOperation(
            "pending",
            root: root,
            createdAt: now.addingTimeInterval(-200),
            pending: true,
            encoder: encoder
        )
        try writeOperation(
            "recovery-evidence",
            root: root,
            createdAt: now.addingTimeInterval(-200),
            extraFile: true,
            encoder: encoder
        )
        let unmanaged = root.appendingPathComponent("manual-diagnostic.json")
        try Data("private unmanaged evidence".utf8).write(to: unmanaged)

        let report = try OperationArtifactRetention.maintain(
            directoryURL: root,
            policy: OperationArtifactRetentionPolicy(
                maxCompletedDirectoryCount: 3,
                maxCompletedBytes: .max,
                maxCompletedAge: 100
            ),
            now: now,
            preservingDirectoryNames: ["current"]
        )

        try require(!exists(root, "old-complete"), "expired completed operation evidence was not pruned")
        try require(exists(root, "pending"), "pending operation evidence must be preserved")
        try require(exists(root, "recovery-evidence"), "unexpected recovery evidence must be preserved")
        try require(exists(root, "current"), "current operation must be preserved")
        try require(fileManager.fileExists(atPath: unmanaged.path), "unmanaged root evidence must be preserved")
        try require(report.removedDirectoryCount == 1, "retention removed an unexpected number of completed operations")
        try require(report.unmanagedRootEntryCount == 1, "unmanaged root evidence was not reported")
    }

    private static func testCountPressureIgnoresRecoveryDirectories() throws {
        let fileManager = FileManager.default
        let root = temporaryDirectory("OperationCountRetention")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let encoder = makeEncoder()
        try writeOperation("complete-a", root: root, createdAt: now.addingTimeInterval(-20), encoder: encoder)
        try writeOperation("complete-b", root: root, createdAt: now.addingTimeInterval(-10), encoder: encoder)
        for index in 0..<8 {
            try writeOperation(
                "pending-\(index)",
                root: root,
                createdAt: now.addingTimeInterval(-200),
                pending: true,
                encoder: encoder
            )
        }

        let report = try OperationArtifactRetention.maintain(
            directoryURL: root,
            policy: OperationArtifactRetentionPolicy(
                maxCompletedDirectoryCount: 2,
                maxCompletedBytes: .max,
                maxCompletedAge: 10_000
            ),
            now: now
        )

        try require(exists(root, "complete-a") && exists(root, "complete-b"), "recovery directories caused over-pruning")
        try require(report.removedDirectoryCount == 0, "protected recovery directories must not count toward the completed cap")
        try require(report.protectedDirectoryCount == 8, "pending operation evidence was not classified as protected")
    }

    private static func testBytePressurePreservesCurrentOperation() throws {
        let fileManager = FileManager.default
        let root = temporaryDirectory("OperationByteRetention")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let encoder = makeEncoder()
        try writeOperation("byte-old", root: root, createdAt: now.addingTimeInterval(-10), encoder: encoder)
        try writeOperation("byte-current", root: root, createdAt: now.addingTimeInterval(-9), encoder: encoder)

        let report = try OperationArtifactRetention.maintain(
            directoryURL: root,
            policy: OperationArtifactRetentionPolicy(
                maxCompletedDirectoryCount: 10,
                maxCompletedBytes: 1,
                maxCompletedAge: 10_000
            ),
            now: now,
            preservingDirectoryNames: ["byte-current"]
        )

        try require(!exists(root, "byte-old"), "byte pressure did not prune the oldest completed artifact")
        try require(exists(root, "byte-current"), "byte pressure removed the current operation")
        try require(report.reclaimedBytes > 0, "reclaimed byte accounting was not recorded")
    }

    private static func testHiddenEvidenceAndSymlinkRootFailSafe() throws {
        let fileManager = FileManager.default
        let root = temporaryDirectory("OperationBoundaryRetention")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let encoder = makeEncoder()
        try writeOperation(
            "hidden-recovery",
            root: root,
            createdAt: now.addingTimeInterval(-200),
            encoder: encoder
        )
        try Data("private hidden recovery evidence".utf8).write(
            to: root
                .appendingPathComponent("hidden-recovery", isDirectory: true)
                .appendingPathComponent(".recovery-evidence")
        )
        _ = try OperationArtifactRetention.maintain(
            directoryURL: root,
            policy: OperationArtifactRetentionPolicy(
                maxCompletedDirectoryCount: 0,
                maxCompletedBytes: 0,
                maxCompletedAge: 1
            ),
            now: now
        )
        try require(
            exists(root, "hidden-recovery"),
            "hidden recovery evidence must make an operation directory non-prunable"
        )

        let link = root.deletingLastPathComponent()
            .appendingPathComponent("PhotoArchiveKitRetentionLink-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: link) }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: root)
        _ = try OperationArtifactRetention.maintain(
            directoryURL: link,
            policy: OperationArtifactRetentionPolicy(
                maxCompletedDirectoryCount: 0,
                maxCompletedBytes: 0,
                maxCompletedAge: 0
            ),
            now: now
        )
        try require(
            exists(root, "hidden-recovery"),
            "retention must not follow a replacement operations-root symlink"
        )
    }

    private static func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoArchiveKitRetentionSelfTest-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func exists(_ root: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RetentionSelfTestFailure(message: message) }
    }

    private static func writeOperation(
        _ sessionID: String,
        root: URL,
        createdAt: Date,
        pending: Bool = false,
        extraFile: Bool = false,
        encoder: JSONEncoder
    ) throws {
        let fileManager = FileManager.default
        let directory = root.appendingPathComponent(sessionID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let complete = OrganizationApplyManifest(
            schemaVersion: 1,
            sessionID: sessionID,
            policy: "retention_selftest",
            createdAt: createdAt,
            state: "complete",
            moves: [],
            filesModified: true
        )
        try encoder.encode(complete).write(to: directory.appendingPathComponent("organization.json"))
        if pending {
            let pendingManifest = OrganizationApplyManifest(
                schemaVersion: 1,
                sessionID: sessionID,
                policy: "retention_selftest",
                createdAt: createdAt,
                state: "pending",
                moves: [],
                filesModified: false
            )
            try encoder.encode(pendingManifest).write(
                to: directory.appendingPathComponent("organization.pending.json")
            )
        }
        if extraFile {
            try Data("private recovery evidence".utf8).write(
                to: directory.appendingPathComponent("recovery.txt")
            )
        }
    }
}
