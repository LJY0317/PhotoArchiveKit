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

            ToolbarItem {
                Menu {
                    if let presentation = store.presentation {
                        ForEach(presentation.scopeRoots) { root in
                            Button {
                                store.toggleRoot(root.id)
                            } label: {
                                Label(
                                    root.label,
                                    systemImage: store.selectedRootIDs.contains(root.id)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                            }
                        }
                    }
                } label: {
                    Label("비교 위치", systemImage: "folder.badge.gearshape")
                }
                .help("현재 duplicate snapshot에서 비교할 registered root를 선택합니다")
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
        .safeAreaInset(edge: .bottom) {
            ReviewActionBar(store: store)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if let presentation = store.presentation {
                ReviewSummaryHeader(presentation: presentation)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
            }

            List(store.visibleItems, selection: $store.selection) { item in
                ReviewSidebarRow(item: item, isApproved: store.isApproved(item))
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
                total: store.visibleItems.count,
                isApproved: store.isApproved(item),
                cleanupCopyIDs: store.cleanupCopyIDsByItem[item.id, default: []],
                onToggleCleanup: { store.toggleCleanup($0, item: item) },
                onKeepOnly: { store.keepOnly($0, item: item) },
                onApproveAndNext: { store.approveAndNext(item) },
                onUnapprove: { store.unapprove(item) }
            )
        } else {
            ContentUnavailableView(
                "검토할 중복이 없습니다",
                systemImage: "checkmark.circle",
                description: Text("현재 검색에 표시할 automatic exact duplicate group이 없습니다.")
            )
        }
    }
}

private struct ReviewActionBar: View {
    @ObservedObject var store: ReviewStore

