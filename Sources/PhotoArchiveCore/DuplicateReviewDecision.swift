import Foundation

public enum DuplicateReviewSelectionPolicy {
    public static func toggledCleanupCopyIDs(
        current: Set<String>,
        clickedCopyID: String,
        allCopyIDs: [String]
    ) -> Set<String> {
        var next = current
        if next.contains(clickedCopyID) {
            next.remove(clickedCopyID)
            return next
        }

        next.insert(clickedCopyID)
        let all = Set(allCopyIDs)
        if all.count > 1, all.isSubset(of: next) {
            return [clickedCopyID]
        }
        return next
    }
}

public struct DuplicateReviewDecision: Codable, Sendable, Equatable {
    public let itemID: String
    public let subjectID: String
    public let keptResourceIDs: [String]
    public let cleanupResourceIDs: [String]

    public init(
        itemID: String,
        subjectID: String,
        keptResourceIDs: [String],
        cleanupResourceIDs: [String]
    ) {
        self.itemID = itemID
        self.subjectID = subjectID
        self.keptResourceIDs = keptResourceIDs.sorted()
        self.cleanupResourceIDs = cleanupResourceIDs.sorted()
    }
}

public struct DuplicateReviewDecisionBundle: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionID: String
    public let submittedAt: Date
    public let decisions: [DuplicateReviewDecision]

    public init(
        schemaVersion: Int = 1,
        sessionID: String,
        submittedAt: Date = Date(),
        decisions: [DuplicateReviewDecision]
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.submittedAt = submittedAt
        self.decisions = decisions.sorted { $0.itemID < $1.itemID }
    }
}

public enum DuplicateReviewDecisionStore {
    public static var defaultURL: URL {
        PhotoArchivePaths.applicationSupportDirectoryURL
            .appendingPathComponent("review-decisions.json", isDirectory: false)
    }

    public static func save(
        _ bundle: DuplicateReviewDecisionBundle,
        to url: URL = defaultURL,
        fileManager: FileManager = .default
    ) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(from url: URL = defaultURL) throws -> DuplicateReviewDecisionBundle? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            DuplicateReviewDecisionBundle.self,
            from: Data(contentsOf: url)
        )
    }
}
