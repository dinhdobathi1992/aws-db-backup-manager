// Every mutating operation this app can perform: a port of
// internal/actions (helpers.go, backup.go, restore.go). Manual snapshots,
// on-demand AWS Backup jobs, backup plans, raising automated retention, and
// restores into a brand-new identifier. There is no delete, remove,
// terminate or failover call here; SafetyGuard enforces that independently,
// but every function is written as if it were the only line of defense.
import Foundation

public struct Actions: Sendable {
    public let inventory: Inventory
    public init(inventory: Inventory) { self.inventory = inventory }

    /// Mirrors SafetyGuard's floor so the user gets a specific message
    /// before any AWS call; the guard stays the real enforcement point.
    static let minBackupPlanRetentionDays = SafetyGuard.minBackupPlanRetentionDays
    static let defaultBackupVaultName = "Default"

    // MARK: Helpers

    static func defaultBackupRoleArn(_ accountNumber: String) -> String {
        "arn:aws:iam::\(accountNumber):role/service-role/AWSBackupDefaultServiceRole"
    }

    /// "<db>-manual-<yyyymmdd-hhmm>" in UTC.
    static func manualSnapshotID(_ db: String, now: Date) -> String {
        let c = Cron.utcCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        return String(format: "%@-manual-%04d%02d%02d-%02d%02d", db, c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    /// Writers re-derive identity each time (never inventory's cache).
    static func resolveAccountNumber(_ c: AWSClient) async throws -> String {
        do { return try await c.query(.getCallerIdentity).str("Account") }
        catch { throw BackendError.wrap("get caller identity", error) }
    }

    func client(_ account: Account, _ region: String) async throws -> AWSClient {
        try await inventory.clients.client(profile: account.profile, region: region, readOnly: account.readOnly)
    }

    var nowRFC3339: String { RFC3339.string(inventory.now()) }

    /// A logging failure never fails the action: the AWS call already happened.
    func recordAudit(_ account: Account, arn: String, action: String, target: String, result: String) {
        try? inventory.audit.append(AuditEntry(time: nowRFC3339, account: account.id, profile: account.profile,
                                               arn: arn, action: action, target: target, result: result))
    }

    // MARK: Backup

    /// Starts an on-demand manual snapshot.
    public func createSnapshot(_ account: Account, _ req: CreateSnapshotReq) async throws -> Snapshot {
        if req.dbIdentifier.isEmpty { throw BackendError("dbIdentifier is required") }
        let name = req.snapshotName.isEmpty ? Self.manualSnapshotID(req.dbIdentifier, now: inventory.now()) : req.snapshotName
        try Validate.identifier(name)
        let c = try await client(account, req.region)

        var snap: Snapshot
        if req.kind == .cluster {
            let r: XMLNode
            do {
                r = try await c.query(.createDBClusterSnapshot, ["DBClusterIdentifier": req.dbIdentifier,
                                                                 "DBClusterSnapshotIdentifier": name])
            } catch { throw BackendError.wrap("create db cluster snapshot", error) }
            let s = r.child("DBClusterSnapshot") ?? r
            snap = Snapshot(id: s.str("DBClusterSnapshotIdentifier"), arn: s.str("DBClusterSnapshotArn"),
                            dbIdentifier: s.str("DBClusterIdentifier"), kind: .cluster, source: .manual, status: s.str("Status"),
                            createdAt: AWSTime.str(s.optStr("SnapshotCreateTime")), sizeGb: s.int64("AllocatedStorage"),
                            encrypted: s.bool("StorageEncrypted"), engine: s.str("Engine"))
        } else {
            let r: XMLNode
            do {
                r = try await c.query(.createDBSnapshot, ["DBInstanceIdentifier": req.dbIdentifier, "DBSnapshotIdentifier": name])
            } catch { throw BackendError.wrap("create db snapshot", error) }
            let s = r.child("DBSnapshot") ?? r
            snap = Snapshot(id: s.str("DBSnapshotIdentifier"), arn: s.str("DBSnapshotArn"),
                            dbIdentifier: s.str("DBInstanceIdentifier"), kind: .instance, source: .manual, status: s.str("Status"),
                            createdAt: AWSTime.str(s.optStr("SnapshotCreateTime")), sizeGb: s.int64("AllocatedStorage"),
                            encrypted: s.bool("Encrypted"), engine: s.str("Engine"))
        }
        recordAudit(account, arn: snap.arn, action: "CreateSnapshot", target: req.dbIdentifier, result: snap.status)
        inventory.refreshSnapshots(account, region: req.region, db: req.dbIdentifier)
        return snap
    }

    /// Starts an on-demand AWS Backup job, defaulting to the Default vault
    /// and AWS Backup's default service role.
    public func startBackupJob(_ account: Account, _ req: StartBackupJobReq) async throws -> Activity {
        if req.dbIdentifier.isEmpty { throw BackendError("dbIdentifier is required") }
        let c = try await client(account, req.region)
        let acct = try await Self.resolveAccountNumber(c)
        let vault = req.vaultName.isEmpty ? Self.defaultBackupVaultName : req.vaultName
        let role = req.iamRoleArn.isEmpty ? Self.defaultBackupRoleArn(acct) : req.iamRoleArn
        let arn = InventoryMapping.resourceArn(region: req.region, accountNumber: acct, kind: req.kind, identifier: req.dbIdentifier)

        let out: JSONValue
        do {
            out = try await c.backup(.startBackupJob, body: .object([
                "BackupVaultName": .string(vault), "IamRoleArn": .string(role), "ResourceArn": .string(arn),
            ]))
        } catch { throw BackendError.wrap("start backup job", error) }

        let jobId = out["BackupJobId"]?.string ?? ""
        recordAudit(account, arn: arn, action: "StartBackupJob", target: req.dbIdentifier, result: "pending")
        return Activity(time: AWSTime.json(out["CreationDate"]), source: .backupJob, db: req.dbIdentifier,
                        action: "start-backup-job", status: "pending", message: "backup job \(jobId) started in vault \(vault)")
    }

    /// Creates an AWS Backup plan with one rule and one selection targeting
    /// a single database by ARN.
    public func createBackupPlan(_ account: Account, _ req: CreateBackupPlanReq) async throws -> BackupPlanSummary {
        if req.dbIdentifier.isEmpty { throw BackendError("dbIdentifier is required") }
        if req.cron.isEmpty { throw BackendError("cron schedule expression is required") }
        if req.retentionDays < Self.minBackupPlanRetentionDays {
            throw BackendError("retentionDays must be at least \(Self.minBackupPlanRetentionDays)")
        }
        let planName = req.planName.isEmpty ? req.dbIdentifier + "-plan" : req.planName
        let ruleName = req.ruleName.isEmpty ? "default-rule" : req.ruleName
        let vault = req.vaultName.isEmpty ? Self.defaultBackupVaultName : req.vaultName

        let c = try await client(account, req.region)
        let acct = try await Self.resolveAccountNumber(c)
        let role = req.iamRoleArn.isEmpty ? Self.defaultBackupRoleArn(acct) : req.iamRoleArn
        let arn = InventoryMapping.resourceArn(region: req.region, accountNumber: acct, kind: req.kind, identifier: req.dbIdentifier)

        let planOut: JSONValue
        do {
            planOut = try await c.backup(.createBackupPlan, body: .object(["BackupPlan": .object([
                "BackupPlanName": .string(planName),
                "Rules": .array([.object([
                    "RuleName": .string(ruleName),
                    "TargetBackupVaultName": .string(vault),
                    "ScheduleExpression": .string(req.cron),
                    "Lifecycle": .object(["DeleteAfterDays": .number(Double(req.retentionDays))]),
                ])]),
            ])]))
        } catch { throw BackendError.wrap("create backup plan", error) }
        let planId = planOut["BackupPlanId"]?.string ?? ""

        do {
            _ = try await c.backup(.createBackupSelection, path: ["BackupPlanId": planId], body: .object(["BackupSelection": .object([
                "SelectionName": .string(planName + "-selection"),
                "IamRoleArn": .string(role),
                "Resources": .array([.string(arn)]),
            ])]))
        } catch { throw BackendError.wrap("create backup selection", error) }

        recordAudit(account, arn: arn, action: "CreateBackupPlan", target: req.dbIdentifier, result: planId)

        if let dbs = try? await inventory.listDatabases(account),
           let db = dbs.first(where: { $0.identifier == req.dbIdentifier && $0.region == req.region }) {
            return try await inventory.getBackupPlan(account, db: db)
        }
        // The plan exists in AWS; return what we know rather than failing.
        return BackupPlanSummary(db: req.dbIdentifier, awsBackup: [AWSBackupPlanRef(
            planId: planId, planName: planName, ruleName: ruleName, cron: req.cron,
            lifecycle: "\(req.retentionDays) day(s)", vault: vault)])
    }

    /// Changes the automated backup window and/or raises retention.
    /// Retention can only go up.
    public func modifyAutomatedBackup(_ account: Account, _ req: ModifyAutomatedBackupReq) async throws -> Database {
        if req.dbIdentifier.isEmpty { throw BackendError("dbIdentifier is required") }
        let window = req.window ?? ""
        let retention = req.retentionDays ?? 0
        if window.isEmpty && retention == 0 { throw BackendError("window or retentionDays is required") }

        let c = try await client(account, req.region)
        let current = try await Self.currentRetention(c, kind: req.kind, identifier: req.dbIdentifier)
        if retention > 0 && retention < current {
            throw BackendError("retention can only be raised, not lowered: current is \(current) day(s), requested \(retention)")
        }

        var params: [String: String] = ["ApplyImmediately": "true"]
        params[req.kind == .cluster ? "DBClusterIdentifier" : "DBInstanceIdentifier"] = req.dbIdentifier
        if retention > 0 { params["BackupRetentionPeriod"] = String(retention) }
        if !window.isEmpty { params["PreferredBackupWindow"] = window }
        do { _ = try await c.query(req.kind == .cluster ? .modifyDBCluster : .modifyDBInstance, params) }
        catch { throw BackendError.wrap("modify automated backup settings", error) }

        recordAudit(account, arn: req.dbIdentifier, action: "ModifyAutomatedBackup", target: req.dbIdentifier, result: "applied")
        inventory.refreshDatabases(account)
        let dbs = try await inventory.listDatabases(account)
        if let db = dbs.first(where: { $0.identifier == req.dbIdentifier && $0.region == req.region }) { return db }
        throw BackendError("database \(goQuote(req.dbIdentifier)) not found after modify")
    }

    /// Live (uncached) retention, so "raise only" is checked against truth.
    static func currentRetention(_ c: AWSClient, kind: DBKind, identifier: String) async throws -> Int {
        let (op, param, list, label) = kind == .cluster
            ? (AWSOperation.describeDBClusters, "DBClusterIdentifier", "DBClusters", "cluster")
            : (AWSOperation.describeDBInstances, "DBInstanceIdentifier", "DBInstances", "instance")
        let node: XMLNode?
        do { node = try await c.query(op, [param: identifier]).list(list).first }
        catch { throw BackendError.wrap("describe \(label) \(goQuote(identifier))", error) }
        guard let n = node else { throw BackendError("describe \(label) \(goQuote(identifier)): not found") }
        return n.int("BackupRetentionPeriod")
    }
}
