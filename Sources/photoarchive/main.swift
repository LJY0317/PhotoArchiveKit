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
            case "archive-coverage":
                try await runScan(arguments, mode: .archiveCoverage)
            case "plan":
                try await runScan(arguments, mode: .plan)
            case "organize-plan":
                try await runScan(arguments, mode: .organizePlan)
            case "archive-plan":
                try await runScan(arguments, mode: .archivePlan)
            case "archive-copy":
                try await runArchiveCopy(arguments)
            case "archive-index":
                try await runArchiveIndex(arguments)
            case "organize":
                try await runScan(arguments, mode: .organize)
            case "quarantine":
                try await runScan(arguments, mode: .quarantine)
            case "restore-quarantine":
                try runRestoreQuarantine(arguments)
            case "cleanup-empty-dirs":
                try runCleanupEmptyDirectories(arguments)
            case "catalog":
                try runCatalog(arguments)
            case "root":
                try runRoot(arguments)
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

    private static func runArchiveCopy(_ arguments: [String]) async throws {
        var catalogURL: URL?
        var destinationURL: URL?
        var rootBindings: [ArchiveCopyRootBinding] = []
        var apply = false
        var outputJSON = false
        var outputAgentJSON = false
        var planPaths: [String] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--catalog":
                catalogURL = fileURL(try value(after: argument, at: &index, in: arguments))
            case "--to":
                destinationURL = fileURL(try value(after: argument, at: &index, in: arguments))
            case "--bind-root":
                rootBindings.append(try parseArchiveCopyRootBinding(
                    try value(after: argument, at: &index, in: arguments)
                ))
            case "--apply":
                apply = true
            case "--json":
                outputJSON = true
            case "--agent-json":
                outputAgentJSON = true
            case "--help", "-h":
                printArchiveCopyHelp()
                return
            default:
                if argument.hasPrefix("-") {
                    throw CLIError("Unknown archive-copy option: \(argument)")
                }
                planPaths.append(argument)
            }
            index += 1
        }

        guard planPaths.count == 1 else {
            throw CLIError("archive-copy requires exactly one immutable archive plan path.")
        }
        if outputJSON && outputAgentJSON {
            throw CLIError("Use either --json or --agent-json, not both.")
        }

        let planURL = fileURL(planPaths[0])
        let report: ArchiveCopyReport
        if apply {
            report = try await ArchiveCopyExecutor.apply(
                planURL: planURL,
                rootBindings: rootBindings,
                destinationURL: destinationURL,
                catalogURL: catalogURL
            )
        } else {
            report = try ArchiveCopyExecutor.preflight(
                planURL: planURL,
                rootBindings: rootBindings,
                destinationURL: destinationURL,
                catalogURL: catalogURL
            )
        }

        if outputAgentJSON {
            try printJSON(AgentSafeArchiveCopyReport(report: report))
        } else if outputJSON {
            try printJSON(report)
        } else {
            printArchiveCopyReport(report)
        }
    }

    private static func runArchiveIndex(_ arguments: [String]) async throws {
        var catalogURL = PhotoArchivePaths.defaultCatalogURL
        var apply = false
        var outputJSON = false
        var outputAgentJSON = false
        var reuseHashCache = true
        var showProgress = true
        var maxConcurrency = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
        var paths: [String] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--catalog":
                catalogURL = fileURL(try value(after: argument, at: &index, in: arguments))
            case "--apply":
                apply = true
            case "--json":
                outputJSON = true
            case "--agent-json":
                outputAgentJSON = true
            case "--fresh":
                reuseHashCache = false
            case "--no-progress":
                showProgress = false
            case "--jobs":
                let raw = try value(after: argument, at: &index, in: arguments)
                guard let value = Int(raw), value > 0, value <= 64 else {
                    throw CLIError("--jobs must be between 1 and 64.")
                }
                maxConcurrency = value
            case "--help", "-h":
                printArchiveIndexHelp()
                return
            default:
                if argument.hasPrefix("-") {
                    throw CLIError("Unknown archive-index option: \(argument)")
                }
                paths.append(argument)
            }
            index += 1
        }

        guard paths.count == 1 else {
            throw CLIError("archive-index requires exactly one existing archive root path.")
        }
        if outputJSON && outputAgentJSON {
            throw CLIError("Use either --json or --agent-json, not both.")
        }

        let progressRenderer = ScanProgressRenderer(enabled: showProgress)
        defer { progressRenderer.finish() }
        let progressHandler: ScanProgressHandler?
        if showProgress {
            progressHandler = { progress in
                progressRenderer.render(progress)
            }
        } else {
            progressHandler = nil
        }
        let report = try await ArchiveRootIndexer.run(
            rootURL: fileURL(paths[0]),
            catalogURL: catalogURL,
            writeSnapshot: apply,
            reuseHashCache: reuseHashCache,
            maxConcurrentProbes: maxConcurrency,
            progressHandler: progressHandler
        )
        if outputAgentJSON {
            try printJSON(AgentSafeArchiveRootInventoryReport(report: report))
        } else if outputJSON {
            try printJSON(report)
        } else {
            printArchiveRootInventoryReport(report)
        }
    }

    private static func runRestoreQuarantine(_ arguments: [String]) throws {
        var catalogURL = PhotoArchivePaths.defaultCatalogURL
        var apply = false
        var outputJSON = false
        var outputAgentJSON = false
        var manifestPaths: [String] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--catalog":
                catalogURL = fileURL(try value(after: argument, at: &index, in: arguments))
            case "--apply":
                apply = true
            case "--json":
                outputJSON = true
            case "--agent-json":
                outputAgentJSON = true
            case "--help", "-h":
                printRestoreQuarantineHelp()
                return
            default:
                if argument.hasPrefix("-") {
                    throw CLIError("Unknown restore-quarantine option: \(argument)")
                }
                manifestPaths.append(argument)
            }
            index += 1
        }

        guard manifestPaths.count == 1 else {
            throw CLIError("restore-quarantine requires exactly one manifest.json path.")
        }
        if outputJSON && outputAgentJSON {
            throw CLIError("Use either --json or --agent-json, not both.")
        }

        let manifestURL = fileURL(manifestPaths[0])
        let report = try apply
            ? QuarantineRestoreExecutor.apply(manifestURL: manifestURL, catalogURL: catalogURL)
            : QuarantineRestoreExecutor.preflight(manifestURL: manifestURL, catalogURL: catalogURL)

        if outputAgentJSON {
            try printJSON(AgentSafeQuarantineRestoreReport(report: report))
        } else if outputJSON {
            try printJSON(report)
        } else {
            printQuarantineRestoreReport(report)
        }
    }

    private static func runCleanupEmptyDirectories(_ arguments: [String]) throws {
        var catalogURL = PhotoArchivePaths.defaultCatalogURL
        var apply = false
        var outputJSON = false
        var outputAgentJSON = false
        var manifestPaths: [String] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--catalog":
                catalogURL = fileURL(try value(after: argument, at: &index, in: arguments))
            case "--apply":
                apply = true
            case "--json":
                outputJSON = true
            case "--agent-json":
                outputAgentJSON = true
            case "--help", "-h":
                printCleanupEmptyDirectoriesHelp()
                return
            default:
                if argument.hasPrefix("-") {
                    throw CLIError("Unknown cleanup-empty-dirs option: \(argument)")
                }
                manifestPaths.append(argument)
            }
            index += 1
        }

        guard manifestPaths.count == 1 else {
            throw CLIError("cleanup-empty-dirs requires exactly one organization.json path.")
        }
        if outputJSON && outputAgentJSON {
            throw CLIError("Use either --json or --agent-json, not both.")
        }

        let manifestURL = fileURL(manifestPaths[0])
        let report = try apply
            ? EmptyDirectoryCleanupExecutor.apply(
                organizationManifestURL: manifestURL,
                catalogURL: catalogURL
            )
            : EmptyDirectoryCleanupExecutor.preflight(
                organizationManifestURL: manifestURL,
                catalogURL: catalogURL
            )

        if outputAgentJSON {
            try printJSON(AgentSafeEmptyDirectoryCleanupReport(report: report))
        } else if outputJSON {
            try printJSON(report)
        } else {
            printEmptyDirectoryCleanupReport(report)
        }
    }

    private static func runCatalog(_ arguments: [String]) throws {
        guard let action = arguments.first else {
            printCatalogHelp()
            return
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "export":
            var catalogURL = PhotoArchivePaths.defaultCatalogURL
            var outputURL: URL?
            var outputJSON = false
            var outputAgentJSON = false
            var index = 0
            while index < rest.count {
                let argument = rest[index]
                switch argument {
                case "--catalog":
                    catalogURL = fileURL(try value(after: argument, at: &index, in: rest))
                case "--output":
                    outputURL = fileURL(try value(after: argument, at: &index, in: rest))
                case "--json":
                    outputJSON = true
                case "--agent-json":
                    outputAgentJSON = true
                case "--help", "-h":
                    printCatalogExportHelp()
                    return
                default:
                    throw CLIError("Unknown catalog export option: \(argument)")
                }
                index += 1
            }
            guard let outputURL else {
                throw CLIError("catalog export requires --output PATH.")
            }
            if outputJSON && outputAgentJSON {
                throw CLIError("Use either --json or --agent-json, not both.")
            }
            let report = try CatalogSnapshotExporter.export(
                catalogURL: catalogURL,
                outputURL: outputURL
            )
            if outputAgentJSON {
                try printJSON(AgentSafeCatalogSnapshotReport(report: report))
            } else if outputJSON {
                try printJSON(report)
            } else {
                printCatalogSnapshotReport(report)
            }

        case "restore":
            var destinationURL: URL?
            var apply = false
            var outputJSON = false
            var outputAgentJSON = false
            var snapshotPaths: [String] = []
            var rootBindings: [CatalogRootBinding] = []
            var index = 0
            while index < rest.count {
                let argument = rest[index]
                switch argument {
                case "--to":
                    destinationURL = fileURL(try value(after: argument, at: &index, in: rest))
                case "--bind-root":
                    rootBindings.append(try parseCatalogRootBinding(
                        try value(after: argument, at: &index, in: rest)
                    ))
                case "--apply":
                    apply = true
                case "--json":
                    outputJSON = true
                case "--agent-json":
                    outputAgentJSON = true
                case "--help", "-h":
                    printCatalogRestoreHelp()
                    return
                default:
                    if argument.hasPrefix("-") {
                        throw CLIError("Unknown catalog restore option: \(argument)")
                    }
                    snapshotPaths.append(argument)
                }
                index += 1
            }
            guard snapshotPaths.count == 1 else {
                throw CLIError("catalog restore requires exactly one snapshot JSONL path.")
            }
            guard let destinationURL else {
                throw CLIError("catalog restore requires --to PATH.")
            }
            if outputJSON && outputAgentJSON {
                throw CLIError("Use either --json or --agent-json, not both.")
            }
            let snapshotURL = fileURL(snapshotPaths[0])
            let report = try apply
                ? CatalogSnapshotRestorer.apply(
                    snapshotURL: snapshotURL,
                    destinationCatalogURL: destinationURL,
                    rootBindings: rootBindings
                )
                : CatalogSnapshotRestorer.preflight(
                    snapshotURL: snapshotURL,
                    destinationCatalogURL: destinationURL,
                    rootBindings: rootBindings
                )
            if outputAgentJSON {
                try printJSON(AgentSafeCatalogSnapshotReport(report: report))
            } else if outputJSON {
                try printJSON(report)
            } else {
                printCatalogSnapshotReport(report)
            }

        case "help", "--help", "-h":
            printCatalogHelp()
        default:
            throw CLIError("Unknown catalog action: \(action)")
        }
    }

    private static func runRoot(_ arguments: [String]) throws {
        guard let action = arguments.first else {
            printRootHelp()
            return
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "inspect":
            guard rest.count == 1 else { throw CLIError("Usage: photoarchive root inspect PATH") }
            let rootURL = fileURL(rest[0])
            if let marker = try RootMarkerStore.readIfPresent(at: rootURL) {
                print("PhotoArchiveKit root marker: present")
                print("Schema: \(marker.schemaVersion)")
            } else {
                print("PhotoArchiveKit root marker: absent")
            }
        case "init":
            var apply = false
            var paths: [String] = []
            for argument in rest {
                if argument == "--apply" { apply = true }
                else if argument == "--help" || argument == "-h" { printRootHelp(); return }
                else if argument.hasPrefix("-") { throw CLIError("Unknown root init option: \(argument)") }
                else { paths.append(argument) }
            }
            guard paths.count == 1 else { throw CLIError("Usage: photoarchive root init [--apply] PATH") }
            let rootURL = fileURL(paths[0])
            if try RootMarkerStore.readIfPresent(at: rootURL) != nil {
                print("PhotoArchiveKit root marker already present. No change needed.")
                return
            }
            if !apply {
                print("Dry run: a .photoarchive-root marker would be created in the supplied root.")
                print("No files were modified. Re-run with --apply to create it.")
                return
            }
            _ = try RootMarkerStore.create(at: rootURL)
            print("Created .photoarchive-root marker.")
            print("Media files were not modified.")
        case "help", "--help", "-h":
            printRootHelp()
        default:
            throw CLIError("Unknown root action: \(action)")
        }
    }

    private enum WorkflowMode {
        case scan
        case archiveCoverage
        case plan
        case organizePlan
        case archivePlan
        case organize
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
        var showProgress = true
        var singletonLeafOnly = false
        var quarantineTargetURL: URL?
        var archiveDestinationURL: URL?
        var archivePlanOutputURL: URL?
        var applyMutation = false
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
            case "--no-progress":
                showProgress = false
            case "--singleton-leaf-only":
                guard mode == .organize || mode == .organizePlan else {
                    throw CLIError("--singleton-leaf-only is only valid with organize or organize-plan.")
                }
                singletonLeafOnly = true
            case "--to":
                guard mode == .quarantine || mode == .archivePlan else {
                    throw CLIError("--to is only valid with quarantine or archive-plan.")
                }
                let url = fileURL(try value(after: argument, at: &index, in: arguments))
                if mode == .archivePlan { archiveDestinationURL = url }
                else { quarantineTargetURL = url }
            case "--output":
                guard mode == .archivePlan else {
                    throw CLIError("--output is only valid with archive-plan.")
                }
                archivePlanOutputURL = fileURL(try value(after: argument, at: &index, in: arguments))
            case "--apply":
                guard mode == .quarantine || mode == .organize else {
                    throw CLIError("--apply is only valid with the quarantine or organize command.")
                }
                applyMutation = true
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
                case .archiveCoverage: command = "archive-coverage"
                case .plan: command = "plan"
                case .organizePlan: command = "organize-plan"
                case .archivePlan: command = "archive-plan"
                case .organize: command = "organize"
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
        if mode == .archiveCoverage && roots.count < 2 {
            throw CLIError("archive-coverage requires at least two roots to compare.")
        }
        if mode == .archiveCoverage && !computeExactDuplicates {
            throw CLIError("archive-coverage requires exact duplicate comparison.")
        }
        if outputJSON && outputAgentJSON {
            throw CLIError("Use either --json or --agent-json, not both.")
        }

        let progressRenderer = ScanProgressRenderer(enabled: showProgress)
        defer { progressRenderer.finish() }
        let progressHandler: ScanProgressHandler?
        if showProgress {
            progressHandler = { progress in
                progressRenderer.render(progress)
            }
        } else {
            progressHandler = nil
        }
        let scanner = try ArchiveScanner(catalogURL: catalogURL)
        let report = try await scanner.scan(
            roots: roots,
            options: ScanOptions(
                computeExactDuplicates: computeExactDuplicates,
                computeArchiveIntegrityPreconditions: mode == .archivePlan,
                exactDuplicateEngine: exactDuplicateEngine,
                eventGap: eventGapHours * 60 * 60,
                maxConcurrentProbes: maxConcurrency,
                progressHandler: progressHandler
            )
        )

        if mode == .archiveCoverage {
            let coverage = ArchiveCoverageBuilder.makeReport(from: report)
            if outputAgentJSON {
                try printJSON(AgentSafeArchiveCoverageReport(report: coverage))
            } else if outputJSON {
                try printJSON(coverage)
            } else {
                printArchiveCoverageReport(coverage)
            }
            return
        }

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

        if mode == .organizePlan {
            let basePlan = OrganizationPlanner.makePlan(from: report)
            let plan = singletonLeafOnly
                ? OrganizationPlanner.cleanSingletonLeafPlan(from: basePlan, report: report)
                : basePlan
            if outputAgentJSON {
                try printJSON(AgentSafeOrganizationPlan(plan: plan))
            } else if outputJSON {
                try printJSON(plan)
            } else {
                printOrganizationPlan(plan)
            }
            return
        }

        if mode == .archivePlan {
            guard computeExactDuplicates else {
                throw CLIError("archive-plan requires exact duplicate comparison.")
            }
            guard let archiveDestinationURL else {
                throw CLIError("archive-plan requires --to PATH.")
            }
            guard let archivePlanOutputURL else {
                throw CLIError("archive-plan requires --output PATH.")
            }
            let plan = try scanner.makeArchivePlan(
                from: report,
                destinationURL: archiveDestinationURL
            )
            try ArchivePlanStore.write(plan, to: archivePlanOutputURL)
            if outputAgentJSON {
                try printJSON(AgentSafeArchivePlan(plan: plan))
            } else if outputJSON {
                try printJSON(plan)
            } else {
                printArchivePlan(plan, outputURL: archivePlanOutputURL)
            }
            return
        }

        if mode == .organize {
            let basePlan = OrganizationPlanner.makePlan(from: report)
            let plan = singletonLeafOnly
                ? OrganizationPlanner.cleanSingletonLeafPlan(from: basePlan, report: report)
                : basePlan
            let applyReport = applyMutation
                ? try OrganizationExecutor.apply(
                    report: report,
                    plan: plan,
                    commitCatalog: { try scanner.commitAppliedOrganizationPlan(plan) }
                )
                : try OrganizationExecutor.preflight(report: report, plan: plan)
            if outputAgentJSON {
                try printJSON(AgentSafeOrganizationApplyReport(report: applyReport))
            } else if outputJSON {
                try printJSON(applyReport)
            } else {
                printOrganizationApplyReport(applyReport)
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
            if applyMutation {
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

    private static func printOrganizationPlan(_ plan: OrganizationPlan) {
        print("PhotoArchiveKit read-only organization plan")
        print("Policy: \(plan.policy)")
        print("Session: \(plan.sessionID)")
        print("Automatic items: \(plan.summary.automaticItemCount)")
        print("Automatic resources: \(plan.summary.automaticResourceCount)")
        print("Review items: \(plan.summary.reviewItemCount)")
        print("Review resources: \(plan.summary.reviewResourceCount)")
        print("")
        for item in plan.items.prefix(80) {
            print("[\(item.itemID)] \(item.decision.rawValue) \(item.kind.rawValue) \(item.reason.rawValue)")
            for move in item.moves.prefix(4) {
                print("  \(move.sourceRelativePath) -> \(move.destinationRelativePath) [\(move.role.rawValue)]")
            }
        }
        if plan.items.count > 80 {
            print("... \(plan.items.count - 80) more items; use --json locally or --agent-json for an AI agent")
        }
        print("")
        print("No media files were modified.")
    }

    private static func printArchivePlan(_ plan: ArchivePlan, outputURL: URL) {
        print("PhotoArchiveKit immutable archive plan")
        print("Plan: \(plan.planID)")
        print("Policy: \(plan.policy)")
        print("Automatic items: \(plan.summary.automaticItemCount)")
        print("Automatic resources: \(plan.summary.automaticResourceCount)")
        print("Review items: \(plan.summary.reviewItemCount)")
        print("Review resources: \(plan.summary.reviewResourceCount)")
        print("Plan file: \(outputURL.path)")
        print("")
        print("The plan file is local-private: it contains source/destination paths, exact byte sizes, and expected SHA-256 preconditions.")
        print("No media files were modified.")
    }

    private static func printArchiveCopyReport(_ report: ArchiveCopyReport) {
        print(report.dryRun ? "PhotoArchiveKit archive copy dry run" : "PhotoArchiveKit archive copy")
        print("Plan: \(report.planID)")
        print("Automatic items: \(report.automaticItemCount)")
        print("Automatic resources: \(report.automaticResourceCount)")
        print("Review items skipped: \(report.reviewItemCount)")
        print("Already final: \(report.alreadyFinalResourceCount)")
        print("Verified staging: \(report.stagedResourceCount)")
        print("Copy required: \(report.copyRequiredResourceCount)")
        print("Catalog committed: \(report.catalogCommitted)")
        print("Portable snapshot written: \(report.snapshotWritten)")
        print("Manifest: \(report.manifestPath)")
        print("Snapshot: \(report.snapshotPath)")
        print("")
        if report.dryRun {
            print("No archive media files were created. Re-run with --apply only after reviewing this preflight.")
        } else if report.filesModified {
            print("AUTO resources were copied and byte-verified; source media was not moved or deleted.")
        } else {
            print("The recorded archive copy was already complete and verified; no files changed.")
        }
    }

    private static func printArchiveRootInventoryReport(_ report: ArchiveRootInventoryReport) {
        print(report.snapshotWritten
            ? "PhotoArchiveKit archive root indexed and portable inventory written"
            : "PhotoArchiveKit archive root indexed")
        print("Root: \(report.rootID)")
        print("Resources: \(report.resourceCount)")
        print("Media resources: \(report.mediaResourceCount)")
        print("Folders represented: \(report.folderCount)")
        print("Exact hashes available: \(report.exactHashResourceCount)")
        print("Exact hashes reused from cache: \(report.reusedExactHashCount)")
        print("Portable inventory: \(report.inventoryPath)")
        print("")
        if report.snapshotWritten {
            print("Only the hidden portable inventory was written to the archive root; media files were not moved, renamed, or deleted.")
        } else {
            print("No files were written to the archive root. Re-run with --apply to write the portable inventory after reviewing the index.")
        }
    }

    private static func printArchiveCoverageReport(_ report: ArchiveCoverageReport) {
        print("PhotoArchiveKit archive coverage")
        print("Session: \(report.sessionID)")
        print("Media files modified: \(report.filesModified)")
        print("")

        for root in report.roots {
            print("[\(root.rootID)] \(root.label)")
            print("  media resources: \(root.mediaResourceCount)")
            print("  exact-covered elsewhere: \(root.exactCoveredElsewhereResourceCount)")
            print("  exact-unique to this root: \(root.exactUniqueToRootResourceCount)")
            print("  Live Photo occurrences: \(root.livePhotos.occurrenceCount)")
            print("    complete elsewhere: \(root.livePhotos.completeElsewhere)")
            print("    split/ambiguous elsewhere: \(root.livePhotos.splitOrAmbiguousElsewhere)")
            print("    still only elsewhere: \(root.livePhotos.stillOnlyElsewhere)")
            print("    video only elsewhere: \(root.livePhotos.videoOnlyElsewhere)")
            print("    no counterpart elsewhere: \(root.livePhotos.noCounterpart)")
            for peer in root.exactPeers {
                print("  exact peer \(peer.peerRootID): \(peer.sharedExactGroupCount) groups, \(peer.coveredResourceCount) local resources covered")
            }
            print("")
        }

        if !report.pairwiseExact.isEmpty {
            print("Pairwise exact overlap:")
            for pair in report.pairwiseExact {
                print("  \(pair.leftRootID) <-> \(pair.rightRootID): \(pair.sharedExactGroupCount) groups")
            }
            print("")
        }

        if !report.notices.isEmpty {
            print("Notices:")
            for notice in report.notices.prefix(30) {
                let location = notice.relativePath.map { " [\($0)]" } ?? ""
                print("  \(notice.code)\(location): \(notice.message)")
            }
            if report.notices.count > 30 {
                print("  ... \(report.notices.count - 30) more; use --json for the full report")
            }
        }
    }

    private static func printOrganizationApplyReport(_ report: OrganizationApplyReport) {
        print(report.dryRun ? "PhotoArchiveKit organization dry run" : "PhotoArchiveKit organization applied")
        print("Session: \(report.sessionID)")
        print("Items: \(report.itemCount)")
        print("Resources: \(report.resourceCount)")
        if let manifestPath = report.manifestPath {
            print("Manifest: \(manifestPath)")
        }
        print("")
        if report.dryRun {
            print("No media files were modified. A stable root marker is required before this dry run can succeed.")
        } else {
            print("Only automatic organization items were moved. Review items and custom filenames were untouched.")
        }
    }

    private static func printEmptyDirectoryCleanupReport(_ report: EmptyDirectoryCleanupReport) {
        print(report.dryRun ? "PhotoArchiveKit empty-directory cleanup dry run" : "PhotoArchiveKit empty-directory cleanup applied")
        print("Session: \(report.sessionID)")
        print("Directories: \(report.directoryCount)")
        if let cleanupManifestPath = report.cleanupManifestPath {
            print("Cleanup manifest: \(cleanupManifestPath)")
        }
        print("")
        if report.dryRun {
            print("No directories were removed. Re-run with --apply only after reviewing this preflight.")
        } else if report.filesModified {
            print("Only empty directories derived from the completed organization manifest were removed.")
        } else {
            print("No removable empty directories remained.")
        }
    }

    private static func printQuarantineRestoreReport(_ report: QuarantineRestoreReport) {
        print(report.dryRun ? "PhotoArchiveKit quarantine restore dry run" : "PhotoArchiveKit quarantine restored")
        print("Session: \(report.sessionID)")
        print("Items: \(report.itemCount)")
        print("Resources: \(report.resourceCount)")
        print("Bytes: \(report.totalBytes)")
        print("Manifest: \(report.manifestPath)")
        if let restoreStatePath = report.restoreStatePath {
            print("Restore state: \(restoreStatePath)")
        }
        print("")
        if report.dryRun {
            print("No files were modified. Re-run with --apply only after reviewing this restore preflight.")
        } else {
            print("Quarantined resources were restored to their recorded source locations.")
        }
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

    private static func printCatalogSnapshotReport(_ report: CatalogSnapshotReport) {
        switch report.operation {
        case .export:
            print("PhotoArchiveKit portable catalog snapshot exported")
        case .restore:
            print(report.dryRun
                ? "PhotoArchiveKit catalog restore dry run"
                : "PhotoArchiveKit catalog snapshot restored")
        }
        print("Records: \(report.recordCount)")
        print("Roots: \(report.rootCount)")
        print("Resources: \(report.resourceCount)")
        print("Logical assets: \(report.assetCount)")
        print("Collections: \(report.collectionCount)")
        if report.operation == .restore {
            print("Unbound roots: \(report.unboundRootCount)")
        }
        print("Snapshot: \(report.snapshotPath)")
        print("Catalog: \(report.catalogPath)")
        print("")
        if report.operation == .export {
            print("The JSONL snapshot omits absolute root paths, raw hashes, Live Photo fingerprints, filesystem IDs, capture timestamps, provider object IDs, and generated scan/event caches.")
            print("It remains local-private because portable restore records include relative paths, original filenames, and collection labels. Do not treat it as agent-safe or share-safe data.")
        } else if report.dryRun {
            print("No catalog was created. Re-run with --apply after reviewing root bindings.")
        } else {
            print("A new catalog was created from the portable semantic snapshot. Existing catalogs are never overwritten by restore.")
        }
        print("No media files were modified.")
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
        print("Exact hashes reused from cache: \(report.summary.reusedExactHashCount)")
        print("Automatic event suggestions: \(report.summary.eventSuggestionCount)")
        print("Notices: \(report.notices.count)")
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

        if !report.notices.isEmpty {
            print("Notices:")
            for notice in report.notices.prefix(30) {
                let location = notice.relativePath.map { " [\($0)]" } ?? ""
                print("  \(notice.code)\(location): \(notice.message)")
            }
            if report.notices.count > 30 {
                print("  ... \(report.notices.count - 30) more; use --json for the full report")
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

    private static func parseCatalogRootBinding(_ value: String) throws -> CatalogRootBinding {
        guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
            throw CLIError("--bind-root must use ROOT_ID=PATH.")
        }
        let rootID = String(value[..<separator])
        let path = String(value[value.index(after: separator)...])
        guard !path.isEmpty else {
            throw CLIError("--bind-root must use ROOT_ID=PATH.")
        }
        return CatalogRootBinding(rootID: rootID, url: fileURL(path))
    }

    private static func parseArchiveCopyRootBinding(_ value: String) throws -> ArchiveCopyRootBinding {
        guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
            throw CLIError("--bind-root must use ROOT_ID=PATH.")
        }
        let rootID = String(value[..<separator])
        let path = String(value[value.index(after: separator)...])
        guard !path.isEmpty else {
            throw CLIError("--bind-root must use ROOT_ID=PATH.")
        }
        return ArchiveCopyRootBinding(rootID: rootID, url: fileURL(path))
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
              photoarchive archive-coverage [options] ROOT...
              photoarchive plan [options] ROOT...
              photoarchive organize-plan [options] ROOT...
              photoarchive archive-plan --to PATH --output PLAN [options] ROOT...
              photoarchive archive-copy [--apply] [--to PATH] [--bind-root ROOT_ID=PATH] PLAN
              photoarchive archive-index [--apply] [options] PATH
              photoarchive organize [--apply] [options] ROOT...
              photoarchive quarantine --to PATH [--apply] [options] ROOT...
              photoarchive restore-quarantine [--apply] [--catalog PATH] MANIFEST
              photoarchive cleanup-empty-dirs [--apply] [--catalog PATH] ORGANIZATION_MANIFEST
              photoarchive catalog export --output PATH [--catalog PATH]
              photoarchive catalog restore [--apply] --to PATH [--bind-root ROOT_ID=PATH] SNAPSHOT
              photoarchive root inspect PATH
              photoarchive root init [--apply] PATH
              photoarchive doctor
              photoarchive version

            Scan, archive-coverage, and plan are media-read-only. Quarantine also defaults to a verified dry run;
            only an explicit --apply moves automatic exact-duplicate candidates into a
            user-supplied local quarantine directory. It never permanently deletes media.

            Run 'photoarchive scan --help', 'photoarchive archive-coverage --help', 'photoarchive plan --help',
            'photoarchive organize-plan --help', 'photoarchive archive-plan --help',
            'photoarchive archive-copy --help',
            'photoarchive archive-index --help',
            'photoarchive organize --help',
            'photoarchive quarantine --help', 'photoarchive restore-quarantine --help',
            'photoarchive cleanup-empty-dirs --help', or 'photoarchive catalog --help'
            for options.
            """
        )
    }

    private static func printArchiveCopyHelp() {
        print(
            """
            Usage:
              photoarchive archive-copy [options] PLAN

            Options:
              --catalog PATH             Override the SQLite catalog recorded by the plan
              --to PATH                  Rebind a moved archive destination with the same marker
              --bind-root ROOT_ID=PATH   Rebind a moved source root with the same marker; repeatable
              --apply                    Copy, verify, finalize, catalog, and snapshot; default is dry-run
              --json                     Print local diagnostic JSON including private state paths
              --agent-json               Print privacy-minimized counts/status without paths or hashes
              --help                     Show this help

            archive-copy accepts only AUTO items from an immutable archive plan. It verifies
            current catalog evidence, source root markers, source bytes, destination marker,
            destination/staging bytes, and Live Photo item completeness. Apply copies through
            .photoarchive staging, supports idempotent resume, then scans the verified archive
            destination into the catalog and writes a portable catalog snapshot. Source media
            is never deleted or moved.
            """
        )
    }

    private static func printArchiveIndexHelp() {
        print(
            """
            Usage:
              photoarchive archive-index [options] PATH

            Options:
              --catalog PATH   Local authoritative SQLite catalog
              --jobs NUMBER    Concurrent metadata probes, 1-64
              --fresh          Ignore hash caches and re-read every media byte
              --no-progress    Disable scan progress output on stderr
              --apply          Write PATH/.photoarchive/inventory-v1.jsonl after indexing
              --json           Print local diagnostic JSON including the inventory path
              --agent-json     Print privacy-minimized counts/status without paths or hashes
              --help           Show this help

            archive-index treats PATH as a user-managed archive root. PATH must already have
            a stable .photoarchive-root marker. The scan recursively records existing folder
            hierarchy as user-authored collection semantics and computes exact hashes for all
            media resources. Unchanged files reuse the local SQLite hash cache; when present,
            the portable root inventory can also seed hashes after the drive is attached to a
            different computer. Cache evidence is only an accelerator: mutating workflows still
            perform fresh byte verification before acting. Use --fresh for a full periodic
            integrity pass that re-reads every media resource instead of trusting size/mtime.

            The command never moves, renames, or deletes media. Without --apply it also writes
            nothing to the archive root. --apply writes only the hidden portable inventory file.
            """
        )
    }

    private static func printCatalogHelp() {
        print(
            """
            Usage:
              photoarchive catalog export --output PATH [--catalog PATH] [--json|--agent-json]
              photoarchive catalog restore [--apply] --to PATH [--bind-root ROOT_ID=PATH] SNAPSHOT

            catalog export writes a versioned JSONL disaster-recovery snapshot of portable
            semantic state. It excludes absolute root paths, raw exact hashes, keyed Live
            Photo fingerprints, filesystem IDs, capture timestamps, provider object IDs,
            and generated scan/event caches. The snapshot is still local-private because it
            includes relative paths, original filenames, and collection labels required for
            restore. It is not an agent-safe/share-safe report.

            catalog restore validates the full snapshot by default and creates nothing.
            --apply creates a new SQLite catalog only; it refuses to overwrite an existing
            catalog. Repeated --bind-root ROOT_ID=PATH arguments reconnect unmarked roots to
            their current local directories. Roots with matching .photoarchive-root markers
            can be rebound by a later scan even when they are not explicitly bound here.
            """
        )
    }

    private static func printCatalogExportHelp() {
        print(
            """
            Usage:
              photoarchive catalog export --output PATH [options]

            Options:
              --catalog PATH   Source SQLite catalog (default: Application Support catalog)
              --output PATH    New JSONL snapshot path; existing files are never overwritten
              --json           Print local diagnostic JSON including snapshot/catalog paths
              --agent-json     Print only path-free snapshot counts/status
              --help           Show this help
            """
        )
    }

    private static func printCatalogRestoreHelp() {
        print(
            """
            Usage:
              photoarchive catalog restore [options] SNAPSHOT

            Options:
              --to PATH                  New SQLite catalog path (required)
              --bind-root ROOT_ID=PATH   Bind one snapshot root to a current local directory; repeatable
              --apply                    Create the restored catalog; default is dry-run
              --json                     Print local diagnostic JSON including local paths
              --agent-json               Print privacy-minimized counts/status without paths
              --help                     Show this help

            Restore never overwrites an existing catalog and never modifies media files.
            """
        )
    }

    private static func printCleanupEmptyDirectoriesHelp() {
        print(
            """
            Usage:
              photoarchive cleanup-empty-dirs [options] ORGANIZATION_MANIFEST

            Options:
              --catalog PATH   SQLite catalog containing resource location history
              --apply          Remove verified empty directories; default is dry-run
              --json           Print local diagnostic JSON, including directory paths
              --agent-json     Print privacy-minimized JSON without directory paths
              --help           Show this help

            Cleanup is intentionally narrow: it considers only source directories recorded
            by a completed organization manifest, confirms those source locations exist in
            local catalog history, requires the stable root marker, skips package/symlink
            boundaries, and removes only directories that are still literally empty when
            --apply runs. The registered root itself is never removed.
            """
        )
    }

    private static func printRestoreQuarantineHelp() {
        print(
            """
            Usage:
              photoarchive restore-quarantine [options] MANIFEST

            Options:
              --catalog PATH   SQLite catalog containing the original exact-file evidence
              --apply          Restore after full preflight; default is dry-run
              --json           Print local diagnostic JSON, including local manifest path
              --agent-json     Print privacy-minimized JSON without file paths or hashes
              --help           Show this help

            Restore accepts only a completed quarantine manifest. Before any move it verifies
            that every original source path is free, each quarantined resource is still a
            regular file of the expected size, and its fresh SHA-256 matches the original
            exact hash stored in the local catalog. Live Photo restore items must contain both
            still and paired-video roles. A failed apply rolls already restored resources back
            into quarantine. No permanent deletion is performed.
            """
        )
    }

    private static func printRootHelp() {
        print(
            """
            Usage:
              photoarchive root inspect PATH
              photoarchive root init [--apply] PATH

            root inspect reports whether PATH has a stable .photoarchive-root marker.
            root init is a dry run by default. --apply creates only the hidden marker file
            and never modifies media bytes. A later scan binds the marker to the catalog
            so the same root can be recognized after it is moved.
            """
        )
    }

    private static func printScanHelp(command: String) {
        let mutationOptions: String
        if command == "quarantine" {
            mutationOptions = "  --to PATH                  Existing quarantine directory (required)\n  --apply                    Move verified AUTO candidates; default is dry-run\n"
        } else if command == "archive-plan" {
            mutationOptions = "  --to PATH                  Existing marker-initialized archive destination (required)\n  --output PATH              New local-private immutable plan JSON path (required)\n"
        } else if command == "organize" {
            mutationOptions = "  --apply                    Rename/flatten verified AUTO organization items; default is dry-run\n  --singleton-leaf-only      Limit to clean nested folders containing exactly one planned logical asset\n"
        } else if command == "organize-plan" {
            mutationOptions = "  --singleton-leaf-only      Limit to clean nested folders containing exactly one planned logical asset\n"
        } else {
            mutationOptions = ""
        }
        let operationNotes: String
        if command == "quarantine" {
            operationNotes = """
            quarantine never acts on REVIEW items. Before --apply it freshly re-hashes
            every candidate against a preferred exact counterpart; Live Photo candidate
            sets are fully verified before any resource in that item is moved. A local
            restore manifest is written under the quarantine directory.
            """
        } else if command == "archive-plan" {
            operationNotes = """
            archive-plan is media-read-only but writes one immutable local-private plan file.
            It requires a stable marker on the destination. Automatic source representations
            also require stable source markers and are freshly verified with full SHA-256
            before their source/destination paths and byte preconditions are frozen in the plan.
            Review items are never given automatic copy authority.
            """
        } else if command == "organize" {
            operationNotes = """
            organize never changes custom filenames or REVIEW items. Apply requires a
            stable .photoarchive-root marker. Live Photo still+paired-video resources use
            one destination basename, and post-move filesystem identity/size is verified.
            A local restore manifest is written under Application Support.
            """
        } else if command == "archive-coverage" {
            operationNotes = """
            archive-coverage requires at least two registered roots and performs a current
            media-read-only scan before reporting current exact cross-root coverage. It also
            summarizes whether each Live Photo occurrence has a complete, partial, ambiguous,
            or missing counterpart on other roots. It never moves, renames, or deletes media.
            """
        } else {
            operationNotes = ""
        }
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
              --no-progress              Disable scan progress output on stderr
            \(mutationOptions)  --help                     Show this help

            \(operationNotes)

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

private final class ScanProgressRenderer: @unchecked Sendable {
    private let enabled: Bool
    private let terminal: Bool
    private let lock = NSLock()
    private var lastStage: ScanProgressStage?
    private var lastPercentBucket = -1
    private var lastCompleted = -1
    private var lastEmission = Date.distantPast
    private var hasRenderedTTYLine = false

    init(enabled: Bool) {
        self.enabled = enabled
        self.terminal = isatty(STDERR_FILENO) == 1
    }

    func render(_ progress: ScanProgress) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let stageChanged = lastStage != progress.stage
        let completed = progress.totalUnitCount.map { progress.completedUnitCount >= $0 } ?? false
        let percent = progress.totalUnitCount.flatMap { total -> Int? in
            guard total > 0 else { return nil }
            return min(100, max(0, Int((Double(progress.completedUnitCount) / Double(total)) * 100.0)))
        }
        let percentBucket = percent.map { $0 / 5 } ?? -1

        let shouldEmit: Bool
        if terminal {
            shouldEmit = stageChanged || completed || now.timeIntervalSince(lastEmission) >= 0.10
        } else if progress.totalUnitCount == nil {
            shouldEmit = stageChanged || now.timeIntervalSince(lastEmission) >= 5.0
        } else {
            shouldEmit = stageChanged
                || completed
                || percentBucket != lastPercentBucket
                || now.timeIntervalSince(lastEmission) >= 10.0
        }
        guard shouldEmit, stageChanged || progress.completedUnitCount != lastCompleted else { return }

        let text = formatted(progress)
        if terminal {
            writeStandardError("\r\u{001B}[2K\(text)")
            hasRenderedTTYLine = true
        } else {
            writeStandardError("progress: \(text)\n")
        }
        lastStage = progress.stage
        lastPercentBucket = percentBucket
        lastCompleted = progress.completedUnitCount
        lastEmission = now
    }

    func finish() {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        if terminal, hasRenderedTTYLine {
            writeStandardError("\n")
            hasRenderedTTYLine = false
        }
    }

    private func formatted(_ progress: ScanProgress) -> String {
        let label: String
        switch progress.stage {
        case .enumerating: label = "Enumerating"
        case .metadata: label = "Reading metadata"
        case .hashingDuplicates: label = "Hashing duplicate candidates"
        case .hashingIntegrity: label = "Verifying archive hashes"
        case .cataloging: label = "Updating catalog"
        case .finalizing: label = "Finalizing"
        }

        guard let total = progress.totalUnitCount else {
            return "\(label)  \(progress.completedUnitCount) found"
        }
        guard total > 0 else {
            return "\(label)  done"
        }
        let percent = min(100, max(0, Int(
            (Double(progress.completedUnitCount) / Double(total)) * 100.0
        )))
        return "\(label)  \(progress.completedUnitCount)/\(total)  \(percent)%"
    }

    private func writeStandardError(_ text: String) {
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
