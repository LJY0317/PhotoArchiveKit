import Foundation

public enum OrganizationItemKind: String, Codable, Sendable {
    case standalone
    case livePhoto = "live_photo"
}

public enum OrganizationDecision: String, Codable, Sendable {
    case automatic
    case review
}

public enum OrganizationReason: String, Codable, Sendable {
    case cameraNameAndCaptureWallClock = "camera_name_and_capture_wall_clock"
    case incompleteLivePhoto = "incomplete_live_photo"
    case customFilenamePreserved = "custom_filename_preserved"
    case captureTimeNotTrusted = "capture_time_not_trusted"
    case multiplePhysicalRepresentations = "multiple_physical_representations"
}

public struct OrganizationMove: Codable, Sendable, Equatable {
    public let resourceID: String
    public let rootID: String
    public let role: ResourceRole
    public let sourceRelativePath: String
    public let destinationRelativePath: String
}

public struct OrganizationPlanItem: Codable, Sendable, Equatable {
    public let itemID: String
    public let assetID: String
    public let kind: OrganizationItemKind
    public let decision: OrganizationDecision
    public let reason: OrganizationReason
    public let moves: [OrganizationMove]
}

public struct OrganizationPlanSummary: Codable, Sendable, Equatable {
    public let automaticItemCount: Int
    public let reviewItemCount: Int
    public let automaticResourceCount: Int
    public let reviewResourceCount: Int
}

public struct OrganizationPlan: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let policy: String
    public let sessionID: String
    public let summary: OrganizationPlanSummary
    public let items: [OrganizationPlanItem]
    public let filesModified: Bool
}

public struct AgentSafeOrganizationPlanItem: Codable, Sendable, Equatable {
    public let itemID: String
    public let assetID: String
    public let kind: OrganizationItemKind
    public let decision: OrganizationDecision
    public let reason: OrganizationReason
    public let resourceCount: Int
}

public struct AgentSafeOrganizationPlan: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let policy: String
    public let sessionID: String
    public let summary: OrganizationPlanSummary
    public let items: [AgentSafeOrganizationPlanItem]
    public let filesModified: Bool

    public init(plan: OrganizationPlan) {
        schemaVersion = plan.schemaVersion
        privacyMode = "agent_safe"
        policy = plan.policy
        sessionID = plan.sessionID
        summary = plan.summary
        items = plan.items.map {
            AgentSafeOrganizationPlanItem(
                itemID: $0.itemID,
                assetID: $0.assetID,
                kind: $0.kind,
                decision: $0.decision,
                reason: $0.reason,
                resourceCount: $0.moves.count
            )
        }
        filesModified = plan.filesModified
    }
}

public enum OrganizationPlanner {
    private struct Draft {
        let assetID: String
        let kind: OrganizationItemKind
        let decision: OrganizationDecision
        let reason: OrganizationReason
        let rootID: String
        let resources: [ScannedResourceReport]
        let timestampStem: String?
    }

    private struct ResourceKey: Hashable {
        let rootID: String
        let relativePath: String
    }

    public static func makePlan(from report: ScanReport) -> OrganizationPlan {
        let rootsByID = Dictionary(uniqueKeysWithValues: report.roots.map { ($0.rootID, $0) })
        let resourcesByKey = Dictionary(uniqueKeysWithValues: report.resources.map {
            (ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath), $0)
        })
        let eligibleRootIDs = Set(report.roots.filter {
            $0.provenance == .localLibrary || $0.provenance == .appleDirect
        }.map(\.rootID))

        var handled = Set<ResourceKey>()
        var drafts: [Draft] = []

