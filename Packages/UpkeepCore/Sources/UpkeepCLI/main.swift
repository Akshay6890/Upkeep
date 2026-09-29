import Foundation
import UpkeepCore

// Internal development harness for the Upkeep engine.
//
//   upkeep-cli scan [--category <name>]... [--json] [--dry-run]
//   upkeep-cli scan --large-files
//   upkeep-cli cleanup --dry-run [--category <name>]... [--include-review]
//   upkeep-cli categories
//
// Options for testing against a fixture tree instead of your real home folder:
//   --home <path>      use <path> as the home folder (disables tool detection)
//   --tmp <path>       use <path> as the per-user temporary folder
//   --dev-folder <path> add a developer folder for __pycache__ scanning
//
// This tool never deletes anything: `cleanup` only supports --dry-run.
// Real cleanup is only available in the app, behind explicit confirmation.

struct Arguments {
    var command: String?
    var categories: Set<CleanupCategory> = []
    var json = false
    var dryRun = false
    var includeReview = false
    var largeFiles = false
    var home: String?
    var tmp: String?
    var devFolders: [String] = []
}

let aliases: [String: CleanupCategory] = [
    "caches": .applicationCaches, "cache": .applicationCaches,
    "logs": .logs, "crash": .crashReports, "crashreports": .crashReports,
    "temp": .temporaryFiles, "tmp": .temporaryFiles, "trash": .trash,
    "xcode": .xcode, "homebrew": .homebrew, "brew": .homebrew,
    "swiftpm": .swiftPackageManager, "spm": .swiftPackageManager,
    "node": .nodePackageManagers, "npm": .nodePackageManagers,
    "python": .pythonCaches, "large": .largeFiles,
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

func parse(_ raw: [String]) -> Arguments {
    var args = Arguments()
    var iterator = raw.makeIterator()
    while let token = iterator.next() {
        switch token {
        case "--category", "-c":
            guard let value = iterator.next() else { fail("--category needs a value") }
            let key = value.lowercased()
            if let category = aliases[key] ?? CleanupCategory.allCases.first(where: { $0.rawValue.lowercased() == key }) {
                args.categories.insert(category)
            } else {
                fail("unknown category '\(value)'. Run `upkeep-cli categories`.")
            }
        case "--json": args.json = true
        case "--dry-run": args.dryRun = true
        case "--include-review": args.includeReview = true
        case "--large-files": args.largeFiles = true
        case "--home":
            guard let value = iterator.next() else { fail("--home needs a path") }
            args.home = value
        case "--tmp":
            guard let value = iterator.next() else { fail("--tmp needs a path") }
            args.tmp = value
        case "--dev-folder":
            guard let value = iterator.next() else { fail("--dev-folder needs a path") }
            args.devFolders.append(value)
        case "--help", "-h":
            args.command = "help"
        default:
            if args.command == nil && !token.hasPrefix("-") { args.command = token } else { fail("unexpected argument '\(token)'") }
        }
    }
    return args
}

func makeEnvironment(_ args: Arguments) -> ScanEnvironment {
    let devFolders = args.devFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
    var env = ScanEnvironment.current(developerFolders: devFolders)
    if let home = args.home {
        env.homeDirectory = URL(fileURLWithPath: home, isDirectory: true)
        env.homebrewExecutableCandidates = []
        env.xcodeApplicationCandidates = []
        env.toolSearchDirectories = []
        env.xcrunURL = URL(fileURLWithPath: "/nonexistent/xcrun")
    }
    if let tmp = args.tmp {
        env.temporaryDirectory = URL(fileURLWithPath: tmp, isDirectory: true)
    }
    return env
}

func printResult(_ result: ScanResult, environment: ScanEnvironment) {
    for category in result.categories {
        guard category.isAvailable else {
            print("\(category.category.title): not available (\(category.unavailableReason ?? ""))")
            continue
        }
        print("\(category.category.title): \(Formatting.bytes(category.cleanableSize)) in \(Formatting.plural(category.cleanableItems.count, "item"))")
        for item in category.items.prefix(25) {
            let risk = item.risk.shortTitle.padding(toLength: 9, withPad: " ", startingAt: 0)
            print("  [\(risk)] \(Formatting.bytes(item.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(environment.displayPath(item.url))")
        }
        if category.items.count > 25 { print("  …and \(category.items.count - 25) more") }
        for issue in category.issues { print("  ! \(issue.message)") }
    }
    print("")
    print("Reclaimable: \(Formatting.bytes(result.reclaimableBytes)) (safe \(Formatting.bytes(result.reclaimableBytes(risk: .safe))), review \(Formatting.bytes(result.reclaimableBytes(risk: .review))))")
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

let args = parse(Array(CommandLine.arguments.dropFirst()))
let environment = makeEnvironment(args)
var settings = UpkeepSettings()
settings.showProtectedItems = true
let engine = CleanupEngine(environment: environment, settings: settings)
let categories: Set<CleanupCategory>? = args.categories.isEmpty ? nil : args.categories

let semaphore = DispatchSemaphore(value: 0)
Task {
    defer { semaphore.signal() }
    switch args.command {
    case "categories":
        for category in CleanupCategory.allCases {
            print("\(category.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0)) \(category.title)")
        }
    case "scan":
        if args.largeFiles || categories == [.largeFiles] {
            let result = await engine.scanLargeFiles()
            if args.json { printJSON(result) } else {
                for item in result.items {
                    print("\(Formatting.bytes(item.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(environment.displayPath(item.url))")
                }
                for issue in result.issues { print("! \(issue.message)") }
            }
            return
        }
        let result = await engine.scan(categories: categories)
        if args.json { printJSON(result) } else { printResult(result, environment: environment) }
    case "cleanup":
        guard args.dryRun else {
            fail("upkeep-cli only supports `cleanup --dry-run`. Use the Upkeep app to clean.")
        }
        let result = await engine.scan(categories: categories)
        let selection = result.allItems.filter { $0.isCleanable && ($0.risk == .safe || args.includeReview) }
        let plan = engine.preview(selection)
        let report = await engine.cleanup(plan, options: CleanupOptions(dryRun: true, moveToTrash: false))
        if args.json { printJSON(report) } else {
            for group in plan.groups {
                print("\(group.category.title) — \(Formatting.bytes(group.totalBytes))")
            }
            for warning in plan.warnings { print("! \(warning)") }
            print("")
            for entry in report.results {
                print("  \(entry.outcome.summary) — \(environment.displayPath(entry.item.url))")
            }
            print("")
            print("Dry run: would reclaim \(Formatting.bytes(report.wouldReclaimBytes)); \(report.skipped.count) skipped, \(report.failed.count) failed. Nothing was deleted.")
        }
    default:
        print("""
        usage: upkeep-cli scan [--category <name>]... [--json] [--large-files]
               upkeep-cli cleanup --dry-run [--category <name>]... [--include-review] [--json]
               upkeep-cli categories
        options: --home <path>  --tmp <path>  --dev-folder <path>
        """)
    }
}
semaphore.wait()
