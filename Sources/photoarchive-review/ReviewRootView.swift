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
                .help("registered root를 선택하거나 새 폴더를 역할과 함께 등록합니다")
                .disabled(store.isScanning)
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: store.reload) {
                    Label("검토 화면 새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading || store.isScanning)
                .help("디스크를 다시 스캔하지 않고 최신 catalog의 duplicate-review 화면만 다시 읽습니다")
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
        panel.message = "PhotoArchiveKit에 registered root로 추가할 폴더를 선택하세요."
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
                description: Text("현재 검색에 표시할 automatic exact duplicate group이 없습니다.")
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
                Text("비교 스캔 중")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Divider().frame(height: 16)
            }

            Label(
                "삭제 선택 \(store.selectedCleanupItemCount)개 그룹 · \(store.selectedCleanupCopyCount)개 사본",
                systemImage: "trash"
            )
            .foregroundStyle(store.selectedCleanupItemCount > 0 ? .primary : .secondary)

            if let status = store.statusMessage {
                Divider().frame(height: 16)
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
                    Label("이동 전 검증 중…", systemImage: "shield.lefthalf.filled")
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
            .help("현재 빨간색으로 선택한 삭제 대상을 다시 검증한 뒤 실제 목적지로 이동하기 전 최종 확인 화면을 엽니다.")
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
                Text("현재 빨간색으로 선택한 삭제 대상만 적용합니다. 실제 이동 직전에 같은 안전 검증을 다시 수행합니다.")
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                summaryRow("그룹", "\(report.itemCount)개")
                summaryRow("사본", "\(prepared.selectedCopyCount)개")
                summaryRow("파일", "\(report.resourceCount)개")
                summaryRow("용량", ByteCountFormatter.string(fromByteCount: report.totalBytes, countStyle: .file))
                summaryRow("목적지", destinationTitle)
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 9) {
                Label(
                    "선택된 파일의 현재 경로·크기·파일 identity와 가능한 catalog SHA-256을 다시 확인합니다.",
                    systemImage: "checkmark.shield.fill"
                )
                .foregroundStyle(.secondary)

                if report.nonRedundantResourceCount > 0 {
                    Label(
                        "\(report.nonRedundantResourceCount)개 resource는 남아 있는 exact counterpart가 없습니다. 사용자가 명시적으로 선택한 staging/primary-library 항목으로서 reversible destination으로 이동합니다.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }

                if report.onlyCompleteLivePhotoPairRemovalCount > 0 {
                    Label(
                        "\(report.onlyCompleteLivePhotoPairRemovalCount)개 그룹에서는 유일한 완전한 Live Photo 페어가 삭제 대상에 포함됩니다.",
                        systemImage: "livephoto.badge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                }

                if report.removeAllItemCount > 0 {
                    Label(
                        "\(report.removeAllItemCount)개 그룹은 남기는 사본 없이 그룹 전체를 삭제 대상으로 선택했습니다.",
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
                    Text("다시 검증하고 이동하는 중…")
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

    @ViewBuilder
    private func summaryRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
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
                Text("폴더를 먼저 registered root로 등록한 뒤 현재 선택 위치들과 함께 비교 스캔합니다.")
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
                    Text("출처는 keeper 품질 점수가 아니라 source-specific 안전·의미 근거로 사용됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusMessage ?? "등록 및 비교 스캔 중…")
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
                Button("등록하고 비교 스캔") {
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == .livePhotoAsset ? "livephoto" : "photo.stack")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24)
                .foregroundStyle(item.kind == .livePhotoAsset ? .blue : .secondary)
                .help(item.kind == .livePhotoAsset ? "Live Photo" : "Exact duplicate group")

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(item.kind == .livePhotoAsset ? "Exact resource" : "Exact duplicate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(
                            item.kind == .livePhotoAsset
                                ? "Live Photo 안의 하나 이상의 resource가 byte 단위로 동일하다는 뜻입니다. occurrence 전체가 동일하거나 완전하다는 뜻은 아닙니다."
                                : "파일 내용이 byte 단위로 완전히 동일한 사본 그룹입니다."
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
            Text(exactBadgeTitle)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .help(exactBadgeHelp)
            if item.kind == .livePhotoAsset {
                Image(systemName: "livephoto")
                    .foregroundStyle(.blue)
                    .help("Live Photo · still image와 paired video 관계를 하나의 촬영물로 취급합니다.")
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

    private var exactBadgeTitle: String {
        guard item.kind == .livePhotoAsset else { return "EXACT" }
        let copies = item.copies.isEmpty ? fallbackCopies : item.copies
        if !copies.isEmpty && copies.allSatisfy(\.isCompleteLivePhotoOccurrence) {
            return "EXACT PAIR"
        }
        let roles = Set(item.candidateResources.map(\.role))
        if roles == [.photo] { return "EXACT STILL" }
        if roles == [.pairedVideo] { return "EXACT VIDEO" }
        return "EXACT RESOURCE"
    }

    private var exactBadgeHelp: String {
        guard item.kind == .livePhotoAsset else {
            return "각 사본의 파일 내용이 byte 단위로 완전히 동일합니다."
        }
        switch exactBadgeTitle {
        case "EXACT PAIR":
            return "각 Live Photo occurrence의 still과 paired video가 역할별 exact copy입니다. Live Photo completeness는 별도 Still + Paired Video 표시로 확인합니다."
        case "EXACT STILL":
            return "still image resource가 byte 단위로 동일합니다. Live Photo occurrence 전체가 동일하거나 완전하다는 뜻은 아닙니다."
        case "EXACT VIDEO":
            return "paired video resource가 byte 단위로 동일합니다. Live Photo occurrence 전체가 동일하거나 완전하다는 뜻은 아닙니다."
        default:
            return "Live Photo 안의 하나 이상의 resource가 byte 단위로 동일합니다. occurrence 전체의 동일성·완전성과는 별개입니다."
        }
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
                statusPrimaryRow
                    .frame(height: 22, alignment: .leading)

                if itemKind == .livePhotoAsset {
                    statusSecondaryRow
                        .frame(height: 22, alignment: .leading)
                }

                if let primary = copy.primaryResource {
                    ReviewThumbnail(url: primary.fileURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 260)
                        .overlay(alignment: .topTrailing) {
                            if isMarkedForCleanup {
                                Image(systemName: "trash.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.red)
                                    .padding(9)
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

    private var statusPrimaryRow: some View {
        HStack(spacing: 7) {
            if isMarkedForCleanup {
                Label("삭제 예정", systemImage: "trash.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Label("남김", systemImage: "circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if copy.isKeeper {
                Label("추천 keeper", systemImage: "checkmark.seal.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Text("추천 candidate")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            Text("\(copy.resources.count) resource")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .lineLimit(1)
    }

    private var statusSecondaryRow: some View {
        HStack(spacing: 7) {
            livePhotoIntegrityBadge
            Spacer(minLength: 0)
        }
        .lineLimit(1)
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
        livePhotoTimeComparisonRow("capture-primary", "대표 촬영 시각", copies: copies, sectionTitle: "원본 촬영 시각 · 가장 중요한 메타데이터", date: { $0.primaryResource?.captureTime?.instant }) {
            capturePrimaryLabel($0.captureTime)
        },
        livePhotoTimeComparisonRow("capture-evidence-agreement", "원본 timestamp 교차검증", copies: copies) { resource in
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
        livePhotoTimeComparisonRow("quicktime-creation", "QuickTime creation date", copies: copies, monospaced: true) {
            quickTimeCaptureEvidenceLabel($0.captureTime)
        },
        livePhotoTimeComparisonRow("capture-instant", "촬영 시각 (절대시각)", copies: copies, date: { $0.primaryResource?.captureTime?.instant }) {
            formatDate($0.captureTime?.instant)
        },
        livePhotoTimeComparisonRow("capture-source", "대표 촬영 시각 source", copies: copies) {
            $0.captureTime.map { captureSourceLabel($0.source) } ?? "—"
        },
        livePhotoTimeComparisonRow("capture-confidence", "대표 촬영 시각 신뢰도", copies: copies) {
            $0.captureTime.map { captureConfidenceLabel($0.confidence) } ?? "—"
        },
        livePhotoTimeComparisonRow("date-added", "Finder Date Added", copies: copies, sectionTitle: "파일 · 유입 · 관측 시각", date: { $0.primaryResource?.addedAt }) {
            formatDate($0.addedAt)
        },
        livePhotoTimeComparisonRow("creation-date", "파일시스템 생성 시각", copies: copies, date: { $0.primaryResource?.fileSystemFacts.creationDate }) {
            formatDate($0.fileSystemFacts.creationDate)
        },
        livePhotoTimeComparisonRow("filesystem-modified", "파일시스템 수정 시각", copies: copies, date: { $0.primaryResource?.fileSystemFacts.modificationDate }) {
            formatDate($0.fileSystemFacts.modificationDate)
        },
        livePhotoTimeComparisonRow("catalog-modified", "Catalog에 기록된 파일 수정 시각", copies: copies, date: { $0.primaryResource?.details?.catalogModifiedAt }) {
            formatDate($0.details?.catalogModifiedAt)
        },
        livePhotoTimeComparisonRow("first-seen", "PhotoArchiveKit 최초 관측", copies: copies, date: { $0.primaryResource?.details?.firstSeenAt }) {
            formatDate($0.details?.firstSeenAt)
        },
        livePhotoTimeComparisonRow("last-seen", "PhotoArchiveKit 최근 관측", copies: copies, date: { $0.primaryResource?.details?.lastSeenAt }) {
            formatDate($0.details?.lastSeenAt)
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
        comparisonRow("catalog-total-bytes", "Catalog 총 bytes", copies: copies, sectionTitle: "크기", monospaced: true) {
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
        let videoResource = copy.resources.first { $0.role == .pairedVideo }
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
        return "아직 장기 보관이 끝나지 않은 작업·임시 위치입니다. 일반적인 Mac 작업 폴더를 비교할 때 기본값으로 적합합니다."
    case .primaryLibrary:
        return "계속 유지할 주 라이브러리입니다. 다른 위치에 사본이 있어도 이 root 자체를 일반적인 offload 대상으로 보지 않습니다."
    case .archive:
        return "장기 보관·보호 위치입니다. 같은 archive 안의 exact duplicate는 정리할 수 있지만 다른 root의 replica 때문에 보존 사본을 없애지 않습니다."
    case .importSource:
        return "Takeout·export·camera dump 같은 입수처입니다. source-specific 의미와 보존 조건을 확인한 뒤 cleanup authority를 얻습니다."
    case .reference:
        return "비교만 하는 read-only 위치입니다. 이 root 자체를 정리하지 않고 다른 root cleanup의 보존 근거로도 사용하지 않습니다."
    }
}

private func sourceProvenanceLabel(_ provenance: SourceProvenance) -> String {
    switch provenance {
    case .unknown: return "알 수 없음"
    case .localLibrary: return "Local library"
    case .appleDirect: return "Apple direct"
    case .googleTakeout: return "Google Takeout"
    case .googleWeb: return "Google Photos web"
    case .googleIOSShare: return "Google Photos iOS share"
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
        return "근거 부족 · 원본 timestamp가 1개만 확인됨"
    }
    if Set(namedValues.map(\.1)).count == 1 {
        return "초 단위 일치 · \(namedValues.map(\.0).joined(separator: " = "))"
    }
    return "불일치 · " + namedValues.map { "\($0.0)=\($0.1)" }.joined(separator: " · ")
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
