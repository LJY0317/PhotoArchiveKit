import CryptoKit
import Foundation
import PhotoArchiveCore

final class PersistentDriveRevisionManager: @unchecked Sendable, DriveRevisionManaging {
    struct Snapshot: Sendable, Equatable {
        let fileID: String
        let headRevisionID: String
        let bytes: Data
        let keepForever: Bool
        let trashed: Bool
        let parentIDs: [String]
    }

    private struct Revision: Codable {
        var bytes: Data
        var keepForever: Bool
    }

    private struct FileRecord: Codable {
        var id: String
        var name: String
        var mimeType: String
        var headRevisionID: String
        var revisions: [String: Revision]
        var trashed: Bool
        var parentIDs: [String]
    }

    private struct PersistedState: Codable {
        var folders: [String: String]
        var folderPathsByID: [String: String]
        var files: [String: FileRecord]
        var nextID: Int
        var updateCounts: [String: Int]

        static func empty() -> PersistedState {
            PersistedState(
                folders: [PersistentDriveRevisionManager.key(parent: "root", name: "camera"): "folder:camera"],
                folderPathsByID: ["root": "", "folder:camera": "camera"],
                files: [:],
                nextID: 0,
                updateCounts: [:]
            )
        }
    }

    private let lock = NSLock()
    private let stateURL: URL
    private let mirrorRootURL: URL
    private var state: PersistedState

