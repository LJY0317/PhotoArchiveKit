import Foundation

public enum ArchiveScannerError: LocalizedError {
    case noRoots
    case rootDoesNotExist(String)
    case rootIsNotDirectory(String)
    case duplicateRoot(String)
    case cannotEnumerate(String)

    public var errorDescription: String? {
        switch self {
        case .noRoots:
            return "At least one source root is required."
        case let .rootDoesNotExist(path):
            return "Source root does not exist: \(path)"
        case let .rootIsNotDirectory(path):
            return "Source root is not a directory: \(path)"
        case let .duplicateRoot(path):
            return "The same source root was supplied more than once: \(path)"
        case let .cannotEnumerate(path):
            return "Could not enumerate source root: \(path)"
        }
    }
}

public final class ArchiveScanner {
    private let catalog: SQLiteCatalog

    public init(catalogURL: URL = PhotoArchivePaths.defaultCatalogURL) throws {
        self.catalog = try SQLiteCatalog(url: catalogURL)
    }

    public func scan(
        roots inputs: [ScanRoot],
        options: ScanOptions = ScanOptions()
    ) async throws -> ScanReport {
        guard !inputs.isEmpty else { throw ArchiveScannerError.noRoots }

        let startedAt = Date()
        let roots = try resolveAndValidateRoots(inputs)
        let sessionID = try catalog.beginScan(startedAt: startedAt, rootCount: roots.count)

        do {
            var warnings: [ScanWarning] = []
            let enumeration = try enumerate(roots: roots)
            warnings.append(contentsOf: enumeration.warnings)
            let pending = enumeration.files
            var resources = await probe(
                pendingFiles: pending,
                maxConcurrency: options.maxConcurrentProbes
            )
            TakeoutSidecarImporter.applyCaptureTimes(to: &resources)

            let privacyKey = try catalog.liveIdentifierPrivacyKey()
            for index in resources.indices {
                if let identifier = resources[index].rawLivePhotoIdentifier {
                    resources[index].identifierFingerprint = PrivacyFingerprint.livePhotoIdentifier(
                        identifier,
                        key: privacyKey
                    )
                    resources[index].rawLivePhotoIdentifier = nil
                }
            }

            if options.computeExactDuplicates {
                warnings.append(contentsOf: await hashDuplicateCandidates(
                    resources: &resources,
                    maxConcurrency: min(options.maxConcurrentProbes, 4)
                ))
            }

            warnings.append(contentsOf: metadataWarnings(resources))
            warnings.append(contentsOf: AssetAssembler.unverifiedBasenamePairWarnings(
                resources: resources
            ))
            warnings.append(contentsOf: filenameCollisionWarnings(resources))

            var finalReport: ScanReport?
            try catalog.withTransaction {
                try catalog.persistResources(sessionID: sessionID, resources: &resources)
                _ = try catalog.persistAssets(sessionID: sessionID, resources: &resources)

                let internalDuplicateGroups = duplicateGroups(from: resources)
                let duplicateGroupIDs = try catalog.persistDuplicateGroups(
                    sessionID: sessionID,
                    resources: resources,
                    groups: internalDuplicateGroups
                )

                let reportParts = buildReportParts(
                    roots: roots,
                    resources: resources,
                    duplicateGroups: internalDuplicateGroups,
                    duplicateGroupIDs: duplicateGroupIDs,
                    initialWarnings: warnings,
                    eventGap: options.eventGap
                )
                try catalog.persistEvents(
                    sessionID: sessionID,
                    events: reportParts.events
                )

                let completedAt = Date()
                let summary = ScanSummary(
                    rootCount: roots.count,
                    resourceCount: resources.count,
                    logicalAssetCount: reportParts.logicalAssetCount,
                    livePhotoAssetCount: reportParts.livePhotos.count,
                    exactDuplicateGroupCount: reportParts.duplicates.count,
                    eventSuggestionCount: reportParts.events.count,
                    warningCount: reportParts.warnings.count
                )
                try catalog.finishScan(
                    sessionID: sessionID,
                    completedAt: completedAt,
                    summary: summary
                )

                finalReport = ScanReport(
                    sessionID: sessionID,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    catalogPath: catalog.url.path,
                    summary: summary,
                    roots: reportParts.roots,
                    livePhotos: reportParts.livePhotos,
                    exactDuplicateGroups: reportParts.duplicates,
                    eventSuggestions: reportParts.events,
                    warnings: reportParts.warnings,
                    filesModified: false
                )
            }

            guard let finalReport else {
                throw CatalogError.invalidCatalogValue("Scan report was not assembled.")
            }
            return finalReport
        } catch {
            catalog.failScan(sessionID: sessionID, completedAt: Date())
            throw error
        }
    }

