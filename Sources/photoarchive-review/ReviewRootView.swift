import AppKit
import PhotoArchiveCore
import QuickLookThumbnailing
import SwiftUI

struct ReviewRootView: View {
    @StateObject private var store = ReviewStore()
    @State private var addRootRequest: AddComparisonRootRequest?

    var body: some View {
        ReviewWindowLayout {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
            detail
        } actions: {
            ReviewActionBar(store: store)
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
                    if store.activeRegisteredRoots.isEmpty {
                        Text("등록된 위치가 없습니다")
                    } else {
                        ForEach(store.activeRegisteredRoots, id: \.rootID) { root in
                            Button {
                                store.toggleRoot(root.rootID)
                            } label: {
                                Label(
                                    rootMenuTitle(root),
                                    systemImage: store.selectedRootIDs.contains(root.rootID)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                            }
                            .disabled(!root.isAvailable && !store.selectedRootIDs.contains(root.rootID))
                        }
                    }

                    Divider()

                    Button {
                        chooseComparisonFolder()
                    } label: {
                        Label("폴더 추가…", systemImage: "folder.badge.plus")
                    }

                    Button {
                        Task { await store.scanSelectedRoots() }
                    } label: {
                        Label(
                            store.selectedRootsNeedScan ? "선택 위치 스캔 필요" : "선택 위치 다시 스캔",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(store.selectedRootIDs.isEmpty || store.isScanning)
                } label: {
                    Label("비교 위치", systemImage: "folder.badge.gearshape")
                }
                .help("비교할 위치를 선택하거나 새 폴더를 추가합니다")
                .disabled(store.isScanning)
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: store.reload) {
                    Label("검토 화면 새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading || store.isScanning)
                .help("파일을 다시 검사하지 않고 최근 검사 결과를 화면에 다시 불러옵니다")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoArchiveReloadReview)) { _ in
            store.reload()
        }
        .sheet(item: $addRootRequest) { request in
            AddComparisonRootSheet(
                request: request,
                isWorking: store.isScanning,
                statusMessage: store.statusMessage,
                onCancel: { addRootRequest = nil },
                onRegisterAndScan: { role, provenance in
                    Task {
                        let succeeded = await store.registerAndScan(
                            url: request.url,
                            role: role,
                            provenance: provenance
                        )
                        if succeeded {
                            addRootRequest = nil
                        }
                    }
                }
            )
        }
        .sheet(item: $store.preparedCleanup) { prepared in
            ReviewCleanupConfirmationSheet(
                prepared: prepared,
                isApplying: store.isApplyingCleanup,
                errorMessage: store.cleanupErrorMessage,
                onCancel: store.cancelPreparedCleanup,
                onApply: {
                    Task { await store.applyPreparedCleanup() }
                }
            )
        }
        .alert(item: $store.removeAllConfirmation) { request in
            Alert(
                title: Text("모든 사본을 삭제 대상으로 선택할까요?"),
                message: Text(request.message),
                primaryButton: .destructive(Text("모두 삭제 대상으로 선택")) {
                    store.confirmRemoveAll(request)
                },
                secondaryButton: .cancel(Text("취소")) {
                    store.cancelRemoveAll()
                }
            )
        }
    }

    private func chooseComparisonFolder() {
        let panel = NSOpenPanel()
        panel.title = "비교할 폴더 선택"
        panel.prompt = "선택"
        panel.message = "비교에 추가할 폴더를 선택하세요."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addRootRequest = AddComparisonRootRequest(url: url.standardizedFileURL)
    }

    private func rootMenuTitle(_ root: RegisteredRootReport) -> String {
        let availability = root.isAvailable ? "" : " · 오프라인"
        return "\(root.label) · \(rootUsageRoleLabel(root.usageRole))\(availability)"
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
                ReviewSidebarRow(item: item)
                    .tag(item.id)
            }
            .listStyle(.sidebar)
            .searchable(text: $store.searchText, prompt: "파일명 또는 위치 검색")
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 36)
            }
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
                cleanupCopyIDs: store.cleanupCopyIDsByItem[item.id, default: []],
                onToggleCleanupFromColumn: { store.toggleCleanupFromColumn($0, item: item) },
                onToggleCleanupFromButton: { store.toggleCleanupFromButton($0, item: item) },
                canToggleCleanup: { store.canToggleCleanup($0, item: item) },
                columnToggleHelp: { store.columnToggleHelp($0, item: item) },
                cleanupToggleHelp: { store.cleanupToggleHelp($0, item: item) }
            )
        } else {
            ContentUnavailableView(
                "검토할 중복이 없습니다",
                systemImage: "checkmark.circle",
                description: Text("현재 검색 조건에 맞는 중복 항목이 없습니다.")
            )
        }
    }
}

private struct ReviewActionBar: View {
    @ObservedObject var store: ReviewStore

