import Foundation
import PhotoArchiveCore

@MainActor
final class ReviewStore: ObservableObject {
    @Published var presentation: DuplicateReviewPresentation?
    @Published var selection: String?
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var isLoading = false
    @Published var selectedRootIDs = Set<String>()
    @Published private(set) var cleanupCopyIDsByItem: [String: Set<String>] = [:]
    @Published private(set) var approvedItemIDs = Set<String>()

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
            let next = try DuplicateReviewPresentationBuilder.latest()
            presentation = next
            selectedRootIDs = Set(next.scopeRoots.map(\.id))
            cleanupCopyIDsByItem = Dictionary(uniqueKeysWithValues: next.items.map { item in
                let suggested = Set(item.copies.filter { !$0.isKeeper }.map(\.id))
                return (item.id, suggested)
            })
            approvedItemIDs.removeAll()
            if let selection, next.items.contains(where: { $0.id == selection }) {
                self.selection = selection
            } else {
                selection = next.items.first?.id
            }
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
        if let selection, !visibleItems.contains(where: { $0.id == selection }) {
            self.selection = visibleItems.first?.id
        }
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

    func toggleCleanup(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) {
        statusMessage = nil
        var next = cleanupCopyIDsByItem[item.id, default: []]
        if next.contains(copy.id) {
            next.remove(copy.id)
        } else {
            next.insert(copy.id)
        }
        guard selectionIsSafe(next, for: item) else {
            statusMessage = item.kind == .livePhotoAsset
                ? "Live Photo는 최소 하나의 온전한 still + paired video occurrence를 남겨야 합니다."
                : "모든 사본을 정리 대상으로 선택할 수는 없습니다."
            return
        }
        cleanupCopyIDsByItem[item.id] = next
        approvedItemIDs.remove(item.id)
    }

    func keepOnly(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) {
        statusMessage = nil
        if item.kind == .livePhotoAsset && !copy.isCompleteLivePhotoOccurrence {
            statusMessage = "온전한 Live Photo occurrence만 단독 keeper로 지정할 수 있습니다."
            return
        }
        let next = Set(item.copies.filter { $0.id != copy.id }.map(\.id))
        guard selectionIsSafe(next, for: item) else { return }
        cleanupCopyIDsByItem[item.id] = next
        approvedItemIDs.remove(item.id)
    }

    func approve(_ item: DuplicateReviewPresentationItem) {
        let selected = cleanupCopyIDsByItem[item.id, default: []]
        guard selectionIsSafe(selected, for: item) else {
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

    func submitApproved() {
        guard let presentation else { return }
        let approvedItems = presentation.items.filter { approvedItemIDs.contains($0.id) }
        guard !approvedItems.isEmpty else {
            statusMessage = "먼저 하나 이상의 그룹을 검토 완료로 표시하세요."
            return
        }

        let decisions = approvedItems.map { item -> DuplicateReviewDecision in
            let cleanupIDs = cleanupCopyIDsByItem[item.id, default: []]
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

        do {
            try DuplicateReviewDecisionStore.save(
                DuplicateReviewDecisionBundle(
                    sessionID: presentation.sessionID,
                    decisions: decisions
                )
            )
            statusMessage = "검토 \(decisions.count)개 그룹을 제출했습니다. 파일은 아직 이동하지 않았습니다."
        } catch {
            statusMessage = "검토 제출에 실패했습니다: \(error.localizedDescription)"
        }
    }

    private func selectionIsSafe(
        _ cleanupIDs: Set<String>,
        for item: DuplicateReviewPresentationItem
    ) -> Bool {
        let remaining = item.copies.filter { !cleanupIDs.contains($0.id) }
        guard !remaining.isEmpty else { return false }
        if item.kind == .livePhotoAsset {
            return remaining.contains(where: \.isCompleteLivePhotoOccurrence)
        }
        return true
    }

    func selectPrevious() {
        guard let index = selectedIndex, index > 0 else { return }
        selection = visibleItems[index - 1].id
    }

    func selectNext() {
        guard let index = selectedIndex, index + 1 < visibleItems.count else { return }
        selection = visibleItems[index + 1].id
    }
}
