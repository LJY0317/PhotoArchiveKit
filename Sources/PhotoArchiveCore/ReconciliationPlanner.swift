import Foundation

public enum ReconciliationItemKind: String, Codable, Sendable {
    case standaloneExactGroup = "standalone_exact_group"
    case livePhotoAsset = "live_photo_asset"
    case takeoutOnlyExactGroup = "takeout_only_exact_group"
}

public enum ReconciliationDecision: String, Codable, Sendable {
    case automaticRedundant = "automatic_redundant"
    case review
}

public enum ReconciliationReason: String, Codable, Sendable {
    case preferredNonTakeoutExactCopy = "preferred_non_takeout_exact_copy"
    case livePhotoCanonicalCoverage = "live_photo_canonical_coverage"
    case noCompletePreferredLivePhoto = "no_complete_preferred_live_photo"
    case uncoveredLivePhotoVariant = "uncovered_live_photo_variant"
    case takeoutCollectionSemanticsPending = "takeout_collection_semantics_pending"
}

public struct ReconciliationPlanItem: Codable, Sendable, Equatable {
    public let itemID: String
    public let kind: ReconciliationItemKind
    public let subjectID: String
    public let decision: ReconciliationDecision
    public let reason: ReconciliationReason
    public let preferredRootID: String?
    public let preferredResources: [ResourceReference]
    public let candidateResources: [ResourceReference]
}

public struct ReconciliationPlanSummary: Codable, Sendable, Equatable {
    public let automaticItemCount: Int
    public let reviewItemCount: Int
    public let automaticRedundantResourceCount: Int
    public let reviewResourceCount: Int
}

public struct ReconciliationPlan: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let policy: String
    public let sessionID: String
    public let summary: ReconciliationPlanSummary
    public let items: [ReconciliationPlanItem]
    public let filesModified: Bool
}

public struct AgentSafeReconciliationPlanItem: Codable, Sendable, Equatable {
    public let itemID: String
    public let kind: ReconciliationItemKind
    public let subjectID: String
    public let decision: ReconciliationDecision
    public let reason: ReconciliationReason
    public let preferredRootID: String?
    public let candidateRootIDs: [String]
    public let candidateResourceCount: Int
    public let candidateRoles: [ResourceRole]
}

public struct AgentSafeReconciliationPlan: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let policy: String
    public let sessionID: String
    public let summary: ReconciliationPlanSummary
    public let items: [AgentSafeReconciliationPlanItem]
    public let filesModified: Bool

    public init(plan: ReconciliationPlan) {
        schemaVersion = plan.schemaVersion
        privacyMode = "agent_safe"
        policy = plan.policy
        sessionID = plan.sessionID
        summary = plan.summary
        items = plan.items.map { item in
            AgentSafeReconciliationPlanItem(
                itemID: item.itemID,
                kind: item.kind,
                subjectID: item.subjectID,
                decision: item.decision,
                reason: item.reason,
                preferredRootID: item.preferredRootID,
                candidateRootIDs: Array(Set(item.candidateResources.map(\.rootID))).sorted(),
                candidateResourceCount: item.candidateResources.count,
                candidateRoles: Array(Set(item.candidateResources.map { $0.role.rawValue }))
                    .sorted()
                    .compactMap(ResourceRole.init(rawValue:))
            )
        }
        filesModified = plan.filesModified
    }
}

public enum ReconciliationPlanner {
    private struct ResourceKey: Hashable {
        let rootID: String
        let relativePath: String
    }

    private struct DraftItem {
        let kind: ReconciliationItemKind
        let subjectID: String
        let decision: ReconciliationDecision
        let reason: ReconciliationReason
        let preferredRootID: String?
        let preferredResources: [ResourceReference]
        let candidateResources: [ResourceReference]
    }

