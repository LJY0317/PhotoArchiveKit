import Foundation

struct CanonicalResourceKey: Hashable {
    let rootID: String
    let relativePath: String
}

enum CanonicalKeeperPolicy {
    static func key(_ resource: ResourceReference) -> CanonicalResourceKey {
        CanonicalResourceKey(rootID: resource.rootID, relativePath: resource.relativePath)
    }

    static func isProtectedReplicaRoot(_ root: RootScanReport?) -> Bool {
        guard let root else { return true }
        return root.kind == .archive || root.kind == .reference
    }

    static func isPrimaryLibraryRoot(_ root: RootScanReport?) -> Bool {
        guard let root else { return false }
        return root.kind == .inbox && root.provenance == .localLibrary
    }

    static func isImportCleanupRoot(_ root: RootScanReport?) -> Bool {
        guard let root else { return false }
        if isProtectedReplicaRoot(root) || isPrimaryLibraryRoot(root) { return false }
        return root.kind == .importSource
            || root.provenance == .googleTakeout
            || root.provenance == .googleWeb
            || root.provenance == .googleIOSShare
            || root.provenance == .appleDirect
    }

    static func preferredResource(
        _ lhs: ResourceReference,
        before rhs: ResourceReference,
        rootsByID: [String: RootScanReport],
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport]
    ) -> Bool {
        let lhsScore = resourceScore(lhs, rootsByID: rootsByID, resourcesByKey: resourcesByKey)
        let rhsScore = resourceScore(rhs, rootsByID: rootsByID, resourcesByKey: resourcesByKey)
        if lhsScore.rootRank != rhsScore.rootRank { return lhsScore.rootRank < rhsScore.rootRank }
        if lhsScore.captureRank != rhsScore.captureRank { return lhsScore.captureRank < rhsScore.captureRank }
        if lhsScore.pathDepth != rhsScore.pathDepth { return lhsScore.pathDepth < rhsScore.pathDepth }
        return (lhs.rootID, lhs.relativePath, lhs.role.rawValue)
            < (rhs.rootID, rhs.relativePath, rhs.role.rawValue)
    }

    static func preferredOccurrence(
        _ lhs: LivePhotoOccurrenceReport,
        before rhs: LivePhotoOccurrenceReport,
        rootsByID: [String: RootScanReport],
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport]
    ) -> Bool {
        let lhsScore = occurrenceScore(lhs, rootsByID: rootsByID, resourcesByKey: resourcesByKey)
        let rhsScore = occurrenceScore(rhs, rootsByID: rootsByID, resourcesByKey: resourcesByKey)
        if lhsScore.statusRank != rhsScore.statusRank { return lhsScore.statusRank < rhsScore.statusRank }
        if lhsScore.rootRank != rhsScore.rootRank { return lhsScore.rootRank < rhsScore.rootRank }
        if lhsScore.captureRank != rhsScore.captureRank { return lhsScore.captureRank < rhsScore.captureRank }
        if lhsScore.pathDepth != rhsScore.pathDepth { return lhsScore.pathDepth < rhsScore.pathDepth }
        return occurrenceStableKey(lhs) < occurrenceStableKey(rhs)
    }

    private struct ResourceScore {
        let rootRank: Int
        let captureRank: Int
        let pathDepth: Int
    }

    private struct OccurrenceScore {
        let statusRank: Int
        let rootRank: Int
        let captureRank: Int
        let pathDepth: Int
    }

    private static func resourceScore(
        _ resource: ResourceReference,
        rootsByID: [String: RootScanReport],
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport]
    ) -> ResourceScore {
        ResourceScore(
            rootRank: rootRank(rootsByID[resource.rootID]),
            captureRank: captureRank(resourcesByKey[key(resource)]?.captureTime),
            pathDepth: pathDepth(resource.relativePath)
        )
    }

    private static func occurrenceScore(
        _ occurrence: LivePhotoOccurrenceReport,
        rootsByID: [String: RootScanReport],
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport]
    ) -> OccurrenceScore {
        let captureRanks = occurrence.resources.map {
            captureRank(resourcesByKey[key($0)]?.captureTime)
        }
        return OccurrenceScore(
            statusRank: statusRank(occurrence.status),
            rootRank: rootRank(rootsByID[occurrence.rootID]),
            captureRank: captureRanks.max() ?? Int.max,
            pathDepth: occurrence.resources.map { pathDepth($0.relativePath) }.min() ?? Int.max
        )
    }

    private static func rootRank(_ root: RootScanReport?) -> Int {
        guard let root else { return 100 }
        if isPrimaryLibraryRoot(root) { return 0 }
        if root.kind == .archive { return 1 }
        if root.kind == .reference { return 2 }
        switch root.provenance {
        case .appleDirect: return 3
        case .googleWeb: return 4
        case .unknown: return 5
        case .googleIOSShare: return 6
        case .googleTakeout: return 7
        case .localLibrary: return 8
        }
    }

    private static func captureRank(_ capture: CaptureTime?) -> Int {
        guard let capture else { return 5 }
        switch capture.confidence {
        case .trusted: return 0
        case .providerSidecar: return 1
        case .incompleteTimezone: return 2
        case .fallback: return 3
        case .unknown: return 4
        }
    }

    private static func statusRank(_ status: LivePhotoOccurrenceStatus) -> Int {
        switch status {
        case .complete: return 0
        case .stillOnly, .videoOnly: return 1
        case .stillImageTimeMissing, .stillImageTimeInvalid, .stillImageTimeUnreadable: return 2
        case .multipleStills, .multipleVideos, .multipleVariants: return 3
        }
    }

    private static func pathDepth(_ relativePath: String) -> Int {
        max((relativePath as NSString).pathComponents.count - 1, 0)
    }

    private static func occurrenceStableKey(_ occurrence: LivePhotoOccurrenceReport) -> String {
        let firstPath = occurrence.resources.map(\.relativePath).sorted().first ?? ""
        return occurrence.rootID + "\u{0}" + firstPath
    }
}
