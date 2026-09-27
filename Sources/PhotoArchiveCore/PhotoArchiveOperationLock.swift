import Darwin
import Foundation

enum PhotoArchiveOperationLockError: LocalizedError {
    case anotherOperationIsRunning

    var errorDescription: String? {
        "Another PhotoArchiveKit filesystem operation is already running for this catalog."
    }
}

/// Cross-process advisory lock shared by scans and filesystem mutations.
///
/// The filename intentionally preserves the existing `.scan.lock` location so
/// older builds and newer builds still exclude each other.
final class PhotoArchiveOperationLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(catalogURL: URL) throws -> PhotoArchiveOperationLock {
        let lockURL = catalogURL.deletingLastPathComponent().appendingPathComponent(
            ".\(catalogURL.lastPathComponent).scan.lock",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw PhotoArchiveOperationLockError.anotherOperationIsRunning
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw PhotoArchiveOperationLockError.anotherOperationIsRunning
        }
        return PhotoArchiveOperationLock(descriptor: descriptor)
    }

    func release() {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
