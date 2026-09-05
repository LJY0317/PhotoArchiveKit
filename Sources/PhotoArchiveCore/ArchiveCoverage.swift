import Foundation

public enum LivePhotoElsewhereCoverage: String, Codable, Sendable, CaseIterable {
    case completeElsewhere = "complete_elsewhere"
    case splitOrAmbiguousElsewhere = "split_or_ambiguous_elsewhere"
    case stillOnlyElsewhere = "still_only_elsewhere"
    case videoOnlyElsewhere = "video_only_elsewhere"
    case noCounterpart = "no_counterpart"
}

public struct LivePhotoCoverageSummary: Codable, Sendable, Equatable {
    public let occurrenceCount: Int
    public let completeElsewhere: Int
    public let splitOrAmbiguousElsewhere: Int
    public let stillOnlyElsewhere: Int
    public let videoOnlyElsewhere: Int
    public let noCounterpart: Int

    public init(
        occurrenceCount: Int,
        completeElsewhere: Int,
        splitOrAmbiguousElsewhere: Int,
        stillOnlyElsewhere: Int,
        videoOnlyElsewhere: Int,
        noCounterpart: Int
    ) {
        self.occurrenceCount = occurrenceCount
        self.completeElsewhere = completeElsewhere
        self.splitOrAmbiguousElsewhere = splitOrAmbiguousElsewhere
        self.stillOnlyElsewhere = stillOnlyElsewhere
        self.videoOnlyElsewhere = videoOnlyElsewhere
        self.noCounterpart = noCounterpart
    }
}

public struct ExactPeerCoverageReport: Codable, Sendable, Equatable {
    public let peerRootID: String
    public let sharedExactGroupCount: Int
    public let coveredResourceCount: Int

    public init(peerRootID: String, sharedExactGroupCount: Int, coveredResourceCount: Int) {
        self.peerRootID = peerRootID
        self.sharedExactGroupCount = sharedExactGroupCount
        self.coveredResourceCount = coveredResourceCount
    }
}

public struct ArchiveCoverageRootReport: Codable, Sendable, Equatable {
    public let rootID: String
    public let label: String
    public let kind: SourceRootKind
    public let usageRole: RootUsageRole
    public let provenance: SourceProvenance
    public let canonicalPath: String
    public let mediaResourceCount: Int
    public let exactCoveredElsewhereResourceCount: Int
    public let exactUniqueToRootResourceCount: Int
    public let exactPeers: [ExactPeerCoverageReport]
    public let livePhotos: LivePhotoCoverageSummary

    public init(
        rootID: String,
        label: String,
        kind: SourceRootKind,
        usageRole: RootUsageRole,
        provenance: SourceProvenance,
        canonicalPath: String,
        mediaResourceCount: Int,
        exactCoveredElsewhereResourceCount: Int,
        exactUniqueToRootResourceCount: Int,
        exactPeers: [ExactPeerCoverageReport],
        livePhotos: LivePhotoCoverageSummary
    ) {
        self.rootID = rootID
        self.label = label
        self.kind = kind
        self.usageRole = usageRole
        self.provenance = provenance
        self.canonicalPath = canonicalPath
        self.mediaResourceCount = mediaResourceCount
        self.exactCoveredElsewhereResourceCount = exactCoveredElsewhereResourceCount
        self.exactUniqueToRootResourceCount = exactUniqueToRootResourceCount
        self.exactPeers = exactPeers
        self.livePhotos = livePhotos
    }
}

public struct PairwiseExactCoverageReport: Codable, Sendable, Equatable {
    public let leftRootID: String
    public let rightRootID: String
    public let sharedExactGroupCount: Int

    public init(leftRootID: String, rightRootID: String, sharedExactGroupCount: Int) {
        self.leftRootID = leftRootID
        self.rightRootID = rightRootID
        self.sharedExactGroupCount = sharedExactGroupCount
    }
}

