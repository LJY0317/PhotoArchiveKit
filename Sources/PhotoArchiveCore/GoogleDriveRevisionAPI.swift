import Foundation

package struct DriveFileState: Sendable, Equatable {
    package let id: String
    package let name: String
    package let mimeType: String?
    package let byteSize: Int64
    package let sha256: Data?
    package let headRevisionID: String?
    package let trashed: Bool
    package let parentIDs: [String]

    package init(
        id: String,
        name: String,
        mimeType: String?,
        byteSize: Int64,
        sha256: Data?,
        headRevisionID: String?,
        trashed: Bool,
        parentIDs: [String]
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sha256 = sha256
        self.headRevisionID = headRevisionID
        self.trashed = trashed
        self.parentIDs = parentIDs
    }
}

package struct DriveRevisionState: Sendable, Equatable {
    package let id: String
    package let byteSize: Int64
    package let keepForever: Bool
    package let md5Checksum: String?

    package init(
        id: String,
        byteSize: Int64,
        keepForever: Bool,
        md5Checksum: String? = nil
    ) {
        self.id = id
        self.byteSize = byteSize
        self.keepForever = keepForever
        self.md5Checksum = md5Checksum
    }
}

package enum DriveRevisionAPIError: Error, Sendable, Equatable {
    case authentication
    case permission
    case revisionLimit
    case notFound
    case conflict
    case invalidResponse
    case transport
}

package protocol DriveRevisionManaging: AnyObject, Sendable {
    func rootFolderID() throws -> String
    func children(
        parentID: String,
        named name: String,
        includeTrashed: Bool
    ) throws -> [DriveFileState]
    func file(id: String) throws -> DriveFileState?
    func revisions(fileID: String) throws -> [DriveRevisionState]
    func revision(fileID: String, revisionID: String) throws -> DriveRevisionState?
    func pinRevision(fileID: String, revisionID: String) throws
    func downloadRevision(fileID: String, revisionID: String, to destination: URL) throws
    func generateFileID() throws -> String
    func createFolder(parentID: String, name: String) throws -> DriveFileState
    func createEmptyFile(
        id: String,
        parentID: String,
        name: String
    ) throws -> DriveFileState
    func createFile(
        id: String,
        parentID: String,
        name: String,
        source: URL
    ) throws -> DriveFileState
    func updateFile(fileID: String, source: URL) throws -> DriveFileState
    func moveFile(fileID: String, parentID: String, name: String) throws -> DriveFileState
}

