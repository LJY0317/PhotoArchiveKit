import AppKit
import PhotoArchiveCore
import QuickLookThumbnailing
import SwiftUI

struct ReviewRootView: View {
    @StateObject private var store = ReviewStore()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: store.selectPrevious) {
                    Label("이전", systemImage: "chevron.left")
                }
                .disabled(store.selectedIndex == nil || store.selectedIndex == 0)

                Button(action: store.selectNext) {
                    Label("다음", systemImage: "chevron.right")
                }
                .disabled(
                    store.selectedIndex == nil
                        || store.selectedIndex == max(0, store.visibleItems.count - 1)
                )
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: store.reload) {
                    Label("다시 불러오기", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoArchiveReloadReview)) { _ in
            store.reload()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if let presentation = store.presentation {
                ReviewSummaryHeader(presentation: presentation)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                Picker("필터", selection: $store.filter) {
                    ForEach(ReviewStore.Filter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            List(store.visibleItems, selection: $store.selection) { item in
                ReviewSidebarRow(item: item)
                    .tag(item.id)
            }
            .listStyle(.sidebar)
            .searchable(text: $store.searchText, prompt: "파일명 또는 위치 검색")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if store.isLoading {
            ContentUnavailableView {
                ProgressView()
                Text("중복 검토를 불러오는 중…")
            }
        } else if let message = store.errorMessage {
            ContentUnavailableView(
                "검토 데이터를 열 수 없습니다",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        } else if let item = store.selectedItem {
            ReviewDetailView(
                item: item,
                index: (store.selectedIndex ?? 0) + 1,
                total: store.visibleItems.count
            )
        } else {
            ContentUnavailableView(
                "검토할 중복이 없습니다",
                systemImage: "checkmark.circle",
                description: Text("현재 필터에 표시할 automatic exact duplicate group이 없습니다.")
            )
        }
    }
}

private struct ReviewSummaryHeader: View {
    let presentation: DuplicateReviewPresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate Review")
                    .font(.headline)
                Text("\(presentation.items.count)개 그룹 · \(presentation.candidateResourceCount)개 후보")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
                .help("읽기 전용 검토")
        }
    }
}

private struct ReviewSidebarRow: View {
    let item: DuplicateReviewPresentationItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == .livePhotoAsset ? "livephoto" : "photo.stack")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryName)
                    .font(.body)
                    .lineLimit(1)
                Text(item.kind == .livePhotoAsset ? "Live Photo" : "Exact duplicate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            Text("\(item.candidateResources.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 3)
    }

    private var primaryName: String {
        item.preferredResources.first?.fileName
            ?? item.candidateResources.first?.fileName
            ?? item.id
    }
}

private struct ReviewDetailView: View {
    let item: DuplicateReviewPresentationItem
    let index: Int
    let total: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                HStack(alignment: .top, spacing: 16) {
                    ReviewSideSection(
                        title: "KEEPER",
                        subtitle: "남길 사본",
                        systemImage: "checkmark.circle.fill",
                        resources: item.preferredResources,
                        isKeeper: true
                    )
                    .frame(maxWidth: .infinity, alignment: .top)

                    ReviewSideSection(
                        title: "CANDIDATE",
                        subtitle: item.candidateResources.count == 1
                            ? "중복 정리 후보"
                            : "중복 정리 후보 \(item.candidateResources.count)개",
                        systemImage: "minus.circle",
                        resources: item.candidateResources,
                        isKeeper: false
                    )
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(index) / \(total)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("EXACT")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                if item.kind == .livePhotoAsset {
                    Label("Live Photo", systemImage: "livephoto")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(rationaleTitle(item.rationale))
                .font(.title2.weight(.semibold))

            Text(rationaleDetail(item.rationale))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ReviewSideSection: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let resources: [DuplicateReviewPresentationResource]
    let isKeeper: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.bold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isKeeper ? .green : .secondary)
            }

            ForEach(resources) { resource in
                ReviewResourceCard(resource: resource, isKeeper: isKeeper)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ReviewResourceCard: View {
    let resource: DuplicateReviewPresentationResource
    let isKeeper: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReviewThumbnail(url: resource.fileURL)
                .frame(maxWidth: .infinity)
                .aspectRatio(4 / 3, contentMode: .fit)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(resource.fileName)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(ByteCountFormatter.string(fromByteCount: resource.byteSize, countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                MetadataLine(label: "위치", value: resource.rootLabel)
                MetadataLine(label: "경로", value: resource.relativePath)
                if let addedAt = resource.addedAt {
                    MetadataLine(label: "Date Added", value: addedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let captureTime = resource.captureTime {
                    MetadataLine(label: "촬영 근거", value: captureSummary(captureTime))
                }
            }

            HStack {
                Button("Finder에서 보기") {
                    NSWorkspace.shared.activateFileViewerSelecting([resource.fileURL])
                }
                .buttonStyle(.borderless)

                Spacer()

                Label(
                    resource.mediaKind == .video ? "Video" : "Image",
                    systemImage: resource.mediaKind == .video ? "film" : "photo"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isKeeper ? Color.green.opacity(0.32) : Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct MetadataLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

private struct ReviewThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "doc")
                        .font(.system(size: 30))
                    Text("미리보기를 만들 수 없습니다")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: url) {
            let result = await ThumbnailProvider.thumbnail(for: url, size: CGSize(width: 620, height: 460))
            image = result
            failed = result == nil
        }
    }
}

private enum ThumbnailProvider {
    static func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
    }
}

private func captureSummary(_ captureTime: CaptureTime) -> String {
    let source = captureTime.source.rawValue.replacingOccurrences(of: "_", with: " ")
    return "\(source) · \(captureTime.confidence.rawValue)"
}

private func rationaleTitle(_ rationale: DuplicateReviewPresentationRationale) -> String {
    switch rationale {
    case .protectedOrPreferredRoot: return "보존 역할이 더 강한 사본을 남깁니다"
    case .cleanerFilename: return "복사본 표식이 없는 이름을 남깁니다"
    case .recognizableFilename: return "더 알아보기 쉬운 원본형 파일명을 남깁니다"
    case .earlierDateAdded: return "Finder에 더 먼저 추가된 사본을 남깁니다"
    case .matchingParentFolder: return "폴더 구조가 더 자연스러운 사본을 남깁니다"
    case .strongerCaptureEvidence: return "촬영시각 근거가 더 강한 사본을 남깁니다"
    case .shallowerPath: return "더 단순한 위치의 사본을 남깁니다"
    case .deterministicTieBreak: return "내용은 같고 의미 있는 차이를 찾지 못했습니다"
    case .completeLivePhotoOccurrence: return "Live Photo의 더 완전한 보존 형태를 남깁니다"
    case .sourceSemantics: return "보존 가능한 source semantics가 있는 사본을 남깁니다"
    }
}

private func rationaleDetail(_ rationale: DuplicateReviewPresentationRationale) -> String {
    switch rationale {
    case .deterministicTieBreak:
        return "현재 PhotoArchiveKit이 비교하는 근거에서는 우열이 크지 않습니다. 이 화면은 읽기 전용이며 파일을 이동하지 않습니다."
    case .completeLivePhotoOccurrence:
        return "still image와 paired video 관계를 하나의 asset으로 취급해 더 안전하게 복원 가능한 occurrence를 keeper로 표시합니다."
    default:
        return "두 사본은 byte 단위로 동일합니다. 아래 metadata와 실제 미리보기를 함께 보고 keeper 선택이 자연스러운지 확인할 수 있습니다. 이 화면은 파일을 변경하지 않습니다."
    }
}
