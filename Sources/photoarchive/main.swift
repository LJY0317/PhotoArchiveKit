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
                try await runScan(arguments, mode: .scan)
            case "plan":
                try await runScan(arguments, mode: .plan)
            case "quarantine":
                try await runScan(arguments, mode: .quarantine)
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

    private enum WorkflowMode {
        case scan
        case plan
        case quarantine
    }

    private static func runScan(_ arguments: [String], mode: WorkflowMode) async throws {
        var catalogURL = PhotoArchivePaths.defaultCatalogURL
        var outputJSON = false
        var outputAgentJSON = false
        var computeExactDuplicates = true
        var exactDuplicateEngine = ExactDuplicateEngine.automatic
        var eventGapHours = 6.0
        var maxConcurrency = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
        var quarantineTargetURL: URL?
        var applyQuarantine = false
        var roots: [ScanRoot] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--catalog":
                catalogURL = fileURL(try value(after: argument, at: &index, in: arguments))
            case "--json":
                outputJSON = true
            case "--agent-json":
                outputAgentJSON = true
            case "--no-exact-duplicates":
                computeExactDuplicates = false
            case "--exact-engine":
                let raw = try value(after: argument, at: &index, in: arguments)
                guard let engine = ExactDuplicateEngine(rawValue: raw.lowercased()) else {
                    throw CLIError("--exact-engine must be one of: automatic, native, czkawka.")
                }
                exactDuplicateEngine = engine
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
            case "--to":
                guard mode == .quarantine else {
                    throw CLIError("--to is only valid with the quarantine command.")
                }
                quarantineTargetURL = fileURL(try value(after: argument, at: &index, in: arguments))
            case "--apply":
                guard mode == .quarantine else {
                    throw CLIError("--apply is only valid with the quarantine command.")
                }
                applyQuarantine = true
            case "--inbox":
                let path = try value(after: argument, at: &index, in: arguments)
                roots.append(ScanRoot(url: fileURL(path), kind: .inbox))
            case "--local":
                let path = try value(after: argument, at: &index, in: arguments)
                roots.append(ScanRoot(
                    url: fileURL(path),
                    kind: .inbox,
                    provenance: .localLibrary
                ))
            case "--apple":
                let path = try value(after: argument, at: &index, in: arguments)
                roots.append(ScanRoot(
                    url: fileURL(path),
                    kind: .importSource,
                    provenance: .appleDirect
                ))
            case "--takeout":
                let path = try value(after: argument, at: &index, in: arguments)
                roots.append(ScanRoot(
                    url: fileURL(path),
                    kind: .importSource,
                    provenance: .googleTakeout
                ))
            case "--google-web":
                let path = try value(after: argument, at: &index, in: arguments)
                roots.append(ScanRoot(
                    url: fileURL(path),
                    kind: .importSource,
                    provenance: .googleWeb
                ))
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
                let command: String
                switch mode {
                case .scan: command = "scan"
                case .plan: command = "plan"
                case .quarantine: command = "quarantine"
                }
                printScanHelp(command: command)
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
        if outputJSON && outputAgentJSON {
            throw CLIError("Use either --json or --agent-json, not both.")
        }

        let scanner = try ArchiveScanner(catalogURL: catalogURL)
        let report = try await scanner.scan(
            roots: roots,
            options: ScanOptions(
                computeExactDuplicates: computeExactDuplicates,
                exactDuplicateEngine: exactDuplicateEngine,
                eventGap: eventGapHours * 60 * 60,
                maxConcurrentProbes: maxConcurrency
            )
        )

        if mode == .plan {
            let plan = ReconciliationPlanner.makePlan(from: report)
            if outputAgentJSON {
                try printJSON(AgentSafeReconciliationPlan(plan: plan))
            } else if outputJSON {
                try printJSON(plan)
            } else {
                printReconciliationPlan(plan)
            }
            return
        }

        if mode == .quarantine {
            guard computeExactDuplicates else {
                throw CLIError("quarantine requires exact duplicate comparison.")
            }
            guard let quarantineTargetURL else {
                throw CLIError("quarantine requires --to PATH.")
            }
            let plan = ReconciliationPlanner.makePlan(from: report)
            let quarantineReport: QuarantineReport
            if applyQuarantine {
                quarantineReport = try QuarantineExecutor.apply(
                    report: report,
                    plan: plan,
                    targetURL: quarantineTargetURL
                )
            } else {
                quarantineReport = try QuarantineExecutor.preflight(
                    report: report,
                    plan: plan,
                    targetURL: quarantineTargetURL
                )
            }

            if outputAgentJSON {
                try printJSON(AgentSafeQuarantineReport(report: quarantineReport))
            } else if outputJSON {
                try printJSON(quarantineReport)
            } else {
                printQuarantineReport(quarantineReport)
            }
            return
        }

        if outputAgentJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(AgentSafeScanReport(report: report))
            print(String(decoding: data, as: UTF8.self))
        } else if outputJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            printHumanReport(report)
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func printReconciliationPlan(_ plan: ReconciliationPlan) {
        print("PhotoArchiveKit read-only reconciliation plan")
        print("Policy: \(plan.policy)")
        print("Session: \(plan.sessionID)")
        print("Automatic redundant resources: \(plan.summary.automaticRedundantResourceCount)")
        print("Review resources: \(plan.summary.reviewResourceCount)")
        print("Automatic items: \(plan.summary.automaticItemCount)")
        print("Review items: \(plan.summary.reviewItemCount)")
        print("")

        for item in plan.items.prefix(80) {
            print("[\(item.itemID)] \(item.decision.rawValue) \(item.kind.rawValue)")
            print("  subject: \(item.subjectID)")
            print("  reason: \(item.reason.rawValue)")
            if let preferredRootID = item.preferredRootID {
                print("  preferred root: \(preferredRootID)")
            }
            for resource in item.candidateResources.prefix(12) {
                print("  candidate: \(resource.rootLabel)/\(resource.relativePath) [\(resource.role.rawValue)]")
            }
            if item.candidateResources.count > 12 {
                print("  ... \(item.candidateResources.count - 12) more candidate resources")
            }
        }
        if plan.items.count > 80 {
            print("... \(plan.items.count - 80) more items; use --json locally or --agent-json for an AI agent")
        }
        print("")
        print("No media files were modified.")
    }

    private static func printQuarantineReport(_ report: QuarantineReport) {
        print(report.dryRun ? "PhotoArchiveKit quarantine dry run" : "PhotoArchiveKit quarantine applied")
        print("Session: \(report.sessionID)")
        print("Target: \(report.targetPath)")
        print("Items: \(report.itemCount)")
        print("Resources: \(report.resourceCount)")
        print("Bytes: \(report.totalBytes)")
        if let manifestPath = report.manifestPath {
            print("Manifest: \(manifestPath)")
        }
        print("")
        if report.dryRun {
            print("No media files were modified. Re-run with --apply only after reviewing this dry run.")
        } else {
            print("Only automatic exact-duplicate candidates were moved. Review candidates were untouched.")
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
            print("  provenance: \(root.provenance.rawValue)")
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
              photoarchive plan [options] ROOT...
              photoarchive quarantine --to PATH [--apply] [options] ROOT...
              photoarchive doctor
              photoarchive version

            Scan and plan are read-only. Quarantine also defaults to a verified dry run;
            only an explicit --apply moves automatic exact-duplicate candidates into a
            user-supplied local quarantine directory. It never permanently deletes media.

            Run 'photoarchive scan --help', 'photoarchive plan --help', or
            'photoarchive quarantine --help' for options.
            """
        )
    }

    private static func printScanHelp(command: String) {
        let quarantineOptions = command == "quarantine"
            ? "  --to PATH                  Existing quarantine directory (required)\n  --apply                    Move verified AUTO candidates; default is dry-run\n"
            : ""
        print(
            """
            Usage:
              photoarchive \(command) [options] ROOT...

            Root options (repeatable):
              --inbox PATH       Register an Inbox root with unknown provenance
              --local PATH       Register a mixed local/iPhone-derived library root
              --apple PATH       Register a direct Apple/iPhone import root
              --takeout PATH     Register a Google Photos Takeout root
              --google-web PATH  Register a Google Photos web-download root
              --archive PATH     Register an archive root
              --import PATH      Register an import/export staging root
              --reference PATH   Register a read-only comparison root

            Nested roots are assigned to the most specific registered root. For example,
            --local ~/Pictures plus --takeout ~/Pictures/Takeout scans Takeout only once
            and preserves its Google Takeout provenance.

            Bare ROOT arguments are treated as Inbox roots.

            Other options:
              --catalog PATH             SQLite catalog path
              --json                     Print the full local diagnostic JSON report
              --agent-json               Print path-free, metadata-minimized JSON for AI agents
              --no-exact-duplicates      Skip exact duplicate comparisons
              --exact-engine ENGINE      automatic, native, or czkawka (default: automatic)
              --event-gap-hours NUMBER   Start a new event after this gap (default: 6)
              --jobs NUMBER              Concurrent metadata probes, 1-64
            \(quarantineOptions)  --help                     Show this help

            quarantine never acts on REVIEW items. Before --apply it freshly re-hashes
            every candidate against a preferred exact counterpart; Live Photo candidate
            sets are fully verified before any resource in that item is moved. A local
            restore manifest is written under the quarantine directory.

            automatic exact mode currently uses the native SHA-256 path. The explicit
            czkawka engine uses Czkawka cache/prehash candidate discovery and then native
            SHA-256 verification; it is intended for cross-checking until benchmarking
            shows that a future integration avoids duplicate work.

            --json is for local human diagnostics and includes paths. AI agents should
            use --agent-json, which omits catalog/root/file paths, filenames, byte sizes,
            capture timestamps, folder suggestions, raw hashes, and Live Photo identifiers.
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
