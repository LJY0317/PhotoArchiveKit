import Darwin
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
    public let currentItemCount: Int
    public let staleItemCount: Int
    public let offlineItemCount: Int
    public let keeperLinkCount: Int
    public let candidateLinkCount: Int
    public let workspacePath: String
    public let mediaFilesModified: Bool
}

public struct AgentSafeDuplicateReviewWorkspaceReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let privacyMode: String
    public let itemCount: Int
    public let currentItemCount: Int
    public let staleItemCount: Int
    public let offlineItemCount: Int
    public let keeperLinkCount: Int
    public let candidateLinkCount: Int
    public let mediaFilesModified: Bool

    public init(report: DuplicateReviewWorkspaceReport) {
        schemaVersion = report.schemaVersion
        privacyMode = "agent_safe"
        itemCount = report.itemCount
        currentItemCount = report.currentItemCount
        staleItemCount = report.staleItemCount
        offlineItemCount = report.offlineItemCount
        keeperLinkCount = report.keeperLinkCount
        candidateLinkCount = report.candidateLinkCount
        mediaFilesModified = report.mediaFilesModified
    }
}

public enum DuplicateReviewWorkspace {
    private enum FreshnessStatus: String {
        case current = "CURRENT"
        case stale = "STALE"
        case offline = "OFFLINE"
    }

    private struct ResourceFreshness {
        let status: FreshnessStatus
        let sourceURL: URL?
        let reason: String?
    }

    private struct RootFreshness {
        let status: FreshnessStatus
        let reason: String?
    }

    private struct ReviewFileFacts {
        let fileName: String
        let parentRelativePath: String
        let byteSize: Int64
        let creationDate: Date?
        let modificationDate: Date?
        let fileSystemIdentifier: String?
        let captureTime: CaptureTime?
        let extendedAttributes: [String: Data]?
    }

