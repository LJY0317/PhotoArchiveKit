import Foundation

public enum ArchivePlanItemKind: String, Codable, Sendable {
    case standalone
    case livePhoto = "live_photo"
}

public enum ArchivePlanDecision: String, Codable, Sendable {
    case automatic
    case review
}

public enum ArchivePlanReason: String, Codable, Sendable {
    case canonicalRepresentation = "canonical_representation"
    case sourceRootMarkerMissing = "source_root_marker_missing"
    case incompleteLivePhoto = "incomplete_live_photo"
    case conflictingCompleteLivePhotoVariants = "conflicting_complete_live_photo_variants"
    case ambiguousStandaloneRepresentations = "ambiguous_standalone_representations"
}

public struct ArchivePlanRoot: Codable, Sendable, Equatable {
    public let rootID: String
    public let kind: SourceRootKind
    public let provenance: SourceProvenance
    public let canonicalPath: String
    public let markerKey: String?
}

public struct ArchivePlanDestination: Codable, Sendable, Equatable {
    public let canonicalPath: String
    public let markerKey: String
}

public struct ArchivePlannedResource: Codable, Sendable, Equatable {
    public let resourceID: String
    public let sourceRootID: String
    public let role: ResourceRole
    public let sourceRelativePath: String
    public let destinationRelativePath: String
    public let byteSize: Int64
    public let expectedSHA256: String?
}

public struct ArchivePlanItem: Codable, Sendable, Equatable {
    public let itemID: String
    public let assetID: String
    public let kind: ArchivePlanItemKind
    public let decision: ArchivePlanDecision
    public let reason: ArchivePlanReason
    public let resources: [ArchivePlannedResource]
}

public struct ArchivePlanSummary: Codable, Sendable, Equatable {
    public let automaticItemCount: Int
    public let reviewItemCount: Int
    public let automaticResourceCount: Int
    public let reviewResourceCount: Int
}

public struct ArchivePlan: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let planID: String
    public let policy: String
    public let createdAt: Date
    public let scanSessionID: String
    public let catalogPath: String
    public let sourceRoots: [ArchivePlanRoot]
    public let destination: ArchivePlanDestination
    public let summary: ArchivePlanSummary
    public let items: [ArchivePlanItem]
    public let mediaFilesModified: Bool
}

public struct AgentSafeArchivePlanItem: Codable, Sendable, Equatable {
    public let itemID: String
    public let assetID: String
    public let kind: ArchivePlanItemKind
    public let decision: ArchivePlanDecision
    public let reason: ArchivePlanReason
    public let resourceCount: Int
}

public struct AgentSafeArchivePlan: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let planID: String
    public let policy: String
    public let scanSessionID: String
    public let summary: ArchivePlanSummary
    public let items: [AgentSafeArchivePlanItem]
    public let mediaFilesModified: Bool

    public init(plan: ArchivePlan) {
        schemaVersion = plan.schemaVersion
        privacyMode = "agent_safe"
        planID = plan.planID
        policy = plan.policy
        scanSessionID = plan.scanSessionID
        summary = plan.summary
        items = plan.items.map {
            AgentSafeArchivePlanItem(
                itemID: $0.itemID,
                assetID: $0.assetID,
                kind: $0.kind,
                decision: $0.decision,
                reason: $0.reason,
                resourceCount: $0.resources.count
            )
        }
        mediaFilesModified = plan.mediaFilesModified
    }
}

public enum ArchivePlanError: LocalizedError {
    case destinationMissing(String)
    case destinationNotDirectory(String)
    case destinationMarkerRequired(String)
    case destinationChanged(String)
    case destinationOverlapsSource(String)
    case unsafeDestinationPath(String)
    case unsafeRelativePath(String)
    case sourceChanged(String)
    case planOutputExists(String)
    case planWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .destinationMissing(path):
            return "Archive destination does not exist: \(path)"
        case let .destinationNotDirectory(path):
            return "Archive destination is not a directory: \(path)"
        case let .destinationMarkerRequired(path):
            return "Archive destination requires a .photoarchive-root marker: \(path)"
        case let .destinationChanged(path):
            return "Archive destination marker changed while the plan was being created: \(path)"
        case let .destinationOverlapsSource(path):
            return "Archive destination overlaps a scanned source root: \(path)"
        case let .unsafeDestinationPath(path):
            return "Archive destination path crosses a symlink or non-directory boundary: \(path)"
        case let .unsafeRelativePath(path):
            return "Unsafe relative path in archive plan: \(path)"
        case let .sourceChanged(path):
            return "A source resource changed or could not be freshly verified: \(path)"
        case let .planOutputExists(path):
            return "Archive plan output already exists: \(path)"
        case let .planWriteFailed(path):
            return "Archive plan could not be written: \(path)"
        }
    }
}

