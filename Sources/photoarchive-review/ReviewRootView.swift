import AppKit
import PhotoArchiveCore
import QuickLookThumbnailing
import SwiftUI

private enum ReviewKeyboardRegion: Hashable {
    case sidebar
    case detail
}

struct ReviewRootView: View {
    @StateObject private var store = ReviewStore()
    @State private var addRootRequest: AddComparisonRootRequest?
    @State private var isComparisonLocationsPresented = false
    @State private var isRootManagerPresented = false
    @State private var returnsToRootManagerAfterAdd = false
    @State private var syncRequest: FolderSyncRequest?
    @State private var returnsToRootManagerAfterSync = false
    @State private var folderNotice: String?
    @State private var keyboardRegion: ReviewKeyboardRegion = .sidebar
    @State private var detailFocusedCopyID: String?

    var body: some View {
        ReviewWindowLayout {
            sidebar
                .simultaneousGesture(
                    TapGesture().onEnded { keyboardRegion = .sidebar }
                )
        } detail: {
            VStack(spacing: 0) {
                if store.isScanning {
                    ReviewScanProgressStrip(progress: store.scanProgress)
                }
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ReviewVisualStyle.detailSurface.ignoresSafeArea())
            .simultaneousGesture(
                TapGesture().onEnded { keyboardRegion = .detail }
            )
        } actions: {
            ReviewActionBar(store: store)
        }
        .background(
            ReviewArrowKeyMonitor(onMove: handleArrowKey)
                .allowsHitTesting(false)
        )
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

                Button {
                    NotificationCenter.default.post(
                        name: .photoArchiveToggleSidebar,
                        object: nil
                    )
                } label: {
                    Label("사이드바 보기 또는 숨기기", systemImage: "sidebar.left")
                }
                .help("사이드바 보기 또는 숨기기")
            }

            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isComparisonLocationsPresented.toggle()
                } label: {
                    Label("비교 폴더", systemImage: "folder.badge.gearshape")
                }
                .help("비교할 폴더를 선택하거나 새 폴더를 추가합니다")
                .disabled(store.hasFilesystemOperationInProgress)
                .popover(isPresented: $isComparisonLocationsPresented, arrowEdge: .top) {
                    ComparisonLocationsPopover(
                        roots: store.registeredRoots,
                        selectedRootIDs: store.selectedRootIDs,
                        selectedRootsNeedScan: store.selectedRootsNeedScan,
                        selectedRootsNeedCurrentComparison: store.selectedRootsNeedCurrentComparison,
                        isScanning: store.hasFilesystemOperationInProgress,
                        noticeMessage: folderNotice,
                        onToggle: store.toggleRoot,
                        onReorder: store.reorderRegisteredRoots,
                        onAddFolder: {
                            isComparisonLocationsPresented = false
                            chooseComparisonFolder()
                        },
                        onManage: {
                            isComparisonLocationsPresented = false
                            isRootManagerPresented = true
                        },
                        onScan: {
                            isComparisonLocationsPresented = false
                            Task { await store.scanSelectedRoots() }
                        }
                    )
                }

                Button(action: store.reload) {
                    Label("검토 화면 새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading || store.hasFilesystemOperationInProgress)
                .help("파일을 다시 스캔하지 않고 최근 결과를 화면에 다시 불러옵니다")

                ReviewToolbarSearchField(
                    text: $store.searchText,
                    prompt: "파일명 또는 위치 검색"
                )
                .frame(width: 300)
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
                onCancel: {
                    addRootRequest = nil
                    reopenRootManagerAfterAddIfNeeded()
                },
                onRegisterAndScan: { purpose in
                    Task {
                        let succeeded = await store.registerAndScan(
                            url: request.url,
                            purpose: purpose
                        )
                        if succeeded {
                            addRootRequest = nil
                            reopenRootManagerAfterAddIfNeeded()
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $isRootManagerPresented) {
            ComparisonRootManagerSheet(
                roots: store.registeredRoots,
                selectedRootIDs: store.selectedRootIDs,
                isWorking: store.hasFilesystemOperationInProgress,
                noticeMessage: folderNotice,
                onClose: { isRootManagerPresented = false },
                onAddFolder: {
                    isRootManagerPresented = false
                    DispatchQueue.main.async {
                        chooseComparisonFolder(returnToManager: true)
                    }
                },
                onToggle: store.toggleRoot,
                onSetPurpose: store.setRootUserPurpose,
                onSync: { rootID in
                    isRootManagerPresented = false
                    returnsToRootManagerAfterSync = true
                    DispatchQueue.main.async {
                        syncRequest = FolderSyncRequest(rootID: rootID)
                    }
                },
                onRemove: store.unregisterRoot,
                onReorder: store.reorderRegisteredRoots
            )
        }
        .sheet(item: $syncRequest) { request in
            if let root = store.registeredRoots.first(where: { $0.rootID == request.rootID }) {
                FolderSyncSheet(
                    store: store,
                    root: root,
                    onClose: {
                        syncRequest = nil
                        if returnsToRootManagerAfterSync {
                            returnsToRootManagerAfterSync = false
                            scheduleRootManagerPresentation()
                        }
                    }
                )
            }
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
        .onAppear {
            synchronizeDetailKeyboardFocus()
        }
        .onChange(of: store.selection) { _, _ in
            synchronizeDetailKeyboardFocus()
        }
    }

    private var keyboardCopies: [DuplicateReviewPresentationCopy] {
        guard let item = store.selectedItem else { return [] }
        if !item.copies.isEmpty { return item.copies }
        return item.preferredResources.map {
            DuplicateReviewPresentationCopy(
                id: "fallback-keeper:\($0.id)",
                isKeeper: true,
                resources: [$0]
            )
        } + item.candidateResources.map {
            DuplicateReviewPresentationCopy(
                id: "fallback-candidate:\($0.id)",
                isKeeper: false,
                resources: [$0]
            )
        }
    }

    private func synchronizeDetailKeyboardFocus() {
        let copies = keyboardCopies
        guard !copies.isEmpty else {
            detailFocusedCopyID = nil
            return
        }
        if let detailFocusedCopyID,
           copies.contains(where: { $0.id == detailFocusedCopyID }) {
            return
        }
        detailFocusedCopyID = copies.first?.id
    }

    private func handleArrowKey(_ direction: MoveCommandDirection) -> Bool {
        switch keyboardRegion {
        case .sidebar:
            return handleSidebarMove(direction)
        case .detail:
            return handleDetailMove(direction)
        }
    }

    private func handleSidebarMove(_ direction: MoveCommandDirection) -> Bool {
        switch direction {
        case .up:
            if store.selectedIndex == nil {
                store.selection = store.visibleItems.first?.id
            } else {
                store.selectPrevious()
            }
            return true
        case .down:
            if store.selectedIndex == nil {
                store.selection = store.visibleItems.first?.id
            } else {
                store.selectNext()
            }
            return true
        case .right:
            synchronizeDetailKeyboardFocus()
            keyboardRegion = .detail
            return true
        default:
            return false
        }
    }

    private func handleDetailMove(_ direction: MoveCommandDirection) -> Bool {
        let copies = keyboardCopies
        guard !copies.isEmpty else {
            if direction == .left {
                keyboardRegion = .sidebar
                return true
            }
            return false
        }

        let currentIndex = detailFocusedCopyID.flatMap { focusedID in
            copies.firstIndex(where: { $0.id == focusedID })
        }

        switch direction {
        case .left:
            guard let currentIndex else {
                detailFocusedCopyID = copies.first?.id
                return true
            }
            if currentIndex > 0 {
                detailFocusedCopyID = copies[currentIndex - 1].id
            } else {
                keyboardRegion = .sidebar
            }
            return true
        case .right:
            guard let currentIndex else {
                detailFocusedCopyID = copies.first?.id
                return true
            }
            if currentIndex + 1 < copies.count {
                detailFocusedCopyID = copies[currentIndex + 1].id
            }
            return true
        default:
            return false
        }
    }

    private func focusDetailCopy(_ copyID: String) {
        detailFocusedCopyID = copyID
        keyboardRegion = .detail
    }


    private func chooseComparisonFolder(returnToManager: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = "비교할 폴더 선택"
        panel.prompt = "선택"
        panel.message = "비교에 추가할 폴더를 선택하세요."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else {
            if returnToManager {
                scheduleRootManagerPresentation()
            }
            return
        }
        let standardized = url.standardizedFileURL
        if store.isRegisteredRoot(standardized) {
            store.selectRegisteredRoot(at: standardized)
            showFolderNotice("이미 등록된 폴더입니다.")
            if returnToManager {
                scheduleRootManagerPresentation()
            } else {
                scheduleComparisonFoldersPresentation()
            }
            return
        }
        returnsToRootManagerAfterAdd = returnToManager
        addRootRequest = AddComparisonRootRequest(url: standardized)
    }

    private func reopenRootManagerAfterAddIfNeeded() {
        guard returnsToRootManagerAfterAdd else { return }
        returnsToRootManagerAfterAdd = false
        scheduleRootManagerPresentation()
    }

    private func scheduleRootManagerPresentation() {
        DispatchQueue.main.async {
            isRootManagerPresented = true
        }
    }

    private func scheduleComparisonFoldersPresentation() {
        DispatchQueue.main.async {
            isComparisonLocationsPresented = true
        }
    }

    private func showFolderNotice(_ message: String) {
        folderNotice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if folderNotice == message {
                folderNotice = nil
            }
        }
    }

    private var sidebar: some View {
        ReviewSidebarScrollView(scrollTargetID: store.selection) {
            LazyVStack(spacing: 2) {
                if store.presentation != nil {
                    ReviewSummaryHeader(
                        itemCount: store.visibleItems.count,
                        selectedRootLabels: store.selectedRootLabels
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }

                ForEach(store.visibleItems) { item in
                    ReviewSidebarItem(
                        item: item,
                        selectedCleanupCount: store.cleanupCopyIDsByItem[item.id, default: []].count,
                        isSelected: store.selection == item.id,
                        isKeyboardFocused: keyboardRegion == .sidebar && store.selection == item.id,
                        onSelect: {
                            keyboardRegion = .sidebar
                            store.selection = item.id
                        }
                    )
                    .id(item.id)
                }
            }
            .padding(.bottom, 8)
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
        } else if store.selectedRootIDs.isEmpty {
            ContentUnavailableView(
                "비교할 폴더를 선택하세요",
                systemImage: "folder"
            )
        } else if store.selectedRootsNeedCurrentComparison {
            ContentUnavailableView(
                "선택한 폴더는 재스캔이 필요합니다.",
                systemImage: "clock.arrow.circlepath",
                description: Text("최신 결과를 보려면 다시 스캔해 주세요.")
            )
        } else if let item = store.selectedItem {
            ReviewDetailView(
                item: item,
                cleanupCopyIDs: store.cleanupCopyIDsByItem[item.id, default: []],
                onToggleCleanupFromColumn: { store.toggleCleanupFromColumn($0, item: item) },
                onToggleCleanupFromButton: { store.toggleCleanupFromButton($0, item: item) },
                canToggleCleanup: { store.canToggleCleanup($0, item: item) },
                columnToggleHelp: { store.columnToggleHelp($0, item: item) },
                cleanupToggleHelp: { store.cleanupToggleHelp($0, item: item) },
                focusedCopyID: keyboardRegion == .detail ? detailFocusedCopyID : nil,
                onFocusCopy: focusDetailCopy
            )
        } else if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "검색 결과가 없습니다",
                systemImage: "magnifyingglass",
                description: Text("현재 검색 조건에 맞는 중복 항목이 없습니다.")
            )
        } else {
            ContentUnavailableView(
                "중복 항목이 없습니다",
                systemImage: "checkmark.circle",
                description: Text("선택한 폴더에서 중복 항목을 찾지 못했습니다.")
            )
        }
    }
}

private struct ReviewArrowKeyMonitor: NSViewRepresentable {
    let onMove: (MoveCommandDirection) -> Bool

    func makeNSView(context: Context) -> ReviewArrowKeyMonitorView {
        let view = ReviewArrowKeyMonitorView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: ReviewArrowKeyMonitorView, context: Context) {
        nsView.onMove = onMove
    }
}

private final class ReviewArrowKeyMonitorView: NSView {
    var onMove: ((MoveCommandDirection) -> Bool)?
    private var eventMonitor: Any?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    private func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow,
                  NSApp.keyWindow === window,
                  !self.isEditingText(in: window),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let direction = self.direction(for: event),
                  self.onMove?(direction) == true
            else {
                return event
            }
            return nil
        }
    }

    private func isEditingText(in window: NSWindow) -> Bool {
        if window.firstResponder is NSTextView { return true }
        if window.firstResponder is NSTextField { return true }
        return false
    }

    private func direction(for event: NSEvent) -> MoveCommandDirection? {
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }
}