    private func resolveAndValidateRoots(_ inputs: [ScanRoot]) throws -> [RootDescriptor] {
        var seenPaths = Set<String>()
        var roots: [RootDescriptor] = []

        for input in inputs {
            let url = input.url.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw ArchiveScannerError.rootDoesNotExist(url.path)
            }
            guard isDirectory.boolValue else {
                throw ArchiveScannerError.rootIsNotDirectory(url.path)
            }
            guard seenPaths.insert(url.path).inserted else {
                throw ArchiveScannerError.duplicateRoot(url.path)
            }
            roots.append(try catalog.resolveRoot(input))
        }

        return roots
    }

    private func enumerate(
        roots: [RootDescriptor]
    ) throws -> (files: [PendingFile], warnings: [ScanWarning]) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey
        ]
        var pending: [PendingFile] = []
        var warnings: [ScanWarning] = []

        for root in roots {
            let nestedRootPaths = Set(
                roots
                    .filter { $0.id != root.id && isDescendant($0.url, of: root.url) }
                    .map { $0.url.standardizedFileURL.path }
            )

            guard let enumerator = FileManager.default.enumerator(
                at: root.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, _ in
                    warnings.append(ScanWarning(
                        code: "enumeration_error",
                        message: "A path could not be enumerated.",
                        rootID: root.id,
                        relativePath: self.relativePath(of: url, under: root.url)
                    ))
                    return true
                }
            ) else {
                throw ArchiveScannerError.cannotEnumerate(root.url.path)
            }

            for case let url as URL in enumerator {
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    if values.isDirectory == true,
                       nestedRootPaths.contains(url.standardizedFileURL.path) {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard values.isRegularFile == true,
                          values.isSymbolicLink != true,
                          let type = SupportedFileTypes.classify(url: url)
                    else {
                        continue
                    }

                    pending.append(PendingFile(
                        root: root,
                        url: url,
                        relativePath: relativePath(of: url, under: root.url),
                        type: type,
                        byteSize: Int64(values.fileSize ?? 0),
                        modifiedAt: values.contentModificationDate,
                        createdAt: values.creationDate
                    ))
                } catch {
                    warnings.append(ScanWarning(
                        code: "resource_values_error",
                        message: "File metadata could not be read; the file was skipped.",
                        rootID: root.id,
                        relativePath: relativePath(of: url, under: root.url)
                    ))
                }
            }
        }

        return (
            files: pending.sorted {
                ($0.root.label, $0.relativePath) < ($1.root.label, $1.relativePath)
            },
            warnings: warnings
        )
    }

    private func probe(
        pendingFiles: [PendingFile],
        maxConcurrency: Int
    ) async -> [ProbedResource] {
        guard !pendingFiles.isEmpty else { return [] }

        return await withTaskGroup(of: ProbedResource.self) { group in
            var iterator = pendingFiles.makeIterator()
            var results: [ProbedResource] = []
            results.reserveCapacity(pendingFiles.count)

            for _ in 0..<min(maxConcurrency, pendingFiles.count) {
                if let file = iterator.next() {
                    group.addTask { await MetadataProbe.probe(file) }
                }
            }

            while let result = await group.next() {
                results.append(result)
                if let file = iterator.next() {
                    group.addTask { await MetadataProbe.probe(file) }
                }
            }

            return results.sorted {
                ($0.root.label, $0.relativePath) < ($1.root.label, $1.relativePath)
            }
        }
    }

    private struct HashResult: Sendable {
        let index: Int
        let hash: Data?
        let errorMessage: String?
    }

    private func hashDuplicateCandidates(
        resources: inout [ProbedResource],
        maxConcurrency: Int
    ) async -> [ScanWarning] {
        let candidateIndices = Dictionary(grouping: resources.indices.filter {
            resources[$0].mediaKind != .sidecar && resources[$0].byteSize > 0
        }) { resources[$0].byteSize }
        .values
        .filter { $0.count > 1 }
        .flatMap { $0 }

        guard !candidateIndices.isEmpty else { return [] }

        let results = await withTaskGroup(of: HashResult.self) { group in
            var iterator = candidateIndices.makeIterator()
            var output: [HashResult] = []
            output.reserveCapacity(candidateIndices.count)

            for _ in 0..<min(maxConcurrency, candidateIndices.count) {
                if let index = iterator.next() {
                    let url = resources[index].url
                    group.addTask {
                        do {
                            return HashResult(
                                index: index,
                                hash: try FileHasher.sha256(url: url),
                                errorMessage: nil
                            )
                        } catch {
                            return HashResult(
                                index: index,
                                hash: nil,
                                errorMessage: String(describing: error)
                            )
                        }
                    }
                }
            }

            while let result = await group.next() {
                output.append(result)
                if let index = iterator.next() {
                    let url = resources[index].url
                    group.addTask {
                        do {
                            return HashResult(
                                index: index,
                                hash: try FileHasher.sha256(url: url),
                                errorMessage: nil
                            )
                        } catch {
                            return HashResult(
                                index: index,
                                hash: nil,
                                errorMessage: String(describing: error)
                            )
                        }
                    }
                }
            }
            return output
        }

        var warnings: [ScanWarning] = []
        for result in results {
            resources[result.index].exactHash = result.hash
            if result.errorMessage != nil {
                warnings.append(ScanWarning(
                    code: "exact_hash_error",
                    message: "A local exact-duplicate comparison could not be completed.",
                    rootID: resources[result.index].root.id,
                    relativePath: resources[result.index].relativePath
                ))
            }
        }
        return warnings
    }

    private func duplicateGroups(from resources: [ProbedResource]) -> [InternalDuplicateGroup] {
        Dictionary(grouping: resources.compactMap { resource -> (Data, ProbedResource)? in
            guard resource.mediaKind != .sidecar,
                  let hash = resource.exactHash
            else {
                return nil
            }
            return (hash, resource)
        }, by: { $0.0 })
        .compactMap { hash, values in
            guard values.count > 1 else { return nil }
            return InternalDuplicateGroup(
                contentHash: hash,
                resources: values.map(\.1).sorted {
                    ($0.root.label, $0.relativePath) < ($1.root.label, $1.relativePath)
                }
            )
        }
        .sorted {
            let lhs = $0.resources.first.map { ($0.root.label, $0.relativePath) }
                ?? ("", "")
            let rhs = $1.resources.first.map { ($0.root.label, $0.relativePath) }
                ?? ("", "")
            return lhs < rhs
        }
    }

    private struct ReportParts {
        let roots: [RootScanReport]
        let livePhotos: [LivePhotoAssetReport]
        let duplicates: [ExactDuplicateGroupReport]
        let events: [EventSuggestionReport]
        let warnings: [ScanWarning]
        let logicalAssetCount: Int
    }

    private func buildReportParts(
        roots: [RootDescriptor],
        resources: [ProbedResource],
        duplicateGroups: [InternalDuplicateGroup],
        duplicateGroupIDs: [Data: String],
        initialWarnings: [ScanWarning],
        eventGap: TimeInterval
    ) -> ReportParts {
        let assemblies = AssetAssembler.livePhotoAssemblies(from: resources)
        var warnings = initialWarnings
        var occurrencesByRoot: [String: [LivePhotoOccurrenceReport]] = [:]

        let livePhotoReports: [LivePhotoAssetReport] = assemblies.compactMap { assembly in
            guard let assetID = assembly.resources.compactMap(\.persistentAssetID).first else {
                return nil
            }

            let rootGroups = Dictionary(grouping: assembly.resources, by: { $0.root.id })
            let occurrences = rootGroups.values.map { group -> LivePhotoOccurrenceReport in
                let stills = group.filter { $0.mediaKind == .image }
                let videos = group.filter { $0.mediaKind == .video }
                let status = AssetAssembler.occurrenceStatus(
                    stillCount: stills.count,
                    videoCount: videos.count
                )
                let representative = group[0]
                let report = LivePhotoOccurrenceReport(
                    rootID: representative.root.id,
                    rootLabel: representative.root.label,
                    status: status,
                    stillCount: stills.count,
                    videoCount: videos.count,
                    resources: group.map(AssetAssembler.resourceReference).sorted {
                        $0.relativePath < $1.relativePath
                    }
                )

                if status != .complete {
                    warnings.append(ScanWarning(
                        code: "live_photo_occurrence_\(status.rawValue)",
                        message: livePhotoWarningMessage(status),
                        rootID: representative.root.id,
                        relativePath: group.map(\.relativePath).sorted().first
                    ))
                }
                occurrencesByRoot[representative.root.id, default: []].append(report)
                return report
            }
            .sorted { ($0.rootLabel, $0.rootID) < ($1.rootLabel, $1.rootID) }

            return LivePhotoAssetReport(
                assetID: assetID,
                occurrenceCount: occurrences.count,
                stillCopyCount: assembly.resources.count { $0.mediaKind == .image },
                videoCopyCount: assembly.resources.count { $0.mediaKind == .video },
                occurrences: occurrences
            )
        }
        .sorted { lhs, rhs in
            let lhsPath = lhs.occurrences.first?.resources.first?.relativePath ?? lhs.assetID
            let rhsPath = rhs.occurrences.first?.resources.first?.relativePath ?? rhs.assetID
            return lhsPath < rhsPath
        }

        let rootReports = roots.map { root -> RootScanReport in
            let rootResources = resources.filter { $0.root.id == root.id }
            let occurrences = occurrencesByRoot[root.id] ?? []
            return RootScanReport(
                rootID: root.id,
                label: root.label,
                kind: root.kind,
                provenance: root.provenance,
                canonicalPath: root.url.path,
                mediaFileCount: rootResources.count {
                    $0.mediaKind == .image || $0.mediaKind == .video
                },
                completeLivePhotos: occurrences.count { $0.status == .complete },
                stillOnlyLiveResources: occurrences
                    .filter { $0.status == .stillOnly || $0.status == .multipleStills }
                    .reduce(0) { $0 + $1.stillCount },
                videoOnlyLiveResources: occurrences
                    .filter { $0.status == .videoOnly || $0.status == .multipleVideos }
                    .reduce(0) { $0 + $1.videoCount },
                standaloneImages: rootResources.count {
                    $0.mediaKind == .image && $0.identifierFingerprint == nil
                },
                standaloneVideos: rootResources.count {
                    $0.mediaKind == .video && $0.identifierFingerprint == nil
                },
                sidecars: rootResources.count { $0.mediaKind == .sidecar },
                metadataProbeFailures: rootResources.filter(\.metadataProbeFailed).count
            )
        }
        .sorted { ($0.label, $0.rootID) < ($1.label, $1.rootID) }

        let duplicateReports = duplicateGroups.compactMap { group -> ExactDuplicateGroupReport? in
            guard let groupID = duplicateGroupIDs[group.contentHash] else { return nil }
            return ExactDuplicateGroupReport(
                groupID: groupID,
                byteSize: group.resources.first?.byteSize ?? 0,
                members: group.resources.map(AssetAssembler.resourceReference)
            )
        }
        .sorted { $0.groupID < $1.groupID }

        let eventAssets = makeEventAssets(resources: resources)
        let events = EventClusterer.cluster(assets: eventAssets, gap: eventGap)
        let logicalAssetCount = Set(resources.compactMap(\.persistentAssetID)).count

        warnings.sort {
            ($0.code, $0.rootID ?? "", $0.relativePath ?? "")
                < ($1.code, $1.rootID ?? "", $1.relativePath ?? "")
        }

        return ReportParts(
            roots: rootReports,
            livePhotos: livePhotoReports,
            duplicates: duplicateReports,
            events: events,
            warnings: warnings,
            logicalAssetCount: logicalAssetCount
        )
    }

    private func makeEventAssets(resources: [ProbedResource]) -> [InternalEventAsset] {
        let grouped = Dictionary(grouping: resources.filter {
            $0.persistentAssetID != nil && $0.mediaKind != .sidecar
        }, by: { $0.persistentAssetID! })

        return grouped.compactMap { assetID, group in
            let candidates = group.compactMap { resource -> (ProbedResource, CaptureTime)? in
                guard let capture = resource.captureTime,
                      capture.instant != nil,
                      capture.confidence != .fallback,
                      capture.confidence != .unknown
                else {
                    return nil
                }
                return (resource, capture)
            }
            .sorted { lhs, rhs in
                let lhsImageRank = lhs.0.mediaKind == .image ? 0 : 1
                let rhsImageRank = rhs.0.mediaKind == .image ? 0 : 1
                let lhsTrustRank = lhs.1.confidence == .trusted ? 0 : 1
                let rhsTrustRank = rhs.1.confidence == .trusted ? 0 : 1
                return (lhsTrustRank, lhsImageRank, lhs.0.relativePath)
                    < (rhsTrustRank, rhsImageRank, rhs.0.relativePath)
            }

            guard let selected = candidates.first else { return nil }
            let localDay = selected.1.localTimestamp.flatMap { value -> String? in
                guard value.count >= 10 else { return nil }
                return String(value.prefix(10))
            }
            return InternalEventAsset(
                assetID: assetID,
                captureInstant: selected.1.instant!,
                localDay: localDay
            )
        }
    }

    private func filenameCollisionWarnings(_ resources: [ProbedResource]) -> [ScanWarning] {
        let media = resources.filter { $0.mediaKind == .image || $0.mediaKind == .video }
        let groups = Dictionary(grouping: media) { $0.fileName.lowercased() }

        return groups.values.compactMap { group in
            guard group.count > 1 else { return nil }

            let sizes = Set(group.map(\.byteSize))
            let knownHashes = Set(group.compactMap(\.exactHash))
            let differs = sizes.count > 1 || knownHashes.count > 1
            guard differs else { return nil }

            let representative = group.sorted {
                ($0.root.label, $0.relativePath) < ($1.root.label, $1.relativePath)
            }.first!
            return ScanWarning(
                code: "filename_collision",
                message: "The same filename is used by different media content. Filename equality was not treated as asset identity.",
                rootID: representative.root.id,
                relativePath: representative.relativePath
            )
        }
        .sorted {
            ($0.rootID ?? "", $0.relativePath ?? "")
                < ($1.rootID ?? "", $1.relativePath ?? "")
        }
    }

    private func metadataWarnings(_ resources: [ProbedResource]) -> [ScanWarning] {
        resources.compactMap { resource in
            guard resource.metadataProbeFailed else { return nil }
            return ScanWarning(
                code: "metadata_probe_failed",
                message: "The file was cataloged, but embedded metadata could not be read.",
                rootID: resource.root.id,
                relativePath: resource.relativePath
            )
        }
    }

    private func livePhotoWarningMessage(_ status: LivePhotoOccurrenceStatus) -> String {
        switch status {
        case .complete:
            return "The Live Photo occurrence is complete."
        case .stillOnly:
            return "A Live Photo still image was found without its paired video in this source root."
        case .videoOnly:
            return "A Live Photo paired video was found without its still image in this source root."
        case .multipleStills:
            return "Multiple still-image resources share one Live Photo identifier in this source root."
        case .multipleVideos:
            return "Multiple video resources share one Live Photo identifier in this source root."
        case .multipleVariants:
            return "Multiple still and video resources share one Live Photo identifier in this source root."
        }
    }

    private func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath != parentPath else { return false }
        return childPath.hasPrefix(parentPath.hasSuffix("/") ? parentPath : parentPath + "/")
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = url.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath) else { return url.lastPathComponent }

        let suffix = childPath.dropFirst(rootPath.count)
        return String(suffix.drop(while: { $0 == "/" }))
    }
}
