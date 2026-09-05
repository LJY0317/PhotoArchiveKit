import Foundation

public enum EmptyDirectoryCleanupError: LocalizedError {
    case manifestMissing
    case invalidManifest
    case incompleteOrganizationManifest
    case missingRoot(String)
    case rootRoleDisallowsCleanup(String)
    case rootMarkerRequired(String)
    case sourceLocationNotInCatalog(String)
    case unsafeSourceLocation(String)
    case protectedDirectory(String)
    case directoryChanged(String)
    case cleanupManifestWriteFailed
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return "The organization manifest does not exist."
        case .invalidManifest:
            return "The organization manifest could not be decoded."
        case .incompleteOrganizationManifest:
            return "Empty-directory cleanup requires a completed organization manifest."
        case let .missingRoot(rootID):
            return "A source root recorded by the organization manifest is missing from the catalog: \(rootID)"
        case let .rootRoleDisallowsCleanup(rootID):
            return "The current root role does not allow organization cleanup: \(rootID)"
        case let .rootMarkerRequired(rootID):
            return "Empty-directory cleanup requires a stable root marker for: \(rootID)"
        case let .sourceLocationNotInCatalog(resourceID):
            return "An organization source location is not present in catalog history for resource: \(resourceID)"
        case let .unsafeSourceLocation(resourceID):
            return "An organization source location escapes its recorded root for resource: \(resourceID)"
        case let .protectedDirectory(rootID):
            return "A cleanup candidate crosses a protected package or symlink boundary in root: \(rootID)"
        case let .directoryChanged(rootID):
            return "A cleanup candidate changed after preflight in root: \(rootID)"
        case .cleanupManifestWriteFailed:
            return "The empty-directory cleanup manifest could not be written."
        case let .rollbackFailed(rootID):
            return "Empty-directory cleanup rollback failed in root: \(rootID)"
        }
    }
}

public struct EmptyDirectoryCleanupManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let createdAt: Date
    public let state: String
    public let organizationManifestPath: String
    public let removedDirectories: [String]
    public let filesModified: Bool
}

public struct EmptyDirectoryCleanupReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let dryRun: Bool
    public let organizationManifestPath: String
    public let directoryCount: Int
    public let directories: [String]
    public let cleanupManifestPath: String?
    public let filesModified: Bool
}

public struct AgentSafeEmptyDirectoryCleanupReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let sessionID: String
    public let dryRun: Bool
    public let directoryCount: Int
    public let filesModified: Bool

    public init(report: EmptyDirectoryCleanupReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        sessionID = report.sessionID
        dryRun = report.dryRun
        directoryCount = report.directoryCount
        filesModified = report.filesModified
    }
}

public enum EmptyDirectoryCleanupExecutor {
    private struct VerifiedCleanup {
        let organizationManifest: OrganizationApplyManifest
        let organizationManifestURL: URL
        let directories: [URL]
        let rootIDByDirectoryPath: [String: String]
    }

    public static func preflight(
        organizationManifestURL: URL,
        catalogURL: URL
    ) throws -> EmptyDirectoryCleanupReport {
        let verified = try verify(
            organizationManifestURL: organizationManifestURL,
            catalogURL: catalogURL
        )
        return EmptyDirectoryCleanupReport(
            schemaVersion: 1,
            sessionID: verified.organizationManifest.sessionID,
            dryRun: true,
            organizationManifestPath: verified.organizationManifestURL.path,
            directoryCount: verified.directories.count,
            directories: verified.directories.map(\.path),
            cleanupManifestPath: nil,
            filesModified: false
        )
    }

