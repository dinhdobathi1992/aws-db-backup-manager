// FixtureService: an in-memory BackendService returning realistic fake data,
// a port of internal/api/fixture.go. It exists only for UI development and
// manual review; the app selects it only when ADBM_FIXTURES=1. It never talks
// to AWS. Unlike v0.1 it also honours an account's readOnly flag on writes.
import Foundation

public struct FixtureError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public final class FixtureService: BackendService, @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: [Account]
    private var databases: [String: [Database]]          // keyed by account id
    private var snapshots: [String: [Snapshot]]          // keyed by db identifier
    private var plans: [String: BackupPlanSummary]       // keyed by db identifier
    private var schedules: [String: [Schedule]]          // keyed by account id
    private var activity: [String: [Activity]]           // keyed by account id

    /// Builds the fixture dataset: 2 accounts, 6 databases across them, with
    /// a mix of manual, automated and AWS Backup sources.
    public init() {
        let now = Date()
        func ago(_ hours: Double) -> String { RFC3339.string(now.addingTimeInterval(-hours * 3600)) }
        func agoMin(_ minutes: Double) -> String { RFC3339.string(now.addingTimeInterval(-minutes * 60)) }
        func ahead(_ hours: Double) -> String { RFC3339.string(now.addingTimeInterval(hours * 3600)) }

        accounts = [
            Account(id: "acct-prod", name: "Production", profile: "prod", regions: ["us-east-1", "us-west-2"], color: "#2563eb"),
            Account(id: "acct-staging", name: "Staging", profile: "staging", regions: ["us-east-1"], color: "#16a34a"),
        ]

        databases = [
            "acct-prod": [
                Database(accountId: "acct-prod", region: "us-east-1", kind: .cluster, identifier: "prod-orders-cluster",
                         engine: "aurora-postgresql", engineVersion: "15.4", class: "", status: "available",
                         endpoint: "prod-orders-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com", multiAz: true,
                         storageGb: 200, encrypted: true, backupRetentionDays: 7, preferredBackupWindow: "03:00-03:30",
                         latestRestorableTime: agoMin(2), tags: ["env": "prod", "team": "orders"],
                         members: [
                            ClusterMember(identifier: "prod-orders-cluster-instance-1", isWriter: true, class: "db.r6g.large",
                                          status: "available", availabilityZone: "us-east-1a", engineVersion: "15.4"),
                            ClusterMember(identifier: "prod-orders-cluster-instance-2", isWriter: false, class: "db.r6g.large",
                                          status: "available", availabilityZone: "us-east-1b", engineVersion: "15.4"),
                            ClusterMember(identifier: "prod-orders-cluster-instance-3", isWriter: false, class: "db.r6g.large",
                                          status: "available", availabilityZone: "us-east-1c", engineVersion: "15.4"),
                         ]),
                Database(accountId: "acct-prod", region: "us-east-1", kind: .instance, identifier: "prod-reporting-pg",
                         engine: "postgres", engineVersion: "16.1", class: "db.m6g.xlarge", status: "available",
                         endpoint: "prod-reporting-pg.xxxxx.us-east-1.rds.amazonaws.com", multiAz: true,
                         storageGb: 500, encrypted: true, backupRetentionDays: 14, preferredBackupWindow: "02:00-02:30",
                         latestRestorableTime: agoMin(5), tags: ["env": "prod", "team": "data"]),
                Database(accountId: "acct-prod", region: "us-west-2", kind: .instance, identifier: "prod-users-mysql",
                         engine: "mysql", engineVersion: "8.0.35", class: "db.r6g.large", status: "available",
                         endpoint: "prod-users-mysql.xxxxx.us-west-2.rds.amazonaws.com", multiAz: false,
                         storageGb: 100, encrypted: true, backupRetentionDays: 7, preferredBackupWindow: "05:00-05:30",
                         latestRestorableTime: agoMin(10), tags: ["env": "prod", "team": "identity"]),
                Database(accountId: "acct-prod", region: "us-east-1", kind: .cluster, identifier: "prod-billing-cluster",
                         engine: "aurora-mysql", engineVersion: "3.05.2", class: "", status: "available",
                         endpoint: "prod-billing-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com", multiAz: true,
                         storageGb: 300, encrypted: true, backupRetentionDays: 30, preferredBackupWindow: "01:00-01:30",
                         latestRestorableTime: agoMin(1), tags: ["env": "prod", "team": "billing"],
                         members: [
                            ClusterMember(identifier: "prod-billing-writer", isWriter: true, class: "db.r6g.xlarge",
                                          status: "available", availabilityZone: "us-east-1a", engineVersion: "3.05.2"),
                            ClusterMember(identifier: "prod-billing-reader", isWriter: false, class: "db.r6g.large",
                                          status: "modifying", availabilityZone: "us-east-1b", engineVersion: "3.05.2"),
                         ]),
            ],
            "acct-staging": [
                Database(accountId: "acct-staging", region: "us-east-1", kind: .instance, identifier: "staging-orders-pg",
                         engine: "postgres", engineVersion: "16.1", class: "db.t4g.medium", status: "available",
                         endpoint: "staging-orders-pg.xxxxx.us-east-1.rds.amazonaws.com", multiAz: false,
                         storageGb: 50, encrypted: true, backupRetentionDays: 1, preferredBackupWindow: "04:00-04:30",
                         latestRestorableTime: agoMin(20), tags: ["env": "staging"]),
                Database(accountId: "acct-staging", region: "us-east-1", kind: .instance, identifier: "staging-sandbox-mysql",
                         engine: "mysql", engineVersion: "8.0.35", class: "db.t4g.small", status: "stopped",
                         endpoint: "staging-sandbox-mysql.xxxxx.us-east-1.rds.amazonaws.com", multiAz: false,
                         storageGb: 20, encrypted: false, backupRetentionDays: 1, preferredBackupWindow: "06:00-06:30",
                         latestRestorableTime: nil, tags: ["env": "staging"]),
            ],
        ]

        snapshots = [
            "prod-orders-cluster": [
                Snapshot(id: "prod-orders-cluster-manual-2026-11-10", arn: "arn:aws:rds:us-east-1:111111111111:cluster-snapshot:prod-orders-cluster-manual-2026-11-10", dbIdentifier: "prod-orders-cluster", kind: .cluster, source: .manual, status: "available", createdAt: ago(72), sizeGb: 200, encrypted: true, engine: "aurora-postgresql"),
                Snapshot(id: "rds:prod-orders-cluster-2026-11-13-03-00", arn: "arn:aws:rds:us-east-1:111111111111:cluster-snapshot:rds:prod-orders-cluster-2026-11-13-03-00", dbIdentifier: "prod-orders-cluster", kind: .cluster, source: .automated, status: "available", createdAt: ago(17), sizeGb: 200, encrypted: true, engine: "aurora-postgresql"),
                Snapshot(id: "backup-rp-orders-0001", arn: "arn:aws:backup:us-east-1:111111111111:recovery-point:orders-0001", dbIdentifier: "prod-orders-cluster", kind: .cluster, source: .awsBackup, status: "completed", createdAt: ago(41), sizeGb: 200, encrypted: true, engine: "aurora-postgresql", vaultName: "prod-vault"),
            ],
            "prod-reporting-pg": [
                Snapshot(id: "rds:prod-reporting-pg-2026-11-13-02-00", arn: "arn:aws:rds:us-east-1:111111111111:snapshot:rds:prod-reporting-pg-2026-11-13-02-00", dbIdentifier: "prod-reporting-pg", kind: .instance, source: .automated, status: "available", createdAt: ago(18), sizeGb: 500, encrypted: true, engine: "postgres"),
            ],
            "prod-users-mysql": [
                Snapshot(id: "prod-users-mysql-manual-pre-migration", arn: "arn:aws:rds:us-west-2:111111111111:snapshot:prod-users-mysql-manual-pre-migration", dbIdentifier: "prod-users-mysql", kind: .instance, source: .manual, status: "available", createdAt: ago(240), sizeGb: 100, encrypted: true, engine: "mysql"),
                Snapshot(id: "rds:prod-users-mysql-2026-11-13-05-00", arn: "arn:aws:rds:us-west-2:111111111111:snapshot:rds:prod-users-mysql-2026-11-13-05-00", dbIdentifier: "prod-users-mysql", kind: .instance, source: .automated, status: "available", createdAt: ago(15), sizeGb: 100, encrypted: true, engine: "mysql"),
            ],
            "prod-billing-cluster": [
                Snapshot(id: "backup-rp-billing-0007", arn: "arn:aws:backup:us-east-1:111111111111:recovery-point:billing-0007", dbIdentifier: "prod-billing-cluster", kind: .cluster, source: .awsBackup, status: "completed", createdAt: ago(16), sizeGb: 300, encrypted: true, engine: "aurora-mysql", vaultName: "prod-vault"),
                Snapshot(id: "rds:prod-billing-cluster-2026-11-13-01-00", arn: "arn:aws:rds:us-east-1:111111111111:cluster-snapshot:rds:prod-billing-cluster-2026-11-13-01-00", dbIdentifier: "prod-billing-cluster", kind: .cluster, source: .automated, status: "available", createdAt: ago(19), sizeGb: 300, encrypted: true, engine: "aurora-mysql"),
            ],
            "staging-orders-pg": [
                Snapshot(id: "rds:staging-orders-pg-2026-11-13-04-00", arn: "arn:aws:rds:us-east-1:222222222222:snapshot:rds:staging-orders-pg-2026-11-13-04-00", dbIdentifier: "staging-orders-pg", kind: .instance, source: .automated, status: "available", createdAt: ago(16), sizeGb: 50, encrypted: true, engine: "postgres"),
            ],
            "staging-sandbox-mysql": [
                Snapshot(id: "staging-sandbox-mysql-manual-before-stop", arn: "arn:aws:rds:us-east-1:222222222222:snapshot:staging-sandbox-mysql-manual-before-stop", dbIdentifier: "staging-sandbox-mysql", kind: .instance, source: .manual, status: "available", createdAt: ago(500), sizeGb: 20, encrypted: false, engine: "mysql"),
            ],
        ]

        plans = [
            "prod-orders-cluster": BackupPlanSummary(
                db: "prod-orders-cluster",
                manual: .init(count: 1, latest: ago(72)),
                automated: .init(retention: 7, window: "03:00-03:30", earliest: ago(168), latest: ago(17)),
                awsBackup: [AWSBackupPlanRef(planId: "plan-orders", planName: "orders-daily", ruleName: "daily-3am", cron: "cron(0 3 * * ? *)", lifecycle: "delete-after-35-days", vault: "prod-vault")]),
            "prod-reporting-pg": BackupPlanSummary(
                db: "prod-reporting-pg",
                manual: .init(count: 0),
                automated: .init(retention: 14, window: "02:00-02:30", earliest: ago(336), latest: ago(18)),
                awsBackup: []),
            "prod-users-mysql": BackupPlanSummary(
                db: "prod-users-mysql",
                manual: .init(count: 1, latest: ago(240)),
                automated: .init(retention: 7, window: "05:00-05:30", earliest: ago(168), latest: ago(15)),
                awsBackup: []),
            "prod-billing-cluster": BackupPlanSummary(
                db: "prod-billing-cluster",
                manual: .init(count: 0),
                automated: .init(retention: 30, window: "01:00-01:30", earliest: ago(720), latest: ago(19)),
                awsBackup: [AWSBackupPlanRef(planId: "plan-billing", planName: "billing-compliance", ruleName: "daily-1am", cron: "cron(0 1 * * ? *)", lifecycle: "delete-after-365-days", vault: "prod-vault")]),
            "staging-orders-pg": BackupPlanSummary(
                db: "staging-orders-pg",
                manual: .init(count: 0),
                automated: .init(retention: 1, window: "04:00-04:30", earliest: ago(24), latest: ago(16)),
                awsBackup: []),
            "staging-sandbox-mysql": BackupPlanSummary(
                db: "staging-sandbox-mysql",
                manual: .init(count: 1, latest: ago(500)),
                automated: .init(retention: 1, window: "06:00-06:30"),
                awsBackup: []),
        ]

        schedules = [
            "acct-prod": [
                Schedule(source: .automatedWindow, db: "prod-orders-cluster", expression: "03:00-03:30 UTC daily", nextRun: ahead(7), retention: 7),
                Schedule(source: .automatedWindow, db: "prod-reporting-pg", expression: "02:00-02:30 UTC daily", nextRun: ahead(6), retention: 14),
                Schedule(source: .awsBackupRule, db: "prod-orders-cluster", expression: "cron(0 3 * * ? *)", nextRun: ahead(7), retention: 35),
                Schedule(source: .awsBackupRule, db: "prod-billing-cluster", expression: "cron(0 1 * * ? *)", nextRun: ahead(5), retention: 365),
            ],
            "acct-staging": [
                Schedule(source: .automatedWindow, db: "staging-orders-pg", expression: "04:00-04:30 UTC daily", nextRun: ahead(8), retention: 1),
            ],
        ]

        activity = [
            "acct-prod": [
                Activity(time: ago(17), source: .rdsEvent, db: "prod-orders-cluster", action: "automated-snapshot", status: "completed", message: "Automated backup finished"),
                Activity(time: ago(16), source: .backupJob, db: "prod-billing-cluster", action: "backup-job", status: "completed", message: "AWS Backup job completed to prod-vault"),
                Activity(time: ago(72), source: .app, db: "prod-orders-cluster", action: "create-snapshot", status: "completed", message: "Manual snapshot requested from AWS DB Backup Manager"),
            ],
            "acct-staging": [
                Activity(time: ago(16), source: .rdsEvent, db: "staging-orders-pg", action: "automated-snapshot", status: "completed", message: "Automated backup finished"),
            ],
        ]
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    /// Looks up the account and applies the read-only write gate. Caller holds the lock.
    private func writableAccount(_ accountId: String) throws {
        guard let account = accounts.first(where: { $0.id == accountId }) else {
            throw FixtureError("account \"\(accountId)\" not found")
        }
        try requireWritable(account)
    }

    // MARK: Accounts

    public func listAccounts() async throws -> [Account] { locked { accounts } }

    public func saveAccount(_ account: Account) async throws -> Account {
        locked {
            if let i = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[i] = account
            } else {
                accounts.append(account)
            }
            return account
        }
    }

    public func testAccount(_ accountId: String) async throws -> AccountStatus {
        try locked {
            guard let a = accounts.first(where: { $0.id == accountId }) else {
                throw FixtureError("account \"\(accountId)\" not found")
            }
            return AccountStatus(accountId: a.id, arn: "arn:aws:iam::111111111111:user/\(a.profile)",
                                 awsAccountId: "111111111111", state: .ok, message: "fixture data")
        }
    }

    public func ssoLogin(_ accountId: String) async throws -> AccountStatus {
        try await testAccount(accountId)
    }

    // MARK: Read model

    public func listDatabases(_ accountId: String) async throws -> [Database] {
        locked { databases[accountId] ?? [] }
    }

    public func getBackupPlan(_ accountId: String, db: String) async throws -> BackupPlanSummary {
        try locked {
            guard let plan = plans[db] else { throw FixtureError("no backup plan for database \"\(db)\"") }
            return plan
        }
    }

    public func listSnapshots(_ accountId: String, db: String) async throws -> [Snapshot] {
        locked { snapshots[db] ?? [] }
    }

    public func listSchedules(_ accountId: String) async throws -> [Schedule] {
        locked { schedules[accountId] ?? [] }
    }

    public func listActivity(_ accountId: String, limit: Int) async throws -> [Activity] {
        locked {
            let items = activity[accountId] ?? []
            return limit > 0 && limit < items.count ? Array(items.prefix(limit)) : items
        }
    }

    // MARK: Writes

    public func refresh(_ accountId: String) async {}

    public func createSnapshot(_ req: CreateSnapshotReq) async throws -> Snapshot {
        try locked {
            try writableAccount(req.accountId)
            let snap = Snapshot(id: req.snapshotName,
                                arn: "arn:aws:rds:\(req.region):111111111111:snapshot:\(req.snapshotName)",
                                dbIdentifier: req.dbIdentifier, kind: req.kind, source: .manual,
                                status: "creating", createdAt: RFC3339.string(Date()), encrypted: true)
            snapshots[req.dbIdentifier, default: []].append(snap)
            return snap
        }
    }

    public func startBackupJob(_ req: StartBackupJobReq) async throws -> Activity {
        try locked {
            try writableAccount(req.accountId)
            let act = Activity(time: RFC3339.string(Date()), source: .backupJob, db: req.dbIdentifier,
                               action: "backup-job", status: "running",
                               message: "On-demand AWS Backup job started to \(req.vaultName)")
            activity[req.accountId, default: []].append(act)
            return act
        }
    }

    public func createBackupPlan(_ req: CreateBackupPlanReq) async throws -> BackupPlanSummary {
        try locked {
            try writableAccount(req.accountId)
            var plan = plans[req.dbIdentifier] ?? BackupPlanSummary(db: req.dbIdentifier)
            plan.db = req.dbIdentifier
            plan.awsBackup.append(AWSBackupPlanRef(planId: "plan-\(req.planName)", planName: req.planName,
                                                   ruleName: req.ruleName, cron: req.cron,
                                                   lifecycle: "delete-after-\(req.retentionDays)-days",
                                                   vault: req.vaultName))
            plans[req.dbIdentifier] = plan
            return plan
        }
    }

    public func modifyAutomatedBackup(_ req: ModifyAutomatedBackupReq) async throws -> Database {
        try locked {
            try writableAccount(req.accountId)
            guard var dbs = databases[req.accountId],
                  let i = dbs.firstIndex(where: { $0.identifier == req.dbIdentifier }) else {
                throw FixtureError("database \"\(req.dbIdentifier)\" not found in account \"\(req.accountId)\"")
            }
            if let w = req.window, !w.isEmpty { dbs[i].preferredBackupWindow = w }
            if let r = req.retentionDays, r > 0 { dbs[i].backupRetentionDays = r }
            databases[req.accountId] = dbs
            return dbs[i]
        }
    }

    public func restore(_ req: RestoreReq) async throws -> Activity {
        try locked {
            try writableAccount(req.accountId)
            for dbs in databases.values where dbs.contains(where: { $0.identifier == req.targetIdentifier }) {
                throw FixtureError("target identifier \"\(req.targetIdentifier)\" already exists")
            }
            let act = Activity(time: RFC3339.string(Date()), source: .restoreJob, db: req.targetIdentifier,
                               action: "restore-from-\(req.source.rawValue)", status: "creating",
                               message: "Restoring \(req.source.rawValue) into new database \"\(req.targetIdentifier)\"")
            activity[req.accountId, default: []].append(act)
            return act
        }
    }
}
