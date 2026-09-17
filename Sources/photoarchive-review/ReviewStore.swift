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

func folderSyncConfirmationItemCount(_ journal: FolderSyncJournal) -> Int {
    let confirmationItemCount = journal.items.count(where: {
        $0.state == .confirmationRequired
    })
    return max(
        confirmationItemCount,
        journal.pendingDeletionPlan?.logicalItemCount ?? 0
    )
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
    @Published private(set) var syncConnections: [FolderSyncConnection] = []
    @Published private(set) var syncDriveRemotes: [RcloneDriveRemote] = []
    @Published private(set) var isLoadingSyncRemotes = false
    @Published private(set) var isSyncing = false
    @Published private(set) var syncProgress: FolderSyncProgress?
    @Published var syncErrorMessage: String?
    @Published private(set) var syncPendingDeletionPlans: [String: FolderSyncDeletionPlan] = [:]
    @Published private(set) var syncConfirmationItemCounts: [String: Int] = [:]
    @Published private(set) var syncConflictItemsByConnection: [String: [FolderSyncConflictItem]] = [:]
    @Published private(set) var syncRecoveryItemsByConnection: [String: [FolderSyncRecoveryItem]] = [:]
    @Published private(set) var isLoadingSyncConflicts = false
    @Published private(set) var isResolvingSyncConflict = false
    @Published private(set) var isLoadingSyncRecovery = false
    @Published private(set) var isRestoringSyncRecovery = false
    @Published private(set) var isCleaningSyncRecovery = false
    private var hasLoadedRootSelection = false
    private var completedScanRootIDs = Set<String>()
    private var reloadState = ReviewReloadApplicationGate()
    private var activeScanGeneration = ReviewGenerationGate()
    private let syncService = RcloneBisyncService()

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
        recommendedCleanupSelectionIsApplied ? "추천 모두 해제" : "추천 모두 선택"
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
        selectedRootsNeedInitialScan(
            selected: selectedRootIDs,
            completed: completedScanRootIDs
        )
    }

    var selectedRootsNeedCurrentComparison: Bool {
        reviewSelectionNeedsCurrentComparison(
            selected: selectedRootIDs,
            completed: completedScanRootIDs,
            snapshot: currentSnapshotRootIDs
        )
    }

    var selectedItem: DuplicateReviewPresentationItem? {
        guard let selection else { return visibleItems.first }
        return visibleItems.first(where: { $0.id == selection }) ?? visibleItems.first
    }

    var selectedIndex: Int? {
        guard let item = selectedItem else { return nil }
        return visibleItems.firstIndex(where: { $0.id == item.id })
    }

    var hasFilesystemOperationInProgress: Bool {
        isScanning || isSyncing || isPreparingCleanup || isApplyingCleanup
            || isResolvingSyncConflict || isRestoringSyncRecovery || isCleaningSyncRecovery
    }

    func syncConnection(for rootID: String) -> FolderSyncConnection? {
        syncConnections.first(where: { $0.rootID == rootID })
    }

    func reload() {
        guard !isScanning, !isSyncing else { return }
        let generation = reloadState.begin()
        isLoading = reloadState.isLoading
        errorMessage = nil
        statusMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try Self.loadReviewState()
                }.value
                guard self.reloadState.completeIfCurrent(generation) else { return }
                self.isLoading = self.reloadState.isLoading
                self.registeredRoots = loaded.registeredRoots
                self.completedScanRootIDs = loaded.completedScanRootIDs
                self.cleanupDestinationSetting = loaded.cleanupDestinationSetting
                self.syncConnections = loaded.syncConnections
                self.refreshSyncJournalState()
                self.syncErrorMessage = loaded.syncLoadErrorMessage
                if let next = loaded.presentation {
                    self.installPresentation(next, selectAllScopeRoots: !self.hasLoadedRootSelection)
                } else {
                    self.presentation = nil
                    self.selection = nil
                    self.resetReviewChoicesForRootChange()
                }
                self.ensureUsableRootSelection()
            } catch {
                guard self.reloadState.completeIfCurrent(generation) else { return }
                self.isLoading = self.reloadState.isLoading
                self.presentation = nil
                self.selection = nil
                self.resetReviewChoicesForRootChange()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func invalidatePendingReload() -> Bool {
        let interruptedReload = reloadState.invalidate()
        isLoading = reloadState.isLoading
        return interruptedReload
    }

    private func restartInterruptedReload(_ interruptedReload: Bool) {
        if interruptedReload {
            reload()
        }
    }

    func toggleRoot(_ rootID: String) {
        guard !isScanning, !isSyncing else { return }
        statusMessage = nil
        if selectedRootIDs.contains(rootID) {
            selectedRootIDs.remove(rootID)
        } else {
            if let root = registeredRoots.first(where: { $0.rootID == rootID }),
               root.state != .active {
                let interruptedReload = invalidatePendingReload()
                do {
                    _ = try RootRegistry.setState(target: rootID, state: .active)
                    registeredRoots = try RootRegistry.list()
                    restartInterruptedReload(interruptedReload)
                } catch {
                    restartInterruptedReload(interruptedReload)
                    statusMessage = "폴더를 비교 대상으로 활성화하지 못했습니다: \(error.localizedDescription)"
                    return
                }
            }
            selectedRootIDs.insert(rootID)
        }
        resetReviewChoicesForRootChange()
    }

    func setRootUserPurpose(_ rootID: String, purpose: RootUserPurpose) {
        guard !isScanning, !isSyncing else { return }
        if purpose == .readOnly, syncConnection(for: rootID) != nil {
            statusMessage = "동기화가 연결된 폴더는 먼저 동기화 연결을 정리해야 읽기 전용으로 바꿀 수 있습니다."
            return
        }
        let interruptedReload = invalidatePendingReload()
        do {
            _ = try RootRegistry.setUserPurpose(target: rootID, purpose: purpose)
            reload()
        } catch {
            restartInterruptedReload(interruptedReload)
            statusMessage = "폴더 용도를 바꾸지 못했습니다: \(error.localizedDescription)"
        }
    }

    func unregisterRoot(_ rootID: String) {
        guard !isScanning, !isSyncing else { return }
        if syncConnection(for: rootID) != nil {
            statusMessage = "동기화가 연결된 폴더는 현재 등록 해제할 수 없습니다."
            return
        }
        let interruptedReload = invalidatePendingReload()
        do {
            _ = try RootRegistry.remove(target: rootID)
            registeredRoots = try RootRegistry.list()
            selectedRootIDs.remove(rootID)
            ensureUsableRootSelection()
            resetReviewChoicesForRootChange()
            statusMessage = nil
            restartInterruptedReload(interruptedReload)
        } catch {
            restartInterruptedReload(interruptedReload)
            statusMessage = "폴더 등록을 해제하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func reorderRegisteredRoots(_ rootIDs: [String]) {
        guard !isScanning, !isSyncing else { return }
        let interruptedReload = invalidatePendingReload()
        do {
            registeredRoots = try RootRegistry.setDisplayOrder(rootIDs: rootIDs)
            statusMessage = nil
            restartInterruptedReload(interruptedReload)
        } catch {
            restartInterruptedReload(interruptedReload)
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
        guard !isScanning, !isSyncing else { return false }
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

        invalidatePendingReload()
        let scanGeneration = activeScanGeneration.begin()
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
                guard let self,
                      self.isScanning,
                      self.activeScanGeneration.accepts(scanGeneration)
                else { return }
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
            guard activeScanGeneration.accepts(scanGeneration) else { return false }
            registeredRoots = try RootRegistry.list()
            completedScanRootIDs.formUnion(next.scopeRoots.map(\.id))
            installPresentation(next, selectAllScopeRoots: true)
            statusMessage = "비교가 완료되었습니다 · 중복 항목 \(next.items.count)개"
            scanProgress = nil
            isScanning = false
            return true
        } catch {
            guard activeScanGeneration.accepts(scanGeneration) else { return false }
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
        guard !isScanning, !isSyncing else { return false }
        var interruptedReload = invalidatePendingReload()
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try RootRegistry.addComparisonRoot(url: url, purpose: purpose)
            }.value
            interruptedReload = invalidatePendingReload() || interruptedReload
            registeredRoots = try RootRegistry.list()
            if result.wasAlreadyRegistered {
                if result.root.state == .active,
                   !selectedRootIDs.contains(result.root.rootID) {
                    selectedRootIDs.insert(result.root.rootID)
                    resetReviewChoicesForRootChange()
                }
                restartInterruptedReload(interruptedReload)
                statusMessage = "이미 등록된 폴더입니다."
                return true
            }
            selectedRootIDs.insert(result.root.rootID)
            statusMessage = nil
        } catch {
            interruptedReload = invalidatePendingReload() || interruptedReload
            restartInterruptedReload(interruptedReload)
            statusMessage = "폴더를 추가하지 못했습니다: \(error.localizedDescription)"
            return false
        }
        let scanned = await scanSelectedRoots()
        if !scanned {
            let scanStatusMessage = statusMessage
            restartInterruptedReload(interruptedReload)
            statusMessage = scanStatusMessage
        }
        return scanned
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

    func loadSyncDriveRemotes() async {
        guard !isLoadingSyncRemotes, !isSyncing else { return }
        isLoadingSyncRemotes = true
        syncErrorMessage = nil
        let service = syncService
        do {
            let remotes = try await Task.detached(priority: .userInitiated) {
                try service.driveRemotes()
            }.value
            syncDriveRemotes = remotes.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            if syncDriveRemotes.isEmpty {
                syncErrorMessage = "연결된 Google Drive를 찾지 못했습니다. Google Drive 연결 설정을 확인한 뒤 다시 시도해 주세요."
            }
        } catch {
            syncDriveRemotes = []
            syncErrorMessage = error.localizedDescription
        }
        isLoadingSyncRemotes = false
    }

    @discardableResult
    func createSyncConnection(
        rootID: String,
        remoteName: String,
        remoteDisplayName: String?,
        remotePath: String
    ) -> FolderSyncConnection? {
        guard !hasFilesystemOperationInProgress else { return nil }
        syncErrorMessage = nil
        do {
            let connection = try FolderSyncConnectionManager.create(
                rootID: rootID,
                remoteName: remoteName,
                remoteDisplayName: remoteDisplayName,
                remotePath: remotePath
            )
            syncConnections.removeAll { $0.id == connection.id || $0.rootID == rootID }
            syncConnections.append(connection)
            refreshSyncJournalState()
            return connection
        } catch {
            syncErrorMessage = error.localizedDescription
            return nil
        }
    }

    func runSync(
        connectionID: String,
        confirmInitialSync: Bool,
        approvedDeletionPlanID: String? = nil
    ) async {
        guard !hasFilesystemOperationInProgress,
              let connection = syncConnections.first(where: { $0.id == connectionID })
        else { return }

        invalidatePendingReload()
        isSyncing = true
        syncProgress = FolderSyncProgress(stage: .checking)
        syncErrorMessage = nil
        statusMessage = "폴더를 동기화하는 중입니다…"
        let service = syncService
        let progressHandler: FolderSyncProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.isSyncing else { return }
                self.syncProgress = progress
            }
        }

        do {
            let report = try await Task.detached(priority: .userInitiated) {
                try await service.synchronize(
                    connection: connection,
                    confirmInitialSync: confirmInitialSync,
                    approvedDeletionPlanID: approvedDeletionPlanID,
                    progressHandler: progressHandler
                )
            }.value
            syncConnections.removeAll { $0.id == report.connection.id }
            syncConnections.append(report.connection)
            refreshSyncJournalState()
            isSyncing = false
            syncProgress = nil

            if currentSnapshotRootIDs.contains(report.connection.rootID) {
                presentation = nil
                selection = nil
                resetReviewChoicesForRootChange()
            }
            statusMessage = report.conflictPreserved
                ? "동기화가 완료되었습니다. 충돌한 파일은 양쪽 사본을 보존했습니다."
                : "동기화가 완료되었습니다."
        } catch is CancellationError {
            refreshSyncConnectionsFromDisk()
            isSyncing = false
            syncProgress = nil
            statusMessage = "동기화를 취소했습니다."
        } catch {
            refreshSyncConnectionsFromDisk()
            isSyncing = false
            syncProgress = nil
            syncErrorMessage = error.localizedDescription
            statusMessage = "동기화를 완료하지 못했습니다."
        }
    }

    func removeSyncConnection(connectionID: String) {
        guard !hasFilesystemOperationInProgress else { return }
        syncErrorMessage = nil
        do {
            try FolderSyncConnectionStore.remove(connectionID: connectionID)
            syncConnections.removeAll { $0.id == connectionID }
            syncPendingDeletionPlans[connectionID] = nil
            syncConfirmationItemCounts[connectionID] = nil
            syncConflictItemsByConnection[connectionID] = nil
            syncRecoveryItemsByConnection[connectionID] = nil
            statusMessage = "동기화 연결 정보를 제거했습니다. 폴더와 복구 자료는 그대로 유지됩니다."
        } catch {
            syncErrorMessage = error.localizedDescription
        }
    }

    func cancelSync() {
        guard isSyncing else { return }
        syncService.cancelCurrentRun()
    }

    private func refreshSyncConnectionsFromDisk() {
        do {
            syncConnections = try FolderSyncConnectionStore.loadRecoveringInterrupted()
            refreshSyncJournalState()
        } catch {
            syncErrorMessage = error.localizedDescription
        }
    }

    private func refreshSyncJournalState() {
        var plans: [String: FolderSyncDeletionPlan] = [:]
        var counts: [String: Int] = [:]
        for connection in syncConnections {
            guard let journal = try? FolderSyncJournalStore.load(connection: connection) else {
                counts[connection.id] = 0
                continue
            }
            if let plan = journal.pendingDeletionPlan {
                plans[connection.id] = plan
            }
            counts[connection.id] = folderSyncConfirmationItemCount(journal)
        }
        syncPendingDeletionPlans = plans
        syncConfirmationItemCounts = counts
    }

    func syncConfirmationItemCount(connectionID: String) -> Int {
        syncConfirmationItemCounts[connectionID] ?? 0
    }

    func syncConflictItems(connectionID: String) -> [FolderSyncConflictItem] {
        syncConflictItemsByConnection[connectionID] ?? []
    }

    func loadSyncConflictItems(connectionID: String) async {
        guard !isLoadingSyncConflicts,
              let connection = syncConnections.first(where: { $0.id == connectionID })
        else { return }
        isLoadingSyncConflicts = true
        defer { isLoadingSyncConflicts = false }
        let service = syncService
        do {
            let items = try await Task.detached(priority: .userInitiated) {
                try service.conflictItems(connection: connection)
            }.value
            syncConflictItemsByConnection[connectionID] = items
        } catch {
            syncErrorMessage = error.localizedDescription
        }
    }

    func resolveSyncConflict(
        connectionID: String,
        itemID: String,
        choice: FolderSyncConflictChoice,
        expectedFingerprint: String
    ) async {
        guard !hasFilesystemOperationInProgress,
              let connection = syncConnections.first(where: { $0.id == connectionID })
        else { return }
        guard RcloneBisyncService.productionApplyAvailable else {
            syncErrorMessage = "파일을 안전하게 반영하는 기능을 준비하고 있습니다. 현재는 선택한 내용을 적용할 수 없습니다."
            return
        }

        isResolvingSyncConflict = true
        syncErrorMessage = nil
        defer { isResolvingSyncConflict = false }
        let service = syncService
        do {
            try await Task.detached(priority: .userInitiated) {
                try await service.resolveConflict(
                    connection: connection,
                    itemID: itemID,
                    choice: choice,
                    expectedFingerprint: expectedFingerprint
                )
            }.value
            refreshSyncConnectionsFromDisk()
            await loadSyncConflictItems(connectionID: connectionID)
            await loadSyncRecoveryItems(connectionID: connectionID)
            statusMessage = "선택한 내용을 반영했습니다."
        } catch {
            refreshSyncConnectionsFromDisk()
            syncErrorMessage = error.localizedDescription
            statusMessage = "선택한 내용을 반영하지 못했습니다. 다시 확인해 주세요."
            await loadSyncConflictItems(connectionID: connectionID)
        }
    }

    func syncRecoverySummary(connectionID: String) -> FolderSyncRecoverySummary? {
        guard let items = syncRecoveryItemsByConnection[connectionID] else { return nil }
        return FolderSyncRecoverySummary(items: items)
    }

    func syncRecoveryItems(connectionID: String) -> [FolderSyncRecoveryItem] {
        syncRecoveryItemsByConnection[connectionID] ?? []
    }

    func loadSyncRecoveryItems(connectionID: String) async {
        guard !isLoadingSyncRecovery,
              let connection = syncConnections.first(where: { $0.id == connectionID })
        else { return }
        isLoadingSyncRecovery = true
        defer { isLoadingSyncRecovery = false }
        let service = syncService
        do {
            let items = try await Task.detached(priority: .userInitiated) {
                try service.recoveryItems(connection: connection)
            }.value
            syncRecoveryItemsByConnection[connectionID] = items
        } catch {
            // A disconnected Drive must not erase the already-known local
            // state or turn recovery inventory into a sync mutation.
            syncErrorMessage = error.localizedDescription
        }
    }

    func restoreSyncRecoveryItem(
        connectionID: String,
        itemID: String
    ) async {
        guard !hasFilesystemOperationInProgress,
              let connection = syncConnections.first(where: { $0.id == connectionID }),
              let item = syncRecoveryItemsByConnection[connectionID]?.first(where: { $0.id == itemID })
        else { return }
        isRestoringSyncRecovery = true
        syncErrorMessage = nil
        defer { isRestoringSyncRecovery = false }
        let service = syncService
        do {
            try await Task.detached(priority: .userInitiated) {
                try service.restoreRecoveryItem(item, connection: connection)
            }.value
            statusMessage = "복구 사본을 원래 위치에 복원했습니다. 복구 사본은 그대로 보관합니다."
            await loadSyncRecoveryItems(connectionID: connectionID)
        } catch {
            syncErrorMessage = error.localizedDescription
        }
    }

    func discardSyncRecoveryItem(
        connectionID: String,
        itemID: String
    ) async {
        guard !hasFilesystemOperationInProgress,
              let connection = syncConnections.first(where: { $0.id == connectionID }),
              let item = syncRecoveryItemsByConnection[connectionID]?.first(where: { $0.id == itemID })
        else { return }
        isCleaningSyncRecovery = true
        syncErrorMessage = nil
        defer { isCleaningSyncRecovery = false }
        let service = syncService
        do {
            try await Task.detached(priority: .userInitiated) {
                try service.discardRecoveryItem(item, connection: connection)
            }.value
            statusMessage = "복구 사본을 휴지통으로 옮겼습니다. 원래 위치의 파일은 변경하지 않았습니다."
            await loadSyncRecoveryItems(connectionID: connectionID)
        } catch {
            syncErrorMessage = error.localizedDescription
        }
    }

    func isMarkedForCleanup(
        _ copy: DuplicateReviewPresentationCopy,
        item: DuplicateReviewPresentationItem
    ) -> Bool {
        cleanupCopyIDsByItem[item.id, default: []].contains(copy.id)
    }

    func toggleRecommendedCleanupSelection() {
        guard !isScanning && !isSyncing && !isPreparingCleanup && !isApplyingCleanup else { return }
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
        guard !isSyncing && !isPreparingCleanup && !isApplyingCleanup else { return }
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
        guard !isSyncing, !isApplyingCleanup, let preparedCleanup else { return }
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
        hasLoadedRootSelection = true
        preparedCleanup = nil
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

    nonisolated private static func loadReviewState() throws -> (
        registeredRoots: [RegisteredRootReport],
        completedScanRootIDs: Set<String>,
        cleanupDestinationSetting: DuplicateCleanupDestinationSetting,
        syncConnections: [FolderSyncConnection],
        syncLoadErrorMessage: String?,
        presentation: DuplicateReviewPresentation?
    ) {
        let registeredRoots = try RootRegistry.list()
        let scanner = try ArchiveScanner()
        let completedScanRootIDs = try scanner.completedScanRootIDs()
        let cleanupDestinationSetting = (try? PhotoArchiveSettingsStore.load())?.duplicateCleanupDestination
            ?? .systemTrash
        let syncConnections: [FolderSyncConnection]
        let syncLoadErrorMessage: String?
        do {
            syncConnections = try FolderSyncConnectionStore.loadRecoveringInterrupted()
            syncLoadErrorMessage = nil
        } catch {
            syncConnections = []
            syncLoadErrorMessage = "동기화 상태를 읽지 못했습니다: \(error.localizedDescription)"
        }
        let presentation: DuplicateReviewPresentation?
        do {
            presentation = try DuplicateReviewPresentationBuilder.latest()
        } catch DuplicateReviewPresentationError.noReusableSnapshot {
            presentation = nil
        }
        return (
            registeredRoots,
            completedScanRootIDs,
            cleanupDestinationSetting,
            syncConnections,
            syncLoadErrorMessage,
            presentation
        )
    }
}
