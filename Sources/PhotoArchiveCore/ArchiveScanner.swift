import Darwin
import Foundation

public enum ArchiveScannerError: LocalizedError {
    case noRoots
    case rootDoesNotExist(String)
    case rootIsNotDirectory(String)
    case duplicateRoot(String)
    case cannotEnumerate(String)
    case scanAlreadyRunning

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
        case .scanAlreadyRunning:
            return "Another PhotoArchiveKit scan is already running for this catalog."
        }
    }
}

private final class CatalogScanLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(catalogURL: URL) throws -> CatalogScanLock {
        let lockURL = catalogURL.deletingLastPathComponent().appendingPathComponent(
            ".\(catalogURL.lastPathComponent).scan.lock",
            isDirectory: false
        )
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw ArchiveScannerError.scanAlreadyRunning
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw ArchiveScannerError.scanAlreadyRunning
        }
        return CatalogScanLock(descriptor: descriptor)
    }

    func release() {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

public final class ArchiveScanner {
    private let catalog: SQLiteCatalog

    public init(catalogURL: URL = PhotoArchivePaths.defaultCatalogURL) throws {
        self.catalog = try SQLiteCatalog(url: catalogURL)
    }

    public func commitAppliedOrganizationPlan(_ plan: OrganizationPlan) throws {
        try catalog.withTransaction {
            try catalog.commitAppliedOrganizationPlan(plan)
        }
    }

    public func latestReusableActiveRootsScanReport() throws -> ScanReport? {
        try catalog.latestReusableActiveRootsScanReport()
    }

    public func makeArchivePlan(
        from report: ScanReport,
        destinationURL: URL
    ) throws -> ArchivePlan {
        let destination = destinationURL.resolvingSymlinksInPath().standardizedFileURL
        if let rootID = try catalog.rootID(matching: destination.path),
           let usageRole = try catalog.sourceRootUsageRole(rootID: rootID),
           usageRole != .archive {
            throw ArchivePlanError.destinationRoleConflict(rootID)
        }
        return try ArchivePlanner.makePlan(
            from: report,
            destinationURL: destination,
            expectedHashForResource: { resourceID in
                try self.catalog.archivePlanExactHash(
                    resourceID: resourceID,
                    sessionID: report.sessionID
                )
            }
        )
    }

    public func scan(
        roots inputs: [ScanRoot],
        options: ScanOptions = ScanOptions()
    ) async throws -> ScanReport {
        guard !inputs.isEmpty else { throw ArchiveScannerError.noRoots }

        let scanLock = try CatalogScanLock.acquire(catalogURL: catalog.url)
        defer { scanLock.release() }

        let startedAt = Date()
        let recoveredInterruptedScanCount = try catalog.recoverInterruptedScans(
            completedAt: startedAt
        )
        let roots = try resolveAndValidateRoots(inputs)
        let registeredOwnershipPaths = Set(
            try catalog.rootRegistryRows(includeHistory: false)
                .filter { $0.state == .active || $0.state == .inactive }
                .map {
                    URL(fileURLWithPath: $0.canonicalPath)
                        .resolvingSymlinksInPath()
                        .standardizedFileURL.path
                }
        )
        let sessionID = try catalog.beginScan(startedAt: startedAt, rootCount: roots.count)

        do {
            var warnings: [ScanWarning] = []
            options.progressHandler?(ScanProgress(
                stage: .enumerating,
                completedUnitCount: 0
            ))
            let enumeration = try enumerate(
                roots: roots,
                registeredOwnershipPaths: registeredOwnershipPaths,
                progressHandler: options.progressHandler
            )
            warnings.append(contentsOf: enumeration.warnings)
            let pending = enumeration.files
            options.progressHandler?(ScanProgress(
                stage: .enumerating,
                completedUnitCount: pending.count,
                totalUnitCount: pending.count
            ))
            let metadataReuse: (resources: [ProbedResource], remaining: [PendingFile])
            if options.reuseMetadataCache {
                metadataReuse = try catalog.reuseCachedMetadata(
                    pendingFiles: pending,
                    probeVersion: MetadataProbe.cacheVersion
                )
            } else {
                metadataReuse = ([], pending)
            }
            let newlyProbedResources = await probe(
                pendingFiles: metadataReuse.remaining,
                initialCompletedUnitCount: metadataReuse.resources.count,
                totalUnitCount: pending.count,
                maxConcurrency: options.maxConcurrentProbes,
                progressHandler: options.progressHandler
            )
            var resources = (metadataReuse.resources + newlyProbedResources).sorted {
                ($0.root.label, $0.relativePath) < ($1.root.label, $1.relativePath)
            }
            let reusedMetadataCount = metadataReuse.resources.count
            TakeoutSidecarImporter.applyCaptureTimes(to: &resources)
            let sidecarAssociations = SidecarAssociationDetector.detect(in: resources)

            let reusedExactHashCount: Int
            if options.reuseExactHashCache {
                let localHashCacheHits = try catalog.reuseCachedExactHashes(resources: &resources)
                let portableHashReuse = reusePortableArchiveHashes(
                    resources: &resources,
                    roots: roots
                )
                warnings.append(contentsOf: portableHashReuse.warnings)
                reusedExactHashCount = localHashCacheHits + portableHashReuse.count
            } else {
                reusedExactHashCount = 0
            }

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
                warnings.append(contentsOf: try await hashDuplicateCandidates(
                    resources: &resources,
                    roots: roots,
                    engine: options.exactDuplicateEngine,
                    maxConcurrency: min(options.maxConcurrentProbes, 4),
                    progressHandler: options.progressHandler
                ))
            }
            if options.computeArchiveIntegrityPreconditions {
                warnings.append(contentsOf: await hashArchiveIntegrityPreconditions(
                    resources: &resources,
                    maxConcurrency: min(options.maxConcurrentProbes, 4),
                    progressHandler: options.progressHandler
                ))
            }

            warnings.append(contentsOf: metadataWarnings(resources))
            warnings.append(contentsOf: AssetAssembler.unverifiedBasenamePairWarnings(
                resources: resources
            ))
            warnings.append(contentsOf: filenameCollisionWarnings(resources))

            var finalReport: ScanReport?
            options.progressHandler?(ScanProgress(
                stage: .cataloging,
                completedUnitCount: 0,
                totalUnitCount: 1
            ))
            try catalog.withTransaction {
                try catalog.persistResources(sessionID: sessionID, resources: &resources)
                _ = try catalog.persistAssets(sessionID: sessionID, resources: &resources)
                let recognizedSidecars = try catalog.persistSidecarAssociations(
                    sessionID: sessionID,
                    resources: resources,
                    associations: sidecarAssociations
                )
                let sourceFolderSemanticsCapturedRootIDs = try catalog.persistSourceFolderCollections(
                    resources: resources,
                    roots: roots
                )

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
                    initialNotices: recoveredInterruptedScanCount > 0
                        ? [ScanNotice(
                            code: "interrupted_scan_sessions_recovered",
                            message: "Recovered \(recoveredInterruptedScanCount) incomplete scan session(s) left by an earlier interrupted process."
                        )]
                        : [],
                    initialWarnings: warnings,
                    eventGap: options.eventGap,
                    sourceFolderSemanticsCapturedRootIDs: sourceFolderSemanticsCapturedRootIDs,
                    recognizedSidecars: recognizedSidecars
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
                    warningCount: reportParts.warnings.count,
                    reusedMetadataCount: reusedMetadataCount,
                    reusedExactHashCount: reusedExactHashCount
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
                    resources: reportParts.resources,
                    livePhotos: reportParts.livePhotos,
                    exactDuplicateGroups: reportParts.duplicates,
                    eventSuggestions: reportParts.events,
                    recognizedSidecars: reportParts.recognizedSidecars,
                    notices: reportParts.notices,
                    warnings: reportParts.warnings,
                    filesModified: false
                )
            }
            options.progressHandler?(ScanProgress(
                stage: .cataloging,
                completedUnitCount: 1,
                totalUnitCount: 1
            ))

            guard let finalReport else {
                throw CatalogError.invalidCatalogValue("Scan report was not assembled.")
            }
            options.progressHandler?(ScanProgress(
                stage: .finalizing,
                completedUnitCount: 1,
                totalUnitCount: 1
            ))
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
            let marker = try RootMarkerStore.readIfPresent(at: url)
            roots.append(try catalog.resolveRoot(input, markerKey: marker?.markerKey))
        }

        return roots
    }

    private func enumerate(
        roots: [RootDescriptor],
        registeredOwnershipPaths: Set<String>,
        progressHandler: ScanProgressHandler?
    ) throws -> (files: [PendingFile], warnings: [ScanWarning]) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .addedToDirectoryDateKey,
            .fileResourceIdentifierKey
        ]
        var pending: [PendingFile] = []
        var warnings: [ScanWarning] = []

        for root in roots {
            let suppliedNestedRootPaths = Set(
                roots
                    .filter { $0.id != root.id && isDescendant($0.url, of: root.url) }
                    .map { $0.url.standardizedFileURL.path }
            )
            let registeredNestedRootPaths = Set(
                registeredOwnershipPaths.filter { path in
                    path != root.url.standardizedFileURL.path
                        && isDescendant(URL(fileURLWithPath: path), of: root.url)
                }
            )
            let nestedRootPaths = suppliedNestedRootPaths.union(registeredNestedRootPaths)

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
                        createdAt: values.creationDate,
                        addedAt: values.addedToDirectoryDate,
                        fileSystemIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
                    ))
                    progressHandler?(ScanProgress(
                        stage: .enumerating,
                        completedUnitCount: pending.count
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
        initialCompletedUnitCount: Int,
        totalUnitCount: Int,
        maxConcurrency: Int,
        progressHandler: ScanProgressHandler?
    ) async -> [ProbedResource] {
        progressHandler?(ScanProgress(
            stage: .metadata,
            completedUnitCount: initialCompletedUnitCount,
            totalUnitCount: totalUnitCount
        ))
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
                progressHandler?(ScanProgress(
                    stage: .metadata,
                    completedUnitCount: initialCompletedUnitCount + results.count,
                    totalUnitCount: totalUnitCount
                ))
                if let file = iterator.next() {
                    group.addTask { await MetadataProbe.probe(file) }
                }
            }

            return results.sorted {
                ($0.root.label, $0.relativePath) < ($1.root.label, $1.relativePath)
            }
        }
    }

    private func reusePortableArchiveHashes(
        resources: inout [ProbedResource],
        roots: [RootDescriptor]
    ) -> (count: Int, warnings: [ScanWarning]) {
        var reused = 0
        var warnings: [ScanWarning] = []

        for root in roots where root.kind == .archive {
            guard let markerKey = root.markerKey else { continue }
            let cache: [String: PortableHashEvidence]
            do {
                cache = try ArchiveRootInventoryStore.portableHashCache(
                    rootURL: root.url,
                    markerKey: markerKey
                )
            } catch {
                warnings.append(ScanWarning(
                    code: "archive_inventory_cache_invalid",
                    message: "The portable archive inventory could not be used as a hash cache; files will be verified normally.",
                    rootID: root.id
                ))
                continue
            }

            guard !cache.isEmpty else { continue }
            for index in resources.indices where resources[index].root.id == root.id {
                guard resources[index].mediaKind != .sidecar,
                      resources[index].exactHash == nil,
                      let evidence = cache[resources[index].relativePath],
                      evidence.byteSize == resources[index].byteSize,
                      modificationTimesMatch(evidence.modifiedAt, resources[index].modifiedAt)
                else {
                    continue
                }
                resources[index].exactHash = evidence.exactHash
                reused += 1
            }
        }

        return (reused, warnings)
    }

    private func modificationTimesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 0.001
    }

    private struct HashResult: Sendable {
        let index: Int
        let hash: Data?
        let errorMessage: String?
    }

    private func hashDuplicateCandidates(
        resources: inout [ProbedResource],
        roots: [RootDescriptor],
        engine: ExactDuplicateEngine,
        maxConcurrency: Int,
        progressHandler: ScanProgressHandler?
    ) async throws -> [ScanWarning] {
        switch engine {
        case .native:
            return await hashNativeDuplicateCandidates(
                resources: &resources,
                maxConcurrency: maxConcurrency,
                progressHandler: progressHandler
            )
        case .czkawka:
            return try await hashCzkawkaDuplicateCandidates(
                resources: &resources,
                roots: roots,
                maxConcurrency: maxConcurrency,
                progressHandler: progressHandler
            )
        case .automatic:
            // Real-library benchmarking showed that running Czkawka candidate discovery
            // and then re-reading every candidate for native SHA-256 verification was
            // slightly slower than native exact comparison alone. Keep automatic mode
            // deterministic and single-pass until an integration can avoid double work.
            return await hashNativeDuplicateCandidates(
                resources: &resources,
                maxConcurrency: maxConcurrency,
                progressHandler: progressHandler
            )
        }
    }

    private func hashNativeDuplicateCandidates(
        resources: inout [ProbedResource],
        maxConcurrency: Int,
        progressHandler: ScanProgressHandler?
    ) async -> [ScanWarning] {
        let candidateIndices = Dictionary(grouping: resources.indices.filter {
            resources[$0].mediaKind != .sidecar
                && resources[$0].byteSize > 0
        }) { resources[$0].byteSize }
        .values
        .filter { $0.count > 1 }
        .flatMap { $0 }
        .filter { resources[$0].exactHash == nil }

        return await hashCandidateIndices(
            candidateIndices,
            resources: &resources,
            maxConcurrency: maxConcurrency,
            stage: .hashingDuplicates,
            progressHandler: progressHandler
        )
    }

    private func hashArchiveIntegrityPreconditions(
        resources: inout [ProbedResource],
        maxConcurrency: Int,
        progressHandler: ScanProgressHandler?
    ) async -> [ScanWarning] {
        let missingHashes = resources.indices.filter {
            resources[$0].mediaKind != .sidecar && resources[$0].exactHash == nil
        }
        return await hashCandidateIndices(
            missingHashes,
            resources: &resources,
            maxConcurrency: maxConcurrency,
            stage: .hashingIntegrity,
            progressHandler: progressHandler
        )
    }

    private func hashCzkawkaDuplicateCandidates(
        resources: inout [ProbedResource],
        roots: [RootDescriptor],
        maxConcurrency: Int,
        progressHandler: ScanProgressHandler?
    ) async throws -> [ScanWarning] {
        let groups = try CzkawkaExactCandidateAdapter.exactCandidateGroups(roots: roots)
        let indexByPath = Dictionary(uniqueKeysWithValues: resources.indices.map { index in
            (resources[index].url.standardizedFileURL.path, index)
        })

        var candidateIndices = Set<Int>()
        for group in groups {
            let indices = group.compactMap { path in
                indexByPath[URL(fileURLWithPath: path).standardizedFileURL.path]
            }
            guard indices.count > 1 else { continue }
            candidateIndices.formUnion(indices)
        }

        return await hashCandidateIndices(
            candidateIndices.filter { resources[$0].exactHash == nil }.sorted(),
            resources: &resources,
            maxConcurrency: maxConcurrency,
            stage: .hashingDuplicates,
            progressHandler: progressHandler
        )
    }

    private func hashCandidateIndices(
        _ candidateIndices: [Int],
        resources: inout [ProbedResource],
        maxConcurrency: Int,
        stage: ScanProgressStage,
        progressHandler: ScanProgressHandler?
    ) async -> [ScanWarning] {
        guard !candidateIndices.isEmpty else { return [] }
        progressHandler?(ScanProgress(
            stage: stage,
            completedUnitCount: 0,
            totalUnitCount: candidateIndices.count
        ))

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
                progressHandler?(ScanProgress(
                    stage: stage,
                    completedUnitCount: output.count,
                    totalUnitCount: candidateIndices.count
                ))
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
        let resources: [ScannedResourceReport]
        let livePhotos: [LivePhotoAssetReport]
        let duplicates: [ExactDuplicateGroupReport]
        let events: [EventSuggestionReport]
        let recognizedSidecars: [RecognizedSidecarReport]
        let notices: [ScanNotice]
        let warnings: [ScanWarning]
        let logicalAssetCount: Int
    }

    private func buildReportParts(
        roots: [RootDescriptor],
        resources: [ProbedResource],
        duplicateGroups: [InternalDuplicateGroup],
        duplicateGroupIDs: [Data: String],
        initialNotices: [ScanNotice],
        initialWarnings: [ScanWarning],
        eventGap: TimeInterval,
        sourceFolderSemanticsCapturedRootIDs: Set<String>,
        recognizedSidecars: [RecognizedSidecarReport]
    ) -> ReportParts {
        let assemblies = AssetAssembler.livePhotoAssemblies(from: resources)
        var notices = initialNotices
        var warnings = initialWarnings
        var occurrencesByRoot: [String: [LivePhotoOccurrenceReport]] = [:]

        let livePhotoReports: [LivePhotoAssetReport] = assemblies.compactMap { assembly in
            guard let assetID = assembly.resources.compactMap(\.persistentAssetID).first else {
                return nil
            }

            let rootGroups = Dictionary(grouping: assembly.resources, by: { $0.root.id })
            let occurrences = rootGroups.values
                .flatMap { AssetAssembler.partitionOccurrences($0) }
                .map { group -> LivePhotoOccurrenceReport in
                    let stills = group.filter { $0.mediaKind == .image }
                    let videos = group.filter { $0.mediaKind == .video }
                    let status = AssetAssembler.occurrenceStatus(resources: group)
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

                    if let notice = LivePhotoNamingDiagnostics.notice(for: report) {
                        notices.append(notice)
                    }

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
                .sorted {
                    ($0.rootLabel, $0.rootID, $0.resources.first?.relativePath ?? "")
                        < ($1.rootLabel, $1.rootID, $1.resources.first?.relativePath ?? "")
                }

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
            let recognizedSidecarCount = recognizedSidecars.count { $0.rootID == root.id }
            let totalSidecars = rootResources.count { $0.mediaKind == .sidecar }
            return RootScanReport(
                rootID: root.id,
                label: root.label,
                kind: root.kind,
                usageRole: root.usageRole,
                provenance: root.provenance,
                canonicalPath: root.url.path,
                stableMarkerKey: root.markerKey,
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
                sidecars: totalSidecars,
                recognizedSidecars: recognizedSidecarCount,
                unrecognizedSidecars: max(totalSidecars - recognizedSidecarCount, 0),
                metadataProbeFailures: rootResources.filter(\.metadataProbeFailed).count,
                sourceFolderSemanticsCaptured: sourceFolderSemanticsCapturedRootIDs.contains(root.id)
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
        notices.sort {
            ($0.code, $0.rootID ?? "", $0.relativePath ?? "")
                < ($1.code, $1.rootID ?? "", $1.relativePath ?? "")
        }

        let resourceReports = resources.compactMap { resource -> ScannedResourceReport? in
            guard let resourceID = resource.persistentResourceID else { return nil }
            return ScannedResourceReport(
                resourceID: resourceID,
                assetID: resource.persistentAssetID,
                rootID: resource.root.id,
                rootLabel: resource.root.label,
                relativePath: resource.relativePath,
                fileName: resource.fileName,
                mediaKind: resource.mediaKind,
                role: AssetAssembler.role(for: resource),
                byteSize: resource.byteSize,
                addedAt: resource.addedAt,
                captureTime: resource.captureTime
            )
        }
        .sorted { ($0.rootLabel, $0.relativePath) < ($1.rootLabel, $1.relativePath) }

        return ReportParts(
            roots: rootReports,
            resources: resourceReports,
            livePhotos: livePhotoReports,
            duplicates: duplicateReports,
            events: events,
            recognizedSidecars: recognizedSidecars,
            notices: notices,
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
        case .stillImageTimeMissing:
            return "A matching Live Photo identifier was found, but the paired video has no still-image-time timed metadata marker."
        case .stillImageTimeInvalid:
            return "A matching Live Photo identifier was found, but the paired video's still-image-time timed metadata marker is invalid or ambiguous."
        case .stillImageTimeUnreadable:
            return "A matching Live Photo identifier was found, but the paired video's still-image-time timed metadata could not be verified."
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
