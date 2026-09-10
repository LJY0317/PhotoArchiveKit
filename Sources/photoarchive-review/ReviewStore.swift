import Foundation
import PhotoArchiveCore

struct RemoveAllCleanupConfirmation: Identifiable {
    let id = UUID()
    let itemID: String
    let message: String
}

struct PreparedReviewCleanup: Identifiable {
    let id = UUID()
    let report: ScanReport
    let plan: ReconciliationPlan
    let decisions: [DuplicateReviewDecision]
    let explicitlyRemoveAllItemIDs: Set<String>
    let destination: DuplicateCleanupDestination
    let preflight: DuplicateReviewCleanupReport
    let selectedCopyCount: Int
}

@MainActor
final class ReviewStore: ObservableObject {
    @Published var presentation: DuplicateReviewPresentation?
    @Published var selection: String?
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var isLoading = false
    @Published var isScanning = false
    @Published private(set) var scanProgress: ScanProgress?
    @Published var isPreparingCleanup = false
    @Published var isApplyingCleanup = false
    @Published var cleanupErrorMessage: String?
    @Published var preparedCleanup: PreparedReviewCleanup?
    @Published private(set) var registeredRoots: [RegisteredRootReport] = []
    @Published var selectedRootIDs = Set<String>()
    @Published private(set) var cleanupCopyIDsByItem: [String: Set<String>] = [:]
    @Published private(set) var cleanupDestinationSetting = DuplicateCleanupDestinationSetting.systemTrash
    @Published var removeAllConfirmation: RemoveAllCleanupConfirmation?
    @Published private(set) var explicitlyRemoveAllItemIDs = Set<String>()

    init() {
        reload()
    }