private struct ReviewActionBar: View {
    @ObservedObject var store: ReviewStore

    var body: some View {
        HStack(spacing: 12) {
            if let selectedIndex = store.selectedIndex,
               !store.visibleItems.isEmpty {
                Text("\(selectedIndex + 1) / \(store.visibleItems.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let status = store.statusMessage, !store.isScanning {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle(
                isOn: Binding(
                    get: { store.recommendedCleanupSelectionIsApplied },
                    set: { _ in store.toggleRecommendedCleanupSelection() }
                )
            ) {
                Label(
                    store.recommendedCleanupSelectionTitle,
                    systemImage: store.recommendedCleanupSelectionIsApplied
                        ? "checkmark.circle.fill"
                        : "checkmark.circle"
                )
            }
            .toggleStyle(.button)
            .modifier(
                ReviewSelectionActionButtonStyle(
                    isSelected: store.recommendedCleanupSelectionIsApplied
                )
            )
            .disabled(
                !store.canToggleRecommendedCleanupSelection
                    || store.isScanning
                    || store.isPreparingCleanup
                    || store.isApplyingCleanup
            )
            .help("각 중복 항목에서 남기기 추천 사본은 유지하고 나머지를 한 번에 선택하거나 해제합니다")

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
            .modifier(
                ReviewDestructiveActionButtonStyle(
                    isActive: store.selectedCleanupItemCount > 0
                )
            )
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
        .frame(maxWidth: .infinity)
    }
}

private struct ReviewToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField(frame: .zero)
        searchField.delegate = context.coordinator
        searchField.placeholderString = prompt
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.controlSize = .regular
        searchField.stringValue = text
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        nsView.placeholderString = prompt
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

private struct ReviewActionButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .controlSize(.regular)
        } else {
            content
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
    }
}

private struct ReviewPrimaryActionButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.1, *) {
            content
                .buttonStyle(
                    .glass(
                        .regular
                            .tint(ReviewVisualStyle.selectionAccent)
                            .interactive()
                    )
                )
                .controlSize(.regular)
                .foregroundStyle(.white)
        } else if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .controlSize(.regular)
                .tint(ReviewVisualStyle.selectionAccent)
                .foregroundStyle(.white)
        } else {
            content
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(ReviewVisualStyle.selectionAccent)
                .foregroundStyle(.white)
        }
    }
}

private struct ReviewSelectionActionButtonStyle: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.1, *), isSelected {
            content
                .buttonStyle(
                    .glass(
                        .regular
                            .tint(ReviewVisualStyle.selectionAccent)
                            .interactive()
                    )
                )
                .controlSize(.regular)
                .foregroundStyle(.white)
        } else if isSelected {
            content.modifier(ReviewPrimaryActionButtonStyle())
        } else {
            content.modifier(ReviewActionButtonStyle())
        }
    }
}

private struct ReviewDestructiveActionButtonStyle: ViewModifier {
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            if #available(macOS 26.1, *) {
                content
                    .buttonStyle(
                        .glass(
                            .regular
                                .tint(Color.red.opacity(0.24))
                                .interactive()
                        )
                    )
                    .controlSize(.regular)
                    .foregroundStyle(.red)
            } else {
                content
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.red)
                    .foregroundStyle(.red)
            }
        } else {
            content.modifier(ReviewActionButtonStyle())
        }
    }
}

private struct ReviewEqualWidthActionLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let itemWidth = sizes.map(\.width).max() ?? 0
        let itemHeight = sizes.map(\.height).max() ?? 0
        return CGSize(
            width: itemWidth * CGFloat(subviews.count) + spacing * CGFloat(max(subviews.count - 1, 0)),
            height: itemHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let availableWidth = max(
            bounds.width - spacing * CGFloat(max(subviews.count - 1, 0)),
            0
        )
        let itemWidth = availableWidth / CGFloat(subviews.count)
        var x = bounds.minX
        for subview in subviews {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: itemWidth, height: bounds.height)
            )
            x += itemWidth + spacing
        }
    }
}

private struct ReviewScanProgressStrip: View {
    let progress: ScanProgress?

    private var title: String {
        switch progress?.stage {
        case .enumerating, .none:
            return "파일 찾는 중"
        case .metadata:
            return "파일 확인 중"
        case .hashingDuplicates, .hashingIntegrity:
            return "중복 확인 중"
        case .cataloging, .finalizing:
            return "마무리 중"
        }
    }

