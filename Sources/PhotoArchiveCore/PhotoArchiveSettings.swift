import Darwin
import Foundation

public enum DuplicateCleanupDestinationKind: String, Codable, Sendable, Equatable {
    case systemTrash = "system_trash"
    case customQuarantine = "custom_quarantine"
}

public struct DuplicateCleanupDestinationSetting: Codable, Sendable, Equatable {
    public let kind: DuplicateCleanupDestinationKind
    public let path: String?

    public init(kind: DuplicateCleanupDestinationKind, path: String? = nil) {
        self.kind = kind
        self.path = path
    }

    public static let systemTrash = DuplicateCleanupDestinationSetting(kind: .systemTrash)

    public static func customQuarantine(path: String) -> DuplicateCleanupDestinationSetting {
        DuplicateCleanupDestinationSetting(kind: .customQuarantine, path: path)
    }
}

public struct PhotoArchiveSettings: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public var duplicateCleanupDestination: DuplicateCleanupDestinationSetting

    public init(
        schemaVersion: Int = 1,
        duplicateCleanupDestination: DuplicateCleanupDestinationSetting = .systemTrash
    ) {
        self.schemaVersion = schemaVersion
        self.duplicateCleanupDestination = duplicateCleanupDestination
    }
}

public enum PhotoArchiveSettingsError: LocalizedError {
    case unsupportedSchema(Int)
    case invalidCustomQuarantinePath
    case customQuarantineDoesNotExist(String)
    case customQuarantineIsNotDirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported PhotoArchiveKit settings schema: \(version)"
        case .invalidCustomQuarantinePath:
            return "A custom quarantine destination requires an absolute local directory path."
        case let .customQuarantineDoesNotExist(path):
            return "The custom quarantine destination does not exist: \(path)"
        case let .customQuarantineIsNotDirectory(path):
            return "The custom quarantine destination is not a directory: \(path)"
        }
    }
}

public enum PhotoArchiveSettingsStore {
    public static var defaultURL: URL {
        PhotoArchivePaths.applicationSupportDirectoryURL
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    public static func load(url: URL = defaultURL) throws -> PhotoArchiveSettings {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return PhotoArchiveSettings()
        }
        let decoder = JSONDecoder()
        let settings = try decoder.decode(PhotoArchiveSettings.self, from: Data(contentsOf: url))
        guard settings.schemaVersion == 1 else {
            throw PhotoArchiveSettingsError.unsupportedSchema(settings.schemaVersion)
        }
        try validate(settings.duplicateCleanupDestination, requireExistingDirectory: false)
        return settings
    }

    public static func save(
        _ settings: PhotoArchiveSettings,
        url: URL = defaultURL
    ) throws {
        guard settings.schemaVersion == 1 else {
            throw PhotoArchiveSettingsError.unsupportedSchema(settings.schemaVersion)
        }
        try validate(settings.duplicateCleanupDestination, requireExistingDirectory: true)

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: .atomic)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
    }

    public static func resolvedDestination(
        _ setting: DuplicateCleanupDestinationSetting
    ) throws -> DuplicateCleanupDestination {
        switch setting.kind {
        case .systemTrash:
            return .systemTrash
        case .customQuarantine:
            try validate(setting, requireExistingDirectory: true)
            return .customQuarantine(URL(fileURLWithPath: setting.path!).standardizedFileURL)
        }
    }

    private static func validate(
        _ setting: DuplicateCleanupDestinationSetting,
        requireExistingDirectory: Bool
    ) throws {
        guard setting.kind == .customQuarantine else { return }
        guard let path = setting.path, !path.isEmpty, path.hasPrefix("/") else {
            throw PhotoArchiveSettingsError.invalidCustomQuarantinePath
        }
        guard requireExistingDirectory else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw PhotoArchiveSettingsError.customQuarantineDoesNotExist(path)
        }
        guard isDirectory.boolValue else {
            throw PhotoArchiveSettingsError.customQuarantineIsNotDirectory(path)
        }
    }
}