    public static func create(
        report: ScanReport,
        plan: ReconciliationPlan,
        outputURL rawOutputURL: URL,
        candidateRootTarget: String? = nil,
        preferenceOnly: Bool = false,
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

        let initiallySelectedItems = plan.items.filter { item in
            guard item.decision == .automaticRedundant, !item.candidateResources.isEmpty else {
                return false
            }
            guard let candidateRootID else { return true }
            return item.candidateResources.allSatisfy { $0.rootID == candidateRootID }
        }

        let scannedResourcesByKey = Dictionary(uniqueKeysWithValues: report.resources.map {
            (CanonicalResourceKey(rootID: $0.rootID, relativePath: $0.relativePath), $0)
        })
        let selectedItems = initiallySelectedItems.filter { item in
            guard preferenceOnly else { return true }
            return CanonicalKeeperPolicy.reviewStrength(
                item: item,
                rootsByID: rootsByID,
                resourcesByKey: scannedResourcesByKey
            ) == .preference
        }
        let selectedResources = selectedItems.flatMap { $0.preferredResources + $0.candidateResources }
        let selectedResourceIDs = selectedResources.compactMap {
            scannedResourcesByKey[CanonicalKeeperPolicy.key($0)]?.resourceID
        }
        let catalog = try SQLiteCatalog(url: URL(fileURLWithPath: report.catalogPath))
        let expectedEvidenceByResourceID = try catalog.duplicateReviewExpectedResourceEvidence(
            resourceIDs: selectedResourceIDs
        )
        let involvedRootIDs = Set(selectedResources.map(\.rootID))
        var rootFreshnessByID: [String: RootFreshness] = [:]
        for rootID in involvedRootIDs {
            guard let root = rootsByID[rootID] else {
                throw DuplicateReviewWorkspaceError.sourceRootMissing(rootID)
            }
            rootFreshnessByID[rootID] = rootFreshness(
                root: root,
                fileManager: fileManager
            )
        }

        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        do {
            try writeReadme(to: outputURL)

            var keeperLinkCount = 0
            var candidateLinkCount = 0
            var currentItemCount = 0
            var staleItemCount = 0
            var offlineItemCount = 0
            for (offset, item) in selectedItems.enumerated() {
                let allResources = item.preferredResources + item.candidateResources
                let freshnessByKey = Dictionary(uniqueKeysWithValues: allResources.map { resource in
                    let key = CanonicalKeeperPolicy.key(resource)
                    let scanned = scannedResourcesByKey[key]
                    let expected = scanned.flatMap { expectedEvidenceByResourceID[$0.resourceID] }
                    let freshness = resourceFreshness(
                        resource: resource,
                        root: rootsByID[resource.rootID],
                        rootFreshness: rootFreshnessByID[resource.rootID],
                        expectedEvidence: expected,
                        fileManager: fileManager
                    )
                    return (key, freshness)
                })
                let itemStatus = aggregateStatus(Array(freshnessByKey.values))
                switch itemStatus {
                case .current: currentItemCount += 1
                case .stale: staleItemCount += 1
                case .offline: offlineItemCount += 1
                }
                let groupURL = outputURL.appendingPathComponent(
                    String(
                        format: "%03d-%@-%@-%@",
                        offset + 1,
                        itemStatus.rawValue,
                        item.kind.rawValue,
                        item.itemID
                    ),
                    isDirectory: true
                )
                let keeperDirectoryName = itemStatus == .current ? "KEEPER" : "OLD_KEEPER"
                let candidateDirectoryName = itemStatus == .current ? "CANDIDATE" : "OLD_CANDIDATE"
                let keeperURL = groupURL.appendingPathComponent(keeperDirectoryName, isDirectory: true)
                let candidateURL = groupURL.appendingPathComponent(candidateDirectoryName, isDirectory: true)
                try fileManager.createDirectory(at: keeperURL, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: candidateURL, withIntermediateDirectories: true)

                var locationLines: [String] = [
                    "status: \(itemStatus.rawValue)",
                    "reason: \(item.reason.rawValue)",
                    "kind: \(item.kind.rawValue)",
                    ""
                ]

                for (index, resource) in item.preferredResources.enumerated() {
                    let freshness = freshnessByKey[CanonicalKeeperPolicy.key(resource)]!
                    if let sourceURL = freshness.sourceURL {
                        try createLink(
                            sourceURL: sourceURL,
                            in: keeperURL,
                            prefix: String(format: "%@-%02d", keeperDirectoryName, index + 1),
                            fileManager: fileManager
                        )
                        keeperLinkCount += 1
                        locationLines.append("[\(keeperDirectoryName)] \(sourceURL.path)")
                    }
                    if let reason = freshness.reason {
                        locationLines.append("  freshness: \(reason)")
                    }
                }

                for (index, resource) in item.candidateResources.enumerated() {
                    let freshness = freshnessByKey[CanonicalKeeperPolicy.key(resource)]!
                    if let sourceURL = freshness.sourceURL {
                        try createLink(
                            sourceURL: sourceURL,
                            in: candidateURL,
                            prefix: String(format: "%@-%02d", candidateDirectoryName, index + 1),
                            fileManager: fileManager
                        )
                        candidateLinkCount += 1
                        locationLines.append("[\(candidateDirectoryName)] \(sourceURL.path)")
                    }
                    if let reason = freshness.reason {
                        locationLines.append("  freshness: \(reason)")
                    }
                }

                let locationsURL = groupURL.appendingPathComponent("locations.txt")
                try (locationLines.joined(separator: "\n") + "\n")
                    .write(to: locationsURL, atomically: true, encoding: .utf8)
                try writeComparison(
                    item: item,
                    status: itemStatus,
                    rootsByID: rootsByID,
                    scannedResourcesByKey: scannedResourcesByKey,
                    freshnessByKey: freshnessByKey,
                    groupURL: groupURL,
                    fileManager: fileManager
                )
                if itemStatus != .current {
                    try writeNeedsRefresh(status: itemStatus, to: groupURL)
                }
            }

            return DuplicateReviewWorkspaceReport(
                schemaVersion: 3,
                itemCount: selectedItems.count,
                currentItemCount: currentItemCount,
                staleItemCount: staleItemCount,
                offlineItemCount: offlineItemCount,
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

    private static func rootFreshness(
        root: RootScanReport,
        fileManager: FileManager
    ) -> RootFreshness {
        let rootURL = URL(fileURLWithPath: root.canonicalPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return RootFreshness(status: .offline, reason: "root_offline")
        }
        guard isDirectory.boolValue else {
            return RootFreshness(status: .stale, reason: "root_is_not_directory")
        }
        if let expectedMarker = root.stableMarkerKey {
            do {
                guard try RootMarkerStore.readIfPresent(at: rootURL)?.markerKey == expectedMarker else {
                    return RootFreshness(status: .stale, reason: "root_marker_changed")
                }
            } catch {
                return RootFreshness(status: .stale, reason: "root_marker_unreadable")
            }
        } else if rootURL.resolvingSymlinksInPath().standardizedFileURL.path != rootURL.path {
            return RootFreshness(status: .stale, reason: "unmarked_root_identity_changed")
        }
        return RootFreshness(status: .current, reason: nil)
    }

    private static func resourceFreshness(
        resource: ResourceReference,
        root: RootScanReport?,
        rootFreshness: RootFreshness?,
        expectedEvidence: DuplicateReviewExpectedResourceEvidence?,
        fileManager: FileManager
    ) -> ResourceFreshness {
        guard let root else {
            return ResourceFreshness(status: .stale, sourceURL: nil, reason: "root_missing_from_snapshot")
        }
        if rootFreshness?.status == .offline {
            return ResourceFreshness(status: .offline, sourceURL: nil, reason: rootFreshness?.reason)
        }
        if rootFreshness?.status == .stale {
            return ResourceFreshness(status: .stale, sourceURL: nil, reason: rootFreshness?.reason)
        }

        let rootURL = URL(fileURLWithPath: root.canonicalPath).standardizedFileURL
        let sourceURL = rootURL.appendingPathComponent(resource.relativePath).standardizedFileURL
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard sourceURL.path.hasPrefix(prefix),
              !resource.relativePath.split(separator: "/").contains("..")
        else {
            return ResourceFreshness(status: .stale, sourceURL: nil, reason: "unsafe_relative_path")
        }
        guard let expectedEvidence,
              expectedEvidence.rootID == resource.rootID,
              expectedEvidence.relativePath == resource.relativePath
        else {
            return ResourceFreshness(status: .stale, sourceURL: nil, reason: "catalog_evidence_missing")
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        guard let values = try? sourceURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            if fileManager.fileExists(atPath: sourceURL.path) {
                return ResourceFreshness(status: .stale, sourceURL: sourceURL, reason: "not_regular_file")
            }
            return ResourceFreshness(status: .stale, sourceURL: nil, reason: "file_missing")
        }
        guard let fileSize = values.fileSize,
              Int64(fileSize) == resource.byteSize,
              Int64(fileSize) == expectedEvidence.byteSize
        else {
            return ResourceFreshness(status: .stale, sourceURL: sourceURL, reason: "size_changed")
        }
        guard let currentModifiedAt = values.contentModificationDate,
              let expectedModifiedAt = expectedEvidence.modifiedAt,
              abs(currentModifiedAt.timeIntervalSince1970 - expectedModifiedAt.timeIntervalSince1970) < 0.001
        else {
            return ResourceFreshness(status: .stale, sourceURL: sourceURL, reason: "modification_time_changed")
        }
        if let expectedID = expectedEvidence.fileSystemIdentifier {
            guard let currentID = values.fileResourceIdentifier.map({ String(describing: $0) }),
                  currentID == expectedID
            else {
                return ResourceFreshness(status: .stale, sourceURL: sourceURL, reason: "filesystem_id_changed")
            }
        }
        return ResourceFreshness(status: .current, sourceURL: sourceURL, reason: nil)
    }

    private static func aggregateStatus(_ freshness: [ResourceFreshness]) -> FreshnessStatus {
        if freshness.contains(where: { $0.status == .offline }) { return .offline }
        if freshness.contains(where: { $0.status == .stale }) { return .stale }
        return .current
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

    private static func writeComparison(
        item: ReconciliationPlanItem,
        status: FreshnessStatus,
        rootsByID: [String: RootScanReport],
        scannedResourcesByKey: [CanonicalResourceKey: ScannedResourceReport],
        freshnessByKey: [CanonicalResourceKey: ResourceFreshness],
        groupURL: URL,
        fileManager: FileManager
    ) throws {
        var lines: [String] = [
            "PhotoArchiveKit 중복 파일 비교",
            "",
            "상태: \(localizedStatus(status))",
            "파일 내용 근거: 이 exact 중복 판정에서 대응되는 남길 후보/정리 후보 리소스는 바이트 단위로 완전히 동일합니다 (EXACT BYTES IDENTICAL).",
            "파일 내부 메타데이터: 대응되는 파일은 바이트가 동일하므로 파일 내부에 저장된 메타데이터도 동일합니다.",
            "중요: Finder가 이 review 폴더의 가상본(심볼릭 링크) 크기를 서로 다르게 표시할 수 있습니다. 이는 링크가 저장하는 대상 경로 길이 차이이며 미디어 화질이나 실제 원본 파일 크기 차이가 아닙니다.",
            "변경 작업 안전성: 이 review 결과만으로 파일을 삭제하거나 이동하지 않습니다. 실제 quarantine 직전에는 대상 파일의 바이트를 다시 검증합니다.",
            ""
        ]

        if item.kind == .livePhotoAsset,
           item.reason == .canonicalLocalLivePhotoOccurrence {
            lines.append("남길 후보 선택 이유: 강한 근거 — 완전한 Live Photo 조합을 보존합니다. exact 중복으로 확인된 불필요 리소스도 Live Photo 단위를 깨지 않는 범위에서만 정리 후보가 됩니다.")
        } else if item.preferredResources.count == 1,
                  let preferred = item.preferredResources.first {
            let rationales = item.candidateResources.map {
                CanonicalKeeperPolicy.preferenceRationale(
                    preferred: preferred,
                    candidate: $0,
                    rootsByID: rootsByID,
                    resourcesByKey: scannedResourcesByKey
                )
            }
            let unique = Array(Set(rationales.map(\.rawValue))).sorted()
            let strength = CanonicalKeeperPolicy.reviewStrength(
                item: item,
                rootsByID: rootsByID,
                resourcesByKey: scannedResourcesByKey
            )
            let localizedRationales = unique.compactMap {
                CanonicalKeeperPolicy.PreferenceRationale(rawValue: $0).map(localizedRationale)
            }
            lines.append("남길 후보 선택 이유: \(localizedStrength(strength)) — \(localizedRationales.joined(separator: ", "))")
            if rationales.allSatisfy({ $0 == .deterministicTieBreak }) {
                lines.append("해석: 사실상 동등한 사본 — PhotoArchiveKit이 현재 검사하는 출처·파일 정보에서는 어느 쪽을 우선할 만한 의미 있는 근거를 찾지 못했습니다. 현재 남길 후보/정리 후보 구분은 결과를 항상 일정하게 만들기 위한 기계적인 동률 해소일 뿐입니다.")
            }
        } else {
            lines.append("남길 후보 선택 이유: 여러 리소스를 함께 판단한 정책 결과입니다. 아래의 각 리소스 정보를 확인하세요.")
        }
        lines.append("")
        lines.append("현재 PhotoArchiveKit이 비교하는 메타데이터 범위:")
        lines.append("- 실제 원본 대상 파일의 바이트 크기")
        lines.append("- 파일 내부 메타데이터와 scan이 기록한 촬영 시각 근거")
        lines.append("- 파일명과 부모 폴더 경로")
        lines.append("- 파일시스템 생성 시각(birth time): 약한 출처 근거일 뿐 최초 생성·다운로드 시각의 증명은 아님")
        lines.append("- 파일시스템 수정 시각")
        lines.append("- 파일시스템 파일 식별자")
        lines.append("- 확장 속성(xattr): 이름과 값의 바이트를 로컬에서 비교하되 값 자체는 이 문서에 출력하지 않음")
        lines.append("- ACL, APFS snapshot, 백업 이력, 외부 클라우드/서비스 이력은 현재 비교 범위 밖")
        lines.append("")

        let preferredFacts = item.preferredResources.compactMap { resource -> (ResourceReference, ReviewFileFacts)? in
            let key = CanonicalKeeperPolicy.key(resource)
            guard let sourceURL = freshnessByKey[key]?.sourceURL else { return nil }
            return (
                resource,
                reviewFileFacts(
                    resource: resource,
                    scanned: scannedResourcesByKey[key],
                    sourceURL: sourceURL,
                    root: rootsByID[resource.rootID],
                    fileManager: fileManager
                )
            )
        }
        let candidateFacts = item.candidateResources.compactMap { resource -> (ResourceReference, ReviewFileFacts)? in
            let key = CanonicalKeeperPolicy.key(resource)
            guard let sourceURL = freshnessByKey[key]?.sourceURL else { return nil }
            return (
                resource,
                reviewFileFacts(
                    resource: resource,
                    scanned: scannedResourcesByKey[key],
                    sourceURL: sourceURL,
                    root: rootsByID[resource.rootID],
                    fileManager: fileManager
                )
            )
        }

        for (index, pair) in preferredFacts.enumerated() {
            lines.append(contentsOf: factLines(label: "남길 후보 (KEEPER) \(index + 1)", facts: pair.1))
        }
        for (index, pair) in candidateFacts.enumerated() {
            lines.append(contentsOf: factLines(label: "정리 후보 (CANDIDATE) \(index + 1)", facts: pair.1))
        }

        if preferredFacts.count == 1, candidateFacts.count == 1 {
            lines.append("비교 요약:")
            lines.append(contentsOf: comparisonLines(preferred: preferredFacts[0].1, candidate: candidateFacts[0].1))
        } else {
            lines.append("비교 요약: 여러 리소스로 구성된 그룹입니다. 위의 각 역할별 리소스를 함께 확인하세요. 완전한 Live Photo는 정리 후보에 대응 파일이 없는 paired video를 남길 후보 쪽에 의도적으로 더 포함할 수 있습니다.")
        }

        try (lines.joined(separator: "\n") + "\n").write(
            to: groupURL.appendingPathComponent("comparison.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func reviewFileFacts(
        resource: ResourceReference,
        scanned: ScannedResourceReport?,
        sourceURL: URL,
        root: RootScanReport?,
        fileManager: FileManager
    ) -> ReviewFileFacts {
        let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path)
        let rootURL = root.map { URL(fileURLWithPath: $0.canonicalPath).standardizedFileURL }
        let parentURL = sourceURL.deletingLastPathComponent().standardizedFileURL
        let parentRelativePath: String
        if let rootURL, parentURL.path == rootURL.path {
            parentRelativePath = "."
        } else if let rootURL {
            let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            parentRelativePath = parentURL.path.hasPrefix(prefix)
                ? String(parentURL.path.dropFirst(prefix.count))
                : parentURL.path
        } else {
            parentRelativePath = parentURL.path
        }
        return ReviewFileFacts(
            fileName: sourceURL.lastPathComponent,
            parentRelativePath: parentRelativePath,
            byteSize: (attributes?[.size] as? NSNumber)?.int64Value ?? resource.byteSize,
            creationDate: attributes?[.creationDate] as? Date,
            modificationDate: attributes?[.modificationDate] as? Date,
            fileSystemIdentifier: (attributes?[.systemFileNumber] as? NSNumber).map { String($0.uint64Value) },
            captureTime: scanned?.captureTime,
            extendedAttributes: extendedAttributes(at: sourceURL)
        )
    }

    private static func factLines(label: String, facts: ReviewFileFacts) -> [String] {
        [
            "\(label):",
            "  파일명: \(facts.fileName)",
            "  부모 폴더: \(facts.parentRelativePath)",
            "  실제 원본 대상 크기: \(facts.byteSize) 바이트",
            "  파일시스템 생성 시각: \(formatDate(facts.creationDate))",
            "  파일시스템 수정 시각: \(formatDate(facts.modificationDate))",
            "  scan 촬영 시각 근거: \(formatCaptureTime(facts.captureTime))",
            "  파일시스템 식별자: \(facts.fileSystemIdentifier ?? "확인 불가")",
            "  확장 속성(xattr) 개수: \(facts.extendedAttributes.map { String($0.count) } ?? "확인 불가")",
            ""
        ]
    }

    private static func comparisonLines(
        preferred: ReviewFileFacts,
        candidate: ReviewFileFacts
    ) -> [String] {
        var lines: [String] = []
        lines.append("- 실제 원본 대상 크기: \(preferred.byteSize == candidate.byteSize ? "동일" : "다름")")
        lines.append("- 파일명: \(preferred.fileName == candidate.fileName ? "동일" : "다름")")
        lines.append("- 부모 폴더 경로: \(preferred.parentRelativePath == candidate.parentRelativePath ? "동일" : "다름")")
        let preferredExtension = (preferred.fileName as NSString).pathExtension
        let candidateExtension = (candidate.fileName as NSString).pathExtension
        let extensionComparison: String
        if preferredExtension == candidateExtension {
            extensionComparison = "동일"
        } else if preferredExtension.lowercased() == candidateExtension.lowercased() {
            extensionComparison = "대소문자만 다름 (동일한 파일 형식)"
        } else {
            extensionComparison = "다름"
        }
        lines.append("- 파일 확장자: \(extensionComparison)")
        lines.append("- 파일시스템 생성 시각: \(dateComparison(preferred.creationDate, candidate.creationDate))")
        lines.append("- 파일시스템 수정 시각: \(dateComparison(preferred.modificationDate, candidate.modificationDate))")
        lines.append("- 파일 내부 메타데이터: 동일 (파일 바이트가 동일하므로 내부 메타데이터도 동일)")
        lines.append("- scan 촬영 시각 근거: \(captureComparison(preferred.captureTime, candidate.captureTime))")
        lines.append("- 파일시스템 식별자: \(preferred.fileSystemIdentifier == candidate.fileSystemIdentifier ? "동일" : "다름 (서로 다른 파일 객체라면 정상적인 차이)")")
        lines.append("- 확장 속성(xattr): \(extendedAttributeComparison(preferred.extendedAttributes, candidate.extendedAttributes))")

        let provenanceRelevantSame = preferred.byteSize == candidate.byteSize
            && preferred.fileName == candidate.fileName
            && preferred.parentRelativePath == candidate.parentRelativePath
            && datesMatch(preferred.creationDate, candidate.creationDate)
            && datesMatch(preferred.modificationDate, candidate.modificationDate)
            && preferred.captureTime == candidate.captureTime
            && preferred.extendedAttributes == candidate.extendedAttributes
        if provenanceRelevantSame {
            lines.append("- 결론: PhotoArchiveKit이 현재 검사하는 출처 관련 메타데이터 범위에서는 의미 있는 차이를 찾지 못했습니다. 두 항목은 파일시스템상 서로 다른 사본이지만, 현재 증거만으로 어느 쪽이 역사적인 원본인지 우선할 근거가 없습니다.")
        } else {
            lines.append("- 결론: 파일 내용은 바이트 단위로 동일하지만 파일시스템/출처 관련 메타데이터 중 하나 이상이 다릅니다. 이 차이는 어느 사본을 남길지 고르는 참고 근거가 될 수 있지만 화질·음질 차이를 뜻하지는 않습니다.")
        }
        return lines
    }

    private static func formatDate(_ date: Date?) -> String {
        guard let date else { return "확인 불가" }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func formatCaptureTime(_ capture: CaptureTime?) -> String {
        guard let capture else { return "확인 불가" }
        let instant = capture.instant.map { ISO8601DateFormatter().string(from: $0) } ?? "절대 시각 없음"
        if capture.source == .fileCreationDate {
            return "파일시스템 생성 시각을 fallback으로 사용 (파일 내부 촬영 시각 아님) / 신뢰도: \(localizedCaptureConfidence(capture.confidence)) / \(instant)"
        }
        return "\(localizedCaptureSource(capture.source)) / 신뢰도: \(localizedCaptureConfidence(capture.confidence)) / \(instant)"
    }

    private static func dateComparison(_ lhs: Date?, _ rhs: Date?) -> String {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil ? "양쪽 모두 확인 불가" : "한쪽만 확인 가능" }
        if datesMatch(lhs, rhs) { return "동일" }
        return lhs < rhs ? "남길 후보 쪽이 더 이른 시각" : "정리 후보 쪽이 더 이른 시각"
    }

    private static func captureComparison(_ lhs: CaptureTime?, _ rhs: CaptureTime?) -> String {
        if lhs?.source == .fileCreationDate || rhs?.source == .fileCreationDate {
            let relationship = dateComparison(lhs?.instant, rhs?.instant)
            return "파일시스템 생성 시각 fallback 포함 (파일 내부 촬영 메타데이터 차이라는 뜻이 아님); fallback 값 비교: \(relationship)"
        }
        return lhs == rhs ? "동일" : "다름"
    }

    private static func datesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 0.001
    }

    private static func extendedAttributeComparison(
        _ lhs: [String: Data]?,
        _ rhs: [String: Data]?
    ) -> String {
        guard let lhs, let rhs else { return "확인 불가" }
        if lhs == rhs { return "동일" }
        let lhsNames = Set(lhs.keys)
        let rhsNames = Set(rhs.keys)
        if lhsNames == rhsNames { return "속성 이름은 같지만 하나 이상의 값이 다름" }
        return "속성 집합 자체가 다름"
    }

    private static func localizedStatus(_ status: FreshnessStatus) -> String {
        switch status {
        case .current: return "현재 상태와 일치 (CURRENT)"
        case .stale: return "과거 판정 이후 변경됨 (STALE)"
        case .offline: return "필요한 저장 위치를 현재 사용할 수 없음 (OFFLINE)"
        }
    }

    private static func localizedStrength(_ strength: CanonicalKeeperPolicy.ReviewStrength) -> String {
        switch strength {
        case .strong: return "강한 근거"
        case .preference: return "선호 기준"
        }
    }

    private static func localizedRationale(_ rationale: CanonicalKeeperPolicy.PreferenceRationale) -> String {
        switch rationale {
        case .protectedOrPreferredRoot: return "더 우선하거나 보호되는 저장 위치"
        case .cleanerFilename: return "복사본 표식이 없는 더 깔끔한 파일명"
        case .recognizableFilename: return "출처·용도를 더 알아보기 쉬운 파일명"
        case .strongerCaptureEvidence: return "더 신뢰도 높은 촬영 시각 근거"
        case .shallowerPath: return "더 얕고 단순한 폴더 경로"
        case .deterministicTieBreak: return "의미 있는 우열이 없어 결과를 일정하게 만들기 위한 동률 해소"
        }
    }

    private static func localizedCaptureSource(_ source: CaptureTimeSource) -> String {
        switch source {
        case .exifDateTimeOriginal: return "EXIF 원본 촬영 시각"
        case .quickTimeCreationDate: return "QuickTime 생성 시각"
        case .googleTakeoutPhotoTakenTime: return "Google Takeout 촬영 시각"
        case .fileCreationDate: return "파일시스템 생성 시각"
        case .unknown: return "출처 불명"
        }
    }

    private static func localizedCaptureConfidence(_ confidence: CaptureTimeConfidence) -> String {
        switch confidence {
        case .trusted: return "높음"
        case .providerSidecar: return "provider sidecar"
        case .incompleteTimezone: return "시간대 정보 불완전"
        case .fallback: return "fallback"
        case .unknown: return "불명"
        }
    }

    private static func extendedAttributes(at url: URL) -> [String: Data]? {
        url.withUnsafeFileSystemRepresentation { path -> [String: Data]? in
            guard let path else { return nil }
            let nameBufferSize = listxattr(path, nil, 0, 0)
            guard nameBufferSize >= 0 else { return nil }
            if nameBufferSize == 0 { return [:] }
            var nameBuffer = [CChar](repeating: 0, count: nameBufferSize)
            let filled = listxattr(path, &nameBuffer, nameBuffer.count, 0)
            guard filled >= 0 else { return nil }

            var names: [String] = []
            var start = 0
            for index in 0..<filled where nameBuffer[index] == 0 {
                if index > start {
                    names.append(String(cString: Array(nameBuffer[start...index])))
                }
                start = index + 1
            }

            var result: [String: Data] = [:]
            for name in names {
                let value = name.withCString { attributeName -> Data? in
                    let size = getxattr(path, attributeName, nil, 0, 0, 0)
                    guard size >= 0 else { return nil }
                    if size == 0 { return Data() }
                    var bytes = [UInt8](repeating: 0, count: size)
                    let read = getxattr(path, attributeName, &bytes, bytes.count, 0, 0)
                    guard read >= 0 else { return nil }
                    return Data(bytes.prefix(read))
                }
                if let value { result[name] = value }
            }
            return result
        }
    }

    private static func writeReadme(to outputURL: URL) throws {
        let text = """
        PhotoArchiveKit exact 중복 검토 작업공간

        이 폴더에는 심볼릭 링크(가상본)만 있습니다. 원본 미디어는 복사, 이동, 이름 변경, 삭제되지 않았습니다.

        번호가 붙은 각 폴더는 하나의 exact 중복 판정 그룹이며 현재 상태를 함께 표시합니다.
        - CURRENT: 실제 파일 크기, 수정 시각, 파일시스템 식별자, root 식별 정보가 catalog 기록과 여전히 일치합니다.
        - STALE: 하나 이상의 파일 또는 root 정보가 이전 판정 뒤 변경되었거나 사라졌습니다. 이전 판정을 믿기 전에 duplicate-review --refresh가 필요합니다.
        - OFFLINE: 필요한 저장 위치를 현재 사용할 수 없습니다. 먼저 해당 저장 위치를 다시 연결해야 합니다.

        CURRENT 그룹의 구성:
        - KEEPER: PhotoArchiveKit이 현재 남기는 쪽으로 선호하는 사본입니다.
        - CANDIDATE: 바이트가 동일한 정리 후보입니다. 실제 quarantine 직전에는 다시 암호학적 검증을 수행합니다.
        - comparison.txt: 실제 원본 대상 크기, 남길 후보 선택 이유, 메타데이터 차이 요약을 담은 로컬 전용 문서입니다. Finder에 보이는 가상본 자체의 크기는 원본 미디어 크기가 아닙니다.

        STALE/OFFLINE 그룹은 과거 판정이라는 뜻으로 OLD_KEEPER / OLD_CANDIDATE 이름을 사용합니다.
        - locations.txt: Finder 검토를 위한 실제 원본 위치를 담은 로컬 전용 문서입니다.

        현재 Finder prototype에서는 가상본의 썸네일 또는 Quick Look을 사용할 수 있습니다. 이 작업공간 자체를 백업으로 취급하지 마세요.
        """
        try (text + "\n").write(
            to: outputURL.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func writeNeedsRefresh(status: FreshnessStatus, to groupURL: URL) throws {
        let action = status == .offline
            ? "사용할 수 없는 저장 위치를 다시 연결한 뒤 duplicate-review --refresh를 실행하세요."
            : "이 판정을 다시 신뢰하기 전에 duplicate-review --refresh를 실행하세요."
        let text = """
        \(localizedStatus(status)) / 갱신 필요

        이 그룹의 이전 exact 중복 판정은 현재 상태를 충분히 반영하지 못하므로 정상 검토 대상으로 사용할 수 없습니다.
        \(action)

        이 그룹의 OLD_KEEPER / OLD_CANDIDATE 표시만 근거로 파일을 quarantine하지 마세요.
        """
        try (text + "\n").write(
            to: groupURL.appendingPathComponent("NEEDS-REFRESH.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
