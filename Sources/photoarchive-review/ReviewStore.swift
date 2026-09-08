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
    @Published private(set) var cleanupDestinationSetting = DuplicateCleanupDestinationSetting.systemTrash
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
            guard selectedRootIDs.count > 1 else { return }
            selectedRootIDs.remove(rootID)
        } else {
            selectedRootIDs.insert(rootID)
        }
        cleanupCopyIDsByItem = cleanupCopyIDsByItem.mapValues { _ in [] }
        explicitlyRemoveAllItemIDs.removeAll()
        removeAllConfirmation = nil
        preparedCleanup = nil
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
            statusMessage = "‘\(registered.label)’을 \(role.rawValue) root로 등록했습니다. 비교 스캔을 시작합니다…"
        } catch {
            statusMessage = "위치 등록에 실패했습니다: \(error.localizedDescription)"
            return false
        }
        return await scanSelectedRoots()
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
            statusMessage = "모든 사본을 삭제 대상으로 선택하려면 미리보기의 ‘삭제 대상으로 선택’ 버튼을 사용하세요."
            return
        }

        cleanupCopyIDsByItem[item.id] = next
        explicitlyRemoveAllItemIDs.remove(item.id)
        statusMessage = next.contains(copy.id)
            ? "삭제 대상으로 선택했습니다. 아직 파일은 이동하지 않았습니다."
            : "삭제 선택을 취소했습니다."
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
            if next.contains(copy.id),
               item.kind == .livePhotoAsset,
               copy.isCompleteLivePhotoOccurrence,
               item.copies.filter(\.isCompleteLivePhotoOccurrence).count == 1 {
                statusMessage = "삭제 대상으로 선택했습니다 · 이 사본은 유일한 완전한 Live Photo 페어입니다 · 아직 파일은 이동하지 않았습니다."
            } else {
                statusMessage = next.contains(copy.id)
                    ? "삭제 대상으로 선택했습니다. 아직 파일은 이동하지 않았습니다."
                    : "삭제 선택을 취소했습니다."
            }

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
            statusMessage = "마지막 남은 사본입니다 · 전체 삭제 선택은 확인이 필요합니다."
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
        statusMessage = "이 그룹의 모든 사본을 삭제 대상으로 선택했습니다 · 파일은 아직 이동하지 않았습니다."
    }

    func cancelRemoveAll() {
        removeAllConfirmation = nil
        statusMessage = "전체 삭제 선택을 취소했습니다."
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
        statusMessage = "현재 파일과 삭제 선택을 다시 검증하는 중입니다…"

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
            statusMessage = "이동 전 검증 완료 · 실제 이동 전 최종 확인이 필요합니다."
        } catch {
            cleanupErrorMessage = error.localizedDescription
            statusMessage = "이동 전 검증에 실패했습니다: \(error.localizedDescription)"
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
