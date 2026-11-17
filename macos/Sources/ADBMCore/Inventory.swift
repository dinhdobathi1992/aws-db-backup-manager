// The read-only views (databases, snapshots, backup plans, schedules,
// activity): a port of internal/inventory. Every AWS call goes through the
// guarded AWSClients; nothing here calls a mutating operation.
import Foundation

public final class Inventory: Sendable {
    public let clients: AWSClients
    public let cache: TTLCache
    public let audit: AuditLog
    let now: @Sendable () -> Date

    /// Stays an hour under RDS's 14-day DescribeEvents limit.
    static let activityWindow: TimeInterval = 14 * 24 * 3600 - 3600

    public init(clients: AWSClients, audit: AuditLog = AuditLog(), cache: TTLCache = TTLCache(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.clients = clients; self.audit = audit; self.cache = cache; self.now = now
    }

    func client(_ account: Account, _ region: String) async throws -> AWSClient {
        try await clients.client(profile: account.profile, region: region, readOnly: account.readOnly)
    }

    // MARK: Databases

    /// Every RDS instance and cluster across the account's regions. Cluster
    /// member instances are folded under their cluster's row.
    public func listDatabases(_ account: Account) async throws -> [Database] {
        try await cache.cached("databases|\(account.id)") {
            let (all, errs) = await fanOutRegions(account.regions) { region in
                try await self.listDatabasesInRegion(account, region)
            }
            if !errs.isEmpty && all.isEmpty {
                throw BackendError("list databases for account \(account.id): \(joinErrs(errs))")
            }
            return all
        }
    }

    public func refreshDatabases(_ account: Account) {
        for p in ["databases", "autobk", "clusterEarliest"] { cache.invalidate("\(p)|\(account.id)") }
    }

    /// Everything read for one account: the Refresh button starts from AWS again.
    public func refreshAccount(_ account: Account) {
        for p in ["databases", "snapshots", "rdssnaps", "vaults", "plans", "autobk", "clusterEarliest", "acctnum"] {
            cache.invalidate("\(p)|\(account.id)")
        }
    }

    static func clusterEarliest(_ nodes: [XMLNode]) -> [String: String] {
        var out: [String: String] = [:]
        for n in nodes { if let t = AWSTime.ptr(n.optStr("EarliestRestorableTime")) { out[n.str("DBClusterIdentifier")] = t } }
        return out
    }

    func listDatabasesInRegion(_ account: Account, _ region: String) async throws -> [Database] {
        let c = try await client(account, region)
        let clusterNodes: [XMLNode]
        do { clusterNodes = try await c.queryAll(.describeDBClusters, list: "DBClusters") }
        catch { throw BackendError.wrap("describe db clusters in \(region)", error) }

        // Dedupe by identifier, keeping API order (v0.1 used map order).
        var order: [String] = []
        var clusters: [String: XMLNode] = [:]
        for n in clusterNodes {
            let id = n.str("DBClusterIdentifier")
            if clusters[id] == nil { order.append(id) }
            clusters[id] = n
        }
        var out: [Database] = []
        cache.set("clusterEarliest|\(account.id)|\(region)", Self.clusterEarliest(clusterNodes))

        let instances: [XMLNode]
        do { instances = try await c.queryAll(.describeDBInstances, list: "DBInstances") }
        catch { throw BackendError.wrap("describe db instances in \(region)", error) }
        var byId: [String: XMLNode] = [:]
        for i in instances { byId[i.str("DBInstanceIdentifier")] = i }

        // Cluster members are shown under their cluster, not as databases of their own.
        var members = Set<String>()
        for id in order {
            let n = clusters[id]!
            var db = InventoryMapping.mapCluster(accountId: account.id, region: region, n)
            let ms = n.list("DBClusterMembers").map { m in
                InventoryMapping.mapMember(m, instance: byId[m.str("DBInstanceIdentifier")])
            }
            members.formUnion(ms.map(\.identifier))
            db.members = ms.sorted { ($0.isWriter ? 0 : 1, $0.identifier) < ($1.isWriter ? 0 : 1, $1.identifier) }
            out.append(db)
        }
        for i in instances where !members.contains(i.str("DBInstanceIdentifier")) {
            out.append(InventoryMapping.mapInstance(accountId: account.id, region: region, i))
        }
        return out
    }

    // MARK: Snapshots

    /// Manual/automated RDS snapshots plus AWS Backup recovery points for
    /// one database. RDS "awsbackup" snapshots are skipped (they are the
    /// recovery points, seen from the RDS side).
    ///
    /// The RDS side is read once per region (one paged call for every
    /// database) and recovery points are only asked for when the region's
    /// vaults hold any, so an account with many databases costs a handful
    /// of calls instead of several per database.
    public func listSnapshots(_ account: Account, region: String, kind: DBKind, db: String) async throws -> [Snapshot] {
        try await cache.cached("snapshots|\(account.id)|\(region)|\(db)") {
            var out = try await self.regionSnapshots(account, region: region, kind: kind)[db] ?? []
            out += try await self.recoveryPoints(account, region: region, kind: kind, db: db)
            return out
        }
    }

    public func refreshSnapshots(_ account: Account, region: String, db: String) {
        cache.invalidate("snapshots|\(account.id)|\(region)|\(db)")
        cache.invalidate("rdssnaps|\(account.id)|\(region)|")
        cache.invalidate("vaults|\(account.id)|\(region)")
    }

    /// Every manual/automated RDS snapshot of one kind in a region, by database.
    func regionSnapshots(_ account: Account, region: String, kind: DBKind) async throws -> [String: [Snapshot]] {
        try await cache.cached("rdssnaps|\(account.id)|\(region)|\(kind.rawValue)") {
            let c = try await self.client(account, region)
            let snaps: [Snapshot]
            if kind == .cluster {
                do { snaps = try await c.queryAll(.describeDBClusterSnapshots, list: "DBClusterSnapshots").compactMap(InventoryMapping.mapClusterSnapshot) }
                catch { throw BackendError.wrap("describe db cluster snapshots", error) }
            } else {
                do { snaps = try await c.queryAll(.describeDBSnapshots, list: "DBSnapshots").compactMap(InventoryMapping.mapInstanceSnapshot) }
                catch { throw BackendError.wrap("describe db snapshots", error) }
            }
            return Dictionary(grouping: snaps, by: \.dbIdentifier)
        }
    }

    /// AWS Backup recovery points for one database, best-effort. Skipped
    /// when the region's vaults are known to hold no recovery points.
    func recoveryPoints(_ account: Account, region: String, kind: DBKind, db: String) async throws -> [Snapshot] {
        if await vaultRecoveryPointTotal(account, region: region) == 0 { return [] }
        let c = try await client(account, region)
        guard let acct = try? await resolveAccountNumber(account, region: region), !acct.isEmpty else { return [] }
        let arn = InventoryMapping.resourceArn(region: region, accountNumber: acct, kind: kind, identifier: db)
        return await Self.backupPagesBestEffort(c, .listRecoveryPointsByResource, path: ["ResourceArn": arn], list: "RecoveryPoints")
            .filter(InventoryMapping.isVaultRecoveryPoint)
            .map { InventoryMapping.mapRecoveryPoint(dbIdentifier: db, kind: kind, $0) }
    }

    /// Recovery points held across the region's backup vaults, or nil when
    /// that cannot be read (then every database is asked directly).
    func vaultRecoveryPointTotal(_ account: Account, region: String) async -> Int? {
        try? await cache.cached("vaults|\(account.id)|\(region)") { () async throws -> Int in
            let c = try await self.client(account, region)
            let vaults = try await c.backupAll(.listBackupVaults, list: "BackupVaultList")
            return vaults.reduce(0) { $0 + ($1["NumberOfRecoveryPoints"]?.int ?? 0) }
        }
    }

    func listSnapshotsUncached(_ account: Account, region: String, kind: DBKind, db: String) async throws -> [Snapshot] {
        let c = try await client(account, region)
        var out: [Snapshot] = []
        if kind == .cluster {
            do {
                out += try await c.queryAll(.describeDBClusterSnapshots, ["DBClusterIdentifier": db], list: "DBClusterSnapshots")
                    .compactMap(InventoryMapping.mapClusterSnapshot)
            } catch { throw BackendError.wrap("describe db cluster snapshots", error) }
        } else {
            do {
                out += try await c.queryAll(.describeDBSnapshots, ["DBInstanceIdentifier": db], list: "DBSnapshots")
                    .compactMap(InventoryMapping.mapInstanceSnapshot)
            } catch { throw BackendError.wrap("describe db snapshots", error) }
        }

        // AWS Backup recovery points are best-effort: an account without
        // AWS Backup (or permission to it) just omits this source.
        if let acct = try? await resolveAccountNumber(account, region: region), !acct.isEmpty {
            let arn = InventoryMapping.resourceArn(region: region, accountNumber: acct, kind: kind, identifier: db)
            for rp in await Self.backupPagesBestEffort(c, .listRecoveryPointsByResource, path: ["ResourceArn": arn], list: "RecoveryPoints")
            where InventoryMapping.isVaultRecoveryPoint(rp) {
                out.append(InventoryMapping.mapRecoveryPoint(dbIdentifier: db, kind: kind, rp))
            }
        }
        return out
    }

    /// The account number behind the profile, cached per account.
    func resolveAccountNumber(_ account: Account, region: String) async throws -> String {
        try await cache.cached("acctnum|\(account.id)") {
            let c = try await self.client(account, region)
            do { return try await c.query(.getCallerIdentity).str("Account") }
            catch { throw BackendError.wrap("get caller identity", error) }
        }
    }

    /// NextToken pagination that keeps the pages read before an error.
    static func backupPagesBestEffort(_ c: AWSClient, _ op: AWSOperation, path: [String: String] = [:],
                                      query: [(String, String)] = [], list: String, maxPages: Int = 50) async -> [JSONValue] {
        var out: [JSONValue] = []
        var token: String?
        for _ in 0..<maxPages {
            var q = query
            if let t = token { q.append(("nextToken", t)) }
            guard let r = try? await c.backup(op, path: path, query: q) else { break }
            out += r[list]?.array ?? []
            guard let t = r["NextToken"]?.string, !t.isEmpty else { break }
            token = t
        }
        return out
    }

    // MARK: Backup plan summary

    struct Coverage: Sendable {
        let ref: AWSBackupPlanRef
        let retentionDays: Int
    }

    /// Manual count/latest, the database's own automated settings, and every
    /// AWS Backup rule whose selection covers it.
    public func getBackupPlan(_ account: Account, db: Database) async throws -> BackupPlanSummary {
        let snaps = try await listSnapshots(account, region: db.region, kind: db.kind, db: db.identifier)
        var manual = ManualBackupSummary()
        for s in snaps where s.source == .manual {
            manual.count += 1
            if manual.latest == nil || s.createdAt > manual.latest! { manual.latest = s.createdAt }
        }
        var automated = AutomatedBackupSummary(retention: db.backupRetentionDays, window: db.preferredBackupWindow,
                                               latest: db.latestRestorableTime)
        if let earliest = try? await automatedBackupEarliest(account, db) { automated.earliest = earliest }

        var awsBackup: [AWSBackupPlanRef] = []
        if let cov = try? await awsBackupPlanCoverage(account, db) { awsBackup = cov.map(\.ref) }
        return BackupPlanSummary(db: db.identifier, manual: manual, automated: automated, awsBackup: awsBackup)
    }

    /// Earliest point-in-time restore, read once per region for every database.
    func automatedBackupEarliest(_ account: Account, _ db: Database) async throws -> String? {
        if db.kind == .cluster {
            let byCluster = try await cache.cached("clusterEarliest|\(account.id)|\(db.region)") { () async throws -> [String: String] in
                let c = try await self.client(account, db.region)
                do { return Self.clusterEarliest(try await c.queryAll(.describeDBClusters, list: "DBClusters")) }
                catch { throw BackendError.wrap("describe db clusters in \(db.region)", error) }
            }
            return byCluster[db.identifier]
        }
        let byInstance = try await cache.cached("autobk|\(account.id)|\(db.region)") { () async throws -> [String: String] in
            let c = try await self.client(account, db.region)
            let backups: [XMLNode]
            do { backups = try await c.queryAll(.describeDBInstanceAutomatedBackups, list: "DBInstanceAutomatedBackups") }
            catch { throw BackendError.wrap("describe automated backups in \(db.region)", error) }
            var earliest: [String: Date] = [:]
            for b in backups {
                guard let t = b["RestoreWindow", "EarliestTime"]?.text, let d = RFC3339.date(t) else { continue }
                let id = b.str("DBInstanceIdentifier")
                if earliest[id].map({ d < $0 }) ?? true { earliest[id] = d }
            }
            return earliest.compactMapValues { AWSTime.ptr(RFC3339.string($0)) }
        }
        return byInstance[db.identifier]
    }

    /// One AWS Backup plan with its selections and rules, as read from AWS.
    struct PlanEntry: Sendable {
        let planId: String
        let planName: String
        let selections: [JSONValue]
        let rules: [JSONValue]
    }

    /// Every AWS Backup plan in a region with its selections and rules,
    /// read once and shared by every database there. A plan whose
    /// selections or body cannot be read is left out, as before.
    func backupPlanIndex(_ account: Account, region: String) async throws -> [PlanEntry] {
        try await cache.cached("plans|\(account.id)|\(region)") {
            let c = try await self.client(account, region)
            let plans: [JSONValue]
            do { plans = try await c.backupAll(.listBackupPlans, list: "BackupPlansList") }
            catch { throw BackendError.wrap("list backup plans", error) }
            return await withTaskGroup(of: (Int, PlanEntry?).self) { group in
                for (i, p) in plans.enumerated() {
                    group.addTask {
                        let planId = p["BackupPlanId"]?.string ?? ""
                        guard let selections = try? await self.backupSelections(c, planId: planId),
                              let full = try? await c.backup(.getBackupPlan, path: ["BackupPlanId": planId]),
                              let plan = full["BackupPlan"], plan != .null else { return (i, nil) }
                        return (i, PlanEntry(planId: planId, planName: p["BackupPlanName"]?.string ?? "",
                                             selections: selections, rules: plan["Rules"]?.array ?? []))
                    }
                }
                var out = [PlanEntry?](repeating: nil, count: plans.count)
                for await (i, e) in group { out[i] = e }
                return out.compactMap { $0 }
            }
        }
    }

    func awsBackupPlanCoverage(_ account: Account, _ db: Database) async throws -> [Coverage] {
        let acct = try await resolveAccountNumber(account, region: db.region)
        let dbArn = InventoryMapping.resourceArn(region: db.region, accountNumber: acct, kind: db.kind, identifier: db.identifier)
        var out: [Coverage] = []
        for p in try await backupPlanIndex(account, region: db.region) {
            guard p.selections.contains(where: { InventoryMapping.backupSelectionCovers($0, resourceArn: dbArn, tags: db.tags) }) else { continue }
            for rule in p.rules {
                let lc = rule["Lifecycle"]
                out.append(Coverage(
                    ref: AWSBackupPlanRef(planId: p.planId, planName: p.planName,
                                          ruleName: rule["RuleName"]?.string ?? "", cron: rule["ScheduleExpression"]?.string ?? "",
                                          lifecycle: InventoryMapping.lifecycleText(lc), vault: rule["TargetBackupVaultName"]?.string ?? ""),
                    retentionDays: InventoryMapping.lifecycleRetentionDays(lc)))
            }
        }
        return out
    }

    func backupSelections(_ c: AWSClient, planId: String) async throws -> [JSONValue] {
        let list: [JSONValue]
        do { list = try await c.backupAll(.listBackupSelections, path: ["BackupPlanId": planId], list: "BackupSelectionsList") }
        catch { throw BackendError.wrap("list backup selections", error) }
        var out: [JSONValue] = []
        for s in list {
            guard let full = try? await c.backup(.getBackupSelection,
                                                 path: ["BackupPlanId": planId, "SelectionId": s["SelectionId"]?.string ?? ""]),
                  let sel = full["BackupSelection"], sel != .null else { continue }
            out.append(sel)
        }
        return out
    }

    // MARK: Schedules

    /// Every AWS-native recurring schedule: each database's automated backup
    /// window and every AWS Backup rule covering it.
    public func listSchedules(_ account: Account) async throws -> [Schedule] {
        let dbs = try await listDatabases(account)
        let now = self.now()
        var out: [Schedule] = []
        for db in dbs {
            if !db.preferredBackupWindow.isEmpty {
                out.append(Schedule(source: .automatedWindow, db: db.identifier, expression: db.preferredBackupWindow,
                                    nextRun: Cron.nextAutomatedWindowRun(db.preferredBackupWindow, after: now),
                                    retention: db.backupRetentionDays))
            }
            guard let cov = try? await awsBackupPlanCoverage(account, db) else { continue }
            for c in cov {
                out.append(Schedule(source: .awsBackupRule, db: db.identifier, expression: c.ref.cron,
                                    nextRun: Cron.parseAWSCronNextRun(c.ref.cron, after: now), retention: c.retentionDays))
            }
        }
        return out
    }

    // MARK: Activity

    /// RDS events, AWS Backup job/restore history and this app's own audit
    /// log, merged newest first.
    public func listActivity(_ account: Account, limit: Int) async throws -> [Activity] {
        var (all, errs) = await fanOutRegions(account.regions) { region in
            try await self.listActivityInRegion(account, region)
        }
        if !errs.isEmpty && all.isEmpty {
            throw BackendError("list activity for account \(account.id): \(joinErrs(errs))")
        }
        for e in try audit.readAll() where e.account == account.id {
            all.append(Activity(time: e.time, source: .app, db: e.target, action: e.action, status: e.result,
                                message: "\(e.action) \(e.target): \(e.result)"))
        }
        // Stable: equal times keep their order (v0.1's sort.Slice did not).
        all = all.enumerated().sorted { a, b in
            a.element.time != b.element.time ? a.element.time > b.element.time : a.offset < b.offset
        }.map(\.element)
        if limit > 0 && all.count > limit { all = Array(all.prefix(limit)) }
        return all
    }

    func listActivityInRegion(_ account: Account, _ region: String) async throws -> [Activity] {
        let c = try await client(account, region)
        let start = RFC3339.string(now().addingTimeInterval(-Self.activityWindow))
        var out: [Activity] = []
        let events: XMLNode
        do {
            events = try await c.query(.describeEvents, [
                "StartTime": start,
                "EventCategories.EventCategory.1": "backup",
                "EventCategories.EventCategory.2": "restoration",
                "EventCategories.EventCategory.3": "notification",
            ])
        } catch { throw BackendError.wrap("describe events in \(region)", error) }
        out += events.list("Events").map(InventoryMapping.mapRDSEvent)

        // AWS Backup may not be set up; never fail the whole feed for it.
        out += await Self.backupPagesBestEffort(c, .listBackupJobs, query: [("createdAfter", start)], list: "BackupJobs")
            .map(InventoryMapping.mapBackupJob)
        out += await Self.backupPagesBestEffort(c, .listRestoreJobs, query: [("createdAfter", start)], list: "RestoreJobs")
            .map(InventoryMapping.mapRestoreJob)
        return out
    }
}
