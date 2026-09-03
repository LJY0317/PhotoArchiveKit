import Darwin
import Foundation
import PhotoArchiveCore

private let version = "0.1.0-dev"

@main
struct PhotoArchiveCLI {
    static func main() async {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else {
                printHelp()
                return
            }
            arguments.removeFirst()

            switch command {
            case "scan":
                try await runScan(arguments)
            case "doctor":
                runDoctor()
            case "version", "--version", "-v":
                print("PhotoArchiveKit \(version)")
            case "help", "--help", "-h":
                printHelp()
            default:
                throw CLIError("Unknown command: \(command)")
            }
        } catch {
            writeStandardError("error: \(error.localizedDescription)\n")
            exit(1)
        }
    }

    private static func runScan(_ arguments: [String]) async throws {
        var catalogURL = PhotoArchivePaths.defaultCatalogURL
        var outputJSON = false
        var computeExactDuplicates = true
        var eventGapHours = 6.0
        var maxConcurrency = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
        var roots: [ScanRoot] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--catalog":
                catalogURL = fileURL(try value(after: argument, at: &index, in: arguments))
            case "--json":
                outputJSON = true
            case "--no-exact-duplicates":
                computeExactDuplicates = false
            case "--event-gap-hours":
                let raw = try value(after: argument, at: &index, in: arguments)
                guard let value = Double(raw), value > 0 else {
                    throw CLIError("--event-gap-hours must be a positive number.")
                }
                eventGapHours = value
            case "--jobs":
                let raw = try value(after: argument, at: &index, in: arguments)
                guard let value = Int(raw), value > 0, value <= 64 else {
                    throw CLIError("--jobs must be between 1 and 64.")
                }
                maxConcurrency = value
            case "--inbox":
                let path = try value(after: argument, at: &index, in: arguments)
                roots.append(ScanRoot(url: fileURL(path), kind: .inbox))
            case "--archive":
                let path = try value(after: argument, at: &index, in: arguments)
                roots.append(ScanRoot(url: fileURL(path), kind: .archive))
            case "--import":
                let path = try value(after: argument, at: &index, in: arguments)
                roots.append(ScanRoot(url: fileURL(path), kind: .importSource))
            case "--reference":
                let path = try value(after: argument, at: &index, in: arguments)
                roots.append(ScanRoot(url: fileURL(path), kind: .reference))
            case "--help", "-h":
                printScanHelp()
                return
            default:
                if argument.hasPrefix("-") {
                    throw CLIError("Unknown scan option: \(argument)")
                }
                roots.append(ScanRoot(url: fileURL(argument), kind: .inbox))
            }
            index += 1
        }

        guard !roots.isEmpty else {
            throw CLIError("No source roots were supplied. Run 'photoarchive scan --help'.")
        }

        let scanner = try ArchiveScanner(catalogURL: catalogURL)
        let report = try await scanner.scan(
            roots: roots,
            options: ScanOptions(
                computeExactDuplicates: computeExactDuplicates,
                eventGap: eventGapHours * 60 * 60,
                maxConcurrentProbes: maxConcurrency
            )
        )

        if outputJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            printHumanReport(report)
        }
    }

    private static func printHumanReport(_ report: ScanReport) {
        print("PhotoArchiveKit read-only scan")
        print("Session: \(report.sessionID)")
        print("Catalog: \(report.catalogPath)")
        print("")
        print("Resources: \(report.summary.resourceCount)")
        print("Logical assets: \(report.summary.logicalAssetCount)")
        print("Live Photo assets: \(report.summary.livePhotoAssetCount)")
        print("Exact duplicate groups: \(report.summary.exactDuplicateGroupCount)")
        print("Automatic event suggestions: \(report.summary.eventSuggestionCount)")
        print("Warnings: \(report.summary.warningCount)")
        print("")

        for root in report.roots {
            print("[\(root.label)]")
            print("  kind: \(root.kind.rawValue)")
            print("  media files: \(root.mediaFileCount)")
            print("  complete Live Photos: \(root.completeLivePhotos)")
            print("  unpaired Live still resources: \(root.stillOnlyLiveResources)")
            print("  unpaired Live video resources: \(root.videoOnlyLiveResources)")
            print("  standalone images/videos: \(root.standaloneImages)/\(root.standaloneVideos)")
            print("  sidecars: \(root.sidecars)")
            print("")
        }

        if !report.exactDuplicateGroups.isEmpty {
            print("Exact duplicate resource groups:")
            for group in report.exactDuplicateGroups.prefix(20) {
                print("  \(group.groupID)  \(group.byteSize) bytes  (\(group.members.count) copies)")
                for member in group.members.prefix(12) {
                    print("    \(member.rootLabel)/\(member.relativePath) [\(member.role.rawValue)]")
                }
                if group.members.count > 12 {
                    print("    ... \(group.members.count - 12) more copies")
                }
            }
            if report.exactDuplicateGroups.count > 20 {
                print("  ... \(report.exactDuplicateGroups.count - 20) more groups; use --json for the full report")
            }
            print("")
        }

        if !report.eventSuggestions.isEmpty {
            print("Suggested event folders:")
            for event in report.eventSuggestions.prefix(20) {
                print("  \(event.eventID)  \(event.suggestedFolderName)  (\(event.assetIDs.count) assets)")
            }
            if report.eventSuggestions.count > 20 {
                print("  ... \(report.eventSuggestions.count - 20) more; use --json for the full report")
            }
            print("")
        }

        if !report.warnings.isEmpty {
            print("Warnings:")
            for warning in report.warnings.prefix(30) {
                let location = warning.relativePath.map { " [\($0)]" } ?? ""
                print("  \(warning.code)\(location): \(warning.message)")
            }
            if report.warnings.count > 30 {
                print("  ... \(report.warnings.count - 30) more; use --json for the full report")
            }
            print("")
        }

        print("No media files were modified.")
    }

    private static func runDoctor() {
        print("PhotoArchiveKit \(version)")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Default catalog: \(PhotoArchivePaths.defaultCatalogURL.path)")
        print("")
        print("Required core dependencies:")
        print("  Apple AVFoundation/ImageIO/CryptoKit: available")
        print("  SQLite: linked by the Swift package")
        print("")
        print("Optional interoperability tools (not bundled):")
        for tool in ["rclone", "czkawka_cli", "exiftool", "ffprobe"] {
            if let path = executablePath(tool) {
                print("  \(tool): \(path)")
            } else {
                print("  \(tool): not found")
            }
        }
    }

    private static func executablePath(_ name: String) -> String? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in environmentPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(name)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
    }

    private static func value(
        after option: String,
        at index: inout Int,
        in arguments: [String]
    ) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw CLIError("Missing value after \(option).")
        }
        return arguments[index]
    }

    private static func printHelp() {
        print(
            """
            PhotoArchiveKit \(version)

            A local-first, session-based photo archive scanner for macOS.

            Usage:
              photoarchive scan [options] ROOT...
              photoarchive doctor
              photoarchive version

            The initial release is read-only. It catalogs files, validates Live Photo
            relationships, finds exact duplicate groups locally, and proposes time-based
            event folders. It never sends media, identifiers, or hashes to a server.

            Run 'photoarchive scan --help' for scan options.
            """
        )
    }

    private static func printScanHelp() {
        print(
            """
            Usage:
              photoarchive scan [options] ROOT...

            Root options (repeatable):
              --inbox PATH       Register an Inbox root
              --archive PATH     Register an archive root
              --import PATH      Register an import/export staging root
              --reference PATH   Register a read-only comparison root

            Bare ROOT arguments are treated as Inbox roots.

            Other options:
              --catalog PATH             SQLite catalog path
              --json                     Print the full sanitized JSON report
              --no-exact-duplicates      Skip local SHA-256 duplicate comparisons
              --event-gap-hours NUMBER   Start a new event after this gap (default: 6)
              --jobs NUMBER              Concurrent metadata probes, 1-64
              --help                     Show this help

            The JSON report includes file paths and opaque group IDs, but never raw
            hashes or Live Photo content identifiers.
            """
        )
    }

    private static func writeStandardError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

private struct CLIError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
