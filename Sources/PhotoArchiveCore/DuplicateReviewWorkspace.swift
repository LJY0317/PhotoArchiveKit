import Foundation

public enum DuplicateReviewWorkspaceError: LocalizedError {
    case outputAlreadyExists(String)
    case candidateRootNotFound(String)
    case sourceRootMissing(String)
    case sourceMissing(String)
    case unsafeRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case let .outputAlreadyExists(path):
            return "Duplicate review output already exists: \(path)"
        case let .candidateRootNotFound(value):
            return "No scanned root matches the duplicate-review candidate root: \(value)"
        case let .sourceRootMissing(rootID):
            return "A duplicate-review source root is missing from the scan report: \(rootID)"
        case let .sourceMissing(path):
            return "A duplicate-review source file is no longer available: \(path)"
        case let .unsafeRelativePath(path):
            return "A duplicate-review relative path escapes its registered root: \(path)"
        }
    }
}

public struct DuplicateReviewWorkspaceReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let itemCount: Int
    public let keeperLinkCount: Int
    public let candidateLinkCount: Int
    public let workspacePath: String
    public let mediaFilesModified: Bool
}

public struct AgentSafeDuplicateReviewWorkspaceReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let itemCount: Int
    public let keeperLinkCount: Int
    public let candidateLinkCount: Int
    public let mediaFilesModified: Bool

    public init(report: DuplicateReviewWorkspaceReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        itemCount = report.itemCount
        keeperLinkCount = report.keeperLinkCount
        candidateLinkCount = report.candidateLinkCount
        mediaFilesModified = report.mediaFilesModified
    }
}

public enum DuplicateReviewWorkspace {
    public static func create(
        report: ScanReport,
        plan: ReconciliationPlan,
        outputURL rawOutputURL: URL,
        candidateRootTarget: String? = nil,
        fileManager: FileManager = .default
    ) throws -> DuplicateReviewWorkspaceReport {
        let outputURL = rawOutputURL.standardizedFileURL
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw DuplicateReviewWorkspaceError.outputAlreadyExists(outputURL.path)
        }

        let rootsByID = Dictionary(uniqueKeysWithValues: report.roots.map { ($0.rootID, $0) })
        let candidateRootID: String?
        if let candidateRootTarget {
            let expanded = (candidateRootTarget as NSString).expandingTildeInPath
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard let match = report.roots.first(where: {
                $0.rootID == candidateRootTarget
                    || URL(fileURLWithPath: $0.canonicalPath).standardizedFileURL.path == standardized
            }) else {
                throw DuplicateReviewWorkspaceError.candidateRootNotFound(candidateRootTarget)
            }
            candidateRootID = match.rootID
        } else {
            candidateRootID = nil
        }

        let selectedItems = plan.items.filter { item in
            guard item.decision == .automaticRedundant, !item.candidateResources.isEmpty else {
                return false
            }
            guard let candidateRootID else { return true }
            return item.candidateResources.allSatisfy { $0.rootID == candidateRootID }
        }

        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        do {
            try writeReadme(to: outputURL)

            var keeperLinkCount = 0
            var candidateLinkCount = 0
            for (offset, item) in selectedItems.enumerated() {
                let groupURL = outputURL.appendingPathComponent(
                    String(format: "%03d-%@-%@", offset + 1, item.kind.rawValue, item.itemID),
                    isDirectory: true
                )
                let keeperURL = groupURL.appendingPathComponent("KEEPER", isDirectory: true)
                let candidateURL = groupURL.appendingPathComponent("CANDIDATE", isDirectory: true)
                try fileManager.createDirectory(at: keeperURL, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: candidateURL, withIntermediateDirectories: true)

                var locationLines: [String] = [
                    "reason: \(item.reason.rawValue)",
                    "kind: \(item.kind.rawValue)",
                    ""
                ]

                for (index, resource) in item.preferredResources.enumerated() {
                    let sourceURL = try sourceURL(
                        for: resource,
                        rootsByID: rootsByID,
                        fileManager: fileManager
                    )
                    try createLink(
                        sourceURL: sourceURL,
                        in: keeperURL,
                        prefix: String(format: "KEEPER-%02d", index + 1),
                        fileManager: fileManager
                    )
                    keeperLinkCount += 1
                    locationLines.append("[KEEPER] \(sourceURL.path)")
                }

                for (index, resource) in item.candidateResources.enumerated() {
                    let sourceURL = try sourceURL(
                        for: resource,
                        rootsByID: rootsByID,
                        fileManager: fileManager
                    )
                    try createLink(
                        sourceURL: sourceURL,
                        in: candidateURL,
                        prefix: String(format: "CANDIDATE-%02d", index + 1),
                        fileManager: fileManager
                    )
                    candidateLinkCount += 1
                    locationLines.append("[CANDIDATE] \(sourceURL.path)")
                }

                let locationsURL = groupURL.appendingPathComponent("locations.txt")
                try (locationLines.joined(separator: "\n") + "\n")
                    .write(to: locationsURL, atomically: true, encoding: .utf8)
            }

            return DuplicateReviewWorkspaceReport(
                schemaVersion: 1,
                itemCount: selectedItems.count,
                keeperLinkCount: keeperLinkCount,
                candidateLinkCount: candidateLinkCount,
                workspacePath: outputURL.path,
                mediaFilesModified: false
            )
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    private static func sourceURL(
        for resource: ResourceReference,
        rootsByID: [String: RootScanReport],
        fileManager: FileManager
    ) throws -> URL {
        guard let root = rootsByID[resource.rootID] else {
            throw DuplicateReviewWorkspaceError.sourceRootMissing(resource.rootID)
        }
        let rootURL = URL(fileURLWithPath: root.canonicalPath).standardizedFileURL
        let sourceURL = rootURL.appendingPathComponent(resource.relativePath).standardizedFileURL
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard sourceURL.path.hasPrefix(prefix),
              !resource.relativePath.split(separator: "/").contains("..")
        else {
            throw DuplicateReviewWorkspaceError.unsafeRelativePath(resource.relativePath)
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw DuplicateReviewWorkspaceError.sourceMissing(sourceURL.path)
        }
        return sourceURL
    }

    private static func createLink(
        sourceURL: URL,
        in directoryURL: URL,
        prefix: String,
        fileManager: FileManager
    ) throws {
        let originalName = sourceURL.lastPathComponent
        let linkURL = directoryURL.appendingPathComponent(prefix + "--" + originalName)
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: sourceURL)
    }

    private static func writeReadme(to outputURL: URL) throws {
        let text = """
        PhotoArchiveKit exact-duplicate review workspace

        This folder contains symbolic links only. Original media bytes were not copied, moved, renamed, or deleted.

        Each numbered folder is one automatic exact-duplicate decision:
        - KEEPER: the copy PhotoArchiveKit currently prefers to keep.
        - CANDIDATE: byte-identical copy/copies eligible for quarantine after fresh verification.
        - locations.txt: local-private original paths for Finder review.

        Use Finder thumbnails or Quick Look on the links. Do not treat this workspace itself as a backup.
        """
        try (text + "\n").write(
            to: outputURL.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
