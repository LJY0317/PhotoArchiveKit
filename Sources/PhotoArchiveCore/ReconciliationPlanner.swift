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
    case canonicalExactCopy = "canonical_exact_copy"
    case canonicalLocalLivePhotoOccurrence = "canonical_local_live_photo_occurrence"
    case preferredNonTakeoutExactCopy = "preferred_non_takeout_exact_copy"
    case livePhotoCanonicalCoverage = "live_photo_canonical_coverage"
    case livePhotoIncompleteOccurrenceExactCoverage = "live_photo_incomplete_occurrence_exact_coverage"
    case noCompletePreferredLivePhoto = "no_complete_preferred_live_photo"
    case uncoveredLivePhotoVariant = "uncovered_live_photo_variant"
    case takeoutCollectionSemanticsPending = "takeout_collection_semantics_pending"
    case takeoutSourceFolderSemanticsCaptured = "takeout_source_folder_semantics_captured"
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
        let resourcesByKey = Dictionary(uniqueKeysWithValues: report.resources.map {
            (CanonicalResourceKey(rootID: $0.rootID, relativePath: $0.relativePath), $0)
        })
        let duplicateGroupByResource = duplicateGroupIndex(report.exactDuplicateGroups)
        let duplicateGroupsByID = Dictionary(uniqueKeysWithValues: report.exactDuplicateGroups.map {
            ($0.groupID, $0)
        })
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
            resourcesByKey: resourcesByKey,
            liveResourceKeys: liveResourceKeys
        ))
        drafts.append(contentsOf: localLibraryLivePhotoDrafts(
            report: report,
            rootsByID: rootsByID,
            resourcesByKey: resourcesByKey,
            duplicateGroupByResource: duplicateGroupByResource
        ))
        drafts.append(contentsOf: livePhotoDrafts(
            report: report,
            rootsByID: rootsByID,
            resourcesByKey: resourcesByKey,
            duplicateGroupByResource: duplicateGroupByResource,
            duplicateGroupsByID: duplicateGroupsByID
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
            policy: "canonical_exact_keeper_v5_root_retention_aware",
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
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport],
        liveResourceKeys: Set<ResourceKey>
    ) -> [DraftItem] {
        var output: [DraftItem] = []
        for group in report.exactDuplicateGroups {
            let nonLive = group.members.filter { !liveResourceKeys.contains(resourceKey($0)) }
            let byRole = Dictionary(grouping: nonLive, by: \.role)
            for members in byRole.values where members.count > 1 {
                var candidateKeys = Set<ResourceKey>()

                let byRoot = Dictionary(grouping: members, by: \.rootID)
                for (rootID, rootMembers) in byRoot {
                    guard rootsByID[rootID]?.usageRole != .importSource,
                          CanonicalKeeperPolicy.allowsSameRootExactDedupe(rootsByID[rootID]),
                          rootMembers.count > 1
                    else { continue }
                    let sorted = rootMembers.sorted {
                        CanonicalKeeperPolicy.preferredResource(
                            $0,
                            before: $1,
                            rootsByID: rootsByID,
                            resourcesByKey: resourcesByKey
                        )
                    }
                    for candidate in sorted.dropFirst() {
                        candidateKeys.insert(resourceKey(candidate))
                    }
                }

                var retained = members.filter { !candidateKeys.contains(resourceKey($0)) }
                let importMembers = retained.filter {
                    CanonicalKeeperPolicy.isImportCleanupRoot(rootsByID[$0.rootID])
                        && CanonicalKeeperPolicy.importCleanupSemanticsAreSafe(rootsByID[$0.rootID])
                }
                let stableKeepers = retained.filter {
                    CanonicalKeeperPolicy.canRetainAgainstImportCleanup(rootsByID[$0.rootID])
                }

                if !stableKeepers.isEmpty {
                    for candidate in importMembers {
                        candidateKeys.insert(resourceKey(candidate))
                    }
                } else if importMembers.count > 1 {
                    let semanticsCaptured = importMembers.allSatisfy {
                        CanonicalKeeperPolicy.importCleanupSemanticsAreSafe(rootsByID[$0.rootID])
                    }
                    if semanticsCaptured {
                        let sorted = importMembers.sorted {
                            CanonicalKeeperPolicy.preferredResource(
                                $0,
                                before: $1,
                                rootsByID: rootsByID,
                                resourcesByKey: resourcesByKey
                            )
                        }
                        for candidate in sorted.dropFirst() {
                            candidateKeys.insert(resourceKey(candidate))
                        }
                    }
                }

                let candidates = members
                    .filter { candidateKeys.contains(resourceKey($0)) }
                    .sorted(by: resourceSort)
                guard !candidates.isEmpty else {
                    if members.allSatisfy({ CanonicalKeeperPolicy.isImportCleanupRoot(rootsByID[$0.rootID]) }) {
                        output.append(DraftItem(
                            kind: .takeoutOnlyExactGroup,
                            subjectID: group.groupID,
                            decision: .review,
                            reason: .takeoutCollectionSemanticsPending,
                            preferredRootID: nil,
                            preferredResources: [],
                            candidateResources: members.sorted(by: resourceSort)
                        ))
                    }
                    continue
                }

                retained = members.filter { !candidateKeys.contains(resourceKey($0)) }
                let localCandidateRootIDs = Set(candidates.compactMap { candidate -> String? in
                    guard rootsByID[candidate.rootID]?.usageRole != .importSource else { return nil }
                    return CanonicalKeeperPolicy.allowsSameRootExactDedupe(rootsByID[candidate.rootID])
                        ? candidate.rootID
                        : nil
                })
                let sameRootSurvivors = retained.filter { localCandidateRootIDs.contains($0.rootID) }
                let preferredPool = sameRootSurvivors.isEmpty ? retained : sameRootSurvivors
                let preferred = preferredPool.sorted {
                    CanonicalKeeperPolicy.preferredResource(
                        $0,
                        before: $1,
                        rootsByID: rootsByID,
                        resourcesByKey: resourcesByKey
                    )
                }
                guard let canonical = preferred.first else { continue }

                let hasLocalCandidate = candidates.contains {
                    rootsByID[$0.rootID]?.usageRole != .importSource
                        && CanonicalKeeperPolicy.allowsSameRootExactDedupe(rootsByID[$0.rootID])
                }
                let onlyImport = retained.allSatisfy {
                    CanonicalKeeperPolicy.isImportCleanupRoot(rootsByID[$0.rootID])
                }
                let reason: ReconciliationReason
                let kind: ReconciliationItemKind
                if hasLocalCandidate {
                    reason = .canonicalExactCopy
                    kind = .standaloneExactGroup
                } else if onlyImport {
                    reason = .takeoutSourceFolderSemanticsCaptured
                    kind = .takeoutOnlyExactGroup
                } else {
                    reason = .preferredNonTakeoutExactCopy
                    kind = .standaloneExactGroup
                }
                output.append(DraftItem(
                    kind: kind,
                    subjectID: group.groupID,
                    decision: .automaticRedundant,
                    reason: reason,
                    preferredRootID: canonical.rootID,
                    preferredResources: [canonical],
                    candidateResources: candidates
                ))
            }
        }
        return output
    }

    private static func localLibraryLivePhotoDrafts(
        report: ScanReport,
        rootsByID: [String: RootScanReport],
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport],
        duplicateGroupByResource: [ResourceKey: String]
    ) -> [DraftItem] {
        var output: [DraftItem] = []
        for asset in report.livePhotos {
            let byRoot = Dictionary(grouping: asset.occurrences, by: \.rootID)
            for (rootID, occurrences) in byRoot {
                guard CanonicalKeeperPolicy.allowsSameRootExactDedupe(rootsByID[rootID]),
                      occurrences.count > 1
                else { continue }
                let sorted = occurrences.sorted {
                    CanonicalKeeperPolicy.preferredOccurrence(
                        $0,
                        before: $1,
                        rootsByID: rootsByID,
                        resourcesByKey: resourcesByKey
                    )
                }
                guard let canonical = sorted.first else { continue }
                let canonicalGroupsByRole = exactGroupsByRole(
                    canonical.resources,
                    duplicateGroupByResource: duplicateGroupByResource
                )
                let redundantOccurrences = sorted.dropFirst().filter { occurrence in
                    occurrence.resources.allSatisfy { resource in
                        guard let groupID = duplicateGroupByResource[resourceKey(resource)] else {
                            return false
                        }
                        return canonicalGroupsByRole[resource.role]?.contains(groupID) == true
                    }
                }
                let candidates = redundantOccurrences.flatMap(\.resources).sorted(by: resourceSort)
                guard !candidates.isEmpty else { continue }
                output.append(DraftItem(
                    kind: .livePhotoAsset,
                    subjectID: asset.assetID,
                    decision: .automaticRedundant,
                    reason: .canonicalLocalLivePhotoOccurrence,
                    preferredRootID: rootID,
                    preferredResources: canonical.resources.sorted(by: resourceSort),
                    candidateResources: candidates
                ))
            }
        }
        return output
    }

    private static func livePhotoDrafts(
        report: ScanReport,
        rootsByID: [String: RootScanReport],
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport],
        duplicateGroupByResource: [ResourceKey: String],
        duplicateGroupsByID: [String: ExactDuplicateGroupReport]
    ) -> [DraftItem] {
        var output: [DraftItem] = []

        for asset in report.livePhotos {
            let takeoutResources = asset.occurrences
                .filter {
                    rootsByID[$0.rootID]?.provenance == .googleTakeout
                        && CanonicalKeeperPolicy.importCleanupSemanticsAreSafe(rootsByID[$0.rootID])
                }
                .flatMap(\.resources)
            guard !takeoutResources.isEmpty else { continue }

            let completePreferredOccurrences = asset.occurrences.filter { occurrence in
                occurrence.status == .complete
                    && CanonicalKeeperPolicy.canRetainAgainstImportCleanup(rootsByID[occurrence.rootID])
            }
            let canonical = completePreferredOccurrences.sorted { lhs, rhs in
                CanonicalKeeperPolicy.preferredOccurrence(
                    lhs,
                    before: rhs,
                    rootsByID: rootsByID,
                    resourcesByKey: resourcesByKey
                )
            }.first

            let exactMixedTakeout = takeoutResources.filter { resource in
                guard let groupID = duplicateGroupByResource[resourceKey(resource)],
                      let group = duplicateGroupsByID[groupID]
                else {
                    return false
                }
                return group.members.contains { member in
                    member.role == resource.role
                        && CanonicalKeeperPolicy.canRetainAgainstImportCleanup(rootsByID[member.rootID])
                }
            }
            guard !exactMixedTakeout.isEmpty else { continue }

            guard let canonical else {
                let safeOccurrences = asset.occurrences.filter { occurrence in
                    guard rootsByID[occurrence.rootID]?.provenance == .googleTakeout,
                          occurrence.status == .stillOnly || occurrence.status == .videoOnly
                    else {
                        return false
                    }
                    return occurrence.resources.allSatisfy { resource in
                        preferredExactCounterpart(
                            for: resource,
                            rootsByID: rootsByID,
                            resourcesByKey: resourcesByKey,
                            duplicateGroupByResource: duplicateGroupByResource,
                            duplicateGroupsByID: duplicateGroupsByID
                        ) != nil
                    }
                }
                let safeResources = safeOccurrences.flatMap(\.resources).sorted(by: resourceSort)
                if !safeResources.isEmpty {
                    let preferred = uniqueResources(safeResources.compactMap { resource in
                        preferredExactCounterpart(
                            for: resource,
                            rootsByID: rootsByID,
                            resourcesByKey: resourcesByKey,
                            duplicateGroupByResource: duplicateGroupByResource,
                            duplicateGroupsByID: duplicateGroupsByID
                        )
                    })
                    let preferredRootIDs = Set(preferred.map(\.rootID))
                    output.append(DraftItem(
                        kind: .livePhotoAsset,
                        subjectID: asset.assetID,
                        decision: .automaticRedundant,
                        reason: .livePhotoIncompleteOccurrenceExactCoverage,
                        preferredRootID: preferredRootIDs.count == 1 ? preferredRootIDs.first : nil,
                        preferredResources: preferred,
                        candidateResources: safeResources
                    ))
                }

                let safeKeys = Set(safeResources.map(resourceKey))
                let remaining = exactMixedTakeout
                    .filter { !safeKeys.contains(resourceKey($0)) }
                    .sorted(by: resourceSort)
                if !remaining.isEmpty {
                    output.append(DraftItem(
                        kind: .livePhotoAsset,
                        subjectID: asset.assetID,
                        decision: .review,
                        reason: .noCompletePreferredLivePhoto,
                        preferredRootID: nil,
                        preferredResources: [],
                        candidateResources: remaining
                    ))
                }
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

    private static func preferredExactCounterpart(
        for resource: ResourceReference,
        rootsByID: [String: RootScanReport],
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport],
        duplicateGroupByResource: [ResourceKey: String],
        duplicateGroupsByID: [String: ExactDuplicateGroupReport]
    ) -> ResourceReference? {
        guard let groupID = duplicateGroupByResource[resourceKey(resource)],
              let group = duplicateGroupsByID[groupID]
        else {
            return nil
        }
        return group.members
            .filter {
                $0.role == resource.role
                    && CanonicalKeeperPolicy.canRetainAgainstImportCleanup(rootsByID[$0.rootID])
            }
            .sorted {
                CanonicalKeeperPolicy.preferredResource(
                    $0,
                    before: $1,
                    rootsByID: rootsByID,
                    resourcesByKey: resourcesByKey
                )
            }
            .first
    }

    private static func exactGroupsByRole(
        _ resources: [ResourceReference],
        duplicateGroupByResource: [ResourceKey: String]
    ) -> [ResourceRole: Set<String>] {
        Dictionary(grouping: resources, by: \.role)
            .mapValues { values in
                Set(values.compactMap { duplicateGroupByResource[resourceKey($0)] })
            }
    }

    private static func uniqueResources(_ resources: [ResourceReference]) -> [ResourceReference] {
        var seen = Set<ResourceKey>()
        return resources
            .sorted(by: resourceSort)
            .filter { seen.insert(resourceKey($0)).inserted }
    }

    private static func resourceKey(_ resource: ResourceReference) -> ResourceKey {
        ResourceKey(rootID: resource.rootID, relativePath: resource.relativePath)
    }

    private static func decisionRank(_ decision: ReconciliationDecision) -> Int {
        decision == .automaticRedundant ? 0 : 1
    }

    private static func resourceSort(_ lhs: ResourceReference, _ rhs: ResourceReference) -> Bool {
        (lhs.rootID, lhs.relativePath, lhs.role.rawValue)
            < (rhs.rootID, rhs.relativePath, rhs.role.rawValue)
    }
}