    private var fraction: Double? {
        guard let progress,
              let total = progress.totalUnitCount,
              total > 0
        else { return nil }
        return min(max(Double(progress.completedUnitCount) / Double(total), 0), 1)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if fraction == nil {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(title)
                    .font(.caption.weight(.medium))

                Spacer()

                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }
        }
        .frame(minHeight: 24)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
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
                    .font(.title3.weight(.semibold))
                Text(summaryTitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(recoveryHint)
                    .font(.callout)
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
                ReviewEqualWidthActionLayout {
                    Button(action: onCancel) {
                        Text("취소")
                            .frame(maxWidth: .infinity)
                    }
                        .modifier(ReviewActionButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .disabled(isApplying)
                    Button(action: onApply) {
                        Text(applyButtonTitle)
                            .frame(maxWidth: .infinity)
                    }
                        .modifier(ReviewDestructiveActionButtonStyle(isActive: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(isApplying)
                }
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

    private var recoveryHint: String {
        switch report.destinationKind {
        case .systemTrash:
            return "필요하면 휴지통에서 다시 복원할 수 있습니다."
        case .customQuarantine:
            return "필요하면 격리 폴더에서 다시 복원할 수 있습니다."
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

private struct FolderSyncRequest: Identifiable {
    let rootID: String
    var id: String { rootID }
}

private struct ComparisonLocationsPopover: View {
    let roots: [RegisteredRootReport]
    let selectedRootIDs: Set<String>
    let selectedRootsNeedScan: Bool
    let selectedRootsNeedCurrentComparison: Bool
    let isScanning: Bool
    let noticeMessage: String?
    let onToggle: (String) -> Void
    let onReorder: ([String]) -> Void
    let onAddFolder: () -> Void
    let onManage: () -> Void
    let onScan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("비교 폴더")
                    .font(.headline)
                Text("\(selectedRootIDs.count)개 폴더 선택됨")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if roots.isEmpty {
                ContentUnavailableView(
                    "등록된 폴더가 없습니다",
                    systemImage: "folder",
                    description: Text("비교할 폴더를 추가하세요.")
                )
                .frame(width: 280, height: 96)
            } else {
                ReviewRootList(
                    entries: roots.map { root in
                        ReviewRootListEntry(
                            id: root.rootID, title: root.label, subtitle: rootSubtitle(root),
                            selected: selectedRootIDs.contains(root.rootID),
                            toggleEnabled: root.isAvailable || selectedRootIDs.contains(root.rootID),
                            purposeIndex: nil
                        )
                    },
                    isEnabled: !isScanning,
                    onToggle: { id, _ in onToggle(id) },
                    onReorder: onReorder
                )
                .frame(height: min(CGFloat(roots.count) * 38, 266))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Button(action: onAddFolder) {
                    Label("폴더 추가…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button(action: onManage) {
                    Label("폴더 상세 설정…", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Divider()

                if let noticeMessage {
                    Label(noticeMessage, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if selectedRootsNeedScan {
                    Text("새로 선택한 폴더가 아직 스캔되지 않았습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: onScan) {
                        Label("선택한 폴더 스캔", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .modifier(ReviewPrimaryActionButtonStyle())
                    .disabled(selectedRootIDs.isEmpty || isScanning)
                } else {
                    if selectedRootsNeedCurrentComparison {
                        Text("최신 결과를 보려면 선택한 폴더를 다시 스캔해 주세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(action: onScan) {
                        Label("선택한 폴더 다시 스캔", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedRootIDs.isEmpty || isScanning)
                }
            }
        }
        .padding(12)
        .frame(width: 304)
    }

    private func rootSubtitle(_ root: RegisteredRootReport) -> String {
        if root.isAvailable {
            return rootUsageRoleLabel(root.usageRole)
        }
        return "\(rootUsageRoleLabel(root.usageRole)) · 오프라인"
    }
}

private struct RootRemovalRequest: Identifiable {
    let rootID: String
    let label: String
    var id: String { rootID }
}

private struct ComparisonRootManagerSheet: View {
    let roots: [RegisteredRootReport]
    let selectedRootIDs: Set<String>
    let isWorking: Bool
    let noticeMessage: String?
    let onClose: () -> Void
    let onAddFolder: () -> Void
    let onToggle: (String) -> Void
    let onSetPurpose: (String, RootUserPurpose) -> Void
    let onSync: (String) -> Void
    let onRemove: (String) -> Void
    let onReorder: ([String]) -> Void

    @State private var removalRequest: RootRemovalRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("폴더 상세 설정")
                    .font(.title3.weight(.semibold))
                Text("비교에 포함할 폴더와 순서·용도를 변경합니다.")
                    .foregroundStyle(.secondary)
            }

            ReviewRootList(
                entries: roots.map { root in
                    ReviewRootListEntry(
                        id: root.rootID,
                        title: root.label + (root.isAvailable ? "" : " · 오프라인"),
                        subtitle: root.canonicalPath,
                        selected: selectedRootIDs.contains(root.rootID),
                        toggleEnabled: root.isAvailable || selectedRootIDs.contains(root.rootID),
                        purposeIndex: [RootUserPurpose.standard, .archive, .readOnly]
                            .firstIndex(of: root.usageRole.userPurpose)
                    )
                },
                isEnabled: !isWorking,
                onToggle: { id, _ in onToggle(id) },
                onPurpose: { id, index in
                    let purposes: [RootUserPurpose] = [.standard, .archive, .readOnly]
                    guard purposes.indices.contains(index) else { return }
                    onSetPurpose(id, purposes[index])
                },
                onSync: onSync,
                onRemove: { id in
                    guard let root = roots.first(where: { $0.rootID == id }) else { return }
                    removalRequest = RootRemovalRequest(rootID: id, label: root.label)
                },
                purposeDescriptions: [RootUserPurpose.standard, .archive, .readOnly].map(rootUserPurposeDescription),
                onReorder: onReorder
            )
            .frame(height: min(max(CGFloat(roots.count) * 56, 224), 380))

            if let noticeMessage {
                Label(noticeMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(action: onAddFolder) {
                    Label("폴더 추가…", systemImage: "plus")
                }
                .modifier(ReviewActionButtonStyle())
                .disabled(isWorking)

                Spacer()
                Button("완료", action: onClose)
                    .modifier(ReviewActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 650)
        .alert(item: $removalRequest) { request in
            Alert(
                title: Text("‘\(request.label)’ 폴더 등록을 해제할까요?"),
                message: Text("PhotoArchiveKit에서 등록만 해제합니다. 폴더와 사진은 그대로 유지됩니다."),
                primaryButton: .destructive(Text("등록 해제")) {
                    onRemove(request.rootID)
                },
                secondaryButton: .cancel(Text("취소"))
            )
        }
    }

}

private struct FolderSyncSheet: View {
    @ObservedObject var store: ReviewStore
    let root: RegisteredRootReport
    let onClose: () -> Void

    @State private var remoteName = ""
    @State private var remotePath: String
    @State private var hasRequestedRemotes = false
    @State private var showsInitialSyncConfirmation = false
    @State private var showsDisconnectConfirmation = false
    @State private var showsDeletionPlan = false
    @State private var showsConflictItems = false
    @State private var showsRecoveryItems = false

    init(store: ReviewStore, root: RegisteredRootReport, onClose: @escaping () -> Void) {
        self.store = store
        self.root = root
        self.onClose = onClose
        _remotePath = State(initialValue: root.label)
    }

    private var connection: FolderSyncConnection? {
        store.syncConnection(for: root.rootID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Google Drive 동기화")
                    .font(.title3.weight(.semibold))
                Text("\(root.label) 폴더와 Google Drive를 양방향으로 연결합니다.")
                    .foregroundStyle(.secondary)
            }

            if let connection {
                connectedContent(connection)
            } else if root.usageRole.userPurpose == .readOnly {
                Label(
                    "읽기 전용 폴더는 양방향 동기화할 수 없습니다.",
                    systemImage: "lock"
                )
                .foregroundStyle(.secondary)
            } else {
                setupContent
            }

            if let message = store.syncErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("완료", action: onClose)
                    .modifier(ReviewActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.isSyncing)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task(id: connection?.id) {
            if let connection {
                await store.loadSyncConflictItems(connectionID: connection.id)
                await store.loadSyncRecoveryItems(connectionID: connection.id)
            } else if root.usageRole.userPurpose != .readOnly, !hasRequestedRemotes {
                hasRequestedRemotes = true
                await store.loadSyncDriveRemotes()
                if remoteName.isEmpty {
                    remoteName = store.syncDriveRemotes.first?.name ?? ""
                }
            }
        }
        .alert("첫 동기화를 시작할까요?", isPresented: $showsInitialSyncConfirmation) {
            Button("취소", role: .cancel) {}
            Button("동기화 시작") {
                guard let connection else { return }
                Task {
                    await store.runSync(
                        connectionID: connection.id,
                        confirmInitialSync: true
                    )
                }
            }
        } message: {
            Text(
                "한쪽에만 있는 파일은 양쪽에 합칩니다. 동일한 위치에 서로 다른 내용의 파일이 있으면 어느 쪽도 자동으로 덮어쓰지 않고 첫 동기화를 중단합니다."
            )
        }
        .confirmationDialog(
            "동기화 연결을 해제할까요?",
            isPresented: $showsDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            if let connection {
                Button("연결 해제", role: .destructive) {
                    store.removeSyncConnection(connectionID: connection.id)
                    hasRequestedRemotes = true
                    Task {
                        await store.loadSyncDriveRemotes()
                        if remoteName.isEmpty {
                            remoteName = store.syncDriveRemotes.first?.name ?? ""
                        }
                    }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("연결 정보만 제거합니다. HDD와 Google Drive의 파일, 기존 복구 자료는 삭제하지 않습니다.")
        }
        .sheet(isPresented: $showsDeletionPlan) {
            if let connection,
               let plan = store.syncPendingDeletionPlans[connection.id] {
                FolderSyncDeletionPlanSheet(
                    connection: connection,
                    plan: plan,
                    canApprove: RcloneBisyncService.productionApplyAvailable
                        && !store.hasFilesystemOperationInProgress,
                    onApprove: {
                        showsDeletionPlan = false
                        Task {
                            await store.runSync(
                                connectionID: connection.id,
                                confirmInitialSync: false,
                                approvedDeletionPlanID: plan.id
                            )
                        }
                    },
                    onClose: { showsDeletionPlan = false }
                )
            }
        }
        .sheet(isPresented: $showsRecoveryItems) {
            if let connection {
                FolderSyncRecoveryItemsSheet(
                    store: store,
                    connection: connection,
                    onClose: { showsRecoveryItems = false }
                )
            }
        }
        .sheet(isPresented: $showsConflictItems) {
            if let connection {
                FolderSyncConflictItemsSheet(
                    store: store,
                    connection: connection,
                    onClose: { showsConflictItems = false }
                )
            }
        }
    }

    @ViewBuilder
    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if store.isLoadingSyncRemotes {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Google Drive 연결을 확인하는 중…")
                                .foregroundStyle(.secondary)
                        }
                    } else if store.syncDriveRemotes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("연결된 Google Drive를 찾지 못했습니다.")
                            Text("Google Drive 연결을 설정한 뒤 다시 확인해 주세요.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("다시 확인") {
                                Task { await store.loadSyncDriveRemotes() }
                            }
                        }
                    } else {
                        Picker("Google Drive", selection: $remoteName) {
                            ForEach(store.syncDriveRemotes) { remote in
                                Text(remote.displayName).tag(remote.name)
                            }
                        }

                        TextField("Google Drive 폴더", text: $remotePath)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Label(
                "이 기능은 단순 백업이 아닙니다. 한쪽에서 추가·수정·이동·삭제하면 다른 쪽에도 반영됩니다.",
                systemImage: "exclamationmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "동기화 중에는 동일한 파일을 다른 앱이나 기기에서 수정하지 마세요. 양쪽에서 바뀐 파일은 자동으로 덮어쓰지 않고 확인이 필요합니다."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("동기화 연결…") {
                    let remote = store.syncDriveRemotes.first(where: { $0.name == remoteName })
                    _ = store.createSyncConnection(
                        rootID: root.rootID,
                        remoteName: remoteName,
                        remoteDisplayName: remote?.displayName,
                        remotePath: remotePath
                    )
                }
                .modifier(ReviewPrimaryActionButtonStyle())
                .disabled(
                    remoteName.isEmpty
                        || remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || store.hasFilesystemOperationInProgress
                )
            }
        }
    }

    @ViewBuilder
    private func connectedContent(_ connection: FolderSyncConnection) -> some View {
        let displayStatus = folderSyncDisplayStatus(connection.status)
        let confirmationCount = store.syncConfirmationItemCount(connectionID: connection.id)
        let recoverySummary = store.syncRecoverySummary(connectionID: connection.id)
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        Text("연결")
                            .foregroundStyle(.secondary)
                        Text("\(root.label) ↔ \(connection.remoteDisplayName ?? "Google Drive")")
                    }
                    GridRow {
                        Text("Google Drive 폴더")
                            .foregroundStyle(.secondary)
                        Text(connection.remotePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    GridRow {
                        Text("상태")
                            .foregroundStyle(.secondary)
                        Label(
                            folderSyncStatusText(displayStatus),
                            systemImage: folderSyncStatusIcon(displayStatus)
                        )
                    }
                    if let lastSuccessAt = connection.lastSuccessAt {
                        GridRow {
                            Text(
                                displayStatus == .success || displayStatus == .ready
                                    ? "마지막 동기화 완료"
                                    : "이전 동기화 완료"
                            )
                                .foregroundStyle(.secondary)
                            Text(lastSuccessAt, format: .dateTime.year().month().day().hour().minute())
                        }
                    }
                    GridRow {
                        Text("확인이 필요한 사진")
                            .foregroundStyle(.secondary)
                        Text("\(confirmationCount)개")
                    }
                    GridRow {
                        Text("복구할 항목")
                            .foregroundStyle(.secondary)
                        if let recoverySummary {
                            Text(
                                "\(recoverySummary.itemCount)개 · "
                                    + ByteCountFormatter.string(
                                        fromByteCount: recoverySummary.totalBytes,
                                        countStyle: .file
                                    )
                            )
                        } else if store.isLoadingSyncRecovery {
                            Text("확인 중…")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("확인 필요")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(folderSyncStatusDetail(displayStatus))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !RcloneBisyncService.productionApplyAvailable {
                Label("파일을 안전하게 반영하는 기능을 준비하고 있습니다. 현재는 동기화를 실행할 수 없습니다.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if confirmationCount > 0
                || store.syncPendingDeletionPlans[connection.id] != nil
                || (recoverySummary?.itemCount ?? 0) > 0 {
                HStack(spacing: 10) {
                    if !store.syncConflictItems(connectionID: connection.id).isEmpty {
                        Button("확인이 필요한 사진…") {
                            showsConflictItems = true
                        }
                    }
                    if store.syncPendingDeletionPlans[connection.id] != nil {
                        Button("삭제할 항목 확인…") {
                            showsDeletionPlan = true
                        }
                    }
                    if (recoverySummary?.itemCount ?? 0) > 0 {
                        Button("복구할 항목…") {
                            showsRecoveryItems = true
                        }
                    }
                }
            }

            if store.isSyncing {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(syncProgressText(store.syncProgress?.stage))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("취소", action: store.cancelSync)
                }
            } else {
                HStack {
                    Button("연결 해제…", role: .destructive) {
                        showsDisconnectConfirmation = true
                    }
                    .disabled(store.hasFilesystemOperationInProgress)

                    Spacer()
                    Button("지금 동기화") {
                        if connection.isInitialized {
                            Task {
                                await store.runSync(
                                    connectionID: connection.id,
                                    confirmInitialSync: false
                                )
                            }
                        } else {
                            showsInitialSyncConfirmation = true
                        }
                    }
                    .modifier(ReviewPrimaryActionButtonStyle())
                    .disabled(
                        !RcloneBisyncService.productionApplyAvailable
                            || store.hasFilesystemOperationInProgress
                    )
                    .help(
                        RcloneBisyncService.productionApplyAvailable
                            ? "두 위치의 변경 사항을 확인하고 반영합니다"
                            : "파일을 안전하게 반영하는 기능을 준비하고 있습니다. 현재는 동기화를 실행할 수 없습니다."
                    )
                }
            }
        }
    }

    private func syncProgressText(_ stage: FolderSyncProgressStage?) -> String {
        switch stage {
        case .checking: return "연결과 폴더를 확인하는 중…"
        case .preparing: return "안전한 동기화를 준비하는 중…"
        case .preflight: return "변경 사항을 미리 확인하는 중…"
        case .syncing: return "양쪽 변경 사항을 반영하는 중…"
        case .finalizing: return "동기화 결과를 확인하는 중…"
        case nil: return "동기화하는 중…"
        }
    }
}

private struct FolderSyncConflictItemsSheet: View {
    @ObservedObject var store: ReviewStore
    let connection: FolderSyncConnection
    let onClose: () -> Void

    var body: some View {
        let items = store.syncConflictItems(connectionID: connection.id)
        VStack(alignment: .leading, spacing: 16) {
            Text("확인이 필요한 사진")
                .font(.title3.weight(.semibold))
            Text("양쪽의 동일한 사진이 각각 변경되었습니다. 자동으로 한쪽을 선택하지 않습니다.")
                .foregroundStyle(.secondary)

            if store.isLoadingSyncConflicts {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("현재 상태를 확인하는 중…")
                        .foregroundStyle(.secondary)
                }
            } else if items.isEmpty {
                Text("현재 이 화면에서 선택할 수 있는 항목이 없습니다.")
                    .foregroundStyle(.secondary)
            } else {
                List(items) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: item.isLivePhoto ? "livephoto" : "photo")
                            Text(item.relativePaths.first ?? "사진")
                                .font(.headline)
                        }
                        Text("외장 드라이브 · \(item.externalDriveDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Google Drive · \(item.googleDriveDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(item.availableChoices, id: \.self) { choice in
                                Button(folderSyncConflictChoiceTitle(choice)) {
                                    Task {
                                        await store.resolveSyncConflict(
                                            connectionID: connection.id,
                                            itemID: item.id,
                                            choice: choice,
                                            expectedFingerprint: item.expectedFingerprint
                                        )
                                    }
                                }
                                .disabled(
                                    !RcloneBisyncService.productionApplyAvailable
                                        || store.hasFilesystemOperationInProgress
                                )
                                .help(folderSyncConflictChoiceHelp(choice))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 260)
            }

            if !RcloneBisyncService.productionApplyAvailable {
                Label(
                    "선택 기능은 준비되어 있지만, 현재 버전에서는 파일 반영을 아직 사용할 수 없습니다.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button("다시 확인") {
                    Task { await store.loadSyncConflictItems(connectionID: connection.id) }
                }
                .modifier(ReviewActionButtonStyle())
                .disabled(store.isLoadingSyncConflicts || store.hasFilesystemOperationInProgress)
                Spacer()
                Button("완료", action: onClose)
                    .modifier(ReviewActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }
}

private func folderSyncConflictChoiceTitle(_ choice: FolderSyncConflictChoice) -> String {
    switch choice {
    case .keepBoth: return "둘 다 보관"
    case .useExternalDrive: return "외장 드라이브 버전 사용"
    case .useGoogleDrive: return "Google Drive 버전 사용"
    case .keepModified: return "수정본 보관"
    case .deleteBoth: return "양쪽에서 삭제"
    }
}

private func folderSyncConflictChoiceHelp(_ choice: FolderSyncConflictChoice) -> String {
    switch choice {
    case .keepBoth:
        return "두 버전을 모두 남기며 기존 이름을 덮어쓰지 않습니다."
    case .useExternalDrive:
        return "외장 드라이브의 현재 내용을 Google Drive에도 사용합니다."
    case .useGoogleDrive:
        return "Google Drive의 현재 내용을 외장 드라이브에도 사용합니다."
    case .keepModified:
        return "남아 있는 수정본을 양쪽에 보관합니다."
    case .deleteBoth:
        return "양쪽에서 삭제하며 삭제 전 복구 사본을 보관합니다."
    }
}

private struct FolderSyncDeletionPlanSheet: View {
    let connection: FolderSyncConnection
    let plan: FolderSyncDeletionPlan
    let canApprove: Bool
    let onApprove: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("삭제할 항목 확인")
                .font(.title3.weight(.semibold))
            Text("아래 항목은 반대쪽에서도 제거됩니다. 제거 전 사본은 복구 위치에 보관합니다.")
                .foregroundStyle(.secondary)

            List(plan.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.isLivePhoto ? "Live Photo" : item.relativePaths.first ?? "항목")
                        .font(.headline)
                    Text(folderSyncLocationText(item.location))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(item.relativePaths, id: \.self) { path in
                        Text(path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(minHeight: 220)

            if !plan.emptiedNonEmptyDirectories.isEmpty {
                Label(
                    "비어 있게 되는 폴더가 포함되어 있습니다.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
            }

            HStack {
                Spacer()
                ReviewEqualWidthActionLayout {
                    Button(action: onClose) {
                        Text("취소")
                            .frame(maxWidth: .infinity)
                    }
                        .modifier(ReviewActionButtonStyle())
                    Button(action: onApprove) {
                        Text("확인하고 동기화")
                            .frame(maxWidth: .infinity)
                    }
                        .modifier(ReviewPrimaryActionButtonStyle())
                        .disabled(!canApprove)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 430)
    }
}

private struct FolderSyncRecoveryItemsSheet: View {
    @ObservedObject var store: ReviewStore
    let connection: FolderSyncConnection
    let onClose: () -> Void
    @State private var pendingCleanupItemID: String?

    var body: some View {
        let items = store.syncRecoveryItems(connectionID: connection.id)
        let summary = FolderSyncRecoverySummary(items: items)
        VStack(alignment: .leading, spacing: 16) {
            Text("복구할 항목")
                .font(.title3.weight(.semibold))
            Text(
                "\(summary.itemCount)개 · "
                    + ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file)
            )
            .foregroundStyle(.secondary)

            if items.isEmpty {
                Text("보관된 복구 사본이 없습니다.")
                    .foregroundStyle(.secondary)
            } else {
                List(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.originalRelativePath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(recoveryLocationText(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            if item.location == .externalDrive {
                                Button("복원") {
                                    Task {
                                        await store.restoreSyncRecoveryItem(
                                            connectionID: connection.id,
                                            itemID: item.id
                                        )
                                    }
                                }
                                .disabled(store.hasFilesystemOperationInProgress)
                            } else {
                                Text("Google Drive 복원은 현재 사용할 수 없음")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button("정리…", role: .destructive) {
                                pendingCleanupItemID = item.id
                            }
                            .disabled(store.hasFilesystemOperationInProgress)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .frame(minHeight: 240)
            }

            HStack {
                Button("다시 확인") {
                    Task { await store.loadSyncRecoveryItems(connectionID: connection.id) }
                }
                .modifier(ReviewActionButtonStyle())
                .disabled(store.isLoadingSyncRecovery)
                Spacer()
                Button("완료", action: onClose)
                    .modifier(ReviewActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 460)
        .alert(
            "복구 사본을 정리할까요?",
            isPresented: Binding(
                get: { pendingCleanupItemID != nil },
                set: { if !$0 { pendingCleanupItemID = nil } }
            )
        ) {
            Button("취소", role: .cancel) {
                pendingCleanupItemID = nil
            }
            Button("휴지통으로 이동", role: .destructive) {
                guard let itemID = pendingCleanupItemID else { return }
                pendingCleanupItemID = nil
                Task {
                    await store.discardSyncRecoveryItem(
                        connectionID: connection.id,
                        itemID: itemID
                    )
                }
            }
        } message: {
            Text("선택한 복구 사본만 해당 위치의 휴지통으로 이동합니다. 원래 위치의 파일은 변경하지 않습니다.")
        }
    }

    private func recoveryLocationText(_ item: FolderSyncRecoveryItem) -> String {
        switch item.location {
        case .externalDrive:
            return "외장 드라이브에서 제거된 사본 · Mac 복구 저장소"
        case .googleDrive:
            return "Google Drive에서 제거된 사본 · Google Drive 복구 저장소"
        }
    }
}

private func folderSyncLocationText(_ location: FolderSyncLocation) -> String {
    switch location {
    case .externalDrive: return "외장 드라이브에서 제거"
    case .googleDrive: return "Google Drive에서 제거"
    }
}

private func folderSyncDisplayStatus(_ status: FolderSyncStatus) -> FolderSyncStatus {
    guard !RcloneBisyncService.productionApplyAvailable else { return status }
    switch status {
    case .setupRequired, .ready, .success, .safetyUnavailable:
        return .safetyUnavailable
    default:
        return status
    }
}

func folderSyncStatusText(_ status: FolderSyncStatus) -> String {
    switch status {
    case .setupRequired: return "첫 동기화 필요"
    case .ready: return "동기화 준비됨"
    case .running: return "동기화 중"
    case .success: return "동기화 완료"
    case .failed: return "동기화 실패"
    case .incomplete: return "일부 항목을 완료하지 못했습니다"
    case .confirmationRequired: return "확인이 필요한 사진이 있습니다"
    case .conflict: return "양쪽에서 변경된 사진이 있습니다"
    case .initialConflict: return "첫 동기화에서 확인할 사진이 있습니다"
    case .recoveryRequired: return "복구 필요"
    case .driveUnavailable: return "외장 드라이브를 연결해주세요"
    case .connectionCheckRequired: return "Google Drive에 연결하지 못했습니다"
    case .livePhotoBlocked: return "확인이 필요한 Live Photo가 있습니다"
    case .safetyUnavailable: return "동기화 준비 중"
    case .cancelled: return "동기화 취소됨"
    }
}

func folderSyncStatusIcon(_ status: FolderSyncStatus) -> String {
    switch status {
    case .success: return "checkmark.circle"
    case .running: return "arrow.triangle.2.circlepath"
    case .incomplete, .confirmationRequired, .conflict, .initialConflict,
         .recoveryRequired, .connectionCheckRequired,
         .livePhotoBlocked, .safetyUnavailable:
        return "exclamationmark.triangle"
    case .driveUnavailable: return "externaldrive.badge.questionmark"
    case .setupRequired, .ready, .cancelled, .failed: return "circle"
    }
}

func folderSyncStatusDetail(_ status: FolderSyncStatus) -> String {
    switch status {
    case .setupRequired:
        return "첫 동기화에서는 한쪽에만 있는 파일만 합칠 수 있고, 동일한 위치의 내용이 다르면 중단합니다. 자동 동기화는 사용하지 않습니다."
    case .success, .ready:
        return "마지막으로 완료한 동기화 결과입니다. 자동 감시 상태를 뜻하지 않으며 현재 파일은 다음 동기화 때 다시 확인합니다."
    case .running:
        return "양쪽의 변경 사항을 확인하고 반영하고 있습니다."
    case .incomplete:
        return "일부 항목의 전송 또는 확인이 끝나지 않았습니다. 전체 동기화를 완료로 기록하지 않았으며 정상 원본은 그대로 둡니다."
    case .confirmationRequired:
        return "자동으로 결정하기 어려운 변경을 찾았습니다. 다른 구성요소까지 임의로 삭제하거나 한쪽 사본을 폐기하지 않았습니다."
    case .conflict:
        return "서로 충돌한 파일은 한쪽을 버리지 않고 양쪽 사본을 보존했습니다. 파일을 확인해 주세요."
    case .initialConflict:
        return "첫 동기화 전에 동일한 위치의 서로 다른 파일을 찾았습니다. 어느 쪽도 자동으로 덮어쓰지 않았습니다. 내용을 확인해 주세요."
    case .recoveryRequired:
        return "이전 실행에서 일부 파일이 이미 반영되었을 수 있습니다. 현재 상태를 확인하기 전에는 자동으로 다시 초기화하거나 재실행하지 않습니다."
    case .driveUnavailable:
        return "외장 드라이브를 다시 연결한 뒤 동기화해 주세요. 연결되지 않은 상태를 삭제로 처리하지 않습니다."
    case .connectionCheckRequired:
        return "Google Drive 연결 또는 대상 폴더를 확인한 뒤 다시 시도해 주세요."
    case .livePhotoBlocked:
        return "Live Photo 여부나 구성요소 관계를 안전하게 확인할 수 없는 항목을 찾았습니다. 파일을 임의로 변경하지 않고 확인을 기다립니다."
    case .safetyUnavailable:
        return "파일을 안전하게 반영하는 기능을 준비하고 있습니다. 현재는 동기화를 실행할 수 없습니다."
    case .cancelled:
        return "취소 전 일부 변경이 반영되었을 수 있습니다. 성공으로 기록하지 않았으며 현재 상태를 다시 확인해야 합니다."
    case .failed:
        return "동기화를 완료하지 못했습니다. 실패 전에 일부 변경이 반영되었을 수 있으며 자동으로 초기화하거나 재실행하지 않습니다."
    }
}

struct FolderSyncUIFixtureView: View {
    private let rows: [(FolderSyncStatus, String?)] = [
        (.initialConflict, nil),
        (.incomplete, nil),
        (.confirmationRequired, nil),
        (.conflict, nil),
        (.livePhotoBlocked, nil),
        (.driveUnavailable, nil),
        (.cancelled, nil),
        (.recoveryRequired, nil),
        (.safetyUnavailable, nil),
        (.success, "2026. 9. 12. 오후 8:00")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("동기화 상태 격리 미리보기")
                    .font(.title2.weight(.semibold))
                Text("개인 catalog나 Google Drive 계정을 읽지 않는 synthetic UI fixture입니다.")
                    .foregroundStyle(.secondary)

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                folderSyncStatusText(row.0),
                                systemImage: folderSyncStatusIcon(row.0)
                            )
                            .font(.headline)
                            Text(folderSyncStatusDetail(row.0))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let lastSuccess = row.1 {
                                Text("마지막 동기화 완료 · \(lastSuccess)")
                                    .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 680, minHeight: 640)
        .onAppear {
            let arguments = CommandLine.arguments
            let shouldValidate = ProcessInfo.processInfo.environment["PHOTOARCHIVE_SYNC_UI_FIXTURE_VALIDATE"] == "1"
                || arguments.contains("--sync-ui-fixture-validate")
            guard shouldValidate
            else { return }
            let statuses = Set(rows.map(\.0))
            let required: Set<FolderSyncStatus> = [
                .initialConflict,
                .incomplete,
                .confirmationRequired,
                .conflict,
                .livePhotoBlocked,
                .driveUnavailable,
                .cancelled,
                .recoveryRequired,
                .safetyUnavailable,
                .success
            ]
            guard required.isSubset(of: statuses), rows.contains(where: { $0.1 != nil }) else {
                FileHandle.standardError.write(Data("sync UI fixture is incomplete\n".utf8))
                exit(1)
            }
            let consumerText = rows.flatMap { row in
                [folderSyncStatusText(row.0), folderSyncStatusDetail(row.0)]
            }.joined(separator: "\n")
            let forbiddenTerms = [
                "production", "preflight", "TOCTOU", "journal", "atomicity",
                "bisync", "rclone", "transaction", "backend", "remote"
            ]
            guard !forbiddenTerms.contains(where: { consumerText.localizedCaseInsensitiveContains($0) }) else {
                FileHandle.standardError.write(Data("sync UI exposes internal terminology\n".utf8))
                exit(1)
            }
            guard folderSyncStatusText(.safetyUnavailable) == "동기화 준비 중",
                  folderSyncStatusDetail(.safetyUnavailable)
                    == "파일을 안전하게 반영하는 기능을 준비하고 있습니다. 현재는 동기화를 실행할 수 없습니다."
            else {
                FileHandle.standardError.write(Data("sync unavailable copy does not describe its state clearly\n".utf8))
                exit(1)
            }
            guard !RcloneBisyncService.productionApplyAvailable else {
                FileHandle.standardError.write(Data("sync production gate must remain disabled\n".utf8))
                exit(1)
            }
            let conflictChoiceText = [
                FolderSyncConflictChoice.keepBoth,
                .useExternalDrive,
                .useGoogleDrive,
                .keepModified,
                .deleteBoth
            ].flatMap { choice in
                [folderSyncConflictChoiceTitle(choice), folderSyncConflictChoiceHelp(choice)]
            }.joined(separator: "\n")
            guard [
                "둘 다 보관",
                "외장 드라이브 버전 사용",
                "Google Drive 버전 사용",
                "수정본 보관",
                "양쪽에서 삭제"
            ].allSatisfy({ conflictChoiceText.contains($0) }),
            !forbiddenTerms.contains(where: {
                conflictChoiceText.localizedCaseInsensitiveContains($0)
            }) else {
                FileHandle.standardError.write(Data("sync conflict choices are not consumer-safe\n".utf8))
                exit(1)
            }
            let unavailableError = FolderSyncConnectionError.concurrentMutationSafetyUnavailable.localizedDescription
            guard unavailableError.contains("파일을 안전하게 반영하는 기능을 준비하고 있습니다"),
                  !forbiddenTerms.contains(where: { unavailableError.localizedCaseInsensitiveContains($0) })
            else {
                FileHandle.standardError.write(Data("sync unavailable error copy is not consumer-safe\n".utf8))
                exit(1)
            }
            let implementationErrorText = [
                FolderSyncConnectionError.unsupportedRclone("synthetic").localizedDescription,
                FolderSyncConnectionError.rcloneNotInstalled.localizedDescription,
                FolderSyncConnectionError.unsupportedBisyncLog.localizedDescription
            ].joined(separator: "\n")
            guard !forbiddenTerms.contains(where: {
                implementationErrorText.localizedCaseInsensitiveContains($0)
            }) else {
                FileHandle.standardError.write(Data("sync error copy exposes implementation terminology\n".utf8))
                exit(1)
            }
            let deletionItems = (0..<10).map { index in
                FolderSyncDeletionItem(
                    location: .googleDrive,
                    relativePaths: ["fixture/item-\(index).jpg"],
                    isLivePhoto: false
                )
            }
            var deletionJournal = FolderSyncJournal(
                connectionID: "fixture",
                operationID: "fixture-operation",
                currentAttemptID: "fixture-attempt",
                startedAt: Date(),
                phase: .confirmationRequired,
                items: []
            )
            deletionJournal.pendingDeletionPlan = FolderSyncDeletionPlan(
                items: deletionItems,
                previousCompletedLogicalItemCountLowerBound: 50,
                emptiedNonEmptyDirectories: []
            )
            guard folderSyncConfirmationItemCount(deletionJournal) == 10 else {
                FileHandle.standardError.write(Data("sync deletion confirmation count is not consumer-correct\n".utf8))
                exit(1)
            }
            if let index = arguments.firstIndex(of: "--sync-ui-fixture-result"),
               arguments.indices.contains(index + 1) {
                let resultURL = URL(fileURLWithPath: arguments[index + 1])
                try? "passed\n".write(to: resultURL, atomically: true, encoding: .utf8)
            }
            print("PhotoArchiveKit isolated sync UI fixture rendered required states.")
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

private struct AddComparisonRootSheet: View {
    let request: AddComparisonRootRequest
    let isWorking: Bool
    let statusMessage: String?
    let onCancel: () -> Void
    let onRegisterAndScan: (RootUserPurpose) -> Void

    @State private var purpose: RootUserPurpose = .standard
    @State private var showsAdvancedOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("비교 폴더 추가")
                    .font(.title3.weight(.semibold))
                Text("이 폴더를 비교에 추가합니다.")
                    .font(.callout)
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

            DisclosureGroup("고급 옵션", isExpanded: $showsAdvancedOptions) {
                HStack(spacing: 14) {
                    Text("용도")
                        .foregroundStyle(.secondary)
                    RootPurposePopUpButton(selection: $purpose, isEnabled: !isWorking)
                        .frame(width: 180)
                }
                .padding(.top, 10)
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
                ReviewEqualWidthActionLayout {
                    Button(action: onCancel) {
                        Text("취소")
                            .frame(maxWidth: .infinity)
                    }
                        .modifier(ReviewActionButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .disabled(isWorking)
                    Button {
                        onRegisterAndScan(purpose)
                    } label: {
                        Text("추가하고 비교")
                            .frame(maxWidth: .infinity)
                    }
                    .modifier(ReviewPrimaryActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

private struct ReviewSummaryHeader: View {
    let itemCount: Int
    let selectedRootLabels: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PhotoArchiveKit")
                    .font(.title2.weight(.semibold))
                    .padding(.bottom, 8)

                Text("중복 항목 \(itemCount)개")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !selectedRootLabels.isEmpty {
                    Text(selectedRootLabels.joined(separator: " + "))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("현재 비교에 포함된 폴더")
                }
            }
        }
    }
}

private struct ReviewSidebarItem: View {
    let item: DuplicateReviewPresentationItem
    let selectedCleanupCount: Int
    let isSelected: Bool
    let isKeyboardFocused: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            ReviewSidebarRow(
                item: item,
                selectedCleanupCount: selectedCleanupCount
            )
            .padding(.horizontal, 10)
            .frame(
                maxWidth: .infinity,
                minHeight: ReviewSidebarLayoutMetrics.rowMinimumHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(
            ReviewSidebarItemButtonStyle(
                isSelected: isSelected,
                isHovering: isHovering,
                isKeyboardFocused: isKeyboardFocused
            )
        )
        .padding(.leading, ReviewSidebarLayoutMetrics.rowHorizontalInset)
        .padding(.trailing, ReviewSidebarLayoutMetrics.rowTrailingInset)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ReviewSidebarItemButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isHovering: Bool
    let isKeyboardFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: ReviewSidebarLayoutMetrics.rowCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                if isSelected && isKeyboardFocused {
                    RoundedRectangle(
                        cornerRadius: ReviewSidebarLayoutMetrics.rowCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(ReviewVisualStyle.sidebarKeyboardFocus, lineWidth: 1)
                }
            }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return ReviewVisualStyle.sidebarPressed
        }
        if isSelected {
            return ReviewVisualStyle.sidebarSelection
        }
        if isHovering {
            return ReviewVisualStyle.sidebarHover
        }
        return .clear
    }
}

private struct ReviewSidebarRow: View {
    let item: DuplicateReviewPresentationItem
    let selectedCleanupCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hasCompleteLivePhoto ? "livephoto" : "photo.stack")
                .font(
                    hasCompleteLivePhoto
                        ? .system(size: ReviewThumbnailBadgeMetrics.livePhotoSymbolSize, weight: .semibold)
                        : .body
                )
                .frame(width: 24)
                .foregroundStyle(hasCompleteLivePhoto ? Color.accentColor : Color.secondary)
                .help(hasCompleteLivePhoto ? "완전한 Live Photo" : "동일한 파일")

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(identicalFilePhrase(for: item.allResources))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(duplicateSummaryHelp)
                }
            }

            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if selectedCleanupCount > 0 {
                    Label("\(selectedCleanupCount)", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                        .help("삭제 대상으로 선택한 사본 \(selectedCleanupCount)개")
                }

                Label("\(copyCount)", systemImage: "doc.on.doc")
                    .labelStyle(.titleAndIcon)
                    .help("이 중복 그룹에 존재하는 사본 \(copyCount)개")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
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

    private var hasCompleteLivePhoto: Bool {
        item.copies.contains { $0.isCompleteLivePhotoOccurrence }
    }

    private var duplicateSummaryHelp: String {
        let summary = identicalFilePhrase(for: item.allResources)
        if item.kind == .livePhotoAsset {
            return "\(summary)입니다. Live Photo의 사진·동영상 구성은 오른쪽에서 따로 확인할 수 있습니다."
        }
        return "\(summary)입니다."
    }
}

private struct ReviewDetailView: View {
    let item: DuplicateReviewPresentationItem
    let cleanupCopyIDs: Set<String>
    let onToggleCleanupFromColumn: (DuplicateReviewPresentationCopy) -> Void
    let onToggleCleanupFromButton: (DuplicateReviewPresentationCopy) -> Void
    let canToggleCleanup: (DuplicateReviewPresentationCopy) -> Bool
    let columnToggleHelp: (DuplicateReviewPresentationCopy) -> String
    let cleanupToggleHelp: (DuplicateReviewPresentationCopy) -> String
    let focusedCopyID: String?
    let onFocusCopy: (String) -> Void

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
                VStack(alignment: .leading, spacing: 0) {
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
                        cleanupToggleHelp: cleanupToggleHelp,
                        focusedCopyID: focusedCopyID,
                        onFocusCopy: onFocusCopy
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
        .background(ReviewVisualStyle.detailSurface)
    }

    private var fallbackCopies: [DuplicateReviewPresentationCopy] {
        item.preferredResources.map {
            DuplicateReviewPresentationCopy(id: "fallback-keeper:\($0.id)", isKeeper: true, resources: [$0])
        } + item.candidateResources.map {
            DuplicateReviewPresentationCopy(id: "fallback-candidate:\($0.id)", isKeeper: false, resources: [$0])
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
    let focusedCopyID: String?
    let onFocusCopy: (String) -> Void

    @State private var hoveredCopyID: String?
    @State private var showsAdvancedInformation = false

    var body: some View {
        let rows = comparisonRows(for: copies)
        let advancedRows = advancedComparisonRows(for: copies)
        let baseLastRowID = rows.last?.id
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
                        recommendationText: copy.isKeeper
                            ? keeperRecommendationText(item.rationale, copy: copy)
                            : nil,
                        columnWidth: columnWidth,
                        isMarkedForCleanup: cleanupCopyIDs.contains(copy.id),
                        onToggleCleanupFromColumn: { onToggleCleanupFromColumn(copy) },
                        onToggleCleanupFromButton: { onToggleCleanupFromButton(copy) },
                        canToggleCleanup: canToggleCleanup(copy),
                        columnToggleHelp: columnToggleHelp(copy),
                        cleanupToggleHelp: cleanupToggleHelp(copy)
                    )
                    .background(
                        ReviewCopyFocusRevealer(isFocused: focusedCopyID == copy.id)
                            .allowsHitTesting(false)
                    )
                    .simultaneousGesture(
                        TapGesture().onEnded { onFocusCopy(copy.id) }
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

            metadataRows(rows, lastRowID: baseLastRowID, tracksColumnBottom: true)

            if !showsAdvancedInformation {
                advancedDisclosureButton
                    .gridCellColumns(copies.count + 1)
            }

            if showsAdvancedInformation {
                metadataRows(advancedRows, lastRowID: nil, tracksColumnBottom: false)

                Button {
                    setAdvancedInformationVisible(false)
                } label: {
                    Label("고급 정보 숨기기", systemImage: "chevron.up")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .padding(.bottom, 2)
                .gridCellColumns(copies.count + 1)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .padding(16)
        .background(ReviewVisualStyle.comparisonSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                        let isKeyboardFocused = focusedCopyID == copy.id

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
                            .overlay {
                                if isKeyboardFocused {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(0.72), lineWidth: 2)
                                }
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

    private var advancedDisclosureButton: some View {
        Button {
            setAdvancedInformationVisible(true)
        } label: {
            Label("고급 정보 보기", systemImage: "chevron.down")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 10)
    }

    private func setAdvancedInformationVisible(_ visible: Bool) {
        // A large comparison grid is expensive to animate as one changing
        // layout. Keep the existing viewport stable and let the advanced rows
        // appear/disappear immediately below the disclosure control.
        showsAdvancedInformation = visible
    }

    @ViewBuilder
    private func metadataRows(
        _ rows: [ComparisonRowSpec],
        lastRowID: String?,
        tracksColumnBottom: Bool
    ) -> some View {
        ForEach(rows) { row in
            if let sectionTitle = row.sectionTitle {
                Text(sectionTitle)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    .gridCellColumns(copies.count + 1)
            }

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
                    .simultaneousGesture(
                        TapGesture().onEnded { onFocusCopy(copy.id) }
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
                        tracksColumnBottom && row.id == lastRowID
                            ? [copy.id: ReviewColumnBounds(top: nil, bottom: anchor)]
                            : [:]
                    }
                }
            }

            if row.id != rows.last?.id {
                Divider()
                    .gridCellColumns(copies.count + 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct ReviewCopyFocusRevealer: NSViewRepresentable {
    let isFocused: Bool

    func makeNSView(context: Context) -> ReviewCopyFocusRevealView {
        let view = ReviewCopyFocusRevealView()
        view.isFocused = isFocused
        return view
    }

    func updateNSView(_ nsView: ReviewCopyFocusRevealView, context: Context) {
        nsView.isFocused = isFocused
    }
}

private final class ReviewCopyFocusRevealView: NSView {
    var isFocused = false {
        didSet {
            guard isFocused, !oldValue else { return }
            scheduleReveal()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isFocused { scheduleReveal() }
    }

    private func scheduleReveal() {
        DispatchQueue.main.async { [weak self] in
            self?.revealHorizontally()
        }
    }

    private func revealHorizontally() {
        guard isFocused else { return }
        var ancestor = superview
        var scrollView: NSScrollView?
        while let current = ancestor {
            if let match = current as? NSScrollView {
                scrollView = match
                break
            }
            ancestor = current.superview
        }
        guard let scrollView,
              let documentView = scrollView.documentView else { return }

        let target = convert(bounds, to: documentView)
        let visible = scrollView.contentView.documentVisibleRect
        let margin: CGFloat = 12
        var targetX = visible.minX
        if target.minX < visible.minX + margin {
            targetX = target.minX - margin
        } else if target.maxX > visible.maxX - margin {
            targetX = target.maxX - visible.width + margin
        } else {
            return
        }

        let maximumX = max(0, documentView.frame.width - visible.width)
        targetX = min(max(0, targetX), maximumX)
        scrollView.contentView.scroll(
            to: NSPoint(x: targetX, y: scrollView.contentView.bounds.origin.y)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
                    .font(.caption)
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
            .font(.system(size: ReviewThumbnailBadgeMetrics.livePhotoSymbolSize, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(
                width: ReviewThumbnailBadgeMetrics.overlayFrame,
                height: ReviewThumbnailBadgeMetrics.overlayFrame
            )
            .shadow(color: .black.opacity(0.65), radius: 1.2, y: 0.5)
            .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
            .help("Live Photo")
    }

    private var cleanupThumbnailBadge: some View {
        Image(systemName: "trash.fill")
            .font(.system(size: ReviewThumbnailBadgeMetrics.cleanupSymbolSize, weight: .bold))
            .foregroundStyle(.white)
            .frame(
                width: ReviewThumbnailBadgeMetrics.overlayFrame,
                height: ReviewThumbnailBadgeMetrics.overlayFrame
            )
            .background(.red, in: Circle())
            .shadow(radius: 1.5, y: 0.5)
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
                    Text(formatBytes(resource.fileSystemFacts.currentByteSize ?? resource.byteSize))
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
        Button(action: onToggleCleanupFromButton) {
            Label(
                isMarkedForCleanup ? "해제" : "선택",
                systemImage: isMarkedForCleanup ? "xmark.circle.fill" : "trash"
            )
        }
            .modifier(ReviewDestructiveActionButtonStyle(isActive: isMarkedForCleanup))
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
            Text(row.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if let differenceLabel = row.differenceLabel {
                Label(differenceLabel, systemImage: "arrow.left.arrow.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
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
            row.isDifferent ? Color.secondary.opacity(0.045) : Color.clear,
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
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.10), in: Capsule())
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
        comparisonRow("absolute-path", "전체 경로", copies: copies) {
            componentText($0) { $0.absolutePath }
        },
        comparisonRow("media-kind", "미디어 종류", copies: copies) {
            componentText($0) { mediaKindLabel($0.mediaKind) }
        },
        comparisonRow(
            "capture-primary",
            "촬영 시각",
            copies: copies,
            date: { consumerOriginalCaptureTime($0.primaryResource?.captureTime)?.instant }
        ) { copy in
            consumerOriginalCaptureLabel(copy.primaryResource?.captureTime)
        },
        livePhotoTimeComparisonRow("date-added", "Finder에 추가된 시각", copies: copies, date: { $0.primaryResource?.addedAt }) {
            formatDate($0.addedAt)
        },
        livePhotoTimeComparisonRow("creation-date", "파일 생성 시각", copies: copies, date: { $0.primaryResource?.fileSystemFacts.creationDate }) {
            formatDate($0.fileSystemFacts.creationDate)
        },
        livePhotoTimeComparisonRow("filesystem-modified", "파일 수정 시각", copies: copies, date: { $0.primaryResource?.fileSystemFacts.modificationDate }) {
            formatDate($0.fileSystemFacts.modificationDate)
        },
        comparisonRow("current-total-bytes", "전체 크기", copies: copies, monospaced: true) {
            componentText($0) { resource in
                formatBytes(resource.fileSystemFacts.currentByteSize ?? resource.byteSize)
            }
        }
    ]
}

private func advancedComparisonRows(
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
        comparisonRow("original-name", "최초 파일명", copies: copies, sectionTitle: "이름과 형식") {
            componentText($0) { $0.details?.originalFileName ?? "—" }
        },
        comparisonRow("extension", "확장자", copies: copies) {
            componentText($0) { $0.fileExtension.isEmpty ? "—" : $0.fileExtension }
        },
        comparisonRow("role", "파일 역할", copies: copies) {
            componentText($0) { resourceRoleLabel($0.role) }
        },
        comparisonRow("file-type", "파일 종류", copies: copies) {
            componentText($0) { $0.fileSystemFacts.fileType ?? "—" }
        },
        comparisonRow("type-identifier", "파일 형식 식별자", copies: copies, monospaced: true) {
            componentText($0) { $0.fileSystemFacts.typeIdentifier ?? "—" }
        },

        livePhotoTimeComparisonRow(
            "capture-evidence-agreement",
            "촬영 시각 근거 일치 여부",
            copies: copies,
            sectionTitle: "촬영 메타데이터"
        ) { resource in
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

        livePhotoTimeComparisonRow(
            "catalog-modified",
            "이전에 기록된 수정 시각",
            copies: copies,
            sectionTitle: "PhotoArchiveKit 기록",
            date: { $0.primaryResource?.details?.catalogModifiedAt }
        ) {
            formatDate($0.details?.catalogModifiedAt)
        },
        livePhotoTimeComparisonRow("first-seen", "처음 확인한 시각", copies: copies, date: { $0.primaryResource?.details?.firstSeenAt }) {
            formatDate($0.details?.firstSeenAt)
        },
        livePhotoTimeComparisonRow("last-seen", "최근 확인한 시각", copies: copies, date: { $0.primaryResource?.details?.lastSeenAt }) {
            formatDate($0.details?.lastSeenAt)
        },
        comparisonRow("location-count", "위치 변경 기록 수", copies: copies, monospaced: true) {
            componentText($0) { $0.details.map { String($0.locationHistoryCount) } ?? "—" }
        },

        comparisonRow("root-label", "위치", copies: copies, sectionTitle: "위치") {
            componentText($0) { $0.rootLabel }
        },
        comparisonRow("relative-path", "상대 경로", copies: copies) {
            componentText($0) { $0.relativePath }
        },
        comparisonRow("usage-role", "용도", copies: copies) {
            componentText($0) { rootUsageRoleLabel($0.rootUsageRole) }
        },
        comparisonRow("stable-marker", "위치 확인 키", copies: copies, monospaced: true) {
            componentText($0) { $0.stableMarkerKey ?? "—" }
        },

        comparisonRow("catalog-total-bytes", "기록된 전체 크기", copies: copies, sectionTitle: "크기와 저장 공간", monospaced: true) {
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

        comparisonRow("freshness", "현재 파일 상태", copies: copies, sectionTitle: "무결성과 Live Photo") {
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

        comparisonRow("exists", "현재 파일 존재", copies: copies, sectionTitle: "파일 시스템") {
            componentText($0) { $0.fileSystemFacts.exists ? "예" : "아니오" }
        },
        comparisonRow("catalog-fs-id", "기록된 파일 시스템 식별자", copies: copies, monospaced: true) {
            componentText($0) { $0.details?.catalogFileSystemIdentifier ?? "—" }
        },
        comparisonRow("current-fs-id", "현재 파일 시스템 식별자", copies: copies, monospaced: true) {
            componentText($0) { $0.fileSystemFacts.fileSystemIdentifier ?? "—" }
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

        comparisonRow("metadata-probe", "메타데이터 읽기 상태", copies: copies, sectionTitle: "내부 기록") {
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
    rootUserPurposeLabel(role.userPurpose)
}

private func rootUserPurposeLabel(_ purpose: RootUserPurpose) -> String {
    switch purpose {
    case .standard: return "기본"
    case .archive: return "장기 보관"
    case .readOnly: return "읽기 전용"
    }
}

private func rootUserPurposeDescription(_ purpose: RootUserPurpose) -> String {
    switch purpose {
    case .standard:
        return "일반적인 사진 폴더입니다. 중복 사진을 비교하고 정리할 수 있습니다."
    case .archive:
        return "오래 보관할 사진을 둡니다. 중복 사진을 정리할 때 이 폴더의 사본을 우선 남깁니다."
    case .readOnly:
        return "비교에는 사용하지만 이 폴더의 파일은 이동하거나 삭제하지 않습니다."
    }
}

private struct RootPurposePopUpButton: NSViewRepresentable {
    @Binding var selection: RootUserPurpose
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setAccessibilityLabel("용도")
        configure(button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        configure(button)
    }

    private func configure(_ button: NSPopUpButton) {
        button.removeAllItems()
        for purpose in RootUserPurpose.allCases {
            button.addItem(withTitle: rootUserPurposeLabel(purpose))
            guard let item = button.lastItem else { continue }
            item.representedObject = purpose.rawValue
            item.toolTip = rootUserPurposeDescription(purpose)
        }
        if let index = RootUserPurpose.allCases.firstIndex(of: selection) {
            button.selectItem(at: index)
        }
        button.isEnabled = isEnabled
        button.toolTip = rootUserPurposeDescription(selection)
    }

    final class Coordinator: NSObject {
        var parent: RootPurposePopUpButton

        init(parent: RootPurposePopUpButton) {
            self.parent = parent
        }

        @MainActor @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let rawValue = sender.selectedItem?.representedObject as? String,
                  let purpose = RootUserPurpose(rawValue: rawValue)
            else { return }
            parent.selection = purpose
        }
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    "\(bytes.formatted(.number.grouping(.automatic))) bytes"
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

private func consumerOriginalCaptureTime(_ captureTime: CaptureTime?) -> CaptureTime? {
    guard let captureTime else { return nil }
    switch captureTime.source {
    case .exifDateTimeOriginal, .quickTimeCreationDate:
        return captureTime
    case .googleTakeoutPhotoTakenTime, .fileCreationDate, .unknown:
        return nil
    }
}

private func consumerOriginalCaptureLabel(_ captureTime: CaptureTime?) -> String {
    guard let captureTime = consumerOriginalCaptureTime(captureTime) else { return "—" }
    let timestamp = captureTime.instant.map(formatDate)
        ?? captureTime.localTimestamp
        ?? "—"
    let offset = captureTime.utcOffset.map { " · \($0)" } ?? ""
    return "\(timestamp)\(offset)"
}

private func xattrSummary(_ attributes: [DuplicateReviewExtendedAttribute]) -> String {
    guard !attributes.isEmpty else { return "없음" }
    return attributes.map { attribute in
        let digest = attribute.valueSHA256Hex.map { " · value SHA-256 \($0)" } ?? ""
        return "\(attribute.name) (\(formatBytes(Int64(attribute.byteCount))))\(digest)"
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private enum ReviewThumbnailBadgeMetrics {
    // These SF Symbols have different optical footprints. A slightly larger
    // Live Photo symbol reads as the same visual weight as the filled trash.
    static let livePhotoSymbolSize: CGFloat = 16
    static let cleanupSymbolSize: CGFloat = 13
    static let overlayFrame: CGFloat = 30
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
    case .video: return "동영상"
    case .sidecar: return "보조 파일"
    }
}

private func resourceRoleLabel(_ role: ResourceRole) -> String {
    switch role {
    case .photo: return "Live Photo 사진"
    case .pairedVideo: return "Live Photo 동영상"
    case .standaloneImage: return "일반 사진"
    case .standaloneVideo: return "일반 동영상"
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

private func keeperRecommendationText(
    _ rationale: DuplicateReviewPresentationRationale,
    copy: DuplicateReviewPresentationCopy
) -> String {
    switch rationale {
    case .protectedOrPreferredRoot: return "더 안전하게 보관되는 위치에 있습니다"
    case .cleanerFilename: return "복사본 표시가 없는 파일명입니다"
    case .recognizableFilename: return "원본에 가까운 파일명입니다"
    case .earlierDateAdded: return "Mac에 더 먼저 추가된 사본입니다"
    case .matchingParentFolder: return "폴더 구성이 더 자연스럽습니다"
    case .strongerCaptureEvidence: return "촬영 시각 정보가 더 확실합니다"
    case .shallowerPath: return "더 찾기 쉬운 위치에 있습니다"
    case .deterministicTieBreak:
        return "\(identicalFilePhrase(for: copy.resources))입니다."
    case .completeLivePhotoOccurrence: return "완전한 Live Photo 조합을 보존할 수 있습니다"
    case .clearerLivePhotoStructure: return "Live Photo 구성 관계가 더 명확한 사본입니다"
    case .sourceSemantics: return "출처 정보가 더 잘 보존되어 있습니다"
    }
}

private func identicalFilePhrase(
    for resources: [DuplicateReviewPresentationResource]
) -> String {
    let hasImage = resources.contains { $0.mediaKind == .image }
    let hasVideo = resources.contains { $0.mediaKind == .video }
    let hasSidecar = resources.contains { $0.mediaKind == .sidecar }

    switch (hasImage, hasVideo, hasSidecar) {
    case (true, false, false): return "동일한 사진 파일"
    case (false, true, false): return "동일한 동영상 파일"
    case (true, true, false): return "동일한 사진·동영상 파일 조합"
    default: return "동일한 파일"
    }
}