public enum ArchivePlanner {
    private struct ResourceKey: Hashable {
        let rootID: String
        let relativePath: String
    }

    private struct Draft {
        let assetID: String
        let kind: ArchivePlanItemKind
        let decision: ArchivePlanDecision
        let reason: ArchivePlanReason
        let resources: [ScannedResourceReport]
    }

    public static func makePlan(
        from report: ScanReport,
        destinationURL rawDestinationURL: URL,
        expectedHashForResource: (String) throws -> Data?
    ) throws -> ArchivePlan {
        let fileManager = FileManager.default
        let destinationURL = rawDestinationURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) else {
            throw ArchivePlanError.destinationMissing(destinationURL.path)
        }
        guard isDirectory.boolValue else {
            throw ArchivePlanError.destinationNotDirectory(destinationURL.path)
        }
        guard let destinationMarker = try RootMarkerStore.readIfPresent(at: destinationURL) else {
            throw ArchivePlanError.destinationMarkerRequired(destinationURL.path)
        }

        let rootsByID = Dictionary(uniqueKeysWithValues: report.roots.map { ($0.rootID, $0) })
        let sourceRoots = try report.roots.map { root -> ArchivePlanRoot in
            let rootURL = URL(fileURLWithPath: root.canonicalPath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if overlaps(destinationURL, rootURL) {
                throw ArchivePlanError.destinationOverlapsSource(root.rootID)
            }
            return ArchivePlanRoot(
                rootID: root.rootID,
                kind: root.kind,
                provenance: root.provenance,
                canonicalPath: rootURL.path,
                markerKey: root.stableMarkerKey
            )
        }
        let planRootsByID = Dictionary(uniqueKeysWithValues: sourceRoots.map { ($0.rootID, $0) })
        let resourcesByKey = Dictionary(uniqueKeysWithValues: report.resources.map {
            (ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath), $0)
        })
        let duplicateGroupByResource = duplicateGroupMap(report.exactDuplicateGroups)

        var drafts: [Draft] = []
        var liveResourceKeys = Set<ResourceKey>()

        for asset in report.livePhotos.sorted(by: { $0.assetID < $1.assetID }) {
            for occurrence in asset.occurrences {
                liveResourceKeys.formUnion(occurrence.resources.map {
                    ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath)
                })
            }

            let complete = asset.occurrences.filter { $0.status == .complete }
            guard !complete.isEmpty else {
                drafts.append(Draft(
                    assetID: asset.assetID,
                    kind: .livePhoto,
                    decision: .review,
                    reason: .incompleteLivePhoto,
                    resources: allResources(for: asset, resourcesByKey: resourcesByKey)
                ))
                continue
            }

            let sortedComplete = complete.sorted {
                preferredOccurrence($0, before: $1, rootsByID: rootsByID)
            }
            let canonical = sortedComplete[0]
            let canonicalResources = resources(for: canonical, resourcesByKey: resourcesByKey)
            guard canonicalResources.count == 2,
                  Set(canonicalResources.map(\.role)) == Set([ResourceRole.photo, ResourceRole.pairedVideo])
            else {
                drafts.append(Draft(
                    assetID: asset.assetID,
                    kind: .livePhoto,
                    decision: .review,
                    reason: .incompleteLivePhoto,
                    resources: allResources(for: asset, resourcesByKey: resourcesByKey)
                ))
                continue
            }

            let hasConflictingCompleteVariant = sortedComplete.dropFirst().contains { occurrence in
                !occurrenceIsExactEquivalent(
                    canonical,
                    occurrence,
                    duplicateGroupByResource: duplicateGroupByResource
                )
            }
            if hasConflictingCompleteVariant {
                drafts.append(Draft(
                    assetID: asset.assetID,
                    kind: .livePhoto,
                    decision: .review,
                    reason: .conflictingCompleteLivePhotoVariants,
                    resources: allResources(for: asset, resourcesByKey: resourcesByKey)
                ))
                continue
            }