    var body: some View {
        HStack(spacing: 12) {
            Label("검토 완료 \(store.approvedCount)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(store.approvedCount > 0 ? .green : .secondary)
            Text("남음 \(store.pendingCount)")
                .foregroundStyle(.secondary)

            if let status = store.statusMessage {
                Divider().frame(height: 16)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                store.submitApproved()
            } label: {
                Label("검토 제출 (\(store.approvedCount))", systemImage: "tray.and.arrow.down.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.approvedCount == 0)
            .help("검토 결정을 로컬에 저장합니다. 파일은 아직 이동하지 않습니다.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct ReviewSummaryHeader: View {
    let presentation: DuplicateReviewPresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate Review")
                    .font(.headline)
                Text("\(presentation.items.count)개 그룹 · \(presentation.candidateResourceCount)개 candidate resource")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !presentation.scopeRootLabels.isEmpty {
                    Text(presentation.scopeRootLabels.joined(separator: " + "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help("이 검토 snapshot에 포함된 위치")
                }
            }
        }
    }
}

private struct ReviewSidebarRow: View {
    let item: DuplicateReviewPresentationItem
    let isApproved: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == .livePhotoAsset ? "livephoto" : "photo.stack")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24)
                .foregroundStyle(item.kind == .livePhotoAsset ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("Exact duplicate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)
            if isApproved {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("검토 완료")
            }
            Label("\(candidateCopyCount)", systemImage: "minus.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .help("현재 추천 정리 후보 \(candidateCopyCount)개")
        }
        .padding(.vertical, 3)
    }

    private var primaryName: String {
        item.preferredResources.first?.fileName
            ?? item.candidateResources.first?.fileName
            ?? item.id
    }

    private var candidateCopyCount: Int {
        let count = item.copies.filter { !$0.isKeeper }.count
        return count > 0 ? count : item.candidateResources.count
    }
}

private struct ReviewDetailView: View {
    let item: DuplicateReviewPresentationItem
    let index: Int
    let total: Int
    let isApproved: Bool
    let cleanupCopyIDs: Set<String>
    let onToggleCleanup: (DuplicateReviewPresentationCopy) -> Void
    let onKeepOnly: (DuplicateReviewPresentationCopy) -> Void
    let onApproveAndNext: () -> Void
    let onUnapprove: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let copies = item.copies.isEmpty
                ? fallbackCopies
                : item.copies
            let labelWidth: CGFloat = 150
            let gap: CGFloat = 12
            let horizontalPadding: CGFloat = 22
            let available = max(
                0,
                proxy.size.width
                    - horizontalPadding * 2
                    - labelWidth
                    - gap * CGFloat(max(1, copies.count))
            )
            let fittedWidth = available / CGFloat(max(1, copies.count))
            let columnWidth = max(260, min(430, fittedWidth))
            let gridWidth = labelWidth
                + gap
                + (columnWidth * CGFloat(max(1, copies.count)))
                + (gap * CGFloat(max(0, copies.count - 1)))
            let contentWidth = max(proxy.size.width - horizontalPadding * 2, gridWidth)

            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                        .frame(width: contentWidth, alignment: .leading)

                    ReviewComparisonTable(
                        item: item,
                        copies: copies,
                        labelWidth: labelWidth,
                        columnWidth: columnWidth,
                        gap: gap,
                        cleanupCopyIDs: cleanupCopyIDs,
                        isApproved: isApproved,
                        onToggleCleanup: onToggleCleanup,
                        onKeepOnly: onKeepOnly
                    )

                    HStack {
                        if isApproved {
                            Label("이 그룹은 검토 완료 상태입니다", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("검토 완료 취소", action: onUnapprove)
                        } else {
                            Text("현재 표시된 남김/정리 선택을 확인한 뒤 승인하세요.")
                                .foregroundStyle(.secondary)
                            Button("현재 선택 승인하고 다음", action: onApproveAndNext)
                                .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    }
                    .frame(width: contentWidth)
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var fallbackCopies: [DuplicateReviewPresentationCopy] {
        item.preferredResources.map {
            DuplicateReviewPresentationCopy(id: "fallback-keeper:\($0.id)", isKeeper: true, resources: [$0])
        } + item.candidateResources.map {
            DuplicateReviewPresentationCopy(id: "fallback-candidate:\($0.id)", isKeeper: false, resources: [$0])
        }
    }

    private var header: some View {
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
                Image(systemName: "livephoto")
                    .foregroundStyle(.blue)
                    .help("Live Photo")
            }
            Text("추천 근거: \(rationaleTitle(item.rationale))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(
                "item \(item.id) · \(item.reason.rawValue)"
            )
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReviewComparisonTable: View {
    let item: DuplicateReviewPresentationItem
    let copies: [DuplicateReviewPresentationCopy]
    let labelWidth: CGFloat
    let columnWidth: CGFloat
    let gap: CGFloat
    let cleanupCopyIDs: Set<String>
    let isApproved: Bool
    let onToggleCleanup: (DuplicateReviewPresentationCopy) -> Void
    let onKeepOnly: (DuplicateReviewPresentationCopy) -> Void

    private var rows: [ComparisonRowSpec] {
        comparisonRows(for: copies)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: gap) {
                Text("미리보기")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .leading)
                    .padding(.top, 8)

                ForEach(copies) { copy in
                    CopyHeaderCell(
                        copy: copy,
                        itemKind: item.kind,
                        isMarkedForCleanup: cleanupCopyIDs.contains(copy.id),
                        isApproved: isApproved,
                        onToggleCleanup: { onToggleCleanup(copy) },
                        onKeepOnly: { onKeepOnly(copy) }
                    )
                        .frame(width: columnWidth, alignment: .top)
                }
            }
            .padding(.bottom, 14)

            Divider()

            ForEach(rows) { row in
                ComparisonMetadataRow(
                    row: row,
                    labelWidth: labelWidth,
                    columnWidth: columnWidth,
                    gap: gap
                )
                Divider()
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct CopyHeaderCell: View {
    let copy: DuplicateReviewPresentationCopy
    let itemKind: ReconciliationItemKind
    let isMarkedForCleanup: Bool
    let isApproved: Bool
    let onToggleCleanup: () -> Void
    let onKeepOnly: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label(
                    isMarkedForCleanup ? "정리" : "남김",
                    systemImage: isMarkedForCleanup ? "trash.circle.fill" : "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(isMarkedForCleanup ? .red : .green)

                Text(copy.isKeeper ? "추천 keeper" : "추천 candidate")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if itemKind == .livePhotoAsset {
                    livePhotoIntegrityBadge
                }

                Spacer(minLength: 4)
                Text("\(copy.resources.count) resource")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if let primary = copy.primaryResource {
                ReviewThumbnail(url: primary.fileURL)
                    .frame(height: 260)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: isMarkedForCleanup ? "trash.circle.fill" : "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(isMarkedForCleanup ? .red : .green)
                            .padding(9)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggleCleanup)
                    .help(isMarkedForCleanup ? "클릭하면 정리 표시를 취소합니다" : "클릭하면 정리 대상으로 표시합니다")

                Text(primary.fileName)
                    .font(.headline)
                    .lineLimit(2)

                if copy.resources.count > 1 {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(copy.resources) { resource in
                            HStack(spacing: 6) {
                                Image(systemName: resource.role == .pairedVideo ? "checkmark.seal.fill" : (resource.mediaKind == .video ? "film" : "photo"))
                                    .foregroundStyle(resource.role == .pairedVideo ? .green : .secondary)
                                Text(resourceRoleLabel(resource.role))
                                    .fontWeight(resource.role == .pairedVideo ? .semibold : .regular)
                                Spacer(minLength: 4)
                                Text(ByteCountFormatter.string(fromByteCount: resource.byteSize, countStyle: .file))
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !copy.resources.isEmpty {
                HStack {
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting(copy.resources.map(\.fileURL))
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    if itemKind != .livePhotoAsset || copy.isCompleteLivePhotoOccurrence {
                        Button("이 사본만 남기기", action: onKeepOnly)
                            .buttonStyle(.borderless)
                    }

                    Button(isMarkedForCleanup ? "정리 취소" : "정리 대상으로 표시", action: onToggleCleanup)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(
            isMarkedForCleanup ? Color.red.opacity(0.055) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isApproved
                        ? (isMarkedForCleanup ? Color.red.opacity(0.4) : Color.green.opacity(0.4))
                        : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        }
    }

    @ViewBuilder
    private var livePhotoIntegrityBadge: some View {
        if copy.isCompleteLivePhotoOccurrence {
            Label("Still + Paired Video", systemImage: "livephoto")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .help("온전한 Live Photo occurrence")
        } else if copy.hasLivePhotoStill {
            Label("Still only", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .help("paired video가 없는 occurrence")
        } else if copy.hasPairedVideo {
            Label("Paired video only", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "livephoto")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ComparisonRowSpec: Identifiable {
    let id: String
    let label: String
    let values: [ComparisonCellValue]
    let monospaced: Bool

    var isDifferent: Bool {
        Set(values.map(\.comparisonKey)).count > 1
    }

    var earliestDate: Date? {
        guard isDifferent else { return nil }
        return values.compactMap(\.dateValue).min()
    }

    var latestDate: Date? {
        guard isDifferent else { return nil }
        return values.compactMap(\.dateValue).max()
    }
}

private struct ComparisonCellValue {
    let text: String
    let comparisonKey: String
    let dateValue: Date?
}

private struct ComparisonMetadataRow: View {
    let row: ComparisonRowSpec
    let labelWidth: CGFloat
    let columnWidth: CGFloat
    let gap: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .leading, spacing: 5) {
                Text(row.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if row.isDifferent {
                    Label("다름", systemImage: "arrow.left.arrow.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: labelWidth, alignment: .leading)

            ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                VStack(alignment: .leading, spacing: 6) {
                    Text(value.text)
                        .font(row.monospaced ? .caption.monospaced() : .caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if let date = value.dateValue,
                       let earliest = row.earliestDate,
                       let latest = row.latestDate,
                       abs(earliest.timeIntervalSince(latest)) > 0.001 {
                        HStack(spacing: 5) {
                            if abs(date.timeIntervalSince(earliest)) < 0.001 {
                                Text("가장 빠름")
                                    .comparisonBadge()
                            }
                            if abs(date.timeIntervalSince(latest)) < 0.001 {
                                Text("가장 늦음")
                                    .comparisonBadge()
                            }
                        }
                    }
                }
                .frame(width: columnWidth, alignment: .topLeading)
                .padding(.vertical, 9)
                .padding(.horizontal, 8)
                .background(
                    row.isDifferent ? Color.orange.opacity(0.055) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
        .padding(.vertical, 3)
    }
}

private extension View {
    func comparisonBadge() -> some View {
        self
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.11), in: Capsule())
    }
}

private func comparisonRows(
    for copies: [DuplicateReviewPresentationCopy]
) -> [ComparisonRowSpec] {
    [
        comparisonRow("file-name", "파일명", copies: copies) {
            componentLines($0) { $0.fileName }
        },
        comparisonRow("original-name", "최초 파일명", copies: copies) {
            componentLines($0) { $0.details?.originalFileName ?? "—" }
        },
        comparisonRow("extension", "확장자", copies: copies) {
            componentLines($0) { $0.fileExtension.isEmpty ? "—" : $0.fileExtension }
        },
        comparisonRow("media-kind", "미디어 종류", copies: copies) {
            componentLines($0) { mediaKindLabel($0.mediaKind) }
        },
        comparisonRow("role", "Resource 역할", copies: copies) {
            componentLines($0) { resourceRoleLabel($0.role) }
        },
        comparisonRow("root-label", "위치", copies: copies) {
            componentLines($0) { $0.rootLabel }
        },
        comparisonRow("relative-path", "상대 경로", copies: copies) {
            componentLines($0) { $0.relativePath }
        },
        comparisonRow("absolute-path", "전체 경로", copies: copies) {
            componentLines($0) { $0.absolutePath }
        },
        comparisonRow("catalog-total-bytes", "Catalog 총 bytes", copies: copies, monospaced: true) {
            formatBytes($0.totalByteSize)
        },
        comparisonRow("catalog-resource-bytes", "Catalog resource bytes", copies: copies, monospaced: true) {
            componentLines($0) { formatBytes($0.byteSize) }
        },
        comparisonRow("filesystem-resource-bytes", "현재 filesystem bytes", copies: copies, monospaced: true) {
            componentLines($0) { resource in
                resource.fileSystemFacts.currentByteSize.map(formatBytes) ?? "—"
            }
        },
        comparisonRow("allocated-bytes", "Allocated bytes", copies: copies, monospaced: true) {
            componentLines($0) { resource in
                resource.fileSystemFacts.allocatedByteSize.map(formatBytes) ?? "—"
            }
        },
        comparisonRow("total-allocated-bytes", "Total allocated bytes", copies: copies, monospaced: true) {
            componentLines($0) { resource in
                resource.fileSystemFacts.totalAllocatedByteSize.map(formatBytes) ?? "—"
            }
        },
        comparisonRow("date-added", "Finder Date Added", copies: copies, date: { $0.primaryResource?.addedAt }) {
            componentLines($0) { formatDate($0.addedAt) }
        },
        comparisonRow("creation-date", "파일 생성 시각", copies: copies, date: { $0.primaryResource?.fileSystemFacts.creationDate }) {
            componentLines($0) { formatDate($0.fileSystemFacts.creationDate) }
        },
        comparisonRow("catalog-modified", "Catalog 수정 시각", copies: copies, date: { $0.primaryResource?.details?.catalogModifiedAt }) {
            componentLines($0) { formatDate($0.details?.catalogModifiedAt) }
        },
        comparisonRow("filesystem-modified", "현재 수정 시각", copies: copies, date: { $0.primaryResource?.fileSystemFacts.modificationDate }) {
            componentLines($0) { formatDate($0.fileSystemFacts.modificationDate) }
        },
        comparisonRow("capture-local", "촬영 local timestamp", copies: copies) {
            componentLines($0) { $0.captureTime?.localTimestamp ?? "—" }
        },
        comparisonRow("capture-instant", "촬영 absolute time", copies: copies, date: { $0.primaryResource?.captureTime?.instant }) {
            componentLines($0) { formatDate($0.captureTime?.instant) }
        },
        comparisonRow("capture-offset", "UTC offset", copies: copies) {
            componentLines($0) { $0.captureTime?.utcOffset ?? "—" }
        },
        comparisonRow("capture-source", "촬영 시각 source", copies: copies) {
            componentLines($0) { $0.captureTime.map { captureSourceLabel($0.source) } ?? "—" }
        },
        comparisonRow("capture-confidence", "촬영 시각 신뢰도", copies: copies) {
            componentLines($0) { $0.captureTime.map { captureConfidenceLabel($0.confidence) } ?? "—" }
        },
        comparisonRow("freshness", "현재 lightweight 상태", copies: copies) {
            componentLines($0) { resourceFreshnessLabel($0) }
        },
        comparisonRow("exact-sha256", "Catalog exact SHA-256", copies: copies, monospaced: true) {
            componentLines($0) { $0.details?.exactSHA256Hex ?? "—" }
        },
        comparisonRow("fresh-hash", "Fresh SHA-256", copies: copies) { _ in
            "미수행 — 실제 mutation 직전에 별도 fresh verification"
        },
        comparisonRow("live-fingerprint", "Live identifier fingerprint", copies: copies, monospaced: true) {
            componentLines($0) { $0.details?.liveIdentifierFingerprintHex ?? "—" }
        },
        comparisonRow("live-timed-status", "Live timed metadata", copies: copies) {
            componentLines($0) { $0.details?.liveTimedMetadataStatus?.rawValue ?? "—" }
        },
        comparisonRow("metadata-probe", "Metadata probe", copies: copies) {
            componentLines($0) { resource in
                guard let details = resource.details else { return "—" }
                return details.metadataProbeFailed ? "실패" : "성공"
            }
        },
        comparisonRow("metadata-version", "Metadata probe version", copies: copies, monospaced: true) {
            componentLines($0) { $0.details?.metadataProbeVersion.map(String.init) ?? "—" }
        },
        comparisonRow("resource-id", "Resource ID", copies: copies, monospaced: true) {
            componentLines($0) { $0.id }
        },
        comparisonRow("asset-id", "Asset ID", copies: copies, monospaced: true) {
            componentLines($0) { $0.assetID ?? "—" }
        },
        comparisonRow("root-id", "Root ID", copies: copies, monospaced: true) {
            componentLines($0) { $0.rootID }
        },
        comparisonRow("root-kind", "Root kind", copies: copies) {
            componentLines($0) { $0.rootKind.rawValue }
        },
        comparisonRow("usage-role", "Root usage role", copies: copies) {
            componentLines($0) { $0.rootUsageRole.rawValue }
        },
        comparisonRow("provenance", "Provenance", copies: copies) {
            componentLines($0) { $0.rootProvenance.rawValue }
        },
        comparisonRow("stable-marker", "Stable marker key", copies: copies, monospaced: true) {
            componentLines($0) { $0.stableMarkerKey ?? "—" }
        },
        comparisonRow("catalog-fs-id", "Catalog filesystem ID", copies: copies, monospaced: true) {
            componentLines($0) { $0.details?.catalogFileSystemIdentifier ?? "—" }
        },
        comparisonRow("current-fs-id", "현재 filesystem ID", copies: copies, monospaced: true) {
            componentLines($0) { $0.fileSystemFacts.fileSystemIdentifier ?? "—" }
        },
        comparisonRow("exists", "현재 파일 존재", copies: copies) {
            componentLines($0) { $0.fileSystemFacts.exists ? "예" : "아니오" }
        },
        comparisonRow("file-type", "Filesystem type", copies: copies) {
            componentLines($0) { $0.fileSystemFacts.fileType ?? "—" }
        },
        comparisonRow("type-identifier", "UTType identifier", copies: copies, monospaced: true) {
            componentLines($0) { $0.fileSystemFacts.typeIdentifier ?? "—" }
        },
        comparisonRow("owner", "소유자", copies: copies) {
            componentLines($0) { $0.fileSystemFacts.ownerAccountName ?? "—" }
        },
        comparisonRow("group", "그룹", copies: copies) {
            componentLines($0) { $0.fileSystemFacts.groupOwnerAccountName ?? "—" }
        },
        comparisonRow("permissions", "POSIX 권한", copies: copies, monospaced: true) {
            componentLines($0) { resource in
                resource.fileSystemFacts.posixPermissions.map { String(format: "%04o", $0) } ?? "—"
            }
        },
        comparisonRow("immutable", "Immutable", copies: copies) {
            componentLines($0) { optionalBool($0.fileSystemFacts.isImmutable) }
        },
        comparisonRow("append-only", "Append only", copies: copies) {
            componentLines($0) { optionalBool($0.fileSystemFacts.isAppendOnly) }
        },
        comparisonRow("hidden", "Hidden", copies: copies) {
            componentLines($0) { optionalBool($0.fileSystemFacts.isHidden) }
        },
        comparisonRow("readable", "Readable", copies: copies) {
            componentLines($0) { optionalBool($0.fileSystemFacts.isReadable) }
        },
        comparisonRow("writable", "Writable", copies: copies) {
            componentLines($0) { optionalBool($0.fileSystemFacts.isWritable) }
        },
        comparisonRow("executable", "Executable", copies: copies) {
            componentLines($0) { optionalBool($0.fileSystemFacts.isExecutable) }
        },
        comparisonRow("xattrs", "Extended attributes", copies: copies, monospaced: true) {
            componentLines($0) { xattrSummary($0.fileSystemFacts.extendedAttributes) }
        },
        comparisonRow("location-count", "Location history count", copies: copies, monospaced: true) {
            componentLines($0) { $0.details.map { String($0.locationHistoryCount) } ?? "—" }
        },
        comparisonRow("first-seen", "최초 관측", copies: copies, date: { $0.primaryResource?.details?.firstSeenAt }) {
            componentLines($0) { formatDate($0.details?.firstSeenAt) }
        },
        comparisonRow("last-seen", "최근 관측", copies: copies, date: { $0.primaryResource?.details?.lastSeenAt }) {
            componentLines($0) { formatDate($0.details?.lastSeenAt) }
        },
        comparisonRow("last-session", "최근 scan session", copies: copies, monospaced: true) {
            componentLines($0) { $0.details?.lastSeenSessionID ?? "—" }
        },
        comparisonRow("original-name-session", "최초 이름 session", copies: copies, monospaced: true) {
            componentLines($0) { $0.details?.originalNameFirstSeenSessionID ?? "—" }
        }
    ]
}

private func comparisonRow(
    _ id: String,
    _ label: String,
    copies: [DuplicateReviewPresentationCopy],
    monospaced: Bool = false,
    date: ((DuplicateReviewPresentationCopy) -> Date?)? = nil,
    value: (DuplicateReviewPresentationCopy) -> String
) -> ComparisonRowSpec {
    ComparisonRowSpec(
        id: id,
        label: label,
        values: copies.map { copy in
            let text = value(copy)
            return ComparisonCellValue(
                text: text,
                comparisonKey: text,
                dateValue: date?(copy)
            )
        },
        monospaced: monospaced
    )
}

private func componentLines(
    _ copy: DuplicateReviewPresentationCopy,
    value: (DuplicateReviewPresentationResource) -> String
) -> String {
    if copy.resources.count == 1, let resource = copy.resources.first {
        return value(resource)
    }
    return copy.resources.map { resource in
        "[\(shortRoleLabel(resource.role))] \(value(resource))"
    }.joined(separator: "\n")
}

private func shortRoleLabel(_ role: ResourceRole) -> String {
    switch role {
    case .photo: return "still"
    case .pairedVideo: return "video"
    case .standaloneImage: return "image"
    case .standaloneVideo: return "video"
    case .sidecar: return "sidecar"
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    "\(bytes) B  (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
}

private func formatDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(date: .abbreviated, time: .standard)
}

private func optionalBool(_ value: Bool?) -> String {
    guard let value else { return "—" }
    return value ? "예" : "아니오"
}

private func resourceFreshnessLabel(_ resource: DuplicateReviewPresentationResource) -> String {
    let facts = resource.fileSystemFacts
    guard facts.exists else { return "STALE · 파일 없음" }
    guard facts.currentByteSize == resource.byteSize else { return "STALE · byte size 변경" }
    if let catalogModified = resource.details?.catalogModifiedAt,
       let currentModified = facts.modificationDate,
       abs(catalogModified.timeIntervalSince(currentModified)) >= 0.001 {
        return "STALE · 수정 시각 변경"
    }
    if let catalogID = resource.details?.catalogFileSystemIdentifier,
       let currentID = facts.fileSystemIdentifier,
       catalogID != currentID {
        return "STALE · filesystem ID 변경"
    }
    return "CURRENT · size/mtime/filesystem ID 일치"
}

private func xattrSummary(_ attributes: [DuplicateReviewExtendedAttribute]) -> String {
    guard !attributes.isEmpty else { return "없음" }
    return attributes.map { attribute in
        let digest = attribute.valueSHA256Hex.map { " · value SHA-256 \($0)" } ?? ""
        return "\(attribute.name) (\(attribute.byteCount) B)\(digest)"
    }.joined(separator: "\n")
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

private func mediaKindLabel(_ kind: MediaKind) -> String {
    switch kind {
    case .image: return "Image"
    case .video: return "Video"
    case .sidecar: return "Sidecar"
    }
}

private func resourceRoleLabel(_ role: ResourceRole) -> String {
    switch role {
    case .photo: return "Live Photo still"
    case .pairedVideo: return "Live Photo paired video"
    case .standaloneImage: return "Standalone image"
    case .standaloneVideo: return "Standalone video"
    case .sidecar: return "Sidecar"
    }
}

private func captureSourceLabel(_ source: CaptureTimeSource) -> String {
    switch source {
    case .exifDateTimeOriginal: return "EXIF DateTimeOriginal"
    case .quickTimeCreationDate: return "QuickTime creation date"
    case .googleTakeoutPhotoTakenTime: return "Google Takeout photoTakenTime"
    case .fileCreationDate: return "파일시스템 생성 시각 fallback"
    case .unknown: return "알 수 없음"
    }
}

private func captureConfidenceLabel(_ confidence: CaptureTimeConfidence) -> String {
    switch confidence {
    case .trusted: return "Trusted"
    case .providerSidecar: return "Provider sidecar"
    case .incompleteTimezone: return "Timezone 불완전"
    case .fallback: return "Fallback"
    case .unknown: return "알 수 없음"
    }
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
