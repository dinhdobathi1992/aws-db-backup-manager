// Headless, read-mostly entry point for checking inventory output against
// the AWS CLI without launching the app: a port of v0.1's cli.go
// (ADBM_CLI=1 go run . <command>). Same commands, flags, JSON shape, exit
// codes and stderr lines. save-account only touches local settings;
// create-snapshot exists to prove the read-only gate refuses it.
//
// Usage:
//   adbm-cli list-accounts
//   adbm-cli save-account --name <name> --profile <profile> --regions <r1,r2> [--readonly]
//   adbm-cli list-databases --account <id>
//   adbm-cli get-backup-plan --account <id> --db <identifier>
//   adbm-cli list-snapshots --account <id> --db <identifier>
//   adbm-cli list-schedules --account <id>
//   adbm-cli list-activity --account <id> [--limit N]
//   adbm-cli create-snapshot --account <id> --db <identifier>
//   adbm-cli measure-load --account <id>
import ADBMCore
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func emit<T: Encodable>(_ value: T) {
    do {
        var data = try GoJSON.encode(value)
        data.append(0x0A) // json.Encoder's trailing newline
        FileHandle.standardOutput.write(data)
    } catch { fail("error: \(error.localizedDescription)", code: 1) }
}

func count(_ n: Int) { FileHandle.standardError.write(Data("count: \(n)\n".utf8)) }

/// Go's flag package rules: -flag or --flag, value as "=v" or the next
/// argument, bool flags take only "=v"; parsing stops at the first
/// non-flag argument or a bare "--".
struct Flags {
    static let stringFlags: Set = ["account", "name", "profile", "regions", "db", "limit"]
    static let boolFlags: Set = ["readonly"]
    var values: [String: String] = [:]
    var readOnly = false

    static let usageText = """
    Usage of flags:
      -account string
        \taccount id, as shown by list-accounts
      -db string
        \tdatabase identifier
      -limit int
        \tmax activity entries (default 50)
      -name string
        \taccount display name
      -profile string
        \tlocal AWS CLI profile name
      -readonly
        \tmark the account read-only: write actions are refused before any AWS call
      -regions string
        \tcomma-separated AWS regions
    """

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.count > 1, a.hasPrefix("-") else { break }
            if a == "--" { break }
            var name = String(a.dropFirst(a.hasPrefix("--") ? 2 : 1))
            if name.hasPrefix("-") || name.hasPrefix("=") { fail("bad flag syntax: \(a)\n\(Self.usageText)", code: 2) }
            var value: String?
            if let eq = name.firstIndex(of: "=") {
                value = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            if name == "h" || name == "help" { fail(Self.usageText, code: 0) }
            if Self.boolFlags.contains(name) {
                switch value?.lowercased() {
                case nil, "1", "t", "true": readOnly = true
                case "0", "f", "false": readOnly = false
                default: fail("invalid boolean value \"\(value!)\" for -\(name): parse error\n\(Self.usageText)", code: 2)
                }
            } else if Self.stringFlags.contains(name) {
                if value == nil {
                    i += 1
                    guard i < args.count else { fail("flag needs an argument: -\(name)\n\(Self.usageText)", code: 2) }
                    value = args[i]
                }
                values[name] = value
            } else {
                fail("flag provided but not defined: -\(name)\n\(Self.usageText)", code: 2)
            }
            i += 1
        }
        if let l = values["limit"], Int(l) == nil {
            fail("invalid value \"\(l)\" for flag -limit: parse error\n\(Self.usageText)", code: 2)
        }
    }

    subscript(_ k: String) -> String { values[k] ?? "" }
    var limit: Int { Int(values["limit"] ?? "") ?? 50 }
}

let argv = CommandLine.arguments
if argv.count < 2 {
    fail("usage: list-accounts | save-account | list-databases | get-backup-plan | list-snapshots | list-schedules | list-activity | create-snapshot", code: 2)
}
let cmd = argv[1]
let flags = Flags(Array(argv.dropFirst(2)))
let service: any BackendService = ProcessInfo.processInfo.environment["ADBM_FIXTURES"] == "1"
    ? FixtureService() : AWSBackendService()

func run<T>(_ body: () async throws -> T) async -> T {
    do { return try await body() } catch { fail("error: \(error.localizedDescription)", code: 1) }
}

func requireAccount() -> String {
    if flags["account"].isEmpty { fail("--account is required", code: 2) }
    return flags["account"]
}

func requireAccountAndDB() -> (String, String) {
    if flags["account"].isEmpty || flags["db"].isEmpty { fail("--account and --db are required", code: 2) }
    return (flags["account"], flags["db"])
}

switch cmd {
case "save-account":
    if flags["name"].isEmpty || flags["profile"].isEmpty || flags["regions"].isEmpty {
        fail("--name, --profile and --regions are required", code: 2)
    }
    let account = Account(id: "", name: flags["name"], profile: flags["profile"],
                          regions: flags["regions"].components(separatedBy: ","), color: "", readOnly: flags.readOnly)
    emit(await run { try await service.saveAccount(account) })

case "list-accounts":
    emit(await run { try await service.listAccounts() })

case "list-databases":
    let id = requireAccount()
    let dbs = await run { try await service.listDatabases(id) }
    emit(dbs); count(dbs.count)

case "get-backup-plan":
    let (id, db) = requireAccountAndDB()
    emit(await run { try await service.getBackupPlan(id, db: db) })

case "list-snapshots":
    let (id, db) = requireAccountAndDB()
    let snaps = await run { try await service.listSnapshots(id, db: db) }
    emit(snaps); count(snaps.count)

case "list-schedules":
    let id = requireAccount()
    let s = await run { try await service.listSchedules(id) }
    emit(s); count(s.count)

case "list-activity":
    let id = requireAccount()
    let limit = flags.limit
    let a = await run { try await service.listActivity(id, limit: limit) }
    emit(a); count(a.count)

case "create-snapshot":
    let (id, db) = requireAccountAndDB()
    emit(await run { try await service.createSnapshot(CreateSnapshotReq(accountId: id, dbIdentifier: db)) })

case "measure-load":
    await measureLoad(accountId: requireAccount())

default:
    fail("unknown command: \(cmd)", code: 2)
}