package final class GoogleDriveRevisionAPI: @unchecked Sendable, DriveRevisionManaging {
    private struct APIFile: Decodable {
        let id: String
        let name: String?
        let mimeType: String?
        let size: String?
        let sha256Checksum: String?
        let headRevisionId: String?
        let trashed: Bool?
        let parents: [String]?
    }

    private struct FileList: Decodable {
        let nextPageToken: String?
        let files: [APIFile]
    }

    private struct APIRevision: Decodable {
        let id: String
        let size: String?
        let keepForever: Bool?
        let md5Checksum: String?
    }

    private struct RevisionList: Decodable {
        let nextPageToken: String?
        let revisions: [APIRevision]
    }

    private struct GeneratedIDs: Decodable {
        let ids: [String]
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<(Data, HTTPURLResponse), Error>?

        func store(_ value: Result<(Data, HTTPURLResponse), Error>) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func load() -> Result<(Data, HTTPURLResponse), Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class DownloadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<HTTPURLResponse, Error>?

        func store(_ value: Result<HTTPURLResponse, Error>) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func load() -> Result<HTTPURLResponse, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let accessToken: String
    private let configuredRootFolderID: String?
    private let sharedDriveID: String?
    private let session: URLSession
    private let rootLock = NSLock()
    private var cachedRootFolderID: String?

    package init(
        accessToken: String,
        configuredRootFolderID: String? = nil,
        sharedDriveID: String? = nil,
        session: URLSession = .shared
    ) {
        self.accessToken = accessToken
        self.configuredRootFolderID = configuredRootFolderID
        self.sharedDriveID = sharedDriveID
        self.session = session
    }

    package func rootFolderID() throws -> String {
        if let configuredRootFolderID, !configuredRootFolderID.isEmpty {
            return configuredRootFolderID
        }
        rootLock.lock()
        if let cachedRootFolderID {
            rootLock.unlock()
            return cachedRootFolderID
        }
        rootLock.unlock()

        guard let root = try file(id: "root") else {
            throw DriveRevisionAPIError.notFound
        }
        rootLock.lock()
        cachedRootFolderID = root.id
        rootLock.unlock()
        return root.id
    }

    package func children(
        parentID: String,
        named name: String,
        includeTrashed: Bool
    ) throws -> [DriveFileState] {
        var values: [DriveFileState] = []
        var pageToken: String?
        repeat {
            var items = [
                URLQueryItem(
                    name: "q",
                    value: "'\(Self.queryLiteral(parentID))' in parents and name = '\(Self.queryLiteral(name))'"
                        + (includeTrashed ? "" : " and trashed = false")
                ),
                URLQueryItem(
                    name: "fields",
                    value: "nextPageToken,files(id,name,mimeType,size,sha256Checksum,headRevisionId,trashed,parents)"
                ),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
            ]
            if let sharedDriveID, !sharedDriveID.isEmpty {
                items.append(URLQueryItem(name: "corpora", value: "drive"))
                items.append(URLQueryItem(name: "driveId", value: sharedDriveID))
            }
            if let pageToken {
                items.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let request = try makeRequest(path: "/files", queryItems: items)
            let data = try perform(request)
            let page = try decode(FileList.self, from: data)
            values.append(contentsOf: try page.files.map(Self.state))
            pageToken = page.nextPageToken
        } while pageToken != nil
        return values
    }

    package func file(id: String) throws -> DriveFileState? {
        let request = try makeRequest(
            path: "/files/\(Self.pathComponent(id))",
            queryItems: [
                URLQueryItem(
                    name: "fields",
                    value: "id,name,mimeType,size,sha256Checksum,headRevisionId,trashed,parents"
                ),
                URLQueryItem(name: "supportsAllDrives", value: "true")
            ]
        )
        do {
            let data = try perform(request)
            return try Self.state(decode(APIFile.self, from: data))
        } catch DriveRevisionAPIError.notFound {
            return nil
        }
    }

    package func revisions(fileID: String) throws -> [DriveRevisionState] {
        var values: [DriveRevisionState] = []
        var pageToken: String?
        repeat {
            var items = [
                URLQueryItem(
                    name: "fields",
                    value: "nextPageToken,revisions(id,size,keepForever,md5Checksum)"
                ),
                URLQueryItem(name: "pageSize", value: "200")
            ]
            if let pageToken {
                items.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let request = try makeRequest(
                path: "/files/\(Self.pathComponent(fileID))/revisions",
                queryItems: items
            )
            let data = try perform(request)
            let page = try decode(RevisionList.self, from: data)
            values.append(contentsOf: page.revisions.map(Self.state))
            pageToken = page.nextPageToken
        } while pageToken != nil
        return values
    }

    package func revision(fileID: String, revisionID: String) throws -> DriveRevisionState? {
        let request = try makeRequest(
            path: "/files/\(Self.pathComponent(fileID))/revisions/\(Self.pathComponent(revisionID))",
            queryItems: [URLQueryItem(name: "fields", value: "id,size,keepForever,md5Checksum")]
        )
        do {
            let data = try perform(request)
            return Self.state(try decode(APIRevision.self, from: data))
        } catch DriveRevisionAPIError.notFound {
            return nil
        }
    }

    package func pinRevision(fileID: String, revisionID: String) throws {
        var request = try makeRequest(
            path: "/files/\(Self.pathComponent(fileID))/revisions/\(Self.pathComponent(revisionID))",
            queryItems: [URLQueryItem(name: "fields", value: "id,keepForever,size,md5Checksum")]
        )
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"keepForever\":true}".utf8)
        _ = try perform(request)
    }

    package func downloadRevision(fileID: String, revisionID: String, to destination: URL) throws {
        let request = try makeRequest(
            path: "/files/\(Self.pathComponent(fileID))/revisions/\(Self.pathComponent(revisionID))",
            queryItems: [URLQueryItem(name: "alt", value: "media")]
        )
        try performDownload(request, to: destination)
    }

    package func generateFileID() throws -> String {
        let request = try makeRequest(
            path: "/files/generateIds",
            queryItems: [
                URLQueryItem(name: "count", value: "1"),
                URLQueryItem(name: "space", value: "drive")
            ]
        )
        let generated = try decode(GeneratedIDs.self, from: perform(request))
        guard generated.ids.count == 1, let id = generated.ids.first, !id.isEmpty else {
            throw DriveRevisionAPIError.invalidResponse
        }
        return id
    }

    package func createFolder(parentID: String, name: String) throws -> DriveFileState {
        var request = try makeRequest(
            path: "/files",
            queryItems: Self.fileMutationQueryItems
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentID]
        ])
        return try Self.state(decode(APIFile.self, from: perform(request)))
    }

    package func createFile(
        id: String,
        parentID: String,
        name: String,
        source: URL
    ) throws -> DriveFileState {
        _ = try createEmptyFile(id: id, parentID: parentID, name: name)
        return try updateFile(fileID: id, source: source)
    }

    package func createEmptyFile(
        id: String,
        parentID: String,
        name: String
    ) throws -> DriveFileState {
        var request = try makeRequest(
            path: "/files",
            queryItems: Self.fileMutationQueryItems
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "name": name,
            "parents": [parentID]
        ])
        return try Self.state(decode(APIFile.self, from: perform(request)))
    }

    package func updateFile(fileID: String, source: URL) throws -> DriveFileState {
        try uploadFile(fileID: fileID, source: source)
    }

    package func moveFile(fileID: String, parentID: String, name: String) throws -> DriveFileState {
        guard let current = try file(id: fileID), !current.trashed else {
            throw DriveRevisionAPIError.notFound
        }
        var queryItems = Self.fileMutationQueryItems
        queryItems.append(URLQueryItem(name: "addParents", value: parentID))
        if !current.parentIDs.isEmpty {
            queryItems.append(URLQueryItem(name: "removeParents", value: current.parentIDs.joined(separator: ",")))
        }
        var request = try makeRequest(
            path: "/files/\(Self.pathComponent(fileID))",
            queryItems: queryItems
        )
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        return try Self.state(decode(APIFile.self, from: perform(request)))
    }

    private func uploadFile(fileID: String, source: URL) throws -> DriveFileState {
        let values = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DriveRevisionAPIError.invalidResponse
        }
        guard let modifiedTime = values.contentModificationDate else {
            throw DriveRevisionAPIError.invalidResponse
        }
        var components = URLComponents(
            string: "https://www.googleapis.com/upload/drive/v3/files/"
                + Self.pathComponent(fileID)
        )
        components?.queryItems = Self.fileMutationQueryItems + [
            URLQueryItem(name: "uploadType", value: "media"),
            URLQueryItem(name: "keepRevisionForever", value: "true")
        ]
        guard let url = components?.url else { throw DriveRevisionAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 120
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try performUpload(request, from: source)

        // Direct Drive mutations run before the final bisync history-reconcile
        // dry-run so that the app can enforce file-ID/revision preconditions at
        // the actual mutation boundary. Preserve the local source mtime as
        // rclone's Drive backend normally would; otherwise the reconciliation
        // can report the already-protected upload as another modification (and
        // initial --immutable setup fails closed on the timestamp mismatch).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var metadataRequest = try makeRequest(
            path: "/files/\(Self.pathComponent(fileID))",
            queryItems: Self.fileMutationQueryItems
        )
        metadataRequest.httpMethod = "PATCH"
        metadataRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        metadataRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "modifiedTime": formatter.string(from: modifiedTime)
        ])
        return try Self.state(decode(APIFile.self, from: perform(metadataRequest)))
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3" + path)
        components?.queryItems = queryItems
        guard let url = components?.url else { throw DriveRevisionAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        session.dataTask(with: request) { data, response, error in
            if let error {
                box.store(.failure(error))
            } else if let response = response as? HTTPURLResponse {
                box.store(.success((data ?? Data(), response)))
            } else {
                box.store(.failure(DriveRevisionAPIError.invalidResponse))
            }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 125) == .success,
              let result = box.load()
        else {
            throw DriveRevisionAPIError.transport
        }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try result.get()
        } catch {
            throw DriveRevisionAPIError.transport
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.classify(statusCode: response.statusCode, body: data)
        }
        return data
    }

    private func performDownload(_ request: URLRequest, to destination: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = DownloadBox()
        try? FileManager.default.removeItem(at: destination)
        session.downloadTask(with: request) { temporaryURL, response, error in
            if let error {
                box.store(.failure(error))
            } else if let response = response as? HTTPURLResponse, let temporaryURL {
                if (200..<300).contains(response.statusCode) {
                    do {
                        try FileManager.default.moveItem(at: temporaryURL, to: destination)
                        box.store(.success(response))
                    } catch {
                        box.store(.failure(error))
                    }
                } else {
                    let body = (try? Data(contentsOf: temporaryURL)) ?? Data()
                    box.store(.failure(Self.classify(statusCode: response.statusCode, body: body)))
                }
            } else {
                box.store(.failure(DriveRevisionAPIError.invalidResponse))
            }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 125) == .success,
              let result = box.load()
        else {
            throw DriveRevisionAPIError.transport
        }
        do {
            _ = try result.get()
        } catch let error as DriveRevisionAPIError {
            throw error
        } catch {
            throw DriveRevisionAPIError.transport
        }
    }

    private func performUpload(_ request: URLRequest, from source: URL) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        session.uploadTask(with: request, fromFile: source) { data, response, error in
            if let error {
                box.store(.failure(error))
            } else if let response = response as? HTTPURLResponse {
                box.store(.success((data ?? Data(), response)))
            } else {
                box.store(.failure(DriveRevisionAPIError.invalidResponse))
            }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 125) == .success,
              let result = box.load()
        else {
            throw DriveRevisionAPIError.transport
        }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try result.get()
        } catch {
            throw DriveRevisionAPIError.transport
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.classify(statusCode: response.statusCode, body: data)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DriveRevisionAPIError.invalidResponse
        }
    }

    private static func state(_ value: APIFile) throws -> DriveFileState {
        DriveFileState(
            id: value.id,
            name: value.name ?? "",
            mimeType: value.mimeType,
            byteSize: Int64(value.size ?? "") ?? 0,
            sha256: value.sha256Checksum.flatMap(decodeHex),
            headRevisionID: value.headRevisionId,
            trashed: value.trashed ?? false,
            parentIDs: value.parents ?? []
        )
    }

    private static func state(_ value: APIRevision) -> DriveRevisionState {
        DriveRevisionState(
            id: value.id,
            byteSize: Int64(value.size ?? "") ?? 0,
            keepForever: value.keepForever ?? false,
            md5Checksum: value.md5Checksum
        )
    }

    private static let fileMutationQueryItems = [
        URLQueryItem(
            name: "fields",
            value: "id,name,mimeType,size,sha256Checksum,headRevisionId,trashed,parents"
        ),
        URLQueryItem(name: "supportsAllDrives", value: "true")
    ]

    private static func classify(statusCode: Int, body: Data) -> DriveRevisionAPIError {
        let message = String(data: body, encoding: .utf8)?.lowercased() ?? ""
        switch statusCode {
        case 401:
            return .authentication
        case 403:
            if message.contains("200")
                && (message.contains("revision") || message.contains("keep")) {
                return .revisionLimit
            }
            if message.contains("keepforever") && message.contains("limit") {
                return .revisionLimit
            }
            return .permission
        case 404:
            return .notFound
        case 409, 412:
            return .conflict
        case 429, 500...599:
            return .transport
        default:
            return .invalidResponse
        }
    }

    private static func queryLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func decodeHex(_ value: String) -> Data? {
        guard value.count == 64 else { return nil }
        var data = Data()
        data.reserveCapacity(32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
