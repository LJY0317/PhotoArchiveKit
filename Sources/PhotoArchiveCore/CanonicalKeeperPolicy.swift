import Foundation

struct CanonicalResourceKey: Hashable {
    let rootID: String
    let relativePath: String
}

enum CanonicalKeeperPolicy {
    enum PreferenceRationale: String, Sendable {
        case protectedOrPreferredRoot = "preferred_root_role"
        case cleanerFilename = "cleaner_filename"
        case recognizableFilename = "recognizable_filename"
        case matchingParentFolder = "matching_parent_folder"
        case strongerCaptureEvidence = "stronger_capture_evidence"
        case shallowerPath = "shallower_path"
        case deterministicTieBreak = "deterministic_tie_break"
    }

    enum ReviewStrength: String, Sendable {
        case strong
        case preference
    }

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
        if lhsScore.explicitCopyMarkerRank != rhsScore.explicitCopyMarkerRank {
            return lhsScore.explicitCopyMarkerRank < rhsScore.explicitCopyMarkerRank
        }
        let copyPreference = pairwiseCopyPreference(lhs, rhs)
        if copyPreference != 0 { return copyPreference < 0 }
        if lhsScore.filenameRank != rhsScore.filenameRank { return lhsScore.filenameRank < rhsScore.filenameRank }
        let parentPreference = pairwiseParentFolderPreference(lhs, rhs)
        if parentPreference != 0 { return parentPreference < 0 }
        if lhsScore.captureRank != rhsScore.captureRank { return lhsScore.captureRank < rhsScore.captureRank }
        if lhsScore.pathDepth != rhsScore.pathDepth { return lhsScore.pathDepth < rhsScore.pathDepth }
        return (lhs.rootID, lhs.relativePath, lhs.role.rawValue)
            < (rhs.rootID, rhs.relativePath, rhs.role.rawValue)
    }

    static func preferenceRationale(
        preferred: ResourceReference,
        candidate: ResourceReference,
        rootsByID: [String: RootScanReport],
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport]
    ) -> PreferenceRationale {
        let preferredScore = resourceScore(
            preferred,
            rootsByID: rootsByID,
            resourcesByKey: resourcesByKey
        )
        let candidateScore = resourceScore(
            candidate,
            rootsByID: rootsByID,
            resourcesByKey: resourcesByKey
        )
        if preferredScore.rootRank != candidateScore.rootRank { return .protectedOrPreferredRoot }
        if preferredScore.explicitCopyMarkerRank != candidateScore.explicitCopyMarkerRank {
            return .cleanerFilename
        }
        if pairwiseCopyPreference(preferred, candidate) != 0 { return .cleanerFilename }
        if preferredScore.filenameRank != candidateScore.filenameRank { return .recognizableFilename }
        if pairwiseParentFolderPreference(preferred, candidate) != 0 { return .matchingParentFolder }
        if preferredScore.captureRank != candidateScore.captureRank { return .strongerCaptureEvidence }
        if preferredScore.pathDepth != candidateScore.pathDepth { return .shallowerPath }
        return .deterministicTieBreak
    }

    static func reviewStrength(
        item: ReconciliationPlanItem,
        rootsByID: [String: RootScanReport],
        resourcesByKey: [CanonicalResourceKey: ScannedResourceReport]
    ) -> ReviewStrength {
        switch item.reason {
        case .canonicalLocalLivePhotoOccurrence,
                .preferredNonTakeoutExactCopy,
                .livePhotoCanonicalCoverage,
                .livePhotoIncompleteOccurrenceExactCoverage,
                .takeoutSourceFolderSemanticsCaptured:
            return .strong
        case .canonicalExactCopy,
                .noCompletePreferredLivePhoto,
                .uncoveredLivePhotoVariant,
                .takeoutCollectionSemanticsPending:
            break
        }
        guard item.preferredResources.count == 1,
              let preferred = item.preferredResources.first
        else {
            return .preference
        }
        for candidate in item.candidateResources {
            switch preferenceRationale(
                preferred: preferred,
                candidate: candidate,
                rootsByID: rootsByID,
                resourcesByKey: resourcesByKey
            ) {
            case .protectedOrPreferredRoot, .cleanerFilename, .recognizableFilename,
                    .matchingParentFolder, .shallowerPath:
                continue
            case .strongerCaptureEvidence, .deterministicTieBreak:
                return .preference
            }
        }
        return .strong
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
        let explicitCopyMarkerRank: Int
        let filenameRank: Int
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
            explicitCopyMarkerRank: hasExplicitCopyMarker(filenameStem(resource.relativePath)) ? 1 : 0,
            filenameRank: filenameRank(resource.relativePath),
            captureRank: captureRank(resourcesByKey[key(resource)]?.captureTime),
            pathDepth: pathDepth(resource.relativePath)
        )
    }

    private static func pairwiseCopyPreference(
        _ lhs: ResourceReference,
        _ rhs: ResourceReference
    ) -> Int {
        let lhsName = filenameStem(lhs.relativePath)
        let rhsName = filenameStem(rhs.relativePath)
        let lhsDerived = copyBaseName(lhsName).map { normalizedName($0) == normalizedName(rhsName) } ?? false
        let rhsDerived = copyBaseName(rhsName).map { normalizedName($0) == normalizedName(lhsName) } ?? false
        if lhsDerived == rhsDerived { return 0 }
        return lhsDerived ? 1 : -1
    }

    private static func filenameRank(_ relativePath: String) -> Int {
        let stem = filenameStem(relativePath)
        let normalized = normalizedName(stem)
        if isRecognizableSourceName(normalized) { return 0 }
        if isOpaqueGeneratedName(normalized) { return 2 }
        return 1
    }

    private static func pairwiseParentFolderPreference(
        _ lhs: ResourceReference,
        _ rhs: ResourceReference
    ) -> Int {
        let lhsStructured = hasMatchingParentFolder(lhs.relativePath)
        let rhsStructured = hasMatchingParentFolder(rhs.relativePath)
        let lhsPlaceholder = hasPlaceholderParentFolder(lhs.relativePath)
        let rhsPlaceholder = hasPlaceholderParentFolder(rhs.relativePath)

        if lhsStructured && rhsPlaceholder && !rhsStructured { return -1 }
        if rhsStructured && lhsPlaceholder && !lhsStructured { return 1 }
        return 0
    }

    private static func hasMatchingParentFolder(_ relativePath: String) -> Bool {
        let path = relativePath as NSString
        let parent = (path.deletingLastPathComponent as NSString).lastPathComponent
        guard !parent.isEmpty, parent != "." else { return false }
        return normalizedName(parent) == normalizedName(filenameStem(relativePath))
    }

    private static func hasPlaceholderParentFolder(_ relativePath: String) -> Bool {
        let path = relativePath as NSString
        let parent = normalizedName((path.deletingLastPathComponent as NSString).lastPathComponent)
        let placeholders: Set<String> = [
            "무제 폴더",
            "untitled folder",
            "새 폴더",
            "새폴더",
            "new folder"
        ]
        return placeholders.contains(parent)
    }

    private static func filenameStem(_ relativePath: String) -> String {
        let name = (relativePath as NSString).lastPathComponent as NSString
        return name.deletingPathExtension
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func copyBaseName(_ stem: String) -> String? {
        let patterns = [
            #"(?i)^(.*?)(?:[ _-]+copy)$"#,
            #"^(.*?)(?:[ _-]+복사본)$"#,
            #"^(.*?)(?:[ _-]+사본)$"#,
            #"^(.*?)(?: \([1-9][0-9]*\))$"#,
            #"^(.*?)(?: [1-9][0-9]*)$"#
        ]
        let fullRange = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: stem, range: fullRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: stem)
            else {
                continue
            }
            let base = String(stem[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty { return base }
        }
        return nil
    }

    private static func hasExplicitCopyMarker(_ stem: String) -> Bool {
        let normalized = normalizedName(stem)
        let patterns = [
            #"(?:^|[ _-])copy$"#,
            #"(?:^|[ _-])duplicate$"#,
            #"(?:^|[ _-])복사본$"#,
            #"(?:^|[ _-])사본$"#
        ]
        return patterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
    }

    private static func isRecognizableSourceName(_ stem: String) -> Bool {
        let patterns = [
            #"^img_e?[0-9]{4,6}(?:[ _-].*)?$"#,
            #"^kakaotalk[_ -]photo[_ -].+$"#,
            #"^photo on .+$"#,
            #"^screenshot[ _-].+$"#,
            #"^[12][0-9]{3}[-_]?[01][0-9][-_]?[0-3][0-9].*$"#
        ]
        return patterns.contains { stem.range(of: $0, options: .regularExpression) != nil }
    }

    private static func isOpaqueGeneratedName(_ stem: String) -> Bool {
        if stem.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return stem.range(of: #"^[0-9a-f]{24,}$"#, options: .regularExpression) != nil
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
