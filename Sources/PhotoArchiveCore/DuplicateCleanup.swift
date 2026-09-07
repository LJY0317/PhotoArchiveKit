import Foundation

public enum DuplicateCleanupDestination: Sendable, Equatable {
    case systemTrash
    case customQuarantine(URL)
}

public struct DuplicateCleanupMoveRecord: Codable, Sendable, Equatable {
    public let itemID: String
    public let rootID: String
    public let role: ResourceRole
    public let sourcePath: String
    public let sourceRelativePath: String?
    public let destinationPath: String?
    public let byteSize: Int64
}

public struct DuplicateCleanupReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let dryRun: Bool
    public let destinationKind: DuplicateCleanupDestinationKind
    public let targetPath: String?
    public let itemCount: Int
    public let resourceCount: Int
    public let totalBytes: Int64
    public let moves: [DuplicateCleanupMoveRecord]
    public let manifestPath: String?
    public let removedEmptyDirectoryCount: Int
    public let filesModified: Bool
}

public struct AgentSafeDuplicateCleanupReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let sessionID: String
    public let dryRun: Bool
    public let destinationKind: DuplicateCleanupDestinationKind
    public let itemCount: Int
    public let resourceCount: Int
    public let removedEmptyDirectoryCount: Int
    public let filesModified: Bool

    public init(report: DuplicateCleanupReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        sessionID = report.sessionID
        dryRun = report.dryRun
        destinationKind = report.destinationKind
        itemCount = report.itemCount
        resourceCount = report.resourceCount
        removedEmptyDirectoryCount = report.removedEmptyDirectoryCount
        filesModified = report.filesModified
    }
}

public enum DuplicateCleanupExecutor {
    private struct TrashedMove {
        let record: DuplicateCleanupMoveRecord
        let sourceURL: URL
        let trashURL: URL
    }

    public static func preflight(
        report: ScanReport,
        plan: ReconciliationPlan,
        destination: DuplicateCleanupDestination,
        approvedPreferenceItemIDs: Set<String> = []
    ) throws -> DuplicateCleanupReport {
        switch destination {
        case .customQuarantine(let targetURL):
            return fromQuarantineReport(try QuarantineExecutor.preflight(
                report: report,
                plan: plan,
                targetURL: targetURL,
                approvedPreferenceItemIDs: approvedPreferenceItemIDs
            ), removedEmptyDirectoryCount: 0)
        case .systemTrash:
            let verification = try systemTrashVerification(
                report: report,
                plan: plan,
                approvedPreferenceItemIDs: approvedPreferenceItemIDs
            )
            return DuplicateCleanupReport(
                schemaVersion: 1,
                sessionID: report.sessionID,
                dryRun: true,
                destinationKind: .systemTrash,
                targetPath: nil,
                itemCount: verification.itemCount,
                resourceCount: verification.moves.count,
                totalBytes: verification.moves.reduce(0) { $0 + $1.byteSize },
                moves: verification.moves.map {
                    DuplicateCleanupMoveRecord(
                        itemID: $0.itemID,
                        rootID: $0.rootID,
                        role: $0.role,
                        sourcePath: $0.sourcePath,
                        sourceRelativePath: $0.sourceRelativePath,
                        destinationPath: nil,
                        byteSize: $0.byteSize
                    )
                },
                manifestPath: nil,
                removedEmptyDirectoryCount: 0,
                filesModified: false
            )
        }
    }

    public static func apply(
        report: ScanReport,
        plan: ReconciliationPlan,
        destination: DuplicateCleanupDestination,
        approvedPreferenceItemIDs: Set<String> = []
    ) throws -> DuplicateCleanupReport {
        switch destination {
        case .customQuarantine(let targetURL):
            let quarantine = try QuarantineExecutor.apply(
                report: report,
                plan: plan,
                targetURL: targetURL,
                approvedPreferenceItemIDs: approvedPreferenceItemIDs
            )
            let removed = EmptyParentDirectoryCleaner.removeNowEmptyParents(
                sourceRecords: quarantine.moves,
                roots: report.roots
            )
            return fromQuarantineReport(
                quarantine,
                removedEmptyDirectoryCount: removed.count
            )
        case .systemTrash:
            return try applySystemTrash(
                report: report,
                plan: plan,
                approvedPreferenceItemIDs: approvedPreferenceItemIDs,
                trashMover: systemTrashMover
            )
        }
    }

    package static func applySystemTrashForTesting(
        report: ScanReport,
        plan: ReconciliationPlan,
        approvedPreferenceItemIDs: Set<String> = [],
        trashMover: (URL) throws -> URL
    ) throws -> DuplicateCleanupReport {
        try applySystemTrash(
            report: report,
            plan: plan,
            approvedPreferenceItemIDs: approvedPreferenceItemIDs,
            trashMover: trashMover
        )
    }

