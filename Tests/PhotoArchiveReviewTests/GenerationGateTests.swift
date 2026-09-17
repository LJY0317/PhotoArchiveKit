import Foundation

private actor AsyncLatch {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@main
struct GenerationGateTests {
    private enum DelayedFailure: Error {
        case stale
    }

    static func main() async {
        var reloads = ReviewGenerationGate()
        let firstReload = reloads.begin()
        let secondReload = reloads.begin()
        precondition(!reloads.accepts(firstReload), "older reload result must be rejected")
        precondition(reloads.accepts(secondReload), "latest reload result must be accepted")

        var scans = ReviewGenerationGate()
        let firstScan = scans.begin()
        let secondScan = scans.begin()
        precondition(!scans.accepts(firstScan), "delayed progress from an older scan must be rejected")
        precondition(scans.accepts(secondScan), "current scan progress must be accepted")

        var reloadApplication = ReviewReloadApplicationGate()
        var presentation = "initial"
        var registeredRoots = ["root-a"]
        var errorMessage: String?

        let staleScanReload = reloadApplication.begin()
        let scanReloadLatch = AsyncLatch()
        let delayedScanReload = Task.detached {
            await scanReloadLatch.wait()
            return (presentation: "old-reload", roots: ["root-a"])
        }
        precondition(reloadApplication.isLoading, "a pending reload should set loading state")
        precondition(
            reloadApplication.invalidate(),
            "invalidating a pending reload should request a replacement when no newer operation supersedes it"
        )
        presentation = "new-scan"
        registeredRoots = ["root-b"]
        await scanReloadLatch.release()
        let staleScanResult = await delayedScanReload.value
        if reloadApplication.completeIfCurrent(staleScanReload) {
            presentation = staleScanResult.presentation
            registeredRoots = staleScanResult.roots
        }
        precondition(presentation == "new-scan", "a late reload must not replace a newer scan presentation")
        precondition(registeredRoots == ["root-b"], "a late reload must not replace roots installed by a newer scan")
        precondition(!reloadApplication.isLoading, "invalidating a reload must clear loading state")

        precondition(
            !reloadApplication.invalidate(),
            "invalidating an idle reload gate should not request unnecessary replacement work"
        )

        let staleFolderReload = reloadApplication.begin()
        let folderReloadLatch = AsyncLatch()
        let delayedFolderReload = Task.detached {
            await folderReloadLatch.wait()
            return ["root-a", "root-b"]
        }
        let folderMutationInterruptedReload = reloadApplication.invalidate()
        precondition(
            folderMutationInterruptedReload,
            "a folder mutation should remember that it interrupted required reload work"
        )
        registeredRoots = ["root-b"]
        await folderReloadLatch.release()
        let staleFolderRoots = await delayedFolderReload.value
        if reloadApplication.completeIfCurrent(staleFolderReload) {
            registeredRoots = staleFolderRoots
        }
        precondition(registeredRoots == ["root-b"], "a late reload must not restore pre-mutation folder state")
        precondition(!reloadApplication.isLoading, "folder mutation invalidation must not leave loading enabled")

        let replacementReload = reloadApplication.begin()
        precondition(
            reloadApplication.completeIfCurrent(replacementReload),
            "an interrupted folder reload should be replaceable with current-state work"
        )
        presentation = "current-folder-state"
        precondition(
            presentation == "current-folder-state" && !reloadApplication.isLoading,
            "replacement reload should eventually install current folder-dependent presentation state"
        )

        let staleFailureReload = reloadApplication.begin()
        let failureLatch = AsyncLatch()
        let delayedFailure = Task.detached { () throws -> Void in
            await failureLatch.wait()
            throw DelayedFailure.stale
        }
        let latestReload = reloadApplication.begin()
        if reloadApplication.completeIfCurrent(latestReload) {
            presentation = "latest-reload"
            errorMessage = nil
        }
        await failureLatch.release()
        do {
            try await delayedFailure.value
        } catch {
            if reloadApplication.completeIfCurrent(staleFailureReload) {
                presentation = "failed"
                errorMessage = "stale failure"
            }
        }
        precondition(presentation == "latest-reload", "a stale reload failure must not clear the latest presentation")
        precondition(errorMessage == nil, "a stale reload failure must not replace the latest error state")
        precondition(!reloadApplication.isLoading, "a stale failure must not disturb completed loading state")

        var delayedProgressGate = ReviewGenerationGate()
        var progressValue = 0
        let oldProgressGeneration = delayedProgressGate.begin()
        let progressLatch = AsyncLatch()
        let delayedProgress = Task.detached {
            await progressLatch.wait()
            return 1
        }
        let latestProgressGeneration = delayedProgressGate.begin()
        progressValue = 2
        await progressLatch.release()
        let oldProgress = await delayedProgress.value
        if delayedProgressGate.accepts(oldProgressGeneration) {
            progressValue = oldProgress
        }
        precondition(progressValue == 2, "delayed progress from an older scan must not replace current progress")
        precondition(delayedProgressGate.accepts(latestProgressGeneration), "latest scan progress generation should remain current")

        let completed: Set<String> = ["a", "b", "c"]
        let snapshot: Set<String> = ["c"]
        precondition(!selectedRootsNeedInitialScan(selected: [], completed: completed))
        precondition(!reviewSelectionNeedsCurrentComparison(selected: [], completed: completed, snapshot: snapshot))
        precondition(!selectedRootsNeedInitialScan(selected: ["a", "b"], completed: completed))
        precondition(reviewSelectionNeedsCurrentComparison(
            selected: ["a", "b"], completed: completed, snapshot: snapshot
        ))
        precondition(selectedRootsNeedInitialScan(selected: ["a", "new"], completed: completed))
        precondition(!reviewSelectionNeedsCurrentComparison(
            selected: ["a", "new"], completed: completed, snapshot: snapshot
        ))
        precondition(!reviewSelectionNeedsCurrentComparison(
            selected: ["c"], completed: completed, snapshot: snapshot
        ))
        print("Review generation, state-application, and scan-state tests passed.")
    }
}
