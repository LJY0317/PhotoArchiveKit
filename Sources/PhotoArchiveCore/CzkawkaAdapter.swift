import Foundation

enum CzkawkaAdapterError: LocalizedError {
    case executableNotFound
    case processFailed(Int32)
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "czkawka_cli was not found in PATH."
        case let .processFailed(status):
            return "czkawka_cli exact scan failed with exit status \(status)."
        case .invalidResult:
            return "czkawka_cli returned an unreadable exact-duplicate result."
        }
    }
}

struct CzkawkaExactCandidateAdapter {
    private struct FileRecord: Decodable {
        let path: String
    }

    private typealias ResultPayload = [String: [[FileRecord]]]

    static func executablePath() -> String? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in environmentPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("czkawka_cli")
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func exactCandidateGroups(roots: [RootDescriptor]) throws -> [[String]] {
        guard let executable = executablePath() else {
            throw CzkawkaAdapterError.executableNotFound
        }

        let directories = outermostRootPaths(roots)
        guard !directories.isEmpty else { return [] }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoArchiveKit-Czkawka-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["dup"]
            + directories.flatMap { ["-d", $0] }
            + [
                "-s", "hash",
                "-t", "BLAKE3",
                "-u",
                "-m", "1",
                "-C", outputURL.path,
                "-N",
                "-M",
                "-W"
            ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CzkawkaAdapterError.processFailed(process.terminationStatus)
        }

        guard FileManager.default.fileExists(atPath: outputURL.path),
              let data = try? Data(contentsOf: outputURL),
              let payload = try? JSONDecoder().decode(ResultPayload.self, from: data)
        else {
            throw CzkawkaAdapterError.invalidResult
        }

        return payload.values
            .flatMap { $0 }
            .map { group in
                group.map(\.path)
            }
            .filter { $0.count > 1 }
    }

    private static func outermostRootPaths(_ roots: [RootDescriptor]) -> [String] {
        let sorted = roots.sorted { lhs, rhs in
            lhs.url.standardizedFileURL.path.count < rhs.url.standardizedFileURL.path.count
        }
        var selected: [URL] = []
        for root in sorted {
            let candidate = root.url.standardizedFileURL
            let isNested = selected.contains { parent in
                isDescendant(candidate, of: parent)
            }
            if !isNested {
                selected.append(candidate)
            }
        }
        return selected.map(\.path)
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        guard childPath != parentPath else { return false }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }
}