    var body: some View {
        HStack(spacing: 12) {
            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("비교하는 중…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let status = store.statusMessage {
                if store.isScanning {
                    Divider().frame(height: 16)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task { await store.prepareSelectedCleanup() }
            } label: {
                if store.isPreparingCleanup {
                    Label("파일 확인 중…", systemImage: "shield.lefthalf.filled")
                } else {
                    Label(
                        "\(store.cleanupMoveActionTitle) (\(store.selectedCleanupItemCount))",
                        systemImage: "trash"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                store.selectedCleanupItemCount == 0
                    || store.isScanning
                    || store.isPreparingCleanup
                    || store.isApplyingCleanup
            )
            .help("삭제 예정인 사본을 확인하고 이동할 위치를 보여줍니다")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct ReviewCleanupConfirmationSheet: View {
    let prepared: PreparedReviewCleanup
    let isApplying: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onApply: () -> Void

    private var report: DuplicateReviewCleanupReport { prepared.preflight }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(destinationActionTitle)
                    .font(.title2.weight(.semibold))
                Text(summaryTitle)
                    .foregroundStyle(.secondary)
                if report.destinationKind == .customQuarantine {
                    Text(destinationTitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                if report.nonRedundantResourceCount > 0 {
                    Label(
                        "\(report.nonRedundantResourceCount)개 파일은 동일한 사본이 남지 않습니다.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }

                if report.onlyCompleteLivePhotoPairRemovalCount > 0 {
                    Label(
                        "\(report.onlyCompleteLivePhotoPairRemovalCount)개 그룹에서는 완전한 Live Photo가 남지 않습니다.",
                        systemImage: "livephoto.badge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                }

                if report.removeAllItemCount > 0 {
                    Label(
                        "\(report.removeAllItemCount)개 그룹의 모든 사본이 선택되어 있습니다.",
                        systemImage: "exclamationmark.octagon.fill"
                    )
                    .foregroundStyle(.red)
                }
            }
            .font(.callout)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isApplying {
                    ProgressView()
                        .controlSize(.small)
                    Text("이동하는 중…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("취소", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isApplying)
                Button(applyButtonTitle, action: onApply)
                    .buttonStyle(.borderedProminent)
                    .tint(report.removeAllItemCount > 0 || report.nonRedundantResourceCount > 0 ? .red : nil)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isApplying)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private var summaryTitle: String {
        let size = ByteCountFormatter.string(fromByteCount: report.totalBytes, countStyle: .file)
        return "\(prepared.selectedCopyCount)개 사본 · \(report.resourceCount)개 파일 · \(size)"
    }

    private var destinationTitle: String {
        switch report.destinationKind {
        case .systemTrash:
            return "macOS 휴지통"
        case .customQuarantine:
            guard let path = report.targetPath else { return "사용자 지정 격리 폴더" }
            return "사용자 지정 격리 폴더 · \(URL(fileURLWithPath: path).lastPathComponent)"
        }
    }

    private var applyButtonTitle: String {
        switch report.destinationKind {
        case .systemTrash:
            return "휴지통으로 이동"
        case .customQuarantine:
            return "격리 폴더로 이동"
        }
    }

    private var destinationActionTitle: String {
        switch report.destinationKind {
        case .systemTrash:
            return "휴지통으로 이동"
        case .customQuarantine:
            return "격리 폴더로 이동"
        }
    }
}

private struct AddComparisonRootRequest: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AddComparisonRootSheet: View {
    let request: AddComparisonRootRequest
    let isWorking: Bool
    let statusMessage: String?
    let onCancel: () -> Void
    let onRegisterAndScan: (RootUsageRole, SourceProvenance) -> Void

    @State private var role: RootUsageRole = .staging
    @State private var provenance: SourceProvenance = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("비교 위치 추가")
                    .font(.title2.weight(.semibold))
                Text("이 폴더를 비교 목록에 추가하고 현재 선택한 위치들과 함께 검사합니다.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.url.lastPathComponent)
                        .font(.headline)
                    Text(request.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("역할")
                        .foregroundStyle(.secondary)
                    Picker("역할", selection: $role) {
                        ForEach(RootUsageRole.allCases, id: \.self) { value in
                            Text(rootUsageRoleLabel(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(rootUsageRoleDescription(role))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GridRow {
                    Text("출처")
                        .foregroundStyle(.secondary)
                    Picker("출처", selection: $provenance) {
                        ForEach(SourceProvenance.allCases, id: \.self) { value in
                            Text(sourceProvenanceLabel(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text("출처 정보는 파일이 어디서 왔는지 이해하고 안전하게 비교하는 데 사용됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusMessage ?? "폴더를 추가하고 비교하는 중…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let statusMessage,
                      statusMessage.contains("실패") {
                Label(statusMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("취소", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("추가하고 비교 시작") {
                    onRegisterAndScan(role, provenance)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

private struct ReviewSummaryHeader: View {
    let presentation: DuplicateReviewPresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("중복 사진 검토")
                    .font(.headline)
                Text("중복 항목 \(presentation.items.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !presentation.scopeRootLabels.isEmpty {
                    Text(presentation.scopeRootLabels.joined(separator: " + "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help("현재 비교에 포함된 위치")
                }
            }
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
                .foregroundStyle(item.kind == .livePhotoAsset ? .blue : .secondary)
                .help(item.kind == .livePhotoAsset ? "Live Photo" : "완전히 같은 파일")

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(item.kind == .livePhotoAsset ? "사진 파일이 완전히 같음" : "파일 내용이 완전히 같음")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(
                            item.kind == .livePhotoAsset
                                ? "사진 파일 내용이 완전히 같습니다. Live Photo 비디오 포함 여부는 오른쪽에서 따로 확인할 수 있습니다."
                                : "파일 내용이 완전히 같은 사본들입니다."
                        )
                }
            }

            Spacer(minLength: 8)
            Label("\(copyCount)", systemImage: "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .help("이 중복 그룹에 존재하는 사본 \(copyCount)개")
        }
        .padding(.vertical, 3)
    }

    private var primaryName: String {
        item.preferredResources.first?.fileName
            ?? item.candidateResources.first?.fileName
            ?? item.id
    }

    private var copyCount: Int {
        if !item.copies.isEmpty { return item.copies.count }
        return item.preferredResources.count + item.candidateResources.count
    }
}

private struct ReviewDetailView: View {
    let item: DuplicateReviewPresentationItem
    let index: Int
    let total: Int
    let cleanupCopyIDs: Set<String>
    let onToggleCleanupFromColumn: (DuplicateReviewPresentationCopy) -> Void
    let onToggleCleanupFromButton: (DuplicateReviewPresentationCopy) -> Void
    let canToggleCleanup: (DuplicateReviewPresentationCopy) -> Bool
    let columnToggleHelp: (DuplicateReviewPresentationCopy) -> String
    let cleanupToggleHelp: (DuplicateReviewPresentationCopy) -> String

    var body: some View {
        GeometryReader { proxy in
            let copies = item.copies.isEmpty
                ? fallbackCopies
                : item.copies
            let labelWidth: CGFloat = 150
            let gap: CGFloat = 12
            let horizontalPadding: CGFloat = 22
            let tablePadding: CGFloat = 32
            let viewportWidth = max(0, proxy.size.width - NSScroller.scrollerWidth(
                for: .regular, scrollerStyle: .legacy
            ))
            let available = max(
                0,
                viewportWidth
                    - tablePadding
                    - horizontalPadding * 2
                    - labelWidth
                    - gap * CGFloat(max(1, copies.count))
            )
            let fittedWidth = available / CGFloat(max(1, copies.count))
            let columnWidth = max(260, min(430, fittedWidth))
            let gridWidth = tablePadding + labelWidth
                + gap
                + (columnWidth * CGFloat(max(1, copies.count)))
                + (gap * CGFloat(max(0, copies.count - 1)))
            let documentWidth = max(viewportWidth, gridWidth + horizontalPadding * 2)

            ReviewComparisonScrollView(documentID: item.id) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                        .frame(width: gridWidth, alignment: .leading)

                    ReviewComparisonTable(
                        item: item,
                        copies: copies,
                        labelWidth: labelWidth,
                        columnWidth: columnWidth,
                        gap: gap,
                        cleanupCopyIDs: cleanupCopyIDs,
                        onToggleCleanupFromColumn: onToggleCleanupFromColumn,
                        onToggleCleanupFromButton: onToggleCleanupFromButton,
                        canToggleCleanup: canToggleCleanup,
                        columnToggleHelp: columnToggleHelp,
                        cleanupToggleHelp: cleanupToggleHelp
                    )
                    .frame(width: gridWidth, alignment: .topLeading)
                }
                .frame(width: gridWidth, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 20)
                // Center the bounded comparison as a whole on wide windows.
                // At overflow width there is no extra margin, so column one
                // and the row labels remain reachable at scroll origin zero.
                .frame(width: documentWidth, alignment: .top)
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
            Spacer()
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
    let onToggleCleanupFromColumn: (DuplicateReviewPresentationCopy) -> Void
    let onToggleCleanupFromButton: (DuplicateReviewPresentationCopy) -> Void
    let canToggleCleanup: (DuplicateReviewPresentationCopy) -> Bool
    let columnToggleHelp: (DuplicateReviewPresentationCopy) -> String
    let cleanupToggleHelp: (DuplicateReviewPresentationCopy) -> String

    @State private var hoveredCopyID: String?

    var body: some View {
        let rows = comparisonRows(for: copies)
        let lastRowID = rows.last?.id
        Grid(alignment: .topLeading, horizontalSpacing: gap, verticalSpacing: 0) {
            GridRow(alignment: .top) {
                Text("미리보기")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .leading)
                    .padding(.top, 8)

                ForEach(copies) { copy in
                    CopyHeaderCell(
                        copy: copy,
                        itemKind: item.kind,
                        recommendationText: copy.isKeeper ? keeperRecommendationText(item.rationale) : nil,
                        columnWidth: columnWidth,
                        isMarkedForCleanup: cleanupCopyIDs.contains(copy.id),
                        onToggleCleanupFromColumn: { onToggleCleanupFromColumn(copy) },
                        onToggleCleanupFromButton: { onToggleCleanupFromButton(copy) },
                        canToggleCleanup: canToggleCleanup(copy),
                        columnToggleHelp: columnToggleHelp(copy),
                        cleanupToggleHelp: cleanupToggleHelp(copy)
                    )
                    .onHover { hovering in
                        if hovering {
                            hoveredCopyID = copy.id
                        } else if hoveredCopyID == copy.id {
                            hoveredCopyID = nil
                        }
                    }
                    .anchorPreference(
                        key: ReviewColumnBoundsPreferenceKey.self,
                        value: .bounds
                    ) { anchor in
                        [copy.id: ReviewColumnBounds(top: anchor, bottom: nil)]
                    }
                }
            }

            Divider()
                .gridCellColumns(copies.count + 1)
                .allowsHitTesting(false)

            ForEach(rows) { row in
                GridRow(alignment: .top) {
                    ComparisonMetadataLabel(row: row, width: labelWidth)

                    ForEach(Array(row.values.enumerated()), id: \.offset) { index, value in
                        let copy = copies[index]
                        ComparisonMetadataCell(
                            row: row,
                            value: value,
                            copy: copy,
                            width: columnWidth,
                            isMarkedForCleanup: cleanupCopyIDs.contains(copy.id),
                            onToggleCleanup: { onToggleCleanupFromColumn(copy) },
                            canToggleCleanup: canToggleCleanup(copy),
                            cleanupToggleHelp: columnToggleHelp(copy)
                        )
                        .onHover { hovering in
                            if hovering {
                                hoveredCopyID = copy.id
                            } else if hoveredCopyID == copy.id {
                                hoveredCopyID = nil
                            }
                        }
                        .anchorPreference(
                            key: ReviewColumnBoundsPreferenceKey.self,
                            value: .bounds
                        ) { anchor in
                            row.id == lastRowID
                                ? [copy.id: ReviewColumnBounds(top: nil, bottom: anchor)]
                                : [:]
                        }
                    }
                }

                Divider()
                    .gridCellColumns(copies.count + 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlayPreferenceValue(ReviewColumnBoundsPreferenceKey.self) { bounds in
            GeometryReader { proxy in
                ForEach(copies) { copy in
                    if let pair = bounds[copy.id],
                       let topAnchor = pair.top,
                       let bottomAnchor = pair.bottom {
                        let top = proxy[topAnchor]
                        let bottom = proxy[bottomAnchor]
                        let height = max(0, bottom.maxY - top.minY)
                        let isCleanup = cleanupCopyIDs.contains(copy.id)
                        let isHovered = hoveredCopyID == copy.id

                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isCleanup ? Color.red.opacity(0.018) : Color.clear)
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(
                                        columnStrokeColor(
                                            isCleanup: isCleanup,
                                            isHovered: isHovered
                                        ),
                                        lineWidth: isCleanup ? 1.5 : 1
                                    )
                            }
                            .frame(width: top.width, height: height)
                            .position(x: top.midX, y: top.minY + height / 2)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func columnStrokeColor(isCleanup: Bool, isHovered: Bool) -> Color {
        if isCleanup { return Color.red.opacity(0.68) }
        if isHovered { return Color.accentColor.opacity(0.38) }
        return Color.primary.opacity(0.08)
    }
}

private struct ReviewColumnBounds {
    var top: Anchor<CGRect>?
    var bottom: Anchor<CGRect>?
}

private struct ReviewColumnBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [String: ReviewColumnBounds] = [:]

    static func reduce(
        value: inout [String: ReviewColumnBounds],
        nextValue: () -> [String: ReviewColumnBounds]
    ) {
        for (id, incoming) in nextValue() {
            var merged = value[id] ?? ReviewColumnBounds(top: nil, bottom: nil)
            if let top = incoming.top { merged.top = top }
            if let bottom = incoming.bottom { merged.bottom = bottom }
            value[id] = merged
        }
    }
}

private struct CopyHeaderCell: View {
    let copy: DuplicateReviewPresentationCopy
    let itemKind: ReconciliationItemKind
    let recommendationText: String?
    let columnWidth: CGFloat
    let isMarkedForCleanup: Bool
    let onToggleCleanupFromColumn: () -> Void
    let onToggleCleanupFromButton: () -> Void
    let canToggleCleanup: Bool
    let columnToggleHelp: String
    let cleanupToggleHelp: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if let primary = copy.primaryResource {
                    ReviewThumbnail(url: primary.fileURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 260)
                        .overlay(alignment: .topLeading) {
                            if copy.isCompleteLivePhotoOccurrence {
                                livePhotoThumbnailBadge
                                    .padding(10)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if isMarkedForCleanup {
                                cleanupThumbnailBadge
                                    .padding(10)
                            }
                        }

                    Text(primary.fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(height: 22, alignment: .leading)
                        .help(primary.fileName)
                } else {
                    Color.clear
                        .frame(height: 290)
                }

                if itemKind == .livePhotoAsset {
                    resourceSummary
                        .frame(height: 42, alignment: .topLeading)
                }

                recommendationBlock
                    .frame(height: 46, alignment: .topLeading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleCleanupFromColumn)
            .help(columnToggleHelp)

            actionRows
                .frame(height: 28, alignment: .topLeading)
        }
        .padding(12)
        .frame(width: columnWidth, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private var recommendationBlock: some View {
        if let recommendationText {
            VStack(alignment: .leading, spacing: 3) {
                Label("남기기 추천", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .help("이 사본을 남기는 것을 추천합니다")

                Text(recommendationText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(recommendationText)
            }
        } else {
            Color.clear
        }
    }

    private var livePhotoThumbnailBadge: some View {
        Image(systemName: "livephoto")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(.ultraThinMaterial, in: Circle())
            .shadow(radius: 1.5, y: 0.5)
            .help("Live Photo")
    }

    private var cleanupThumbnailBadge: some View {
        Image(systemName: "trash.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(.red, in: Circle())
            .shadow(radius: 2, y: 1)
            .help("삭제 대상으로 선택됨")
    }

    private var resourceSummary: some View {
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

    private var actionRows: some View {
        HStack(spacing: 8) {
            finderButton
            Spacer()
            cleanupButton
        }
    }

    private var finderButton: some View {
        Button("Finder에서 보기") {
            NSWorkspace.shared.activateFileViewerSelecting(copy.resources.map(\.fileURL))
        }
        .buttonStyle(.borderless)
    }

    private var cleanupButton: some View {
        Button(isMarkedForCleanup ? "삭제 선택 취소" : "삭제 대상으로 선택", action: onToggleCleanupFromButton)
            .buttonStyle(.bordered)
            .disabled(!canToggleCleanup)
            .help(cleanupToggleHelp)
    }

}

private struct ComparisonRowSpec: Identifiable {
    let id: String
    let label: String
    let sectionTitle: String?
    let values: [ComparisonCellValue]
    let monospaced: Bool
    let differenceKind: ComparisonDifferenceKind

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

    var differenceLabel: String? {
        guard isDifferent else { return nil }
        switch differenceKind {
        case .generic:
            return "다름"
        case .time:
            return "시간 다름"
        case .component:
            return "구성 다름"
        case .timeAndComponent:
            return "시간·구성 다름"
        }
    }
}

private enum ComparisonDifferenceKind {
    case generic
    case time
    case component
    case timeAndComponent
}

private struct ComparisonCellValue {
    let text: String
    let comparisonKey: String
    let dateValue: Date?
}

private struct ComparisonMetadataLabel: View {
    let row: ComparisonRowSpec
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let sectionTitle = row.sectionTitle {
                Text(sectionTitle)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.bottom, 4)
            }
            Text(row.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if let differenceLabel = row.differenceLabel {
                Label(differenceLabel, systemImage: "arrow.left.arrow.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 12)
    }
}

private struct ComparisonMetadataCell: View {
    let row: ComparisonRowSpec
    let value: ComparisonCellValue
    let copy: DuplicateReviewPresentationCopy
    let width: CGFloat
    let isMarkedForCleanup: Bool
    let onToggleCleanup: () -> Void
    let canToggleCleanup: Bool
    let cleanupToggleHelp: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if row.sectionTitle != nil {
                Color.clear.frame(height: 20)
            }
            Text(value.text)
                .font(row.monospaced ? .caption.monospaced() : .caption)
                .fixedSize(horizontal: false, vertical: true)

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
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            row.isDifferent ? Color.orange.opacity(0.055) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if canToggleCleanup { onToggleCleanup() }
        }
        .help(cleanupToggleHelp)
        .contextMenu {
            Button("값 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value.text, forType: .string)
            }
        }
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
    let usesLivePhotoSlots = copies.contains { $0.hasLivePhotoStill || $0.hasPairedVideo }
    func componentText(
        _ copy: DuplicateReviewPresentationCopy,
        value: (DuplicateReviewPresentationResource) -> String
    ) -> String {
        componentLines(copy, forceLivePhotoSlots: usesLivePhotoSlots, value: value)
    }

    return [
        comparisonRow("file-name", "파일명", copies: copies) {
            componentText($0) { $0.fileName }
        },
        comparisonRow("original-name", "최초 파일명", copies: copies) {
            componentText($0) { $0.details?.originalFileName ?? "—" }
        },
        comparisonRow("extension", "확장자", copies: copies) {
            componentText($0) { $0.fileExtension.isEmpty ? "—" : $0.fileExtension }
        },
        comparisonRow("media-kind", "미디어 종류", copies: copies) {
            componentText($0) { mediaKindLabel($0.mediaKind) }
        },
        comparisonRow("role", "파일 역할", copies: copies) {
            componentText($0) { resourceRoleLabel($0.role) }
        },
        livePhotoTimeComparisonRow("capture-primary", "촬영 시각", copies: copies, sectionTitle: "원본 촬영 시각", date: { $0.primaryResource?.captureTime?.instant }) {
            capturePrimaryLabel($0.captureTime)
        },
        livePhotoTimeComparisonRow("capture-evidence-agreement", "원본 촬영 시각 일치 여부", copies: copies) { resource in
            if resource.role == .pairedVideo {
                return quickTimeCaptureEvidenceLabel(resource.captureTime)
            }
            return imageCaptureDateAgreementLabel(resource.imageCaptureDateEvidence)
        },
        livePhotoTimeComparisonRow("exif-original", "EXIF DateTimeOriginal", copies: copies, monospaced: true) {
            $0.imageCaptureDateEvidence?.exifDateTimeOriginal ?? "—"
        },
        livePhotoTimeComparisonRow("exif-offset-original", "EXIF OffsetTimeOriginal", copies: copies, monospaced: true) {
            $0.imageCaptureDateEvidence?.exifOffsetTimeOriginal ?? "—"
        },
        livePhotoTimeComparisonRow("exif-subsec-original", "EXIF SubSecTimeOriginal", copies: copies, monospaced: true) {
            $0.imageCaptureDateEvidence?.exifSubsecTimeOriginal ?? "—"
        },
        livePhotoTimeComparisonRow("exif-digitized", "EXIF DateTimeDigitized", copies: copies, monospaced: true) {
            $0.imageCaptureDateEvidence?.exifDateTimeDigitized ?? "—"
        },
        livePhotoTimeComparisonRow("exif-offset-digitized", "EXIF OffsetTimeDigitized", copies: copies, monospaced: true) {
            $0.imageCaptureDateEvidence?.exifOffsetTimeDigitized ?? "—"
        },
        livePhotoTimeComparisonRow("exif-subsec-digitized", "EXIF SubSecTimeDigitized", copies: copies, monospaced: true) {
            $0.imageCaptureDateEvidence?.exifSubsecTimeDigitized ?? "—"
        },
        livePhotoTimeComparisonRow("tiff-datetime", "TIFF DateTime", copies: copies, monospaced: true) {
            $0.imageCaptureDateEvidence?.tiffDateTime ?? "—"
        },
        livePhotoTimeComparisonRow("quicktime-creation", "QuickTime 생성 시각", copies: copies, monospaced: true) {
            quickTimeCaptureEvidenceLabel($0.captureTime)
        },
        livePhotoTimeComparisonRow("capture-instant", "촬영 시각 (시간대 반영)", copies: copies, date: { $0.primaryResource?.captureTime?.instant }) {
            formatDate($0.captureTime?.instant)
        },
        livePhotoTimeComparisonRow("capture-source", "촬영 시각 출처", copies: copies) {
            $0.captureTime.map { captureSourceLabel($0.source) } ?? "—"
        },
        livePhotoTimeComparisonRow("capture-confidence", "촬영 시각 신뢰도", copies: copies) {
            $0.captureTime.map { captureConfidenceLabel($0.confidence) } ?? "—"
        },
        livePhotoTimeComparisonRow("date-added", "Finder에 추가된 시각", copies: copies, sectionTitle: "파일 기록 시각", date: { $0.primaryResource?.addedAt }) {
            formatDate($0.addedAt)
        },
        livePhotoTimeComparisonRow("creation-date", "파일시스템 생성 시각", copies: copies, date: { $0.primaryResource?.fileSystemFacts.creationDate }) {
            formatDate($0.fileSystemFacts.creationDate)
        },
        livePhotoTimeComparisonRow("filesystem-modified", "파일시스템 수정 시각", copies: copies, date: { $0.primaryResource?.fileSystemFacts.modificationDate }) {
            formatDate($0.fileSystemFacts.modificationDate)
        },
        livePhotoTimeComparisonRow("catalog-modified", "이전에 기록된 수정 시각", copies: copies, date: { $0.primaryResource?.details?.catalogModifiedAt }) {
            formatDate($0.details?.catalogModifiedAt)
        },
        livePhotoTimeComparisonRow("first-seen", "처음 확인한 시각", copies: copies, date: { $0.primaryResource?.details?.firstSeenAt }) {
            formatDate($0.details?.firstSeenAt)
        },
        livePhotoTimeComparisonRow("last-seen", "최근 확인한 시각", copies: copies, date: { $0.primaryResource?.details?.lastSeenAt }) {
            formatDate($0.details?.lastSeenAt)
        },
        comparisonRow("root-label", "위치", copies: copies) {
            componentText($0) { $0.rootLabel }
        },
        comparisonRow("relative-path", "상대 경로", copies: copies) {
            componentText($0) { $0.relativePath }
        },
        comparisonRow("absolute-path", "전체 경로", copies: copies) {
            componentText($0) { $0.absolutePath }
        },
        comparisonRow("catalog-total-bytes", "기록된 전체 크기", copies: copies, sectionTitle: "크기", monospaced: true) {
            formatBytes($0.totalByteSize)
        },
        comparisonRow("catalog-resource-bytes", "기록된 파일 크기", copies: copies, monospaced: true) {
            componentText($0) { formatBytes($0.byteSize) }
        },
        comparisonRow("filesystem-resource-bytes", "현재 파일 크기", copies: copies, monospaced: true) {
            componentText($0) { resource in
                resource.fileSystemFacts.currentByteSize.map(formatBytes) ?? "—"
            }
        },
        comparisonRow("allocated-bytes", "디스크 사용 크기", copies: copies, monospaced: true) {
            componentText($0) { resource in
                resource.fileSystemFacts.allocatedByteSize.map(formatBytes) ?? "—"
            }
        },
        comparisonRow("total-allocated-bytes", "전체 디스크 사용 크기", copies: copies, monospaced: true) {
            componentText($0) { resource in
                resource.fileSystemFacts.totalAllocatedByteSize.map(formatBytes) ?? "—"
            }
        },
        comparisonRow("freshness", "현재 파일 상태", copies: copies) {
            componentText($0) { resourceFreshnessLabel($0) }
        },
        comparisonRow("exact-sha256", "기록된 SHA-256", copies: copies, monospaced: true) {
            componentText($0) { $0.details?.exactSHA256Hex ?? "—" }
        },
        comparisonRow("fresh-hash", "현재 SHA-256", copies: copies) {
            componentText($0) { _ in
                "아직 확인하지 않음 — 이동 직전에 확인"
            }
        },
        comparisonRow("live-fingerprint", "Live Photo 식별값", copies: copies, monospaced: true) {
            componentText($0) { $0.details?.liveIdentifierFingerprintHex ?? "—" }
        },
        comparisonRow("live-timed-status", "Live Photo 시간 정보", copies: copies) {
            componentText($0) { $0.details?.liveTimedMetadataStatus?.rawValue ?? "—" }
        },
        comparisonRow("metadata-probe", "메타데이터 읽기", copies: copies) {
            componentText($0) { resource in
                guard let details = resource.details else { return "—" }
                return details.metadataProbeFailed ? "실패" : "성공"
            }
        },
        comparisonRow("metadata-version", "메타데이터 검사 버전", copies: copies, monospaced: true) {
            componentText($0) { $0.details?.metadataProbeVersion.map(String.init) ?? "—" }
        },
        comparisonRow("resource-id", "파일 식별자", copies: copies, monospaced: true) {
            componentText($0) { $0.id }
        },
        comparisonRow("asset-id", "사진 묶음 식별자", copies: copies, monospaced: true) {
            componentText($0) { $0.assetID ?? "—" }
        },
        comparisonRow("root-id", "위치 식별자", copies: copies, monospaced: true) {
            componentText($0) { $0.rootID }
        },
        comparisonRow("root-kind", "위치 종류", copies: copies) {
            componentText($0) { sourceRootKindLabel($0.rootKind) }
        },
        comparisonRow("usage-role", "위치 역할", copies: copies) {
            componentText($0) { rootUsageRoleLabel($0.rootUsageRole) }
        },
        comparisonRow("provenance", "출처", copies: copies) {
            componentText($0) { sourceProvenanceLabel($0.rootProvenance) }
        },
        comparisonRow("stable-marker", "위치 확인 키", copies: copies, monospaced: true) {
            componentText($0) { $0.stableMarkerKey ?? "—" }
        },
        comparisonRow("catalog-fs-id", "기록된 파일 시스템 식별자", copies: copies, monospaced: true) {
            componentText($0) { $0.details?.catalogFileSystemIdentifier ?? "—" }
        },
        comparisonRow("current-fs-id", "현재 파일 시스템 식별자", copies: copies, monospaced: true) {
            componentText($0) { $0.fileSystemFacts.fileSystemIdentifier ?? "—" }
        },
        comparisonRow("exists", "현재 파일 존재", copies: copies) {
            componentText($0) { $0.fileSystemFacts.exists ? "예" : "아니오" }
        },
        comparisonRow("file-type", "파일 종류", copies: copies) {
            componentText($0) { $0.fileSystemFacts.fileType ?? "—" }
        },
        comparisonRow("type-identifier", "파일 형식 식별자", copies: copies, monospaced: true) {
            componentText($0) { $0.fileSystemFacts.typeIdentifier ?? "—" }
        },
        comparisonRow("owner", "소유자", copies: copies) {
            componentText($0) { $0.fileSystemFacts.ownerAccountName ?? "—" }
        },
        comparisonRow("group", "소유 그룹", copies: copies) {
            componentText($0) { $0.fileSystemFacts.groupOwnerAccountName ?? "—" }
        },
        comparisonRow("permissions", "POSIX 권한", copies: copies, monospaced: true) {
            componentText($0) { resource in
                resource.fileSystemFacts.posixPermissions.map { String(format: "%04o", $0) } ?? "—"
            }
        },
        comparisonRow("immutable", "변경 금지", copies: copies) {
            componentText($0) { optionalBool($0.fileSystemFacts.isImmutable) }
        },
        comparisonRow("append-only", "추가만 허용", copies: copies) {
            componentText($0) { optionalBool($0.fileSystemFacts.isAppendOnly) }
        },
        comparisonRow("hidden", "숨김 파일", copies: copies) {
            componentText($0) { optionalBool($0.fileSystemFacts.isHidden) }
        },
        comparisonRow("readable", "읽기 가능", copies: copies) {
            componentText($0) { optionalBool($0.fileSystemFacts.isReadable) }
        },
        comparisonRow("writable", "쓰기 가능", copies: copies) {
            componentText($0) { optionalBool($0.fileSystemFacts.isWritable) }
        },
        comparisonRow("executable", "실행 가능", copies: copies) {
            componentText($0) { optionalBool($0.fileSystemFacts.isExecutable) }
        },
        comparisonRow("xattrs", "확장 속성", copies: copies, monospaced: true) {
            componentText($0) { xattrSummary($0.fileSystemFacts.extendedAttributes) }
        },
        comparisonRow("location-count", "위치 변경 기록 수", copies: copies, monospaced: true) {
            componentText($0) { $0.details.map { String($0.locationHistoryCount) } ?? "—" }
        },
        comparisonRow("last-session", "최근 검사 식별자", copies: copies, monospaced: true) {
            componentText($0) { $0.details?.lastSeenSessionID ?? "—" }
        },
        comparisonRow("original-name-session", "최초 이름 기록 식별자", copies: copies, monospaced: true) {
            componentText($0) { $0.details?.originalNameFirstSeenSessionID ?? "—" }
        }
    ]
}

private func comparisonRow(
    _ id: String,
    _ label: String,
    copies: [DuplicateReviewPresentationCopy],
    sectionTitle: String? = nil,
    monospaced: Bool = false,
    date: ((DuplicateReviewPresentationCopy) -> Date?)? = nil,
    value: (DuplicateReviewPresentationCopy) -> String
) -> ComparisonRowSpec {
    ComparisonRowSpec(
        id: id,
        label: label,
        sectionTitle: sectionTitle,
        values: copies.map { copy in
            let text = value(copy)
            return ComparisonCellValue(
                text: text,
                comparisonKey: text,
                dateValue: date?(copy)
            )
        },
        monospaced: monospaced,
        differenceKind: .generic
    )
}

private struct LivePhotoTimeSlotValue {
    let isPresent: Bool
    let text: String
}

private func livePhotoTimeComparisonRow(
    _ id: String,
    _ label: String,
    copies: [DuplicateReviewPresentationCopy],
    sectionTitle: String? = nil,
    monospaced: Bool = false,
    date: ((DuplicateReviewPresentationCopy) -> Date?)? = nil,
    value: (DuplicateReviewPresentationResource) -> String
) -> ComparisonRowSpec {
    let isLivePhotoComparison = copies.contains { $0.hasLivePhotoStill || $0.hasPairedVideo }
    guard isLivePhotoComparison else {
        return comparisonRow(
            id,
            label,
            copies: copies,
            sectionTitle: sectionTitle,
            monospaced: monospaced,
            date: date
        ) { copy in
            componentLines(copy, value: value)
        }
    }

    let slotPairs: [(still: LivePhotoTimeSlotValue, video: LivePhotoTimeSlotValue)] = copies.map { copy in
        let stillResource = copy.resources.first { $0.role == .photo }
            ?? copy.resources.first { $0.role == .standaloneImage }
        let videoResource = copy.resources.first { $0.role == .pairedVideo }
            ?? copy.resources.first { $0.role == .standaloneVideo }
        return (
            still: LivePhotoTimeSlotValue(
                isPresent: stillResource != nil,
                text: stillResource.map(value) ?? "—"
            ),
            video: LivePhotoTimeSlotValue(
                isPresent: videoResource != nil,
                text: videoResource.map(value) ?? "—"
            )
        )
    }

    let values = zip(copies, slotPairs).map { copy, slots in
        ComparisonCellValue(
            text: "[still] \(slots.still.text)\n[video] \(slots.video.text)",
            comparisonKey: "still:\(slots.still.text)|video:\(slots.video.text)",
            dateValue: date?(copy)
        )
    }
    let differenceKind = livePhotoTimeDifferenceKind(slotPairs)

    return ComparisonRowSpec(
        id: id,
        label: label,
        sectionTitle: sectionTitle,
        values: values,
        monospaced: monospaced,
        differenceKind: differenceKind
    )
}

private func livePhotoTimeDifferenceKind(
    _ pairs: [(still: LivePhotoTimeSlotValue, video: LivePhotoTimeSlotValue)]
) -> ComparisonDifferenceKind {
    var componentDifference = false
    var timeDifference = false

    for slots in [pairs.map(\.still), pairs.map(\.video)] {
        let presence = Set(slots.map(\.isPresent))
        let renderedValues = Set(slots.map(\.text))

        if presence.count > 1, renderedValues.count > 1 {
            componentDifference = true
        }

        let presentValues = Set(slots.filter(\.isPresent).map(\.text))
        if presentValues.count > 1 {
            timeDifference = true
        }
    }

    switch (timeDifference, componentDifference) {
    case (true, true): return .timeAndComponent
    case (true, false): return .time
    case (false, true): return .component
    case (false, false): return .time
    }
}

private func componentLines(
    _ copy: DuplicateReviewPresentationCopy,
    forceLivePhotoSlots: Bool = false,
    value: (DuplicateReviewPresentationResource) -> String
) -> String {
    if forceLivePhotoSlots || copy.hasLivePhotoStill || copy.hasPairedVideo {
        let still = copy.resources.first { $0.role == .photo }
            ?? copy.resources.first { $0.role == .standaloneImage }
        let video = copy.resources.first { $0.role == .pairedVideo }
            ?? copy.resources.first { $0.role == .standaloneVideo }
        var lines = [
            "[still] \(still.map(value) ?? "—")",
            "[video] \(video.map(value) ?? "—")",
        ]
        lines.append(contentsOf: copy.resources
            .filter { $0.role == .sidecar }
            .map { "[sidecar] \(value($0))" })
        return lines.joined(separator: "\n")
    }
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

private func rootUsageRoleLabel(_ role: RootUsageRole) -> String {
    switch role {
    case .staging: return "작업 위치"
    case .primaryLibrary: return "주 라이브러리"
    case .archive: return "장기 보관"
    case .importSource: return "가져오기 원본"
    case .reference: return "비교 전용"
    }
}

private func rootUsageRoleDescription(_ role: RootUsageRole) -> String {
    switch role {
    case .staging:
        return "사진을 정리하거나 옮기기 전에 잠시 두는 작업 폴더입니다."
    case .primaryLibrary:
        return "계속 보관할 주 사진 폴더입니다."
    case .archive:
        return "장기 보관용 폴더입니다. 보관본을 우선 보호합니다."
    case .importSource:
        return "가져오기·내보내기 원본처럼 사진의 출처가 되는 폴더입니다."
    case .reference:
        return "비교에만 사용하는 폴더입니다. 이 위치의 파일은 변경하지 않습니다."
    }
}

private func sourceProvenanceLabel(_ provenance: SourceProvenance) -> String {
    switch provenance {
    case .unknown: return "알 수 없음"
    case .localLibrary: return "Mac의 기존 사진"
    case .appleDirect: return "Apple에서 직접 가져옴"
    case .googleTakeout: return "Google Takeout"
    case .googleWeb: return "Google Photos 웹"
    case .googleIOSShare: return "Google Photos iPhone 공유"
    }
}

private func sourceRootKindLabel(_ kind: SourceRootKind) -> String {
    switch kind {
    case .inbox: return "일반 폴더"
    case .archive: return "보관 폴더"
    case .importSource: return "가져오기 원본"
    case .reference: return "비교 전용"
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
    guard facts.exists else { return "변경됨 · 파일이 없습니다" }
    guard facts.currentByteSize == resource.byteSize else { return "변경됨 · 파일 크기가 달라졌습니다" }
    if let catalogModified = resource.details?.catalogModifiedAt,
       let currentModified = facts.modificationDate,
       abs(catalogModified.timeIntervalSince(currentModified)) >= 0.001 {
        return "변경됨 · 수정 시각이 달라졌습니다"
    }
    if let catalogID = resource.details?.catalogFileSystemIdentifier,
       let currentID = facts.fileSystemIdentifier,
       catalogID != currentID {
        return "변경됨 · 파일 식별자가 달라졌습니다"
    }
    return "변경 없음 · 파일 상태가 이전 기록과 같습니다"
}

private func imageCaptureDateAgreementLabel(
    _ evidence: DuplicateReviewImageCaptureDateEvidence?
) -> String {
    guard let evidence else { return "—" }
    let namedValues: [(String, String)] = [
        ("DateTimeOriginal", evidence.exifDateTimeOriginal ?? ""),
        ("DateTimeDigitized", evidence.exifDateTimeDigitized ?? ""),
        ("TIFF DateTime", evidence.tiffDateTime ?? "")
    ].filter { !$0.1.isEmpty }
    guard namedValues.count >= 2 else {
        return "확인할 원본 촬영 시각이 1개뿐입니다"
    }
    if Set(namedValues.map(\.1)).count == 1 {
        return "서로 일치함 · \(namedValues.map(\.0).joined(separator: " = "))"
    }
    return "서로 다름 · " + namedValues.map { "\($0.0)=\($0.1)" }.joined(separator: " · ")
}

private func quickTimeCaptureEvidenceLabel(_ captureTime: CaptureTime?) -> String {
    guard let captureTime, captureTime.source == .quickTimeCreationDate else { return "—" }
    let timestamp = captureTime.localTimestamp
        ?? captureTime.instant.map(formatDate)
        ?? "—"
    let offset = captureTime.utcOffset.map { " · \($0)" } ?? ""
    return "\(timestamp)\(offset)"
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
    case .image: return "사진"
    case .video: return "비디오"
    case .sidecar: return "보조 파일"
    }
}

private func resourceRoleLabel(_ role: ResourceRole) -> String {
    switch role {
    case .photo: return "Live Photo 사진"
    case .pairedVideo: return "Live Photo 비디오"
    case .standaloneImage: return "일반 사진"
    case .standaloneVideo: return "일반 비디오"
    case .sidecar: return "보조 파일"
    }
}

private func captureSourceLabel(_ source: CaptureTimeSource) -> String {
    switch source {
    case .exifDateTimeOriginal: return "사진 원본(EXIF DateTimeOriginal)"
    case .quickTimeCreationDate: return "QuickTime 원본 시각"
    case .googleTakeoutPhotoTakenTime: return "Google Takeout 촬영 시각"
    case .fileCreationDate: return "파일 생성 시각(대체값)"
    case .unknown: return "알 수 없음"
    }
}

private func capturePrimaryLabel(_ captureTime: CaptureTime?) -> String {
    guard let captureTime else { return "—" }
    let timestamp = captureTime.instant.map(formatDate)
        ?? captureTime.localTimestamp
        ?? "—"
    let offset = captureTime.utcOffset.map { " · \($0)" } ?? ""
    return "\(timestamp)\(offset) · \(captureSourceLabel(captureTime.source)) · \(captureConfidenceLabel(captureTime.confidence))"
}

private func captureConfidenceLabel(_ confidence: CaptureTimeConfidence) -> String {
    switch confidence {
    case .trusted: return "신뢰 높음"
    case .providerSidecar: return "제공자 정보"
    case .incompleteTimezone: return "시간대 정보 불완전"
    case .fallback: return "대체값"
    case .unknown: return "알 수 없음"
    }
}

private func keeperRecommendationText(_ rationale: DuplicateReviewPresentationRationale) -> String {
    switch rationale {
    case .protectedOrPreferredRoot: return "더 안전하게 보관되는 위치에 있습니다"
    case .cleanerFilename: return "복사본 표시가 없는 파일명입니다"
    case .recognizableFilename: return "원본에 가까운 파일명입니다"
    case .earlierDateAdded: return "Mac에 더 먼저 추가된 사본입니다"
    case .matchingParentFolder: return "폴더 구성이 더 자연스럽습니다"
    case .strongerCaptureEvidence: return "촬영 시각 정보가 더 확실합니다"
    case .shallowerPath: return "더 찾기 쉬운 위치에 있습니다"
    case .deterministicTieBreak: return "뚜렷한 차이가 없어 이 사본을 기본으로 추천합니다"
    case .completeLivePhotoOccurrence: return "사진과 비디오가 함께 있는 Live Photo입니다"
    case .sourceSemantics: return "출처 정보가 더 잘 보존되어 있습니다"
    }
}