            guard planRootsByID[canonical.rootID]?.markerKey != nil else {
                drafts.append(Draft(
                    assetID: asset.assetID,
                    kind: .livePhoto,
                    decision: .review,
                    reason: .sourceRootMarkerMissing,
                    resources: canonicalResources
                ))
                continue
            }
            drafts.append(Draft(
                assetID: asset.assetID,
                kind: .livePhoto,
                decision: .automatic,
                reason: .canonicalRepresentation,
                resources: canonicalResources
            ))
        }

        let standaloneResources = report.resources.filter {
            $0.mediaKind != .sidecar
                && !liveResourceKeys.contains(ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath))
        }
        let standaloneByAsset = Dictionary(grouping: standaloneResources) { $0.assetID ?? $0.resourceID }
        for (assetID, group) in standaloneByAsset {
            let sorted = group.sorted {
                preferredResource($0, before: $1, rootsByID: rootsByID)
            }
            guard let canonical = sorted.first else { continue }

            if sorted.count > 1 {
                let canonicalKey = ResourceKey(rootID: canonical.rootID, relativePath: canonical.relativePath)
                let canonicalDuplicateID = duplicateGroupByResource[canonicalKey]
                let allExactEquivalent = sorted.dropFirst().allSatisfy { other in
                    let otherKey = ResourceKey(rootID: other.rootID, relativePath: other.relativePath)
                    return canonicalKey == otherKey
                        || (canonicalDuplicateID != nil && duplicateGroupByResource[otherKey] == canonicalDuplicateID)
                }
                if !allExactEquivalent {
                    drafts.append(Draft(
                        assetID: assetID,
                        kind: .standalone,
                        decision: .review,
                        reason: .ambiguousStandaloneRepresentations,
                        resources: sorted
                    ))
                    continue
                }
            }

            guard planRootsByID[canonical.rootID]?.markerKey != nil else {
                drafts.append(Draft(
                    assetID: assetID,
                    kind: .standalone,
                    decision: .review,
                    reason: .sourceRootMarkerMissing,
                    resources: [canonical]
                ))
                continue
            }
            drafts.append(Draft(
                assetID: assetID,
                kind: .standalone,
                decision: .automatic,
                reason: .canonicalRepresentation,
                resources: [canonical]
            ))
        }

        drafts.sort {
            ($0.decision == .automatic ? 0 : 1, $0.assetID, $0.kind.rawValue)
                < ($1.decision == .automatic ? 0 : 1, $1.assetID, $1.kind.rawValue)
        }

        var reservedDestinations = Set<String>()
        var items: [ArchivePlanItem] = []
        for (offset, draft) in drafts.enumerated() {
            let itemID = String(format: "AR%06d", offset + 1)
            let plannedResources: [ArchivePlannedResource]
            if draft.decision == .automatic {
                plannedResources = try automaticResources(
                    draft.resources,
                    kind: draft.kind,
                    rootsByID: planRootsByID,
                    destinationURL: destinationURL,
                    expectedHashForResource: expectedHashForResource,
                    reservedDestinations: &reservedDestinations
                )
            } else {
                plannedResources = draft.resources.map {
                    ArchivePlannedResource(
                        resourceID: $0.resourceID,
                        sourceRootID: $0.rootID,
                        role: $0.role,
                        sourceRelativePath: $0.relativePath,
                        destinationRelativePath: "",
                        byteSize: $0.byteSize,
                        expectedSHA256: nil
                    )
                }
            }
            items.append(ArchivePlanItem(
                itemID: itemID,
                assetID: draft.assetID,
                kind: draft.kind,
                decision: draft.decision,
                reason: draft.reason,
                resources: plannedResources
            ))
        }

        guard let finalDestinationMarker = try RootMarkerStore.readIfPresent(at: destinationURL),
              finalDestinationMarker.markerKey == destinationMarker.markerKey
        else {
            throw ArchivePlanError.destinationChanged(destinationURL.path)
        }

        let automatic = items.filter { $0.decision == .automatic }
        let review = items.filter { $0.decision == .review }
        return ArchivePlan(
            schemaVersion: 2,
            planID: "AP" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            policy: "canonical_representation_year_folder_v1",
            createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            scanSessionID: report.sessionID,
            catalogPath: report.catalogPath,
            sourceRoots: sourceRoots.sorted { $0.rootID < $1.rootID },
            destination: ArchivePlanDestination(
                canonicalPath: destinationURL.path,
                markerKey: destinationMarker.markerKey
            ),
            summary: ArchivePlanSummary(
                automaticItemCount: automatic.count,
                reviewItemCount: review.count,
                automaticResourceCount: automatic.reduce(0) { $0 + $1.resources.count },
                reviewResourceCount: review.reduce(0) { $0 + $1.resources.count }
            ),
            items: items,
            mediaFilesModified: false
        )
    }

    private static func automaticResources(
        _ resources: [ScannedResourceReport],
        kind: ArchivePlanItemKind,
        rootsByID: [String: ArchivePlanRoot],
        destinationURL: URL,
        expectedHashForResource: (String) throws -> Data?,
        reservedDestinations: inout Set<String>
    ) throws -> [ArchivePlannedResource] {
        guard !resources.isEmpty else { return [] }
        let sorted = resources.sorted { ($0.role.rawValue, $0.resourceID) < ($1.role.rawValue, $1.resourceID) }
        let folder = archiveFolder(for: sorted)

        let baseNames: [String]
        if kind == .livePhoto,
           let still = sorted.first(where: { $0.role == .photo }) {
            let base = (still.fileName as NSString).deletingPathExtension
            baseNames = sorted.map { resource in
                let ext = (resource.fileName as NSString).pathExtension
                return ext.isEmpty ? base : base + "." + ext
            }
        } else {
            baseNames = sorted.map(\.fileName)
        }

        var suffix = 0
        var destinationNames: [String] = []
        while true {
            destinationNames = baseNames.map { applyCollisionSuffix($0, suffix: suffix) }
            let paths = destinationNames.map { folder + "/" + $0 }
            let collisionKeys = paths.map(destinationCollisionKey)
            if Set(collisionKeys).count == collisionKeys.count,
               collisionKeys.allSatisfy({ !reservedDestinations.contains($0) }),
               try destinationPathsAreAvailable(paths, under: destinationURL) {
                for key in collisionKeys { reservedDestinations.insert(key) }
                break
            }
            suffix += 1
        }

        return try zip(sorted, destinationNames).map { resource, destinationName in
            guard let root = rootsByID[resource.rootID], let expectedMarkerKey = root.markerKey else {
                throw ArchivePlanError.sourceChanged(resource.resourceID)
            }
            let rootURL = URL(fileURLWithPath: root.canonicalPath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard let currentMarker = try RootMarkerStore.readIfPresent(at: rootURL),
                  currentMarker.markerKey == expectedMarkerKey
            else {
                throw ArchivePlanError.sourceChanged(resource.resourceID)
            }
            let sourceURL = try safeResourceURL(rootURL: rootURL, relativePath: resource.relativePath)
            let values = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == resource.byteSize,
                  sourceURL.resolvingSymlinksInPath().standardizedFileURL.path == sourceURL.path
            else {
                throw ArchivePlanError.sourceChanged(resource.resourceID)
            }
            guard let expectedHash = try expectedHashForResource(resource.resourceID) else {
                throw ArchivePlanError.sourceChanged(resource.resourceID)
            }
            let freshHash = try FileHasher.sha256(url: sourceURL)
            guard freshHash == expectedHash else {
                throw ArchivePlanError.sourceChanged(resource.resourceID)
            }
            return ArchivePlannedResource(
                resourceID: resource.resourceID,
                sourceRootID: resource.rootID,
                role: resource.role,
                sourceRelativePath: resource.relativePath,
                destinationRelativePath: folder + "/" + destinationName,
                byteSize: resource.byteSize,
                expectedSHA256: freshHash.lowercaseHexString
            )
        }
    }

    private static func destinationPathsAreAvailable(
        _ relativePaths: [String],
        under destinationURL: URL
    ) throws -> Bool {
        let fileManager = FileManager.default
        for relativePath in relativePaths {
            let targetURL = try safeResourceURL(
                rootURL: destinationURL,
                relativePath: relativePath
            )
            try validateDestinationAncestors(
                destinationURL: destinationURL,
                relativePath: relativePath
            )
            if fileManager.fileExists(atPath: targetURL.path) {
                return false
            }
        }
        return true
    }

    private static func validateDestinationAncestors(
        destinationURL: URL,
        relativePath: String
    ) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }

        let fileManager = FileManager.default
        var current = destinationURL
        for component in components.dropLast() {
            current.appendPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory) else {
                continue
            }
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw ArchivePlanError.unsafeDestinationPath(relativePath)
            }
        }
    }

    private static func archiveFolder(for resources: [ScannedResourceReport]) -> String {
        let timestamps = resources.compactMap(\.captureTime?.localTimestamp)
        for timestamp in timestamps.sorted() {
            let prefix = String(timestamp.prefix(4))
            if prefix.count == 4, prefix.allSatisfy(\.isNumber) {
                return "Media/" + prefix
            }
        }
        return "Media/Undated"
    }

    private static func applyCollisionSuffix(_ fileName: String, suffix: Int) -> String {
        guard suffix > 0 else { return fileName }
        let ns = fileName as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let suffixed = String(format: "%@_%02d", stem, suffix)
        return ext.isEmpty ? suffixed : suffixed + "." + ext
    }

    private static func destinationCollisionKey(_ relativePath: String) -> String {
        relativePath.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func duplicateGroupMap(
        _ groups: [ExactDuplicateGroupReport]
    ) -> [ResourceKey: String] {
        var result: [ResourceKey: String] = [:]
        for group in groups {
            for member in group.members {
                result[ResourceKey(rootID: member.rootID, relativePath: member.relativePath)] = group.groupID
            }
        }
        return result
    }

    private static func occurrenceIsExactEquivalent(
        _ lhs: LivePhotoOccurrenceReport,
        _ rhs: LivePhotoOccurrenceReport,
        duplicateGroupByResource: [ResourceKey: String]
    ) -> Bool {
        guard lhs.status == .complete, rhs.status == .complete else { return false }
        let lhsByRole = Dictionary(grouping: lhs.resources, by: \.role)
        let rhsByRole = Dictionary(grouping: rhs.resources, by: \.role)
        for role in [ResourceRole.photo, ResourceRole.pairedVideo] {
            guard let lhsResource = lhsByRole[role]?.only,
                  let rhsResource = rhsByRole[role]?.only
            else {
                return false
            }
            let lhsKey = ResourceKey(rootID: lhsResource.rootID, relativePath: lhsResource.relativePath)
            let rhsKey = ResourceKey(rootID: rhsResource.rootID, relativePath: rhsResource.relativePath)
            if lhsKey == rhsKey { continue }
            guard let lhsGroup = duplicateGroupByResource[lhsKey],
                  duplicateGroupByResource[rhsKey] == lhsGroup
            else {
                return false
            }
        }
        return true
    }

    private static func resources(
        for occurrence: LivePhotoOccurrenceReport,
        resourcesByKey: [ResourceKey: ScannedResourceReport]
    ) -> [ScannedResourceReport] {
        occurrence.resources.compactMap {
            resourcesByKey[ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath)]
        }
    }

    private static func allResources(
        for asset: LivePhotoAssetReport,
        resourcesByKey: [ResourceKey: ScannedResourceReport]
    ) -> [ScannedResourceReport] {
        let values = asset.occurrences.flatMap { resources(for: $0, resourcesByKey: resourcesByKey) }
        var byID: [String: ScannedResourceReport] = [:]
        for value in values { byID[value.resourceID] = value }
        return byID.values.sorted { ($0.rootID, $0.relativePath) < ($1.rootID, $1.relativePath) }
    }

    private static func preferredResource(
        _ lhs: ScannedResourceReport,
        before rhs: ScannedResourceReport,
        rootsByID: [String: RootScanReport]
    ) -> Bool {
        let lhsRank = rootPreference(rootsByID[lhs.rootID])
        let rhsRank = rootPreference(rootsByID[rhs.rootID])
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return (lhs.rootID, lhs.relativePath) < (rhs.rootID, rhs.relativePath)
    }

    private static func preferredOccurrence(
        _ lhs: LivePhotoOccurrenceReport,
        before rhs: LivePhotoOccurrenceReport,
        rootsByID: [String: RootScanReport]
    ) -> Bool {
        let lhsRank = rootPreference(rootsByID[lhs.rootID])
        let rhsRank = rootPreference(rootsByID[rhs.rootID])
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.rootID < rhs.rootID
    }

    private static func rootPreference(_ root: RootScanReport?) -> Int {
        guard let root else { return 100 }
        if root.kind == .archive { return 0 }
        switch root.provenance {
        case .appleDirect: return 1
        case .localLibrary: return 2
        case .googleWeb: return 3
        case .unknown: return 4
        case .googleIOSShare: return 5
        case .googleTakeout: return 6
        }
    }

    private static func safeResourceURL(rootURL: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw ArchivePlanError.unsafeRelativePath(relativePath)
        }
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard isDescendantOrEqual(url, of: rootURL) else {
            throw ArchivePlanError.unsafeRelativePath(relativePath)
        }
        return url
    }

    private static func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
        isDescendantOrEqual(lhs, of: rhs) || isDescendantOrEqual(rhs, of: lhs)
    }

    private static func isDescendantOrEqual(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        if childPath == parentPath { return true }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }
}

public enum ArchivePlanStore {
    public static func write(_ plan: ArchivePlan, to rawURL: URL) throws {
        let url = rawURL.standardizedFileURL
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path) else {
            throw ArchivePlanError.planOutputExists(url.path)
        }
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(plan).write(to: url, options: [.atomic])
        } catch {
            throw ArchivePlanError.planWriteFailed(url.path)
        }
    }

    public static func read(from rawURL: URL) throws -> ArchivePlan {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ArchivePlan.self, from: Data(contentsOf: rawURL.standardizedFileURL))
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