    var visibleItems: [DuplicateReviewPresentationItem] {
        itemsInSelectedRoots.filter { item in
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return item.allResources.contains {
                $0.fileName.localizedCaseInsensitiveContains(query)
                    || $0.relativePath.localizedCaseInsensitiveContains(query)
                    || $0.rootLabel.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var itemsInSelectedRoots: [DuplicateReviewPresentationItem] {
        guard let items = presentation?.items else { return [] }
        return items.filter { item in
            let itemRootIDs = Set(item.allResources.map(\.rootID))
            guard !selectedRootIDs.isEmpty,
                  itemRootIDs.isSubset(of: selectedRootIDs)
            else { return false }
            return true
        }
    }

    var selectedCleanupItemCount: Int {
        cleanupCopyIDsByItem.values.filter { !$0.isEmpty }.count
    }

    var selectedCleanupCopyCount: Int {
        cleanupCopyIDsByItem.values.reduce(0) { $0 + $1.count }
    }

    var cleanupMoveActionTitle: String {
        switch cleanupDestinationSetting.kind {
        case .systemTrash:
            return "휴지통으로 이동…"
        case .customQuarantine:
            return "격리 폴더로 이동…"
        }
    }

    var canToggleRecommendedCleanupSelection: Bool {
        !recommendedCleanupTargetsByItem.isEmpty
    }

    var recommendedCleanupSelectionIsApplied: Bool {
        let targets = recommendedCleanupTargetsByItem
        guard !targets.isEmpty else { return false }
        return targets.allSatisfy { itemID, copyIDs in
            cleanupCopyIDsByItem[itemID, default: []] == copyIDs
        }
    }

    var recommendedCleanupSelectionTitle: String {
        recommendedCleanupSelectionIsApplied ? "삭제 선택 모두 해제" : "추천 삭제 대상 모두 선택"
    }

    var activeRegisteredRoots: [RegisteredRootReport] {
        registeredRoots.filter { $0.state == .active }
    }

    var currentSnapshotRootIDs: Set<String> {
        Set(presentation?.scopeRoots.map(\.id) ?? [])
    }

    var selectedRootLabels: [String] {
        activeRegisteredRoots
            .filter { selectedRootIDs.contains($0.rootID) }
            .map(\.label)
    }

    var selectedRootsNeedScan: Bool {
        !selectedRootIDs.isEmpty && !selectedRootIDs.isSubset(of: currentSnapshotRootIDs)
    }

    var selectedItem: DuplicateReviewPresentationItem? {
        guard let selection else { return visibleItems.first }
        return visibleItems.first(where: { $0.id == selection }) ?? visibleItems.first
    }

    var selectedIndex: Int? {
        guard let item = selectedItem else { return nil }
        return visibleItems.firstIndex(where: { $0.id == item.id })
    }

    func reload() {
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        cleanupDestinationSetting = (try? PhotoArchiveSettingsStore.load())?.duplicateCleanupDestination
            ?? .systemTrash
        do {
            registeredRoots = try RootRegistry.list()
            let next = try DuplicateReviewPresentationBuilder.latest()
            installPresentation(next, selectAllScopeRoots: true)
        } catch {
            presentation = nil
            selection = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func toggleRoot(_ rootID: String) {
        statusMessage = nil
        if selectedRootIDs.contains(rootID) {
            selectedRootIDs.remove(rootID)
        } else {
            selectedRootIDs.insert(rootID)
        }
        resetReviewChoicesForRootChange()
    }

    func setRootActive(_ rootID: String, isActive: Bool) {
        guard !isScanning else { return }
        do {
            _ = try RootRegistry.setState(
                target: rootID,
                state: isActive ? .active : .inactive
            )
            registeredRoots = try RootRegistry.list()
            if !isActive {
                selectedRootIDs.remove(rootID)
            }
            ensureUsableRootSelection()
            resetReviewChoicesForRootChange()
            statusMessage = nil
        } catch {
            statusMessage = "폴더 설정을 바꾸지 못했습니다: \(error.localizedDescription)"
        }
    }

    func setRootUserPurpose(_ rootID: String, purpose: RootUserPurpose) {
        guard !isScanning else { return }
        do {
            _ = try RootRegistry.setUserPurpose(target: rootID, purpose: purpose)
            registeredRoots = try RootRegistry.list()

            let previousSelectedRootIDs = selectedRootIDs
            if let next = try? DuplicateReviewPresentationBuilder.latest() {
                installPresentation(next, selectAllScopeRoots: false)
                let scopeRootIDs = Set(next.scopeRoots.map(\.id))
                selectedRootIDs = previousSelectedRootIDs.intersection(scopeRootIDs)
                ensureUsableRootSelection()
            } else {
                resetReviewChoicesForRootChange()
            }

            statusMessage = nil
        } catch {
            statusMessage = "폴더 용도를 바꾸지 못했습니다: \(error.localizedDescription)"
        }
    }

    func unregisterRoot(_ rootID: String) {
        guard !isScanning else { return }
        do {
            _ = try RootRegistry.remove(target: rootID)
            registeredRoots = try RootRegistry.list()
            selectedRootIDs.remove(rootID)
            ensureUsableRootSelection()
            resetReviewChoicesForRootChange()
            statusMessage = nil
        } catch {
            statusMessage = "폴더 등록을 해제하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func reorderRegisteredRoots(_ rootIDs: [String]) {
        guard !isScanning else { return }
        do {
            registeredRoots = try RootRegistry.setDisplayOrder(rootIDs: rootIDs)
            statusMessage = nil
        } catch {
            statusMessage = "폴더 순서를 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func ensureUsableRootSelection() {
        let activeIDs = Set(activeRegisteredRoots.map(\.rootID))
        selectedRootIDs.formIntersection(activeIDs)
    }

    private func resetReviewChoicesForRootChange() {
        cleanupCopyIDsByItem = cleanupCopyIDsByItem.mapValues { _ in [] }
        explicitlyRemoveAllItemIDs.removeAll()
        removeAllConfirmation = nil
        preparedCleanup = nil
        if let selection, !visibleItems.contains(where: { $0.id == selection }) {
            self.selection = visibleItems.first?.id
        }
    }

    @discardableResult
    func scanSelectedRoots() async -> Bool {
        guard !isScanning else { return false }
        let roots = activeRegisteredRoots.filter { selectedRootIDs.contains($0.rootID) }
        guard !roots.isEmpty else {
            statusMessage = "비교할 폴더를 하나 이상 선택하세요."
            return false
        }
        let unavailable = roots.filter { !$0.isAvailable }
        guard unavailable.isEmpty else {
            let names = unavailable.map(\.label).joined(separator: ", ")
            statusMessage = "현재 사용할 수 없는 폴더가 있습니다: \(names)"
            return false
        }

        isScanning = true
        scanProgress = ScanProgress(stage: .enumerating, completedUnitCount: 0)
        errorMessage = nil
        statusMessage = "선택한 \(roots.count)개 폴더를 스캔하는 중입니다…"
        let scanRoots = roots.map {
            ScanRoot(
                url: URL(fileURLWithPath: $0.canonicalPath, isDirectory: true),
                kind: $0.kind,
                provenance: $0.provenance
            )
        }

        let progressHandler: ScanProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.isScanning else { return }
                self.scanProgress = progress
            }
        }

        do {
            let next = try await Task.detached(priority: .userInitiated) {
                try await Self.scanPresentation(
                    roots: scanRoots,
                    progressHandler: progressHandler
                )
            }.value
            registeredRoots = try RootRegistry.list()
            installPresentation(next, selectAllScopeRoots: true)
            statusMessage = "비교가 완료되었습니다 · 중복 항목 \(next.items.count)개"
            scanProgress = nil
            isScanning = false
            return true
        } catch {
            statusMessage = "비교하지 못했습니다: \(error.localizedDescription)"
            scanProgress = nil
            isScanning = false
            return false
        }
    }

    @discardableResult
    func registerAndScan(
        url: URL,
        purpose: RootUserPurpose
    ) async -> Bool {
        guard !isScanning else { return false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try RootRegistry.addComparisonRoot(url: url, purpose: purpose)
            }.value
            registeredRoots = try RootRegistry.list()
            if result.wasAlreadyRegistered {
                if result.root.state == .active,
                   !selectedRootIDs.contains(result.root.rootID) {
                    selectedRootIDs.insert(result.root.rootID)
                    resetReviewChoicesForRootChange()
                }
                statusMessage = "이미 등록된 폴더입니다."
                return true
            }
            selectedRootIDs.insert(result.root.rootID)
            statusMessage = nil
        } catch {
            statusMessage = "폴더를 추가하지 못했습니다: \(error.localizedDescription)"
            return false
        }
        return await scanSelectedRoots()
    }

    func isRegisteredRoot(_ url: URL) -> Bool {
        registeredRoot(at: url) != nil
    }

    func selectRegisteredRoot(at url: URL) {
        guard let root = registeredRoot(at: url) else { return }
        if root.state == .active,
           !selectedRootIDs.contains(root.rootID) {
            selectedRootIDs.insert(root.rootID)
            resetReviewChoicesForRootChange()
        }
        statusMessage = nil
    }

    private func registeredRoot(at url: URL) -> RegisteredRootReport? {
        let target = normalizedRootPath(url)
        return registeredRoots.first { root in
            normalizedRootPath(URL(fileURLWithPath: root.canonicalPath, isDirectory: true)) == target
        }
    }

    private func normalizedRootPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath()
            .standardizedFileURL.path
            .decomposedStringWithCanonicalMapping
    }

    func isMarkedForCleanup(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) -> Bool {
        cleanupCopyIDsByItem[item.id, default: []].contains(copy.id)
    }

    func toggleRecommendedCleanupSelection() {
        guard !isScanning && !isPreparingCleanup && !isApplyingCleanup else { return }
        let items = itemsInSelectedRoots
        let targets = recommendedCleanupTargetsByItem
        guard !targets.isEmpty else { return }

        statusMessage = nil
        cleanupErrorMessage = nil
        preparedCleanup = nil
        removeAllConfirmation = nil

        if recommendedCleanupSelectionIsApplied {
            for item in items {
                cleanupCopyIDsByItem[item.id] = []
            }
        } else {
            for item in items {
                cleanupCopyIDsByItem[item.id] = targets[item.id] ?? []
            }
        }

        explicitlyRemoveAllItemIDs.subtract(items.map(\.id))
    }

    func canToggleCleanup(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) -> Bool {
        item.copies.count > 1 || isMarkedForCleanup(copy, item: item)
    }

    func cleanupToggleHelp(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) -> String {
        if isMarkedForCleanup(copy, item: item) {
            return "클릭하면 이 사본의 삭제 선택을 취소합니다."
        }
        if item.kind == .livePhotoAsset,
           copy.isCompleteLivePhotoOccurrence,
           item.copies.filter(\.isCompleteLivePhotoOccurrence).count == 1 {
            return "이 사본은 유일한 완전한 Live Photo 페어입니다. 클릭하면 still + paired video 전체를 삭제 대상으로 선택합니다."
        }
        return "클릭하면 이 사본을 삭제 대상으로 선택합니다. 마지막 남은 사본이라면 전체 삭제 선택 여부를 한 번 더 확인합니다."
    }

    func columnToggleHelp(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) -> String {
        let current = cleanupCopyIDsByItem[item.id, default: []]
        if current.contains(copy.id) {
            return "클릭하면 이 사본의 삭제 선택을 취소합니다."
        }
        let wouldSelectAll = !item.copies.isEmpty
            && current.union([copy.id]).count == item.copies.count
        if wouldSelectAll, item.copies.count == 2 {
            return "클릭하면 삭제 대상을 이 사본으로 바꾸고 반대쪽 사본은 남깁니다."
        }
        if wouldSelectAll {
            return "모든 사본을 삭제 대상으로 선택하려면 미리보기의 ‘삭제 대상으로 선택’ 버튼을 사용하세요."
        }
        return "클릭하면 이 사본을 삭제 대상으로 선택합니다."
    }

    func toggleCleanupFromColumn(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) {
        statusMessage = nil
        let current = cleanupCopyIDsByItem[item.id, default: []]
        let next = DuplicateReviewSelectionPolicy.toggleCleanupCopyIDsFromColumn(
            current: current,
            clickedCopyID: copy.id,
            allCopyIDs: item.copies.map(\.id)
        )

        guard next != current else {
            return
        }

        cleanupCopyIDsByItem[item.id] = next
        explicitlyRemoveAllItemIDs.remove(item.id)
    }

    func toggleCleanupFromButton(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) {
        statusMessage = nil
        let current = cleanupCopyIDsByItem[item.id, default: []]
        let result = DuplicateReviewSelectionPolicy.toggleCleanupCopyIDs(
            current: current,
            clickedCopyID: copy.id,
            allCopyIDs: item.copies.map(\.id)
        )

        switch result {
        case let .updated(next):
            cleanupCopyIDsByItem[item.id] = next
            explicitlyRemoveAllItemIDs.remove(item.id)

        case .requiresRemoveAllConfirmation:
            let removesOnlyCompletePair = item.kind == .livePhotoAsset
                && item.copies.filter(\.isCompleteLivePhotoOccurrence).count == 1
                && item.copies.first(where: \.isCompleteLivePhotoOccurrence).map { current.contains($0.id) || $0.id == copy.id } == true
            let livePhotoWarning = removesOnlyCompletePair
                ? " 현재 유일한 완전한 Live Photo 페어도 삭제 대상에 포함됩니다."
                : ""
            removeAllConfirmation = RemoveAllCleanupConfirmation(
                itemID: item.id,
                message: "이 그룹의 \(item.copies.count)개 사본을 모두 삭제 대상으로 선택합니다. 이 단계에서는 파일이 이동되지 않습니다.\(livePhotoWarning)"
            )
        }
    }

    func confirmRemoveAll(_ request: RemoveAllCleanupConfirmation) {
        guard let item = presentation?.items.first(where: { $0.id == request.itemID }) else {
            removeAllConfirmation = nil
            return
        }
        cleanupCopyIDsByItem[item.id] = Set(item.copies.map(\.id))
        explicitlyRemoveAllItemIDs.insert(item.id)
        removeAllConfirmation = nil
    }

    func cancelRemoveAll() {
        removeAllConfirmation = nil
    }

    func prepareSelectedCleanup() async {
        guard !isPreparingCleanup && !isApplyingCleanup else { return }
        guard let presentation else { return }
        let decisions = selectedCleanupDecisions(in: presentation)
        guard !decisions.isEmpty else {
            statusMessage = "먼저 삭제할 사본을 하나 이상 선택하세요."
            return
        }

        isPreparingCleanup = true
        cleanupErrorMessage = nil
        statusMessage = "선택한 파일을 확인하는 중입니다…"

        do {
            let scanner = try ArchiveScanner()
            guard let report = try scanner.latestReusableDuplicateReviewScanReport(),
                  report.sessionID == presentation.sessionID
            else {
                throw DuplicateReviewCleanupError.sessionMismatch
            }
            let plan = ReconciliationPlanner.makePlan(from: report)
            let settings = try PhotoArchiveSettingsStore.load()
            cleanupDestinationSetting = settings.duplicateCleanupDestination
            let destination = try PhotoArchiveSettingsStore.resolvedDestination(
                settings.duplicateCleanupDestination
            )
            let selectedItemIDs = Set(decisions.map(\.itemID))
            let explicitRemoveAll = explicitlyRemoveAllItemIDs.intersection(selectedItemIDs)
            let preflight = try await Task.detached(priority: .userInitiated) {
                try DuplicateReviewCleanupExecutor.preflight(
                    report: report,
                    plan: plan,
                    decisions: decisions,
                    explicitlyRemoveAllItemIDs: explicitRemoveAll,
                    destination: destination
                )
            }.value

            preparedCleanup = PreparedReviewCleanup(
                report: report,
                plan: plan,
                decisions: decisions,
                explicitlyRemoveAllItemIDs: explicitRemoveAll,
                destination: destination,
                preflight: preflight,
                selectedCopyCount: selectedCleanupCopyCount
            )
            statusMessage = nil
        } catch {
            cleanupErrorMessage = error.localizedDescription
            statusMessage = "선택한 파일을 확인하지 못했습니다: \(error.localizedDescription)"
        }
        isPreparingCleanup = false
    }

    func cancelPreparedCleanup() {
        guard !isApplyingCleanup else { return }
        preparedCleanup = nil
        cleanupErrorMessage = nil
        statusMessage = "이동을 취소했습니다."
    }

    func applyPreparedCleanup() async {
        guard !isApplyingCleanup, let preparedCleanup else { return }
        isApplyingCleanup = true
        cleanupErrorMessage = nil
        statusMessage = "선택한 파일을 이동하는 중입니다…"

        do {
            try DuplicateReviewDecisionStore.save(
                DuplicateReviewDecisionBundle(
                    sessionID: preparedCleanup.report.sessionID,
                    decisions: preparedCleanup.decisions
                )
            )
            let applied = try await Task.detached(priority: .userInitiated) {
                try DuplicateReviewCleanupExecutor.apply(
                    report: preparedCleanup.report,
                    plan: preparedCleanup.plan,
                    decisions: preparedCleanup.decisions,
                    explicitlyRemoveAllItemIDs: preparedCleanup.explicitlyRemoveAllItemIDs,
                    destination: preparedCleanup.destination
                )
            }.value

            self.preparedCleanup = nil
            explicitlyRemoveAllItemIDs.removeAll()
            isApplyingCleanup = false

            let destinationText = applied.destinationKind == .systemTrash
                ? "macOS 휴지통"
                : "사용자 지정 격리 폴더"
            let movedSummary = "\(applied.resourceCount)개 파일을 \(destinationText)(으)로 이동했습니다."
            let refreshed = await scanSelectedRoots()
            statusMessage = refreshed
                ? "\(movedSummary) 비교 결과도 새로고침했습니다."
                : movedSummary
        } catch {
            cleanupErrorMessage = error.localizedDescription
            statusMessage = "이동을 적용하지 못했습니다: \(error.localizedDescription)"
            isApplyingCleanup = false
        }
    }

    private func selectedCleanupDecisions(
        in presentation: DuplicateReviewPresentation
    ) -> [DuplicateReviewDecision] {
        presentation.items.compactMap { item in
            let cleanupIDs = cleanupCopyIDsByItem[item.id, default: []]
            guard !cleanupIDs.isEmpty else { return nil }
            let keptResources = item.copies
                .filter { !cleanupIDs.contains($0.id) }
                .flatMap(\.resources)
                .map(\.id)
            let cleanupResources = item.copies
                .filter { cleanupIDs.contains($0.id) }
                .flatMap(\.resources)
                .map(\.id)
            return DuplicateReviewDecision(
                itemID: item.id,
                subjectID: item.subjectID,
                keptResourceIDs: keptResources,
                cleanupResourceIDs: cleanupResources
            )
        }
    }

    private var recommendedCleanupTargetsByItem: [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: itemsInSelectedRoots.compactMap { item in
            let keeperCopyIDs = Set(item.copies.filter(\.isKeeper).map(\.id))
            let cleanupCopyIDs = DuplicateReviewSelectionPolicy.cleanupCopyIDsExcludingKeepers(
                allCopyIDs: item.copies.map(\.id),
                keeperCopyIDs: keeperCopyIDs
            )
            guard !cleanupCopyIDs.isEmpty else { return nil }
            return (item.id, cleanupCopyIDs)
        })
    }

    func selectPrevious() {
        guard let index = selectedIndex, index > 0 else { return }
        selection = visibleItems[index - 1].id
    }

    func selectNext() {
        guard let index = selectedIndex, index + 1 < visibleItems.count else { return }
        selection = visibleItems[index + 1].id
    }

    private func installPresentation(
        _ next: DuplicateReviewPresentation,
        selectAllScopeRoots: Bool
    ) {
        let previousSelection = selection
        presentation = next
        if selectAllScopeRoots {
            selectedRootIDs = Set(next.scopeRoots.map(\.id))
        }
        cleanupCopyIDsByItem = Dictionary(uniqueKeysWithValues: next.items.map { item in
            (item.id, [])
        })
        explicitlyRemoveAllItemIDs.removeAll()
        removeAllConfirmation = nil
        if let previousSelection,
           next.items.contains(where: { $0.id == previousSelection }) {
            selection = previousSelection
        } else {
            selection = next.items.first?.id
        }
    }

    nonisolated private static func scanPresentation(
        roots: [ScanRoot],
        progressHandler: ScanProgressHandler? = nil
    ) async throws -> DuplicateReviewPresentation {
        let scanner = try ArchiveScanner()
        let report = try await scanner.scan(
            roots: roots,
            options: ScanOptions(progressHandler: progressHandler)
        )
        let plan = ReconciliationPlanner.makePlan(from: report)
        let referenceKeys = Set(plan.items.flatMap { item in
            (item.preferredResources + item.candidateResources).map {
                "\($0.rootID)\u{0}\($0.relativePath)"
            }
        })
        let resourceIDs = report.resources.compactMap { resource -> String? in
            let key = "\(resource.rootID)\u{0}\(resource.relativePath)"
            return referenceKeys.contains(key) ? resource.resourceID : nil
        }
        let details = try scanner.duplicateReviewResourceDetails(resourceIDs: resourceIDs)
        return DuplicateReviewPresentationBuilder.makePresentation(
            report: report,
            plan: plan,
            detailsByResourceID: details
        )
    }
}
