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
    @Published var isPreparingCleanup = false
    @Published var isApplyingCleanup = false
    @Published var cleanupErrorMessage: String?
    @Published var preparedCleanup: PreparedReviewCleanup?
    @Published private(set) var registeredRoots: [RegisteredRootReport] = []
    @Published var selectedRootIDs = Set<String>()
    @Published private(set) var cleanupCopyIDsByItem: [String: Set<String>] = [:]
    @Published private(set) var approvedItemIDs = Set<String>()
    @Published var removeAllConfirmation: RemoveAllCleanupConfirmation?
    @Published private(set) var explicitlyRemoveAllItemIDs = Set<String>()

    init() {
        reload()
    }

    var visibleItems: [DuplicateReviewPresentationItem] {
        guard let items = presentation?.items else { return [] }
        return items.filter { item in
            let itemRootIDs = Set(item.allResources.map(\.rootID))
            guard !selectedRootIDs.isEmpty,
                  itemRootIDs.isSubset(of: selectedRootIDs)
            else { return false }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return item.allResources.contains {
                $0.fileName.localizedCaseInsensitiveContains(query)
                    || $0.relativePath.localizedCaseInsensitiveContains(query)
                    || $0.rootLabel.localizedCaseInsensitiveContains(query)
            }
        }
    }

    var approvedCount: Int { approvedItemIDs.count }

    var approvedCleanupItemCount: Int {
        approvedItemIDs.filter { !(cleanupCopyIDsByItem[$0] ?? []).isEmpty }.count
    }

    var approvedCleanupCopyCount: Int {
        approvedItemIDs.reduce(0) { partial, itemID in
            partial + (cleanupCopyIDsByItem[itemID]?.count ?? 0)
        }
    }

    var activeRegisteredRoots: [RegisteredRootReport] {
        registeredRoots
            .filter { $0.state == .active }
            .sorted {
                if $0.label != $1.label { return $0.label.localizedStandardCompare($1.label) == .orderedAscending }
                return $0.canonicalPath < $1.canonicalPath
            }
    }

    var currentSnapshotRootIDs: Set<String> {
        Set(presentation?.scopeRoots.map(\.id) ?? [])
    }

    var selectedRootsNeedScan: Bool {
        !selectedRootIDs.isEmpty && !selectedRootIDs.isSubset(of: currentSnapshotRootIDs)
    }

    var pendingCount: Int {
        max(0, (presentation?.items.count ?? 0) - approvedItemIDs.count)
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
            guard selectedRootIDs.count > 1 else { return }
            selectedRootIDs.remove(rootID)
        } else {
            selectedRootIDs.insert(rootID)
        }
        approvedItemIDs.removeAll()
        if let selection, !visibleItems.contains(where: { $0.id == selection }) {
            self.selection = visibleItems.first?.id
        }
        if selectedRootsNeedScan {
            statusMessage = "현재 snapshot에 없는 위치가 선택되었습니다. ‘선택 위치 스캔’을 실행하면 함께 비교합니다."
        }
    }

    @discardableResult
    func scanSelectedRoots() async -> Bool {
        guard !isScanning else { return false }
        let roots = activeRegisteredRoots.filter { selectedRootIDs.contains($0.rootID) }
        guard !roots.isEmpty else {
            statusMessage = "비교할 registered root를 하나 이상 선택하세요."
            return false
        }
        let unavailable = roots.filter { !$0.isAvailable }
        guard unavailable.isEmpty else {
            let names = unavailable.map(\.label).joined(separator: ", ")
            statusMessage = "현재 사용할 수 없는 위치가 있습니다: \(names)"
            return false
        }

        isScanning = true
        errorMessage = nil
        statusMessage = "선택한 \(roots.count)개 위치를 비교 스캔하는 중입니다…"
        let scanRoots = roots.map {
            ScanRoot(
                url: URL(fileURLWithPath: $0.canonicalPath, isDirectory: true),
                kind: $0.kind,
                provenance: $0.provenance
            )
        }

        do {
            let next = try await Task.detached(priority: .userInitiated) {
                try await Self.scanPresentation(roots: scanRoots)
            }.value
            registeredRoots = try RootRegistry.list()
            installPresentation(next, selectAllScopeRoots: true)
            statusMessage = "비교 스캔 완료 · \(next.items.count)개 duplicate group"
            isScanning = false
            return true
        } catch {
            statusMessage = "비교 스캔에 실패했습니다: \(error.localizedDescription)"
            isScanning = false
            return false
        }
    }

    @discardableResult
    func registerAndScan(
        url: URL,
        role: RootUsageRole,
        provenance: SourceProvenance
    ) async -> Bool {
        guard !isScanning else { return false }
        do {
            let registered = try RootRegistry.add(
                url: url,
                kind: role.sourceKind,
                provenance: provenance,
                usageRole: role
            )
            registeredRoots = try RootRegistry.list()
            selectedRootIDs.insert(registered.rootID)
            approvedItemIDs.removeAll()
            statusMessage = "‘\(registered.label)’을 \(role.rawValue) root로 등록했습니다. 비교 스캔을 시작합니다…"
        } catch {
            statusMessage = "위치 등록에 실패했습니다: \(error.localizedDescription)"
            return false
        }
        return await scanSelectedRoots()
    }

    func isApproved(_ item: DuplicateReviewPresentationItem) -> Bool {
        approvedItemIDs.contains(item.id)
    }

    func isMarkedForCleanup(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) -> Bool {
        cleanupCopyIDsByItem[item.id, default: []].contains(copy.id)
    }

    func canToggleCleanup(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) -> Bool {
        item.copies.count > 1 || isMarkedForCleanup(copy, item: item)
    }

    func canKeepOnly(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) -> Bool {
        let next = Set(item.copies.filter { $0.id != copy.id }.map(\.id))
        return selectionIsSafe(next, for: item)
    }

    func cleanupToggleHelp(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) -> String {
        if isMarkedForCleanup(copy, item: item) {
            return "클릭하면 이 사본의 정리 표시를 취소합니다."
        }
        if item.kind == .livePhotoAsset,
           copy.isCompleteLivePhotoOccurrence,
           item.copies.filter(\.isCompleteLivePhotoOccurrence).count == 1 {
            return "이 사본은 유일한 완전한 Live Photo 페어입니다. 클릭하면 still + paired video 전체를 정리 대상으로 표시합니다."
        }
        return "클릭하면 이 사본을 정리 대상으로 표시합니다. 마지막 남은 사본이라면 전체 정리 여부를 한 번 더 확인합니다."
    }

    func keepOnlyHelp(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) -> String {
        if canKeepOnly(copy, item: item) {
            if item.kind == .livePhotoAsset && !copy.isCompleteLivePhotoOccurrence {
                return "이 occurrence만 남기면 완전한 still + paired video 페어가 남지 않을 수 있습니다. 선택은 허용되며 실제 정리는 별도 검증 단계입니다."
            }
            return "이 열의 사본을 남기고 나머지 사본을 정리 대상으로 표시합니다. 아직 파일은 이동하지 않습니다."
        }
        return "현재 보존 안전 조건 때문에 이 사본만 남길 수 없습니다."
    }

    func toggleCleanup(
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
            approvedItemIDs.remove(item.id)
            if next.contains(copy.id),
               item.kind == .livePhotoAsset,
               copy.isCompleteLivePhotoOccurrence,
               item.copies.filter(\.isCompleteLivePhotoOccurrence).count == 1 {
                statusMessage = "정리 대상으로 표시했습니다 · 이 사본은 유일한 완전한 Live Photo 페어입니다 · 아직 파일은 이동하지 않았습니다."
            } else {
                statusMessage = next.contains(copy.id)
                    ? "정리 대상으로 표시했습니다. 아직 파일은 이동하지 않았습니다."
                    : "정리 표시를 취소했습니다."
            }

        case .requiresRemoveAllConfirmation:
            let removesOnlyCompletePair = item.kind == .livePhotoAsset
                && item.copies.filter(\.isCompleteLivePhotoOccurrence).count == 1
                && item.copies.first(where: \.isCompleteLivePhotoOccurrence).map { current.contains($0.id) || $0.id == copy.id } == true
            let livePhotoWarning = removesOnlyCompletePair
                ? " 현재 유일한 완전한 Live Photo 페어도 정리 대상에 포함됩니다."
                : ""
            removeAllConfirmation = RemoveAllCleanupConfirmation(
                itemID: item.id,
                message: "이 그룹의 \(item.copies.count)개 사본을 모두 정리 대상으로 표시합니다. 이 단계에서는 파일이 이동되지 않습니다.\(livePhotoWarning)"
            )
            statusMessage = "마지막 남은 사본입니다 · 전체 정리는 확인이 필요합니다."
        }
    }

    func confirmRemoveAll(_ request: RemoveAllCleanupConfirmation) {
        guard let item = presentation?.items.first(where: { $0.id == request.itemID }) else {
            removeAllConfirmation = nil
            return
        }
        cleanupCopyIDsByItem[item.id] = Set(item.copies.map(\.id))
        explicitlyRemoveAllItemIDs.insert(item.id)
        approvedItemIDs.remove(item.id)
        removeAllConfirmation = nil
        statusMessage = "이 그룹의 모든 사본을 정리 대상으로 표시했습니다 · 파일은 아직 이동하지 않았습니다."
    }

    func cancelRemoveAll() {
        removeAllConfirmation = nil
        statusMessage = "전체 정리 선택을 취소했습니다."
    }

    func keepOnly(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) {
        statusMessage = nil
        let next = Set(item.copies.filter { $0.id != copy.id }.map(\.id))
        guard selectionIsSafe(next, for: item) else { return }
        cleanupCopyIDsByItem[item.id] = next
        explicitlyRemoveAllItemIDs.remove(item.id)
        approvedItemIDs.remove(item.id)
        statusMessage = item.kind == .livePhotoAsset && !copy.isCompleteLivePhotoOccurrence
            ? "이 occurrence만 남기도록 선택했습니다 · 완전한 Live Photo 페어는 남지 않습니다 · 아직 파일은 이동하지 않았습니다."
            : "이 사본을 남기고 나머지 사본을 정리 대상으로 표시했습니다."
    }

    func approve(_ item: DuplicateReviewPresentationItem) {
        let selected = cleanupCopyIDsByItem[item.id, default: []]
        let removesAll = selected.count == item.copies.count && !item.copies.isEmpty
        guard !removesAll || explicitlyRemoveAllItemIDs.contains(item.id) else {
            statusMessage = "현재 선택은 보존 안전 조건을 만족하지 않습니다."
            return
        }
        approvedItemIDs.insert(item.id)
        statusMessage = "이 그룹의 선택을 검토 완료로 표시했습니다."
    }

    func approveAndNext(_ item: DuplicateReviewPresentationItem) {
        approve(item)
        guard approvedItemIDs.contains(item.id) else { return }
        selectNext()
    }

    func unapprove(_ item: DuplicateReviewPresentationItem) {
        approvedItemIDs.remove(item.id)
        statusMessage = "검토 완료 표시를 취소했습니다."
    }

    func prepareApprovedCleanup() async {
        guard !isPreparingCleanup && !isApplyingCleanup else { return }
        guard let presentation else { return }
        let decisions = approvedCleanupDecisions(in: presentation)
        guard !decisions.isEmpty else {
            statusMessage = "먼저 정리 대상이 있는 그룹을 검토 완료로 표시하세요."
            return
        }

        isPreparingCleanup = true
        cleanupErrorMessage = nil
        statusMessage = "현재 파일과 정리 선택을 다시 검증하는 중입니다…"

        do {
            let scanner = try ArchiveScanner()
            guard let report = try scanner.latestReusableDuplicateReviewScanReport(),
                  report.sessionID == presentation.sessionID
            else {
                throw DuplicateReviewCleanupError.sessionMismatch
            }
            let plan = ReconciliationPlanner.makePlan(from: report)
            let settings = try PhotoArchiveSettingsStore.load()
            let destination = try PhotoArchiveSettingsStore.resolvedDestination(
                settings.duplicateCleanupDestination
            )
            let explicitRemoveAll = explicitlyRemoveAllItemIDs.intersection(approvedItemIDs)
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
                selectedCopyCount: approvedCleanupCopyCount
            )
            statusMessage = "정리 전 검증 완료 · 실제 이동 전 최종 확인이 필요합니다."
        } catch {
            cleanupErrorMessage = error.localizedDescription
            statusMessage = "정리 전 검증에 실패했습니다: \(error.localizedDescription)"
        }
        isPreparingCleanup = false
    }

    func cancelPreparedCleanup() {
        guard !isApplyingCleanup else { return }
        preparedCleanup = nil
        cleanupErrorMessage = nil
        statusMessage = "정리 전 확인을 취소했습니다."
    }

    func applyPreparedCleanup() async {
        guard !isApplyingCleanup, let preparedCleanup else { return }
        isApplyingCleanup = true
        cleanupErrorMessage = nil
        statusMessage = "현재 파일을 다시 검증한 뒤 reversible destination으로 이동하는 중입니다…"

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
            approvedItemIDs.removeAll()
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
            statusMessage = "정리를 적용하지 못했습니다: \(error.localizedDescription)"
            isApplyingCleanup = false
        }
    }

    private func approvedCleanupDecisions(
        in presentation: DuplicateReviewPresentation
    ) -> [DuplicateReviewDecision] {
        presentation.items.compactMap { item in
            guard approvedItemIDs.contains(item.id) else { return nil }
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

    private func selectionIsSafe(
        _ cleanupIDs: Set<String>,
        for item: DuplicateReviewPresentationItem
    ) -> Bool {
        let remaining = item.copies.filter { !cleanupIDs.contains($0.id) }
        return !remaining.isEmpty
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
            let suggested = Set(item.copies.filter { !$0.isKeeper }.map(\.id))
            return (item.id, suggested)
        })
        explicitlyRemoveAllItemIDs.removeAll()
        removeAllConfirmation = nil
        approvedItemIDs.removeAll()
        if let previousSelection,
           next.items.contains(where: { $0.id == previousSelection }) {
            selection = previousSelection
        } else {
            selection = next.items.first?.id
        }
    }

    nonisolated private static func scanPresentation(
        roots: [ScanRoot]
    ) async throws -> DuplicateReviewPresentation {
        let scanner = try ArchiveScanner()
        let report = try await scanner.scan(roots: roots)
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