        for asset in report.livePhotos {
            let eligibleOccurrences = asset.occurrences.filter { eligibleRootIDs.contains($0.rootID) }
            let occurrenceCountsByRoot = Dictionary(grouping: eligibleOccurrences, by: \.rootID)
                .mapValues(\.count)
            for occurrence in eligibleOccurrences {
                let occurrenceResources = occurrence.resources.compactMap {
                    resourcesByKey[ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath)]
                }
                handled.formUnion(occurrence.resources.map {
                    ResourceKey(rootID: $0.rootID, relativePath: $0.relativePath)
                })

                if occurrenceCountsByRoot[occurrence.rootID, default: 0] > 1 {
                    drafts.append(Draft(
                        assetID: asset.assetID,
                        kind: .livePhoto,
                        decision: .review,
                        reason: .multiplePhysicalRepresentations,
                        rootID: occurrence.rootID,
                        resources: occurrenceResources,
                        timestampStem: nil
                    ))
                    continue
                }

                guard occurrence.status == .complete,
                      occurrenceResources.count == occurrence.resources.count,
                      occurrenceResources.count == 2
                else {
                    drafts.append(Draft(
                        assetID: asset.assetID,
                        kind: .livePhoto,
                        decision: .review,
                        reason: .incompleteLivePhoto,
                        rootID: occurrence.rootID,
                        resources: occurrenceResources,
                        timestampStem: nil
                    ))
                    continue
                }

                if isAlreadyOrganizedLivePhoto(occurrenceResources) {
                    continue
                }

                guard occurrenceResources.allSatisfy({ isAppleCameraFilename($0.fileName) }) else {
                    drafts.append(Draft(
                        assetID: asset.assetID,
                        kind: .livePhoto,
                        decision: .review,
                        reason: .customFilenamePreserved,
                        rootID: occurrence.rootID,
                        resources: occurrenceResources,
                        timestampStem: nil
                    ))
                    continue
                }

                guard let stem = preferredTimestampStem(occurrenceResources) else {
                    drafts.append(Draft(
                        assetID: asset.assetID,
                        kind: .livePhoto,
                        decision: .review,
                        reason: .captureTimeNotTrusted,
                        rootID: occurrence.rootID,
                        resources: occurrenceResources,
                        timestampStem: nil
                    ))
                    continue
                }

                drafts.append(Draft(
                    assetID: asset.assetID,
                    kind: .livePhoto,
                    decision: .automatic,
                    reason: .cameraNameAndCaptureWallClock,
                    rootID: occurrence.rootID,
                    resources: occurrenceResources,
                    timestampStem: stem
                ))
            }
        }

        let standaloneCandidates = report.resources.filter { resource in
            eligibleRootIDs.contains(resource.rootID)
                && resource.mediaKind != .sidecar
                && !handled.contains(ResourceKey(rootID: resource.rootID, relativePath: resource.relativePath))
        }
        let standaloneByAsset = Dictionary(grouping: standaloneCandidates) { $0.assetID ?? $0.resourceID }
        for (assetID, group) in standaloneByAsset {
            if group.count != 1 {
                drafts.append(Draft(
                    assetID: assetID,
                    kind: .standalone,
                    decision: .review,
                    reason: .multiplePhysicalRepresentations,
                    rootID: group[0].rootID,
                    resources: group,
                    timestampStem: nil
                ))
                continue
            }
            let resource = group[0]
            guard isAppleCameraFilename(resource.fileName) else {
                continue
            }
            guard let stem = timestampStem(resource.captureTime) else {
                drafts.append(Draft(
                    assetID: assetID,
                    kind: .standalone,
                    decision: .review,
                    reason: .captureTimeNotTrusted,
                    rootID: resource.rootID,
                    resources: [resource],
                    timestampStem: nil
                ))
                continue
            }
            drafts.append(Draft(
                assetID: assetID,
                kind: .standalone,
                decision: .automatic,
                reason: .cameraNameAndCaptureWallClock,
                rootID: resource.rootID,
                resources: [resource],
                timestampStem: stem
            ))
        }

        drafts.sort {
            ($0.rootID, $0.timestampStem ?? "~", $0.assetID, $0.kind.rawValue)
                < ($1.rootID, $1.timestampStem ?? "~", $1.assetID, $1.kind.rawValue)
        }

        var nextSuffixByRootAndStem: [String: Int] = [:]
        var reservedDestinations = Set<ResourceKey>()
        for resource in report.resources {
            reservedDestinations.insert(ResourceKey(rootID: resource.rootID, relativePath: resource.relativePath))
        }

        var items: [OrganizationPlanItem] = []
        for (offset, draft) in drafts.enumerated() {
            var moves: [OrganizationMove] = []
            if draft.decision == .automatic, let baseStem = draft.timestampStem {
                let counterKey = draft.rootID + "\u{0}" + baseStem
                var suffix = nextSuffixByRootAndStem[counterKey, default: 0]
                var destinations: [String] = []
                while true {
                    let stem = suffix == 0 ? baseStem : String(format: "%@_%02d", baseStem, suffix)
                    destinations = draft.resources.map { resource in
                        stem + "." + (resource.fileName as NSString).pathExtension.lowercased()
                    }
                    let collision = destinations.contains { destination in
                        let key = ResourceKey(rootID: draft.rootID, relativePath: destination)
                        guard reservedDestinations.contains(key) else { return false }
                        return !draft.resources.contains { $0.relativePath == destination }
                    }
                    if !collision, Set(destinations).count == destinations.count { break }
                    suffix += 1
                }
                nextSuffixByRootAndStem[counterKey] = suffix + 1
                for (resource, destination) in zip(draft.resources, destinations) {
                    reservedDestinations.insert(ResourceKey(rootID: draft.rootID, relativePath: destination))
                    moves.append(OrganizationMove(
                        resourceID: resource.resourceID,
                        rootID: resource.rootID,
                        role: resource.role,
                        sourceRelativePath: resource.relativePath,
                        destinationRelativePath: destination
                    ))
                }
            } else {
                moves = draft.resources.map {
                    OrganizationMove(
                        resourceID: $0.resourceID,
                        rootID: $0.rootID,
                        role: $0.role,
                        sourceRelativePath: $0.relativePath,
                        destinationRelativePath: $0.relativePath
                    )
                }
            }

            items.append(OrganizationPlanItem(
                itemID: String(format: "O%06d", offset + 1),
                assetID: draft.assetID,
                kind: draft.kind,
                decision: draft.decision,
                reason: draft.reason,
                moves: moves
            ))
        }

        let automatic = items.filter { $0.decision == .automatic }
        let review = items.filter { $0.decision == .review }
        _ = rootsByID
        return OrganizationPlan(
            schemaVersion: 1,
            policy: "iphone_camera_capture_time_flatten_v1",
            sessionID: report.sessionID,
            summary: OrganizationPlanSummary(
                automaticItemCount: automatic.count,
                reviewItemCount: review.count,
                automaticResourceCount: automatic.reduce(0) { $0 + $1.moves.count },
                reviewResourceCount: review.reduce(0) { $0 + $1.moves.count }
            ),
            items: items,
            filesModified: false
        )
    }

    private static func isAlreadyOrganizedLivePhoto(_ resources: [ScannedResourceReport]) -> Bool {
        guard resources.count == 2,
              Set(resources.map(\.role)) == Set([ResourceRole.photo, ResourceRole.pairedVideo]),
              resources.allSatisfy({ ($0.relativePath as NSString).deletingLastPathComponent.isEmpty }),
              let expectedStem = preferredTimestampStem(resources)
        else {
            return false
        }

        let stems = Set(resources.map { ($0.fileName as NSString).deletingPathExtension })
        guard stems.count == 1, let actualStem = stems.first else { return false }
        if actualStem == expectedStem { return true }

        let prefix = expectedStem + "_"
        guard actualStem.hasPrefix(prefix) else { return false }
        let suffix = actualStem.dropFirst(prefix.count)
        return suffix.count >= 2 && suffix.allSatisfy(\.isNumber)
    }

    private static func preferredTimestampStem(_ resources: [ScannedResourceReport]) -> String? {
        let ordered = resources.sorted {
            let lhsRank = $0.role == .photo ? 0 : 1
            let rhsRank = $1.role == .photo ? 0 : 1
            return (lhsRank, $0.resourceID) < (rhsRank, $1.resourceID)
        }
        return ordered.compactMap { timestampStem($0.captureTime) }.first
    }

    private static func timestampStem(_ captureTime: CaptureTime?) -> String? {
        guard let captureTime,
              let local = captureTime.localTimestamp
        else {
            return nil
        }
        let acceptableWallClock = captureTime.confidence == .trusted
            || (captureTime.source == .exifDateTimeOriginal
                && captureTime.confidence == .incompleteTimezone)
        guard acceptableWallClock else { return nil }
        let pattern = #"(\d{4})[-:](\d{2})[-:](\d{2})[T ](\d{2}):(\d{2}):(\d{2})"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: local,
                range: NSRange(local.startIndex..., in: local)
              ),
              match.numberOfRanges == 7
        else {
            return nil
        }
        let values = (1...6).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: local) else { return nil }
            return String(local[range])
        }
        guard values.count == 6 else { return nil }
        return "\(values[0])-\(values[1])-\(values[2])_\(values[3])-\(values[4])-\(values[5])"
    }

    private static func isAppleCameraFilename(_ fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension
        let pattern = #"^IMG_(?:E)?\d{4}$"#
        return stem.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
