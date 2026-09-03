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
            ScanRoot(url: rootA, kind: .reference),
            ScanRoot(url: rootB, kind: .reference)
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

        let encoder = JSONEncoder()
        let json = String(decoding: try encoder.encode(first), as: UTF8.self)
        let rawHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try require(!json.contains(rawHash), "sanitized report exposed a raw content hash")

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
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() {
            throw SelfTestFailure(message)
        }
    }
}

private struct SelfTestFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
