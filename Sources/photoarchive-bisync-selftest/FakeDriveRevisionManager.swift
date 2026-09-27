import CryptoKit
import Foundation
import PhotoArchiveCore

final class FakeDriveRevisionManager: @unchecked Sendable, DriveRevisionManaging {
    struct Snapshot: Sendable, Equatable {
        let fileID: String
        let headRevisionID: String
        let bytes: Data
        let keepForever: Bool
        let trashed: Bool
        let parentIDs: [String]
    }

    private struct Revision {
        var bytes: Data
        var keepForever: Bool
    }

    private struct FileRecord {
        var id: String
        var name: String
        var mimeType: String
        var headRevisionID: String
        var revisions: [String: Revision]
        var trashed: Bool
        var parentIDs: [String]
    }

    private let lock = NSLock()
    private var folders: [String: String] = [:]
    private var files: [String: FileRecord] = [:]
    private var nextID = 0
    private var pinFailure: DriveRevisionAPIError?
    private var downloadFailure: DriveRevisionAPIError?

    init() {
        folders[key(parent: "root", name: "camera")] = "folder:camera"
    }

    func setPinFailure(_ error: DriveRevisionAPIError?) {
        lock.lock()
        pinFailure = error
        lock.unlock()
    }

    func setDownloadFailure(_ error: DriveRevisionAPIError?) {
        lock.lock()
        downloadFailure = error
        lock.unlock()
    }

    @discardableResult
    func seedFile(
        path: String,
        bytes: Data,
        fileID: String? = nil,
        keepForever: Bool = false
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        let components = path.split(separator: "/").map(String.init)
        let name = components.last ?? path
        let parentPath = components.dropLast().joined(separator: "/")
        let parentID = ensureFolderPathLocked(parentPath.isEmpty ? "camera" : "camera/" + parentPath)
        nextID += 1
        let id = fileID ?? "file-\(nextID)"
        let revisionID = "rev-\(id)-1"
        files[id] = FileRecord(
            id: id,
            name: name,
            mimeType: "application/octet-stream",
            headRevisionID: revisionID,
            revisions: [revisionID: Revision(bytes: bytes, keepForever: keepForever)],
            trashed: false,
            parentIDs: [parentID]
        )
        return id
    }

    @discardableResult
    func addRevision(
        fileID: String,
        bytes: Data,
        keepForever: Bool = false
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard var file = files[fileID] else { return "" }
        let revisionID = "rev-\(fileID)-\(file.revisions.count + 1)"
        file.revisions[revisionID] = Revision(bytes: bytes, keepForever: keepForever)
        file.headRevisionID = revisionID
        files[fileID] = file
        return revisionID
    }

    func moveFile(fileID: String, toFolderPath path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var file = files[fileID] else { return }
        file.parentIDs = [ensureFolderPathLocked(path)]
        file.trashed = false
        files[fileID] = file
    }

    func trashFile(fileID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var file = files[fileID] else { return }
        file.trashed = true
        files[fileID] = file
    }

    func removeFile(fileID: String) {
        lock.lock()
        files.removeValue(forKey: fileID)
        lock.unlock()
    }