public struct ArchiveCoverageReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let roots: [ArchiveCoverageRootReport]
    public let pairwiseExact: [PairwiseExactCoverageReport]
    public let notices: [ScanNotice]
    public let filesModified: Bool

    public init(
        schemaVersion: Int = 1,
        sessionID: String,
        roots: [ArchiveCoverageRootReport],
        pairwiseExact: [PairwiseExactCoverageReport],
        notices: [ScanNotice] = [],
        filesModified: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.roots = roots
        self.pairwiseExact = pairwiseExact
        self.notices = notices
        self.filesModified = filesModified
    }
}

public struct AgentSafeArchiveCoverageRootReport: Codable, Sendable, Equatable {
    public let rootID: String
    public let kind: SourceRootKind
    public let usageRole: RootUsageRole
    public let provenance: SourceProvenance
    public let mediaResourceCount: Int
    public let exactCoveredElsewhereResourceCount: Int
    public let exactUniqueToRootResourceCount: Int
    public let exactPeers: [ExactPeerCoverageReport]
    public let livePhotos: LivePhotoCoverageSummary
}

public struct AgentSafeArchiveCoverageReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let sessionID: String
    public let roots: [AgentSafeArchiveCoverageRootReport]
    public let pairwiseExact: [PairwiseExactCoverageReport]
    public let notices: [AgentSafeNotice]
    public let filesModified: Bool

    public init(report: ArchiveCoverageReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        sessionID = report.sessionID
        roots = report.roots.map { root in
            AgentSafeArchiveCoverageRootReport(
                rootID: root.rootID,
                kind: root.kind,
                usageRole: root.usageRole,
                provenance: root.provenance,
                mediaResourceCount: root.mediaResourceCount,
                exactCoveredElsewhereResourceCount: root.exactCoveredElsewhereResourceCount,
                exactUniqueToRootResourceCount: root.exactUniqueToRootResourceCount,
                exactPeers: root.exactPeers,
                livePhotos: root.livePhotos
            )
        }
        pairwiseExact = report.pairwiseExact
        notices = report.notices.map { notice in
            AgentSafeNotice(code: notice.code, rootID: notice.rootID)
        }
        filesModified = report.filesModified
    }
}

public enum ArchiveCoverageBuilder {
    private struct ResourceKey: Hashable {
        let rootID: String
        let relativePath: String
        let role: ResourceRole

        init(_ reference: ResourceReference) {
            rootID = reference.rootID
            relativePath = reference.relativePath
            role = reference.role
        }
    }

    private struct RootPair: Hashable, Comparable {
        let left: String
        let right: String

        init(_ first: String, _ second: String) {
            if first <= second {
                left = first
                right = second
            } else {
                left = second
                right = first
            }
        }

        static func < (lhs: RootPair, rhs: RootPair) -> Bool {
            (lhs.left, lhs.right) < (rhs.left, rhs.right)
        }
    }

