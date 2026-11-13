// How many AWS requests one account load costs. An account with many
// databases must not multiply the AWS Backup plan lookups per database.
import XCTest
@testable import ADBMCore

final class LoadCostTests: XCTestCase {
    static let dbCount = 40

    /// An org-style setup: 4 plans (hourly/daily/weekly/monthly), each with
    /// one tag-based selection, and `dbCount` instances in one region.
    func makeHarness() -> Harness {
        let h = Harness()
        h.stub.onXML(.describeDBClusters, "<DBClusters></DBClusters>")
        let instances = (0..<Self.dbCount).map {
            "<DBInstance><DBInstanceIdentifier>db-\($0)</DBInstanceIdentifier><BackupRetentionPeriod>7</BackupRetentionPeriod><PreferredBackupWindow>04:00-04:30</PreferredBackupWindow></DBInstance>"
        }.joined()
        h.stub.onXML(.describeDBInstances, "<DBInstances>\(instances)</DBInstances>")
        let plans = ["Hourly", "Daily", "Weekly", "Monthly"]
        h.stub.onJSON(.listBackupPlans, ["BackupPlansList": plans.map { ["BackupPlanId": "p-\($0)", "BackupPlanName": $0] }])
        h.stub.onJSON(.listBackupSelections, ["BackupSelectionsList": [["SelectionId": "s1"]]])
        h.stub.on(.getBackupSelection) { c in
            let plan = c.path.components(separatedBy: "/").first { $0.hasPrefix("p-") }?.dropFirst(2) ?? ""
            return (200, jsonData(["BackupSelection": ["Resources": ["*"],
                "ListOfTags": [["ConditionType": "STRINGEQUALS", "ConditionKey": "BackupPlan", "ConditionValue": String(plan)]]]]))
        }
        h.stub.onJSON(.getBackupPlan, ["BackupPlan": ["Rules": [["RuleName": "r", "ScheduleExpression": "cron(0 5 * * ? *)",
                                                                "TargetBackupVaultName": "BackupVault", "Lifecycle": ["DeleteAfterDays": 7]]]]])
        h.stub.onXML(.describeEvents, "<Events></Events>")
        h.stub.onXML(.describeDBSnapshots, "<DBSnapshots></DBSnapshots>")
        return h
    }

    /// What the app does when an account opens: databases, then every
    /// database's snapshots and plan, plus schedules and activity.
    func loadAccount(_ inv: Inventory) async throws {
        let dbs = try await inv.listDatabases(testAccount)
        try await withThrowingTaskGroup(of: Void.self) { g in
            for db in dbs {
                g.addTask { _ = try await inv.listSnapshots(testAccount, region: db.region, kind: db.kind, db: db.identifier) }
                g.addTask { _ = try await inv.getBackupPlan(testAccount, db: db) }
            }
            g.addTask { _ = try await inv.listSchedules(testAccount) }
            g.addTask { _ = try await inv.listActivity(testAccount, limit: 50) }
            try await g.waitForAll()
        }
    }

    func counts(_ h: Harness) -> [AWSOperation: Int] {
        var byOp: [AWSOperation: Int] = [:]
        for op in h.stub.operations { byOp[op, default: 0] += 1 }
        return byOp
    }

    /// Plan, selection, snapshot and automated-backup lookups are made once
    /// per region, not once per database. Recovery points are still asked
    /// per database while the region's vaults hold any.
    func testAccountLoadCostDoesNotScaleWithDatabases() async throws {
        let h = makeHarness()
        h.stub.onJSON(.listBackupVaults, ["BackupVaultList": [["BackupVaultName": "BackupVault", "NumberOfRecoveryPoints": 3]]])
        try await loadAccount(h.inventory)
        let n = counts(h)
        XCTAssertEqual(n[.listBackupPlans], 1)
        XCTAssertEqual(n[.listBackupSelections], 4)
        XCTAssertEqual(n[.getBackupSelection], 4)
        XCTAssertEqual(n[.getBackupPlan], 4)
        XCTAssertEqual(n[.describeDBSnapshots], 1)
        XCTAssertEqual(n[.describeDBInstanceAutomatedBackups], 1)
        XCTAssertEqual(n[.getCallerIdentity], 1)
        XCTAssertEqual(n[.listRecoveryPointsByResource], Self.dbCount)
        XCTAssertLessThanOrEqual(h.stub.calls.count, 23 + Self.dbCount, "\(n)")
    }