    private static func applySystemTrash(
        report: ScanReport,
        plan: ReconciliationPlan,
        approvedPreferenceItemIDs: Set<String>,
        trashMover: (URL) throws -> URL
    ) throws -> DuplicateCleanupReport {
        let verification = try systemTrashVerification(
            report: report,
            plan: plan,
            approvedPreferenceItemIDs: approvedPreferenceItemIDs
        )
        let fileManager = FileManager.default
        var trashed: [TrashedMove] = []

        do {
            for move in verification.moves {
                let sourceURL = URL(fileURLWithPath: move.sourcePath).standardizedFileURL
                let trashURL: URL
                do {
                    trashURL = try trashMover(sourceURL)
                } catch {
                    throw QuarantineError.moveFailed(sourceURL.path)
                }
                trashed.append(TrashedMove(
                    record: DuplicateCleanupMoveRecord(
                        itemID: move.itemID,
                        rootID: move.rootID,
                        role: move.role,
                        sourcePath: move.sourcePath,
                        sourceRelativePath: move.sourceRelativePath,
                        destinationPath: trashURL.path,
                        byteSize: move.byteSize
                    ),
                    sourceURL: sourceURL,
                    trashURL: trashURL
                ))
            }
        } catch {
            for move in trashed.reversed() {
                do {
                    try fileManager.createDirectory(
                        at: move.sourceURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if fileManager.fileExists(atPath: move.trashURL.path),
                       !fileManager.fileExists(atPath: move.sourceURL.path) {
                        try fileManager.moveItem(at: move.trashURL, to: move.sourceURL)
                    }
                } catch {
                    throw QuarantineError.rollbackFailed(move.sourceURL.path)
                }
            }
            throw error
        }

        let sourceRecords = trashed.map {
            QuarantineMoveRecord(
                itemID: $0.record.itemID,
                rootID: $0.record.rootID,
                role: $0.record.role,
                sourcePath: $0.record.sourcePath,
                sourceRelativePath: $0.record.sourceRelativePath,
                destinationPath: $0.record.destinationPath ?? "",
                byteSize: $0.record.byteSize
            )
        }
        let removed = EmptyParentDirectoryCleaner.removeNowEmptyParents(
            sourceRecords: sourceRecords,
            roots: report.roots
        )

        return DuplicateCleanupReport(
            schemaVersion: 1,
            sessionID: report.sessionID,
            dryRun: false,
            destinationKind: .systemTrash,
            targetPath: nil,
            itemCount: verification.itemCount,
            resourceCount: trashed.count,
            totalBytes: trashed.reduce(0) { $0 + $1.record.byteSize },
            moves: trashed.map(\.record),
            manifestPath: nil,
            removedEmptyDirectoryCount: removed.count,
            filesModified: !trashed.isEmpty || !removed.isEmpty
        )
    }

    private static func systemTrashVerification(
        report: ScanReport,
        plan: ReconciliationPlan,
        approvedPreferenceItemIDs: Set<String>
    ) throws -> (itemCount: Int, moves: [QuarantineMoveRecord]) {
        try QuarantineExecutor.verifiedAutomaticCandidates(
            report: report,
            plan: plan,
            approvedPreferenceItemIDs: approvedPreferenceItemIDs
        )
    }

    private static func systemTrashMover(_ sourceURL: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: sourceURL, resultingItemURL: &resultingURL)
        guard let resultingURL else {
            throw QuarantineError.moveFailed(sourceURL.path)
        }
        return resultingURL as URL
    }

    private static func fromQuarantineReport(
        _ report: QuarantineReport,
        removedEmptyDirectoryCount: Int
    ) -> DuplicateCleanupReport {
        DuplicateCleanupReport(
            schemaVersion: 1,
            sessionID: report.sessionID,
            dryRun: report.dryRun,
            destinationKind: .customQuarantine,
            targetPath: report.targetPath,
            itemCount: report.itemCount,
            resourceCount: report.resourceCount,
            totalBytes: report.totalBytes,
            moves: report.moves.map {
                DuplicateCleanupMoveRecord(
                    itemID: $0.itemID,
                    rootID: $0.rootID,
                    role: $0.role,
                    sourcePath: $0.sourcePath,
                    sourceRelativePath: $0.sourceRelativePath,
                    destinationPath: $0.destinationPath,
                    byteSize: $0.byteSize
                )
            },
            manifestPath: report.manifestPath,
            removedEmptyDirectoryCount: removedEmptyDirectoryCount,
            filesModified: report.filesModified || removedEmptyDirectoryCount > 0
        )
    }
}

enum EmptyParentDirectoryCleaner {
    static func removeNowEmptyParents(
        sourceRecords: [QuarantineMoveRecord],
        roots: [RootScanReport],
        fileManager: FileManager = .default
    ) -> [URL] {
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map {
            ($0.rootID, URL(fileURLWithPath: $0.canonicalPath).standardizedFileURL)
        })
        var candidates = Set<String>()

        for record in sourceRecords {
            guard let rootURL = rootsByID[record.rootID] else { continue }
            var directory = URL(fileURLWithPath: record.sourcePath)
                .deletingLastPathComponent()
                .standardizedFileURL
            while directory.path != rootURL.path {
                guard isDescendant(directory, of: rootURL) else { break }
                candidates.insert(directory.path)
                directory = directory.deletingLastPathComponent().standardizedFileURL
            }
        }

        let ordered = candidates
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        var removed: [URL] = []

        for directory in ordered {
            guard fileManager.fileExists(atPath: directory.path),
                  let values = try? directory.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .isPackageKey
                  ]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  values.isPackage != true,
                  let contents = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .isDirectoryKey
                    ],
                    options: []
                  ),
                  contents.allSatisfy({ isIgnorableFilesystemResidue($0) })
            else {
                continue
            }
            if (try? fileManager.removeItem(at: directory)) != nil {
                removed.append(directory)
            }
        }
        return removed
    }

    private static func isIgnorableFilesystemResidue(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isDirectoryKey
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        values.isDirectory != true
        else {
            return false
        }

        let name = url.lastPathComponent
        let lowercased = name.lowercased()
        if lowercased == ".ds_store"
            || lowercased == "thumbs.db"
            || lowercased == "ehthumbs.db"
            || lowercased == "desktop.ini"
            || lowercased == ".directory"
            || lowercased == ".localized"
            || lowercased == "icon\r"
        {
            return true
        }

        // AppleDouble metadata can remain on non-Apple filesystems after the
        // corresponding primary file has already been moved away.
        return name.hasPrefix("._")
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }
}