    public static func makePlan(from report: ScanReport) -> ReconciliationPlan {
        let rootsByID = Dictionary(uniqueKeysWithValues: report.roots.map { ($0.rootID, $0) })
        let duplicateGroupByResource = duplicateGroupIndex(report.exactDuplicateGroups)
        let liveResourceKeys = Set(
            report.livePhotos
                .flatMap(\.occurrences)
                .flatMap(\.resources)
                .map(resourceKey)
        )

        var drafts: [DraftItem] = []
        drafts.append(contentsOf: standaloneDrafts(
            report: report,
            rootsByID: rootsByID,
            liveResourceKeys: liveResourceKeys
        ))
        drafts.append(contentsOf: livePhotoDrafts(
            report: report,
            rootsByID: rootsByID,
            duplicateGroupByResource: duplicateGroupByResource
        ))

        drafts.sort { lhs, rhs in
            let lhsKey = (decisionRank(lhs.decision), lhs.kind.rawValue, lhs.subjectID, lhs.reason.rawValue)
            let rhsKey = (decisionRank(rhs.decision), rhs.kind.rawValue, rhs.subjectID, rhs.reason.rawValue)
            return lhsKey < rhsKey
        }

        let items = drafts.enumerated().map { offset, draft in
            ReconciliationPlanItem(
                itemID: String(format: "P%06d", offset + 1),
                kind: draft.kind,
                subjectID: draft.subjectID,
                decision: draft.decision,
                reason: draft.reason,
                preferredRootID: draft.preferredRootID,
                preferredResources: draft.preferredResources,
                candidateResources: draft.candidateResources
            )
        }

        let automaticItems = items.filter { $0.decision == .automaticRedundant }
        let reviewItems = items.filter { $0.decision == .review }
        return ReconciliationPlan(
            schemaVersion: 1,
            policy: "prefer_non_takeout_exact_v1",
            sessionID: report.sessionID,
            summary: ReconciliationPlanSummary(
                automaticItemCount: automaticItems.count,
                reviewItemCount: reviewItems.count,
                automaticRedundantResourceCount: automaticItems.reduce(0) { $0 + $1.candidateResources.count },
                reviewResourceCount: reviewItems.reduce(0) { $0 + $1.candidateResources.count }
            ),
            items: items,
            filesModified: false
        )
    }

    private static func standaloneDrafts(
        report: ScanReport,
        rootsByID: [String: RootScanReport],
        liveResourceKeys: Set<ResourceKey>
    ) -> [DraftItem] {
        report.exactDuplicateGroups.compactMap { group in
            let members = group.members.filter { !liveResourceKeys.contains(resourceKey($0)) }
            guard members.count > 1 else { return nil }

            let takeout = members.filter { rootsByID[$0.rootID]?.provenance == .googleTakeout }
            guard !takeout.isEmpty else { return nil }
            let preferred = members.filter { rootsByID[$0.rootID]?.provenance != .googleTakeout }

            if let canonical = preferred.sorted(by: { preferredResource($0, before: $1, rootsByID: rootsByID) }).first {
                return DraftItem(
                    kind: .standaloneExactGroup,
                    subjectID: group.groupID,
                    decision: .automaticRedundant,
                    reason: .preferredNonTakeoutExactCopy,
                    preferredRootID: canonical.rootID,
                    preferredResources: [canonical],
                    candidateResources: takeout.sorted(by: resourceSort)
                )
            }

            return DraftItem(
                kind: .takeoutOnlyExactGroup,
                subjectID: group.groupID,
                decision: .review,
                reason: .takeoutCollectionSemanticsPending,
                preferredRootID: nil,
                preferredResources: [],
                candidateResources: takeout.sorted(by: resourceSort)
            )
        }
    }

