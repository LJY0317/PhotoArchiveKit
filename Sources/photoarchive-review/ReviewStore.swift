import Foundation
import PhotoArchiveCore

@MainActor
final class ReviewStore: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case standalone
        case livePhoto

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "전체"
            case .standalone: return "사진·동영상"
            case .livePhoto: return "Live Photo"
            }
        }
    }

    @Published var presentation: DuplicateReviewPresentation?
    @Published var selection: String?
    @Published var filter: Filter = .all
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published var isLoading = false

    init() {
        reload()
    }

    var visibleItems: [DuplicateReviewPresentationItem] {
        guard let items = presentation?.items else { return [] }
        return items.filter { item in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .standalone:
                matchesFilter = item.kind == .standaloneExactGroup
            case .livePhoto:
                matchesFilter = item.kind == .livePhotoAsset
            }
            guard matchesFilter else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return item.allResources.contains {
                $0.fileName.localizedCaseInsensitiveContains(query)
                    || $0.relativePath.localizedCaseInsensitiveContains(query)
                    || $0.rootLabel.localizedCaseInsensitiveContains(query)
            }
        }
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
        do {
            let next = try DuplicateReviewPresentationBuilder.latest()
            presentation = next
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

    func selectPrevious() {
        guard let index = selectedIndex, index > 0 else { return }
        selection = visibleItems[index - 1].id
    }

    func selectNext() {
        guard let index = selectedIndex, index + 1 < visibleItems.count else { return }
        selection = visibleItems[index + 1].id
    }
}