    init(stateURL: URL, mirrorRootURL: URL) throws {
        self.stateURL = stateURL
        self.mirrorRootURL = mirrorRootURL
        if FileManager.default.fileExists(atPath: stateURL.path) {
            state = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: stateURL))
        } else {
            state = .empty()
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        }
    }

    @discardableResult
    func seedFile(
        path: String,
        bytes: Data,
        fileID: String? = nil,
        keepForever: Bool = false
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let components = path.split(separator: "/").map(String.init)
        let name = components.last ?? path
        let parentPath = components.dropLast().joined(separator: "/")
        let parentID = ensureFolderPathLocked(parentPath.isEmpty ? "camera" : "camera/" + parentPath)
        state.nextID += 1
        let id = fileID ?? "file-\(state.nextID)"
        let revisionID = "rev-\(id)-1"
        let record = FileRecord(
            id: id,
            name: name,
            mimeType: "application/octet-stream",
            headRevisionID: revisionID,
            revisions: [revisionID: Revision(bytes: bytes, keepForever: keepForever)],
            trashed: false,
            parentIDs: [parentID]
        )
        state.files[id] = record
        try syncMirrorLocked(record, previousRelativePath: nil)
        try persistLocked()
        return id
    }

    @discardableResult
    func addRevision(
        fileID: String,
        bytes: Data,
        keepForever: Bool = false
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard var file = state.files[fileID] else { throw DriveRevisionAPIError.notFound }
        let previousPath = relativePathLocked(file)
        let revisionID = "rev-\(fileID)-\(file.revisions.count + 1)"
        file.revisions[revisionID] = Revision(bytes: bytes, keepForever: keepForever)
        file.headRevisionID = revisionID
        state.files[fileID] = file
        try syncMirrorLocked(file, previousRelativePath: previousPath)
        try persistLocked()
        return revisionID
    }

    func snapshot(fileID: String) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let file = state.files[fileID], let revision = file.revisions[file.headRevisionID] else {
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
        guard let revision = state.files[fileID]?.revisions[revisionID] else { return nil }
        return (revision.bytes, revision.keepForever)
    }

    func liveFileIDs(path: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return state.files.values.compactMap { file in
            guard !file.trashed, relativePathLocked(file) == path else { return nil }
            return file.id
        }.sorted()
    }

    func updateCount(fileID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return state.updateCounts[fileID, default: 0]
    }

    func rootFolderID() throws -> String { "root" }

    func children(parentID: String, named name: String, includeTrashed: Bool) throws -> [DriveFileState] {
        lock.lock()
        defer { lock.unlock() }
        var values = state.files.values.compactMap { file -> DriveFileState? in
            guard file.name == name,
                  file.parentIDs.contains(parentID),
                  includeTrashed || !file.trashed,
                  let revision = file.revisions[file.headRevisionID]
            else { return nil }
            return fileState(file: file, revision: revision)
        }
        if let folderID = state.folders[Self.key(parent: parentID, name: name)] {
            values.append(folderState(id: folderID, name: name, parentID: parentID))
        }
        return values
    }

    func file(id: String) throws -> DriveFileState? {
        lock.lock()
        defer { lock.unlock() }
        guard let file = state.files[id], let revision = file.revisions[file.headRevisionID] else {
            return nil
        }
        return fileState(file: file, revision: revision)
    }

    func revisions(fileID: String) throws -> [DriveRevisionState] {
        lock.lock()
        defer { lock.unlock() }
        guard let file = state.files[fileID] else { throw DriveRevisionAPIError.notFound }
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
        guard let revision = state.files[fileID]?.revisions[revisionID] else { return nil }
        return DriveRevisionState(
            id: revisionID,
            byteSize: Int64(revision.bytes.count),
            keepForever: revision.keepForever
        )
    }

    func pinRevision(fileID: String, revisionID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var file = state.files[fileID], var revision = file.revisions[revisionID] else {
            throw DriveRevisionAPIError.notFound
        }
        revision.keepForever = true
        file.revisions[revisionID] = revision
        state.files[fileID] = file
        try persistLocked()
    }

    func downloadRevision(fileID: String, revisionID: String, to destination: URL) throws {
        lock.lock()
        guard let revision = state.files[fileID]?.revisions[revisionID] else {
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
        state.nextID += 1
        let id = "generated-file-\(state.nextID)"
        try persistLocked()
        return id
    }

    func createFolder(parentID: String, name: String) throws -> DriveFileState {
        lock.lock()
        defer { lock.unlock() }
        let itemKey = Self.key(parent: parentID, name: name)
        if state.folders[itemKey] != nil { throw DriveRevisionAPIError.conflict }
        guard let parentPath = state.folderPathsByID[parentID] else { throw DriveRevisionAPIError.notFound }
        state.nextID += 1
        let id = "folder-generated-\(state.nextID)"
        let path = parentPath.isEmpty ? name : parentPath + "/" + name
        state.folders[itemKey] = id
        state.folderPathsByID[id] = path
        try persistLocked()
        return folderState(id: id, name: name, parentID: parentID)
    }

    func createEmptyFile(id: String, parentID: String, name: String) throws -> DriveFileState {
        lock.lock()
        defer { lock.unlock() }
        guard state.files[id] == nil else { throw DriveRevisionAPIError.conflict }
        guard state.folderPathsByID[parentID] != nil else { throw DriveRevisionAPIError.notFound }
        let revisionID = "rev-\(id)-1"
        let revision = Revision(bytes: Data(), keepForever: false)
        let record = FileRecord(
            id: id,
            name: name,
            mimeType: "application/octet-stream",
            headRevisionID: revisionID,
            revisions: [revisionID: revision],
            trashed: false,
            parentIDs: [parentID]
        )
        state.files[id] = record
        try syncMirrorLocked(record, previousRelativePath: nil)
        try persistLocked()
        return fileState(file: record, revision: revision)
    }

    func createFile(id: String, parentID: String, name: String, source: URL) throws -> DriveFileState {
        _ = try createEmptyFile(id: id, parentID: parentID, name: name)
        return try updateFile(fileID: id, source: source)
    }

    func updateFile(fileID: String, source: URL) throws -> DriveFileState {
        let bytes = try Data(contentsOf: source)
        lock.lock()
        defer { lock.unlock() }
        guard var file = state.files[fileID], !file.trashed else { throw DriveRevisionAPIError.notFound }
        let previousPath = relativePathLocked(file)
        let revisionID = "rev-\(fileID)-\(file.revisions.count + 1)"
        let revision = Revision(bytes: bytes, keepForever: false)
        file.revisions[revisionID] = revision
        file.headRevisionID = revisionID
        state.files[fileID] = file
        state.updateCounts[fileID, default: 0] += 1
        try syncMirrorLocked(file, previousRelativePath: previousPath)
        try persistLocked()
        return fileState(file: file, revision: revision)
    }

    func moveFile(fileID: String, parentID: String, name: String) throws -> DriveFileState {
        lock.lock()
        defer { lock.unlock() }
        guard var file = state.files[fileID], !file.trashed,
              let revision = file.revisions[file.headRevisionID],
              state.folderPathsByID[parentID] != nil else {
            throw DriveRevisionAPIError.notFound
        }
        let previousPath = relativePathLocked(file)
        file.parentIDs = [parentID]
        file.name = name
        state.files[fileID] = file
        try syncMirrorLocked(file, previousRelativePath: previousPath)
        try persistLocked()
        return fileState(file: file, revision: revision)
    }

    private func ensureFolderPathLocked(_ path: String) -> String {
        var parent = "root"
        var currentPath = ""
        for component in path.split(separator: "/").map(String.init) {
            let itemKey = Self.key(parent: parent, name: component)
            currentPath = currentPath.isEmpty ? component : currentPath + "/" + component
            if let existing = state.folders[itemKey] {
                parent = existing
            } else {
                let id = "folder:" + parent + "/" + component
                state.folders[itemKey] = id
                state.folderPathsByID[id] = currentPath
                parent = id
            }
        }
        return parent
    }

    private func relativePathLocked(_ file: FileRecord) -> String? {
        guard !file.trashed,
              let parentID = file.parentIDs.first,
              let folderPath = state.folderPathsByID[parentID],
              folderPath == "camera" || folderPath.hasPrefix("camera/") else {
            return nil
        }
        let parentRelative = folderPath == "camera"
            ? ""
            : String(folderPath.dropFirst("camera/".count))
        return parentRelative.isEmpty ? file.name : parentRelative + "/" + file.name
    }

    private func syncMirrorLocked(_ file: FileRecord, previousRelativePath: String?) throws {
        let nextRelativePath = relativePathLocked(file)
        if let previousRelativePath, previousRelativePath != nextRelativePath {
            try? FileManager.default.removeItem(
                at: mirrorRootURL.appendingPathComponent(previousRelativePath)
            )
        }
        guard let nextRelativePath,
              let revision = file.revisions[file.headRevisionID] else { return }
        let destination = mirrorRootURL.appendingPathComponent(nextRelativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try revision.bytes.write(to: destination, options: .atomic)
    }

    private func persistLocked() throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private func fileState(file: FileRecord, revision: Revision) -> DriveFileState {
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

    private func folderState(id: String, name: String, parentID: String) -> DriveFileState {
        DriveFileState(
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

    private static func key(parent: String, name: String) -> String {
        parent + "\u{1F}" + name
    }
}
