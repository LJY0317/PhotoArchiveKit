import Foundation

@main
struct PhotoArchiveBisyncSelfTest {
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().first == "--atomic-swap-crash-worker" {
                try await BisyncServiceIntegrationTests.runAtomicSwapCrashWorker(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            }
            if CommandLine.arguments.dropFirst().first == "--drive-empty-create-crash-worker" {
                try await BisyncServiceIntegrationTests.runDriveEmptyCreateCrashWorker(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            }
            if CommandLine.arguments.dropFirst().first == "--drive-crash-worker" {
                try await ActualDriveValidation.runCrashWorker(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            }
            if CommandLine.arguments.dropFirst().first == "--drive-conflict-crash-worker" {
                try await ActualDriveValidation.runConflictCrashWorker(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            }
            if CommandLine.arguments.dropFirst().first == "--actual-drive-validation" {
                try await ActualDriveValidation.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            }
            try await BisyncServiceIntegrationTests.run()
            print("PhotoArchiveKit bisync service integration tests passed.")
        } catch {
            FileHandle.standardError.write(
                Data("bisync service self-test failed: \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }
}