    public static func makeReport(from scan: ScanReport) -> ArchiveCoverageReport {
        var coveredResourcesByRoot: [String: Set<ResourceKey>] = [:]
        var peerResources: [String: [String: Set<ResourceKey>]] = [:]
        var peerGroups: [String: [String: Set<String>]] = [:]
        var pairGroups: [RootPair: Set<String>] = [:]

        for group in scan.exactDuplicateGroups {
            let membersByRoot = Dictionary(grouping: group.members, by: \.rootID)
            let rootIDs = membersByRoot.keys.sorted()
            guard rootIDs.count > 1 else { continue }

            for rootID in rootIDs {
                let localMembers = membersByRoot[rootID] ?? []
                for peerRootID in rootIDs where peerRootID != rootID {
                    let keys = Set(localMembers.map(ResourceKey.init))
                    coveredResourcesByRoot[rootID, default: []].formUnion(keys)
                    peerResources[rootID, default: [:]][peerRootID, default: []].formUnion(keys)
                    peerGroups[rootID, default: [:]][peerRootID, default: []].insert(group.groupID)
                }
            }

            for leftIndex in rootIDs.indices {
                for rightIndex in rootIDs.indices where rightIndex > leftIndex {
                    pairGroups[RootPair(rootIDs[leftIndex], rootIDs[rightIndex]), default: []]
                        .insert(group.groupID)
                }
            }
        }

        var livePhotoCounts: [String: [LivePhotoElsewhereCoverage: Int]] = [:]
        var livePhotoOccurrenceCounts: [String: Int] = [:]
        for asset in scan.livePhotos {
            for occurrence in asset.occurrences {
                livePhotoOccurrenceCounts[occurrence.rootID, default: 0] += 1
                let elsewhere = classifyElsewhere(
                    occurrence: occurrence,
                    allOccurrences: asset.occurrences
                )
                livePhotoCounts[occurrence.rootID, default: [:]][elsewhere, default: 0] += 1
            }
        }

        let roots = scan.roots.map { root -> ArchiveCoverageRootReport in
            let covered = min(
                root.mediaFileCount,
                coveredResourcesByRoot[root.rootID, default: []].count
            )
            let peers = (peerGroups[root.rootID] ?? [:]).map { peerRootID, groups in
                ExactPeerCoverageReport(
                    peerRootID: peerRootID,
                    sharedExactGroupCount: groups.count,
                    coveredResourceCount: peerResources[root.rootID]?[peerRootID]?.count ?? 0
                )
            }
            .sorted { $0.peerRootID < $1.peerRootID }
            let counts = livePhotoCounts[root.rootID] ?? [:]
            let livePhotos = LivePhotoCoverageSummary(
                occurrenceCount: livePhotoOccurrenceCounts[root.rootID, default: 0],
                completeElsewhere: counts[.completeElsewhere, default: 0],
                splitOrAmbiguousElsewhere: counts[.splitOrAmbiguousElsewhere, default: 0],
                stillOnlyElsewhere: counts[.stillOnlyElsewhere, default: 0],
                videoOnlyElsewhere: counts[.videoOnlyElsewhere, default: 0],
                noCounterpart: counts[.noCounterpart, default: 0]
            )
            return ArchiveCoverageRootReport(
                rootID: root.rootID,
                label: root.label,
                kind: root.kind,
                usageRole: root.usageRole,
                provenance: root.provenance,
                canonicalPath: root.canonicalPath,
                mediaResourceCount: root.mediaFileCount,
                exactCoveredElsewhereResourceCount: covered,
                exactUniqueToRootResourceCount: max(0, root.mediaFileCount - covered),
                exactPeers: peers,
                livePhotos: livePhotos
            )
        }
        .sorted { ($0.label, $0.rootID) < ($1.label, $1.rootID) }

        let pairwise = pairGroups.map { pair, groups in
            PairwiseExactCoverageReport(
                leftRootID: pair.left,
                rightRootID: pair.right,
                sharedExactGroupCount: groups.count
            )
        }
        .sorted {
            ($0.leftRootID, $0.rightRootID) < ($1.leftRootID, $1.rightRootID)
        }

        return ArchiveCoverageReport(
            sessionID: scan.sessionID,
            roots: roots,
            pairwiseExact: pairwise,
            notices: scan.notices,
            filesModified: false
        )
    }

    private static func classifyElsewhere(
        occurrence: LivePhotoOccurrenceReport,
        allOccurrences: [LivePhotoOccurrenceReport]
    ) -> LivePhotoElsewhereCoverage {
        let others = allOccurrences.filter { $0.rootID != occurrence.rootID }
        if others.contains(where: { $0.status == .complete }) {
            return .completeElsewhere
        }

        let hasStill = others.contains { $0.stillCount > 0 }
        let hasVideo = others.contains { $0.videoCount > 0 }
        switch (hasStill, hasVideo) {
        case (true, true):
            return .splitOrAmbiguousElsewhere
        case (true, false):
            return .stillOnlyElsewhere
        case (false, true):
            return .videoOnlyElsewhere
        case (false, false):
            return .noCounterpart
        }
    }
}