    func snapshot(fileID: String) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let file = files[fileID], let revision = file.revisions[file.headRevisionID] else {
            return nil
        }
        return Snapshot(
            fileID: file.id,
            headRevisionID: file.headRevisionID,
            bytes: revision.bytes,
            keepForever: revision.keepForever,
            trashed: file.trashed,
            parentIDs: file.parentIDs
        )
    }

    func revisionSnapshot(fileID: String, revisionID: String) -> (bytes: Data, keepForever: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let revision = files[fileID]?.revisions[revisionID] else { return nil }
        return (revision.bytes, revision.keepForever)
    }

    func liveFileIDs(path: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let components = path.split(separator: "/").map(String.init)
        let name = components.last ?? path
        let parentPath = components.dropLast().joined(separator: "/")
        let parentID = ensureFolderPathLocked(parentPath.isEmpty ? "camera" : "camera/" + parentPath)
        return files.values
            .filter { !$0.trashed && $0.name == name && $0.parentIDs.contains(parentID) }
            .map(\.id)
            .sorted()
    }

    func rootFolderID() throws -> String { "root" }

    func children(
        parentID: String,
        named name: String,
        includeTrashed: Bool
    ) throws -> [DriveFileState] {
        lock.lock()
        defer { lock.unlock() }
        var values = files.values.compactMap { file -> DriveFileState? in
            guard file.name == name,
                  file.parentIDs.contains(parentID),
                  includeTrashed || !file.trashed,
                  let revision = file.revisions[file.headRevisionID]
            else { return nil }
            return state(file: file, revision: revision)
        }
        if let folderID = folders[key(parent: parentID, name: name)] {
            values.append(
                DriveFileState(
                    id: folderID,
                    name: name,
                    mimeType: "application/vnd.google-apps.folder",
                    byteSize: 0,
                    sha256: nil,
                    headRevisionID: nil,
                    trashed: false,
                    parentIDs: [parentID]
                )
            )
        } else if values.isEmpty, Self.looksLikeFolder(name) {
            let folderID = "folder:" + parentID + "/" + name
            folders[key(parent: parentID, name: name)] = folderID
            values.append(
                DriveFileState(
                    id: folderID,
                    name: name,
                    mimeType: "application/vnd.google-apps.folder",
                    byteSize: 0,
                    sha256: nil,
                    headRevisionID: nil,
                    trashed: false,
                    parentIDs: [parentID]
                )
            )
        }
        return values
    }

    func file(id: String) throws -> DriveFileState? {
        lock.lock()
        defer { lock.unlock() }
        guard let file = files[id], let revision = file.revisions[file.headRevisionID] else {
            return nil
        }
        return state(file: file, revision: revision)
    }

    func revisions(fileID: String) throws -> [DriveRevisionState] {
        lock.lock()
        defer { lock.unlock() }
        guard let file = files[fileID] else { throw DriveRevisionAPIError.notFound }
        return file.revisions.keys.sorted().compactMap { id in
            guard let revision = file.revisions[id] else { return nil }
            return DriveRevisionState(
                id: id,
                byteSize: Int64(revision.bytes.count),
                keepForever: revision.keepForever
            )
        }
    }

    func revision(fileID: String, revisionID: String) throws -> DriveRevisionState? {
        lock.lock()
        defer { lock.unlock() }
        guard let revision = files[fileID]?.revisions[revisionID] else { return nil }
        return DriveRevisionState(
            id: revisionID,
            byteSize: Int64(revision.bytes.count),
            keepForever: revision.keepForever
        )
    }

    func pinRevision(fileID: String, revisionID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let pinFailure { throw pinFailure }
        guard var file = files[fileID], var revision = file.revisions[revisionID] else {
            throw DriveRevisionAPIError.notFound
        }
        revision.keepForever = true
        file.revisions[revisionID] = revision
        files[fileID] = file
    }

    func downloadRevision(fileID: String, revisionID: String, to destination: URL) throws {
        lock.lock()
        if let downloadFailure {
            lock.unlock()
            throw downloadFailure
        }
        guard let revision = files[fileID]?.revisions[revisionID] else {
            lock.unlock()
            throw DriveRevisionAPIError.notFound
        }
        let bytes = revision.bytes
        lock.unlock()
        try bytes.write(to: destination, options: .atomic)
    }

    func generateFileID() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return "generated-file-\(nextID)"
    }

    func createFolder(parentID: String, name: String) throws -> DriveFileState {
        lock.lock()
        defer { lock.unlock() }
        let itemKey = key(parent: parentID, name: name)
        if folders[itemKey] != nil {
            throw DriveRevisionAPIError.conflict
        }
        nextID += 1
        let id = "folder-generated-\(nextID)"
        folders[itemKey] = id
        return DriveFileState(
            id: id,
            name: name,
            mimeType: "application/vnd.google-apps.folder",
            byteSize: 0,
            sha256: nil,
            headRevisionID: nil,
            trashed: false,
            parentIDs: [parentID]
        )
    }

    func createFile(
        id: String,
        parentID: String,
        name: String,
        source: URL
    ) throws -> DriveFileState {
        _ = try createEmptyFile(id: id, parentID: parentID, name: name)
        return try updateFile(fileID: id, source: source)
    }

    func createEmptyFile(
        id: String,
        parentID: String,
        name: String
    ) throws -> DriveFileState {
        let bytes = Data()
        lock.lock()
        defer { lock.unlock() }
        guard files[id] == nil else { throw DriveRevisionAPIError.conflict }
        let revisionID = "rev-\(id)-1"
        let revision = Revision(bytes: bytes, keepForever: true)
        let record = FileRecord(
            id: id,
            name: name,
            mimeType: "application/octet-stream",
            headRevisionID: revisionID,
            revisions: [revisionID: revision],
            trashed: false,
            parentIDs: [parentID]
        )
        files[id] = record
        return state(file: record, revision: revision)
    }

    func updateFile(fileID: String, source: URL) throws -> DriveFileState {
        let bytes = try Data(contentsOf: source)
        lock.lock()
        defer { lock.unlock() }
        guard var file = files[fileID], !file.trashed else {
            throw DriveRevisionAPIError.notFound
        }
        let revisionID = "rev-\(fileID)-\(file.revisions.count + 1)"
        let revision = Revision(bytes: bytes, keepForever: true)
        file.revisions[revisionID] = revision
        file.headRevisionID = revisionID
        files[fileID] = file
        return state(file: file, revision: revision)
    }

    func moveFile(fileID: String, parentID: String, name: String) throws -> DriveFileState {
        lock.lock()
        defer { lock.unlock() }
        guard var file = files[fileID], !file.trashed,
              let revision = file.revisions[file.headRevisionID] else {
            throw DriveRevisionAPIError.notFound
        }
        file.parentIDs = [parentID]
        file.name = name
        files[fileID] = file
        return state(file: file, revision: revision)
    }

    private func state(file: FileRecord, revision: Revision) -> DriveFileState {
        DriveFileState(
            id: file.id,
            name: file.name,
            mimeType: file.mimeType,
            byteSize: Int64(revision.bytes.count),
            sha256: Data(SHA256.hash(data: revision.bytes)),
            headRevisionID: file.headRevisionID,
            trashed: file.trashed,
            parentIDs: file.parentIDs
        )
    }

    private func ensureFolderPathLocked(_ path: String) -> String {
        var parent = "root"
        for component in path.split(separator: "/").map(String.init) {
            let itemKey = key(parent: parent, name: component)
            if let existing = folders[itemKey] {
                parent = existing
            } else {
                let id = "folder:" + parent + "/" + component
                folders[itemKey] = id
                parent = id
            }
        }
        return parent
    }

    private func key(parent: String, name: String) -> String {
        parent + "\u{1F}" + name
    }

    private static func looksLikeFolder(_ name: String) -> Bool {
        name.hasPrefix(".photoarchivekit-recovery")
            || !name.contains(".")
    }
}