    public static func apply(
        organizationManifestURL: URL,
        catalogURL: URL
    ) throws -> EmptyDirectoryCleanupReport {
        let verified = try verify(
            organizationManifestURL: organizationManifestURL,
            catalogURL: catalogURL
        )
        guard !verified.directories.isEmpty else {
            return EmptyDirectoryCleanupReport(
                schemaVersion: 1,
                sessionID: verified.organizationManifest.sessionID,
                dryRun: false,
                organizationManifestPath: verified.organizationManifestURL.path,
                directoryCount: 0,
                directories: [],
                cleanupManifestPath: nil,
                filesModified: false
            )
        }

        let fileManager = FileManager.default
        var removed: [URL] = []
        do {
            for directory in verified.directories {
                let rootID = verified.rootIDByDirectoryPath[directory.path] ?? "unknown"
                try validateEmptyDirectory(directory, rootID: rootID)
                do {
                    try fileManager.removeItem(at: directory)
                    removed.append(directory)
                } catch {
                    throw EmptyDirectoryCleanupError.directoryChanged(rootID)
                }
            }

            let cleanupManifestURL = verified.organizationManifestURL
                .deletingLastPathComponent()
                .appendingPathComponent("empty-directories.json")
            let cleanupManifest = EmptyDirectoryCleanupManifest(
                schemaVersion: 1,
                sessionID: verified.organizationManifest.sessionID,
                createdAt: Date(),
                state: "complete",
                organizationManifestPath: verified.organizationManifestURL.path,
                removedDirectories: removed.map(\.path),
                filesModified: true
            )
            do {
                try writeManifest(cleanupManifest, to: cleanupManifestURL)
            } catch {
                throw EmptyDirectoryCleanupError.cleanupManifestWriteFailed
            }

            return EmptyDirectoryCleanupReport(
                schemaVersion: 1,
                sessionID: verified.organizationManifest.sessionID,
                dryRun: false,
                organizationManifestPath: verified.organizationManifestURL.path,
                directoryCount: removed.count,
                directories: removed.map(\.path),
                cleanupManifestPath: cleanupManifestURL.path,
                filesModified: true
            )
        } catch {
            for directory in removed.reversed() {
                let rootID = verified.rootIDByDirectoryPath[directory.path] ?? "unknown"
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    throw EmptyDirectoryCleanupError.rollbackFailed(rootID)
                }
            }
            throw error
        }
    }

    private static func verify(
        organizationManifestURL rawManifestURL: URL,
        catalogURL: URL
    ) throws -> VerifiedCleanup {
        let fileManager = FileManager.default
        let manifestURL = rawManifestURL.standardizedFileURL
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw EmptyDirectoryCleanupError.manifestMissing
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let organizationManifest: OrganizationApplyManifest
        do {
            organizationManifest = try decoder.decode(
                OrganizationApplyManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw EmptyDirectoryCleanupError.invalidManifest
        }
        guard organizationManifest.state == "complete",
              organizationManifest.filesModified
        else {
            throw EmptyDirectoryCleanupError.incompleteOrganizationManifest
        }

        let catalog = try SQLiteCatalog(url: catalogURL)
        var rootURLByID: [String: URL] = [:]
        var candidatePaths = Set<String>()
        var rootIDByDirectoryPath: [String: String] = [:]

        for move in organizationManifest.moves {
            let rootURL: URL
            if let cached = rootURLByID[move.rootID] {
                rootURL = cached
            } else {
                guard let rootPath = try catalog.sourceRootPath(rootID: move.rootID) else {
                    throw EmptyDirectoryCleanupError.missingRoot(move.rootID)
                }
                guard let usageRole = try catalog.sourceRootUsageRole(rootID: move.rootID),
                      usageRole.allowsOrganizationMutation
                else {
                    throw EmptyDirectoryCleanupError.rootRoleDisallowsCleanup(move.rootID)
                }
                rootURL = URL(fileURLWithPath: rootPath)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                guard try RootMarkerStore.readIfPresent(at: rootURL) != nil else {
                    throw EmptyDirectoryCleanupError.rootMarkerRequired(move.rootID)
                }
                rootURLByID[move.rootID] = rootURL
            }

            let sourceURL = URL(fileURLWithPath: move.sourcePath).standardizedFileURL
            guard let relativePath = relativePath(of: sourceURL, under: rootURL) else {
                throw EmptyDirectoryCleanupError.unsafeSourceLocation(move.resourceID)
            }
            guard try catalog.resourceLocationExists(
                resourceID: move.resourceID,
                rootID: move.rootID,
                relativePath: relativePath
            ) else {
                throw EmptyDirectoryCleanupError.sourceLocationNotInCatalog(move.resourceID)
            }

            var directory = sourceURL.deletingLastPathComponent().standardizedFileURL
            while directory.path != rootURL.path {
                guard isDescendant(directory, of: rootURL) else {
                    throw EmptyDirectoryCleanupError.unsafeSourceLocation(move.resourceID)
                }
                if fileManager.fileExists(atPath: directory.path) {
                    let values = try directory.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .isPackageKey
                    ])
                    guard values.isDirectory == true,
                          values.isSymbolicLink != true,
                          values.isPackage != true
                    else {
                        throw EmptyDirectoryCleanupError.protectedDirectory(move.rootID)
                    }
                }
                candidatePaths.insert(directory.path)
                rootIDByDirectoryPath[directory.path] = move.rootID
                directory = directory.deletingLastPathComponent().standardizedFileURL
            }
        }

        let removable = try removableDirectories(
            candidatePaths: candidatePaths,
            rootIDByDirectoryPath: rootIDByDirectoryPath
        )
        return VerifiedCleanup(
            organizationManifest: organizationManifest,
            organizationManifestURL: manifestURL,
            directories: removable,
            rootIDByDirectoryPath: rootIDByDirectoryPath
        )
    }

    private static func removableDirectories(
        candidatePaths: Set<String>,
        rootIDByDirectoryPath: [String: String]
    ) throws -> [URL] {
        let fileManager = FileManager.default
        let candidates = candidatePaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { depth($0) > depth($1) }

        var virtuallyRemoved = Set<String>()
        var removable: [URL] = []
        for directory in candidates {
            let rootID = rootIDByDirectoryPath[directory.path] ?? "unknown"
            let values = try directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isPackageKey
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  values.isPackage != true
            else {
                throw EmptyDirectoryCleanupError.protectedDirectory(rootID)
            }
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
            let becomesEmpty = contents.allSatisfy {
                virtuallyRemoved.contains($0.standardizedFileURL.path)
            }
            if becomesEmpty {
                virtuallyRemoved.insert(directory.path)
                removable.append(directory)
            }
        }
        return removable
    }

    private static func validateEmptyDirectory(_ directory: URL, rootID: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            throw EmptyDirectoryCleanupError.directoryChanged(rootID)
        }
        let values = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isPackageKey
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isPackage != true
        else {
            throw EmptyDirectoryCleanupError.protectedDirectory(rootID)
        }
        guard try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw EmptyDirectoryCleanupError.directoryChanged(rootID)
        }
    }

    private static func relativePath(of child: URL, under parent: URL) -> String? {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        guard childPath.hasPrefix(prefix) else { return nil }
        let relative = String(childPath.dropFirst(prefix.count))
        guard !relative.isEmpty,
              !relative.split(separator: "/").contains("..")
        else {
            return nil
        }
        return relative
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }

    private static func depth(_ url: URL) -> Int {
        url.standardizedFileURL.pathComponents.count
    }

    private static func writeManifest(_ manifest: EmptyDirectoryCleanupManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: [.atomic])
    }
}