    private static func livePhotoDrafts(
        report: ScanReport,
        rootsByID: [String: RootScanReport],
        duplicateGroupByResource: [ResourceKey: String]
    ) -> [DraftItem] {
        var output: [DraftItem] = []

        for asset in report.livePhotos {
            let takeoutResources = asset.occurrences
                .filter { rootsByID[$0.rootID]?.provenance == .googleTakeout }
                .flatMap(\.resources)
            guard !takeoutResources.isEmpty else { continue }

            let completePreferredOccurrences = asset.occurrences.filter { occurrence in
                occurrence.status == .complete
                    && rootsByID[occurrence.rootID]?.provenance != .googleTakeout
            }
            let canonical = completePreferredOccurrences.sorted { lhs, rhs in
                preferredOccurrence(lhs, before: rhs, rootsByID: rootsByID)
            }.first

            let exactMixedTakeout = takeoutResources.filter { resource in
                guard let groupID = duplicateGroupByResource[resourceKey(resource)],
                      let group = report.exactDuplicateGroups.first(where: { $0.groupID == groupID })
                else {
                    return false
                }
                return group.members.contains { member in
                    member.role == resource.role
                        && rootsByID[member.rootID]?.provenance != .googleTakeout
                }
            }
            guard !exactMixedTakeout.isEmpty else { continue }

            guard let canonical else {
                output.append(DraftItem(
                    kind: .livePhotoAsset,
                    subjectID: asset.assetID,
                    decision: .review,
                    reason: .noCompletePreferredLivePhoto,
                    preferredRootID: nil,
                    preferredResources: [],
                    candidateResources: exactMixedTakeout.sorted(by: resourceSort)
                ))
                continue
            }

            let canonicalGroupsByRole = Dictionary(grouping: canonical.resources) { $0.role }
                .mapValues { resources in
                    Set(resources.compactMap { duplicateGroupByResource[resourceKey($0)] })
                }
            let covered = takeoutResources.filter { resource in
                guard let groupID = duplicateGroupByResource[resourceKey(resource)] else {
                    return false
                }
                return canonicalGroupsByRole[resource.role]?.contains(groupID) == true
            }

            if covered.count == takeoutResources.count {
                output.append(DraftItem(
                    kind: .livePhotoAsset,
                    subjectID: asset.assetID,
                    decision: .automaticRedundant,
                    reason: .livePhotoCanonicalCoverage,
                    preferredRootID: canonical.rootID,
                    preferredResources: canonical.resources.sorted(by: resourceSort),
                    candidateResources: takeoutResources.sorted(by: resourceSort)
                ))
            } else {
                output.append(DraftItem(
                    kind: .livePhotoAsset,
                    subjectID: asset.assetID,
                    decision: .review,
                    reason: .uncoveredLivePhotoVariant,
                    preferredRootID: canonical.rootID,
                    preferredResources: canonical.resources.sorted(by: resourceSort),
                    candidateResources: exactMixedTakeout.sorted(by: resourceSort)
                ))
            }
        }

        return output
    }

    private static func duplicateGroupIndex(
        _ groups: [ExactDuplicateGroupReport]
    ) -> [ResourceKey: String] {
        var result: [ResourceKey: String] = [:]
        for group in groups {
            for member in group.members {
                result[resourceKey(member)] = group.groupID
            }
        }
        return result
    }

    private static func resourceKey(_ resource: ResourceReference) -> ResourceKey {
        ResourceKey(rootID: resource.rootID, relativePath: resource.relativePath)
    }

    private static func preferredResource(
        _ lhs: ResourceReference,
        before rhs: ResourceReference,
        rootsByID: [String: RootScanReport]
    ) -> Bool {
        let lhsRank = rootPreference(rootsByID[lhs.rootID])
        let rhsRank = rootPreference(rootsByID[rhs.rootID])
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return resourceSort(lhs, rhs)
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
        case .appleDirect:
            return 1
        case .localLibrary:
            return 2
        case .googleWeb:
            return 3
        case .unknown:
            return 4
        case .googleIOSShare:
            return 5
        case .googleTakeout:
            return 6
        }
    }

    private static func decisionRank(_ decision: ReconciliationDecision) -> Int {
        decision == .automaticRedundant ? 0 : 1
    }

    private static func resourceSort(_ lhs: ResourceReference, _ rhs: ResourceReference) -> Bool {
        (lhs.rootID, lhs.relativePath, lhs.role.rawValue)
            < (rhs.rootID, rhs.relativePath, rhs.role.rawValue)
    }
}