    /// A region whose vaults hold no recovery points is not asked per database.
    func testEmptyVaultsSkipRecoveryPointLookups() async throws {
        let h = makeHarness()
        h.stub.onJSON(.listBackupVaults, ["BackupVaultList": [["BackupVaultName": "BackupVault", "NumberOfRecoveryPoints": 0]]])
        try await loadAccount(h.inventory)
        XCTAssertNil(counts(h)[.listRecoveryPointsByResource])
        XCTAssertLessThanOrEqual(h.stub.calls.count, 23, "\(counts(h))")
    }

    /// Unreadable vaults fall back to asking each database, so nothing is missed.
    func testUnreadableVaultsFallBackToPerDatabaseLookups() async throws {
        let h = makeHarness()
        try await loadAccount(h.inventory)
        XCTAssertEqual(counts(h)[.listRecoveryPointsByResource], Self.dbCount)
    }

    /// The same snapshots and plans as reading each database on its own.
    func testRegionIndexMatchesPerDatabaseReads() async throws {
        let h = makeHarness()
        h.stub.onXML(.describeDBSnapshots, """
            <DBSnapshots><DBSnapshot><DBSnapshotIdentifier>m1</DBSnapshotIdentifier><DBInstanceIdentifier>db-1</DBInstanceIdentifier><SnapshotType>manual</SnapshotType></DBSnapshot>
            <DBSnapshot><DBSnapshotIdentifier>a1</DBSnapshotIdentifier><DBInstanceIdentifier>db-2</DBInstanceIdentifier><SnapshotType>automated</SnapshotType></DBSnapshot></DBSnapshots>
            """)
        let dbs = try await h.inventory.listDatabases(testAccount)
        for db in dbs.prefix(3) {
            let cached = try await h.inventory.listSnapshots(testAccount, region: db.region, kind: db.kind, db: db.identifier)
            let direct = try await h.inventory.listSnapshotsUncached(testAccount, region: db.region, kind: db.kind, db: db.identifier)
            // The stub answers every DescribeDBSnapshots the same, so the
            // direct read sees both snapshots; the index keeps only this db's.
            XCTAssertEqual(cached.map(\.id), direct.filter { $0.dbIdentifier == db.identifier }.map(\.id))
        }
    }

    /// Refresh forgets the account's cached reads; the next load goes to AWS.
    func testRefreshAccountRefetches() async throws {
        let h = makeHarness()
        try await loadAccount(h.inventory)
        let first = h.stub.calls.count
        try await loadAccount(h.inventory)
        XCTAssertLessThanOrEqual(h.stub.calls.count - first, 3, "schedules/activity aside, a second load is served from cache")
        h.inventory.refreshAccount(testAccount)
        let before = h.stub.calls.count
        try await loadAccount(h.inventory)
        XCTAssertGreaterThan(h.stub.calls.count - before, 10)
    }
}

final class CacheTests: XCTestCase {
    actor Counter { var n = 0; func bump() -> Int { n += 1; return n } }

    func testConcurrentCallersShareOneLoad() async throws {
        let cache = TTLCache()
        let counter = Counter()
        let values = try await withThrowingTaskGroup(of: Int.self) { g in
            for _ in 0..<20 {
                g.addTask {
                    try await cache.cached("k") { () async throws -> Int in
                        try await Task.sleep(for: .milliseconds(50))
                        return await counter.bump()
                    }
                }
            }
            return try await g.reduce(into: [Int]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(values), [1])
        let loads = await counter.n
        XCTAssertEqual(loads, 1)
    }

    func testErrorsAreNotCached() async throws {
        let cache = TTLCache()
        await assertThrows({ try await cache.cached("k") { () async throws -> Int in throw BackendError("boom") } }, contains: "boom")
        let v = try await cache.cached("k") { () async throws -> Int in 7 }
        XCTAssertEqual(v, 7)
    }

    func testInvalidateDuringLoadDoesNotStoreStaleValue() async throws {
        let cache = TTLCache()
        async let first = cache.cached("k") { () async throws -> Int in
            try await Task.sleep(for: .milliseconds(100)); return 1
        }
        try await Task.sleep(for: .milliseconds(20))
        cache.invalidate("k")
        _ = try await first
        let v = try await cache.cached("k") { () async throws -> Int in 2 }
        XCTAssertEqual(v, 2)
    }
}
