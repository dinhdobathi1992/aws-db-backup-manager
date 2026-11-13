// Ports of internal/inventory/{databases,snapshots,plans,schedules}_test.go.
import XCTest
@testable import ADBMCore

func xml(_ s: String) -> ADBMCore.XMLNode { try! ADBMCore.XMLNode.parse(Data(s.utf8)) }
func json(_ s: String) -> JSONValue { try! JSONValue.parse(Data(s.utf8)) }
func date(_ s: String) -> Date { RFC3339.date(s)! }

let testDBArn = "arn:aws:rds:ap-southeast-1:111122223333:db:prod-reporting-pg"

final class InventoryMappingTests: XCTestCase {
    func testMapInstance() {
        let db = InventoryMapping.mapInstance(accountId: "acct-prod", region: "us-east-1", xml("""
            <DBInstance><DBInstanceIdentifier>prod-reporting-pg</DBInstanceIdentifier><Engine>postgres</Engine>
            <EngineVersion>16.1</EngineVersion><DBInstanceClass>db.m6g.xlarge</DBInstanceClass><DBInstanceStatus>available</DBInstanceStatus>
            <Endpoint><Address>prod-reporting-pg.xxxxx.us-east-1.rds.amazonaws.com</Address></Endpoint><MultiAZ>true</MultiAZ>
            <AllocatedStorage>500</AllocatedStorage><StorageEncrypted>true</StorageEncrypted><BackupRetentionPeriod>14</BackupRetentionPeriod>
            <PreferredBackupWindow>04:00-04:30</PreferredBackupWindow><LatestRestorableTime>2026-11-13T10:00:00.123Z</LatestRestorableTime>
            <TagList><Tag><Key>env</Key><Value>prod</Value></Tag></TagList></DBInstance>
            """))
        XCTAssertEqual(db.kind, .instance)
        XCTAssertEqual(db.identifier, "prod-reporting-pg")
        XCTAssertEqual(db.endpoint, "prod-reporting-pg.xxxxx.us-east-1.rds.amazonaws.com")
        XCTAssertEqual(db.storageGb, 500)
        XCTAssertEqual(db.backupRetentionDays, 14)
        XCTAssertTrue(db.multiAz)
        XCTAssertEqual(db.latestRestorableTime, "2026-11-13T10:00:00Z")
        XCTAssertEqual(db.tags, ["env": "prod"])
        XCTAssertNil(InventoryMapping.mapInstance(accountId: "a", region: "r", xml("<DBInstance/>")).tags)
    }

    func testMapCluster() {
        let db = InventoryMapping.mapCluster(accountId: "acct-prod", region: "us-east-1", xml("""
            <DBCluster><DBClusterIdentifier>prod-orders-cluster</DBClusterIdentifier><Engine>aurora-postgresql</Engine>
            <Status>available</Status><Endpoint>prod-orders-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com</Endpoint>
            <BackupRetentionPeriod>7</BackupRetentionPeriod><PreferredBackupWindow>03:00-03:30</PreferredBackupWindow></DBCluster>
            """))
        XCTAssertEqual(db.kind, .cluster)
        XCTAssertEqual(db.identifier, "prod-orders-cluster")
        XCTAssertEqual(db.backupRetentionDays, 7)
        XCTAssertEqual(db.endpoint, "prod-orders-cluster.cluster-xxxxx.us-east-1.rds.amazonaws.com")
    }

    func testListDatabasesFoldsClusterMembers() async throws {
        let h = Harness()
        h.stub.onXML(.describeDBClusters, """
            <DBClusters><DBCluster><DBClusterIdentifier>prod-orders-cluster</DBClusterIdentifier><DBClusterMembers>
            <DBClusterMember><DBInstanceIdentifier>prod-orders-cluster-writer</DBInstanceIdentifier></DBClusterMember>
            <DBClusterMember><DBInstanceIdentifier>prod-orders-cluster-reader-1</DBInstanceIdentifier></DBClusterMember>
            </DBClusterMembers></DBCluster></DBClusters>
            """)
        h.stub.onXML(.describeDBInstances, """
            <DBInstances><DBInstance><DBInstanceIdentifier>prod-orders-cluster-writer</DBInstanceIdentifier></DBInstance>
            <DBInstance><DBInstanceIdentifier>prod-orders-cluster-reader-1</DBInstanceIdentifier></DBInstance>
            <DBInstance><DBInstanceIdentifier>prod-standalone-pg</DBInstanceIdentifier></DBInstance></DBInstances>
            """)
        let dbs = try await h.inventory.listDatabases(testAccount)
        XCTAssertEqual(dbs.map(\.identifier), ["prod-orders-cluster", "prod-standalone-pg"])
        XCTAssertEqual(dbs.map(\.kind), [.cluster, .instance])
        // Cached: a second read makes no calls.
        let n = h.stub.calls.count
        _ = try await h.inventory.listDatabases(testAccount)
        XCTAssertEqual(h.stub.calls.count, n)
    }

    func testSnapshotSourceFromType() {
        let cases: [String: SnapshotSource?] = ["manual": .manual, "Manual": .manual, "automated": .automated,
                                                "awsbackup": nil, "shared": nil, "": nil]
        for (input, want) in cases { XCTAssertEqual(InventoryMapping.snapshotSource(fromType: input), want, input) }
    }

    func testMapSnapshotsSkipAWSBackupTypeAndKeepManualAutomated() {
        XCTAssertNil(InventoryMapping.mapInstanceSnapshot(xml("<S><DBSnapshotIdentifier>awsbackup:job-1234</DBSnapshotIdentifier><SnapshotType>awsbackup</SnapshotType></S>")))
        XCTAssertNil(InventoryMapping.mapClusterSnapshot(xml("<S><DBClusterSnapshotIdentifier>awsbackup:job-5678</DBClusterSnapshotIdentifier><SnapshotType>awsbackup</SnapshotType></S>")))
        let m = InventoryMapping.mapInstanceSnapshot(xml("""
            <S><DBSnapshotIdentifier>manual-snap-1</DBSnapshotIdentifier><DBInstanceIdentifier>prod-reporting-pg</DBInstanceIdentifier>
            <SnapshotType>manual</SnapshotType><Status>available</Status><AllocatedStorage>500</AllocatedStorage>
            <Encrypted>true</Encrypted><Engine>postgres</Engine></S>
            """))
        XCTAssertEqual(m?.source, .manual)
        XCTAssertEqual(m?.sizeGb, 500)
        XCTAssertEqual(m?.encrypted, true)
        XCTAssertEqual(m?.createdAt, "")
        XCTAssertEqual(InventoryMapping.mapInstanceSnapshot(xml("<S><SnapshotType>automated</SnapshotType></S>"))?.source, .automated)
    }

    func testMapRecoveryPointSizeConversion() {
        let s = InventoryMapping.mapRecoveryPoint(dbIdentifier: "prod-orders-cluster", kind: .cluster, json("""
            {"RecoveryPointArn":"arn:aws:backup:us-east-1:111111111111:recovery-point:abc","BackupSizeBytes":\(3 * 1024 * 1024 * 1024),
             "Status":"COMPLETED","BackupVaultName":"default"}
            """))
        XCTAssertEqual(s.source, .awsBackup)
        XCTAssertEqual(s.sizeGb, 3)
        XCTAssertEqual(s.vaultName, "default")
        XCTAssertEqual(s.id, s.arn)
        XCTAssertFalse(s.encrypted)
    }

    func testRecoveryPointResourceArn() {
        XCTAssertEqual(InventoryMapping.resourceArn(region: "ap-southeast-1", accountNumber: "111122223333", kind: .instance, identifier: "prod-reporting-pg"),
                       testDBArn)
        XCTAssertEqual(InventoryMapping.resourceArn(region: "ap-southeast-1", accountNumber: "111122223333", kind: .cluster, identifier: "prod-orders-cluster"),
                       "arn:aws:rds:ap-southeast-1:111122223333:cluster:prod-orders-cluster")
    }

    func testListSnapshotsMergesRDSAndRecoveryPoints() async throws {
        let h = Harness()
        h.stub.onXML(.describeDBSnapshots, """
            <DBSnapshots><DBSnapshot><DBSnapshotIdentifier>m1</DBSnapshotIdentifier><DBInstanceIdentifier>prod-db</DBInstanceIdentifier><SnapshotType>manual</SnapshotType></DBSnapshot>
            <DBSnapshot><DBSnapshotIdentifier>awsbackup:x</DBSnapshotIdentifier><SnapshotType>awsbackup</SnapshotType></DBSnapshot></DBSnapshots>
            """)
        h.stub.onJSON(.listRecoveryPointsByResource, ["RecoveryPoints": [
            ["RecoveryPointArn": "rp-1", "BackupVaultName": "v"],
            // RDS automated snapshot echoed by AWS Backup: no vault, must not count as AWS Backup.
            ["RecoveryPointArn": "arn:aws:rds:us-east-1:123456789012:snapshot:rds:prod-db-2026-11-13-03-05", "Status": "COMPLETED"],
            ["RecoveryPointArn": "rp-empty-vault", "BackupVaultName": ""]]])
        let snaps = try await h.inventory.listSnapshots(testAccount, region: "us-east-1", kind: .instance, db: "prod-db")
        XCTAssertEqual(snaps.map(\.id), ["m1", "rp-1"])
        let rpCall = try XCTUnwrap(h.stub.calls(.listRecoveryPointsByResource).first)
        XCTAssertTrue(rpCall.path.contains("arn%3Aaws%3Ards%3Aus-east-1%3A123456789012%3Adb%3Aprod-db") || rpCall.path.contains("arn:aws:rds:us-east-1:123456789012:db:prod-db"),
                      rpCall.path)
    }
}

final class SelectionTests: XCTestCase {
    func covers(_ sel: String, _ arn: String = testDBArn, tags: [String: String]? = nil) -> Bool {
        InventoryMapping.backupSelectionCovers(json(sel), resourceArn: arn, tags: tags)
    }

    func testExactResourceArn() {
        XCTAssertTrue(covers(#"{"Resources":["\#(testDBArn)"]}"#))
        XCTAssertFalse(covers(#"{"Resources":["\#(testDBArn)"]}"#, "arn:aws:rds:ap-southeast-1:111122223333:db:other-db"))
    }

    func testWildcards() {
        XCTAssertTrue(covers(#"{"Resources":["*"]}"#))
        let prefix = #"{"Resources":["arn:aws:rds:ap-southeast-1:111122223333:db:prod-*"]}"#
        XCTAssertTrue(covers(prefix))
        XCTAssertFalse(covers(prefix, "arn:aws:rds:ap-southeast-1:111122223333:db:staging-reporting-pg"))
    }

    func testNotResourcesExcludesEvenOnPositiveMatch() {
        XCTAssertFalse(covers(#"{"Resources":["*"],"NotResources":["\#(testDBArn)"]}"#))
    }

    func testListOfTags() {
        let sel = #"{"ListOfTags":[{"ConditionType":"STRINGEQUALS","ConditionKey":"aws:ResourceTag/env","ConditionValue":"prod"}]}"#
        XCTAssertTrue(covers(sel, tags: ["env": "prod"]))
        XCTAssertFalse(covers(sel, tags: ["env": "staging"]))
        XCTAssertFalse(covers(sel))
    }

    func testConditionsStringEqualsAndStringLike() {
        let eq = #"{"Conditions":{"StringEquals":[{"ConditionKey":"aws:ResourceTag/env","ConditionValue":"prod"}]}}"#
        XCTAssertTrue(covers(eq, tags: ["env": "prod"]))
        XCTAssertFalse(covers(eq, tags: ["env": "production"]))
        let like = #"{"Conditions":{"StringLike":[{"ConditionKey":"aws:ResourceTag/env","ConditionValue":"prod*"}]}}"#
        XCTAssertTrue(covers(like, tags: ["env": "production"]))
        XCTAssertFalse(covers(like, tags: ["env": "staging"]))
    }

    func testStringNotEqualsIsNotStandaloneMatch() {
        XCTAssertFalse(covers(#"{"Conditions":{"StringNotEquals":[{"ConditionKey":"aws:ResourceTag/env","ConditionValue":"staging"}]}}"#,
                              tags: ["env": "prod"]))
    }

    func testMatchWildcard() {
        for (v, p, want) in [("production", "prod*", true), ("staging", "prod*", false), ("prod", "prod", true),
                             ("prod", "prod*", true), ("my-prod-db", "*prod*", true), ("my-staging-db", "*prod*", false)] {
            XCTAssertEqual(InventoryMapping.matchWildcard(v, p), want, "\(v) ~ \(p)")
        }
    }

    func testLifecycleTextAndRetentionDays() {
        XCTAssertEqual(InventoryMapping.lifecycleText(nil), "")
        XCTAssertEqual(InventoryMapping.lifecycleRetentionDays(nil), 0)
        XCTAssertEqual(InventoryMapping.lifecycleText(json(#"{"DeleteAfterDays":35}"#)), "35 day(s)")
        XCTAssertEqual(InventoryMapping.lifecycleRetentionDays(json(#"{"DeleteAfterDays":35}"#)), 35)
    }

    func testGetBackupPlanAndSchedulesFromCoveringPlan() async throws {
        let h = Harness()
        h.stub.onXML(.describeDBClusters, "<DBClusters></DBClusters>")
        h.stub.onXML(.describeDBInstances, """
            <DBInstances><DBInstance><DBInstanceIdentifier>prod-db</DBInstanceIdentifier><BackupRetentionPeriod>7</BackupRetentionPeriod>
            <PreferredBackupWindow>04:00-04:30</PreferredBackupWindow></DBInstance></DBInstances>
            """)
        h.stub.onJSON(.listBackupPlans, ["BackupPlansList": [["BackupPlanId": "p1", "BackupPlanName": "daily"]]])
        h.stub.onJSON(.listBackupSelections, ["BackupSelectionsList": [["SelectionId": "s1"]]])
        h.stub.onJSON(.getBackupSelection, ["BackupSelection": ["Resources": ["arn:aws:rds:us-east-1:123456789012:db:prod-*"]]])
        h.stub.onJSON(.getBackupPlan, ["BackupPlan": ["BackupPlanName": "daily", "Rules": [[
            "RuleName": "r1", "ScheduleExpression": "cron(0 5 * * ? *)", "TargetBackupVaultName": "Default",
            "Lifecycle": ["DeleteAfterDays": 35]]]]])
        let schedules = try await h.inventory.listSchedules(testAccount)
        XCTAssertEqual(schedules, [
            Schedule(source: .automatedWindow, db: "prod-db", expression: "04:00-04:30", nextRun: "2026-01-16T04:00:00Z", retention: 7),
            Schedule(source: .awsBackupRule, db: "prod-db", expression: "cron(0 5 * * ? *)", nextRun: "2026-01-16T05:00:00Z", retention: 35),
        ])
    }
}

final class CronTests: XCTestCase {
    func testNextAutomatedWindowRun() {
        XCTAssertEqual(Cron.nextAutomatedWindowRun("04:00-04:30", after: date("2026-11-13T10:00:00Z")), "2026-11-14T04:00:00Z")
        XCTAssertEqual(Cron.nextAutomatedWindowRun("04:00-04:30", after: date("2026-11-13T01:00:00Z")), "2026-11-13T04:00:00Z")
        XCTAssertEqual(Cron.nextAutomatedWindowRun("4:05-4:35", after: date("2026-11-13T01:00:00Z")), "2026-11-13T04:05:00Z")
        XCTAssertNil(Cron.nextAutomatedWindowRun("not-a-window", after: Date()))
        XCTAssertNil(Cron.nextAutomatedWindowRun("", after: Date()))
    }

    func testNormalizeAWSCron() {
        XCTAssertEqual(Cron.normalizeAWSCron("cron(0 5 * * ? *)"), ["0", "5", "*", "*", "*"])
        let f = Cron.normalizeAWSCron("cron(15 3 1 * ? *)")
        XCTAssertEqual(f?[2], "1")
        XCTAssertEqual(f?[4], "*")
        XCTAssertNil(Cron.normalizeAWSCron("cron(0 5 * *)"))
    }

    func testParseAWSCronNextRun() {
        XCTAssertEqual(Cron.parseAWSCronNextRun("cron(0 5 * * ? *)", after: date("2026-11-13T04:00:00Z")), "2026-11-13T05:00:00Z")
        XCTAssertEqual(Cron.parseAWSCronNextRun("cron(0 5 * * ? *)", after: date("2026-11-13T05:00:00Z")), "2026-11-14T05:00:00Z")
        XCTAssertEqual(Cron.parseAWSCronNextRun("cron(0 3 ? * SUN *)", after: date("2026-11-13T04:00:00Z")), "2026-11-15T03:00:00Z")
        XCTAssertEqual(Cron.parseAWSCronNextRun("cron(0 0 1 * ? *)", after: date("2026-11-13T04:00:00Z")), "2026-12-01T00:00:00Z")
        XCTAssertEqual(Cron.parseAWSCronNextRun("cron(*/15 * * * ? *)", after: date("2026-11-13T04:07:00Z")), "2026-11-13T04:15:00Z")
        XCTAssertNil(Cron.parseAWSCronNextRun("not a cron", after: Date()))
        XCTAssertNil(Cron.parseAWSCronNextRun("cron(99 5 * * ? *)", after: Date()))
    }
}

final class GoJSONTests: XCTestCase {
    struct Inner: Encodable { var b: String; var a: Int }
    struct Outer: Encodable {
        var z: String; var list: [Inner]; var empty: [Int]; var opt: String?; var map: [String: Int]; var flag: Bool
        enum CodingKeys: String, CodingKey { case z, list, empty, opt, map, flag }
        func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(z, forKey: .z); try c.encode(list, forKey: .list); try c.encode(empty, forKey: .empty)
            try c.encode(opt, forKey: .opt); try c.encode(map, forKey: .map); try c.encode(flag, forKey: .flag)
        }
    }

    func testMatchesGoMarshalIndent() throws {
        let v = Outer(z: "<a&b> \"q\" \u{2028}", list: [Inner(b: "x", a: 1)], empty: [], opt: nil, map: ["b": 2, "a": 1], flag: true)
        let s = String(decoding: try GoJSON.encode(v), as: UTF8.self)
        XCTAssertEqual(s, """
        {
          "z": "\\u003ca\\u0026b\\u003e \\"q\\" \\u2028",
          "list": [
            {
              "b": "x",
              "a": 1
            }
          ],
          "empty": [],
          "opt": null,
          "map": {
            "a": 1,
            "b": 2
          },
          "flag": true
        }
        """)
    }

    func testCompactAndEmptyObject() throws {
        XCTAssertEqual(String(decoding: try GoJSON.encode(Inner(b: "x", a: -3), indent: false), as: UTF8.self), #"{"b":"x","a":-3}"#)
        XCTAssertEqual(String(decoding: try GoJSON.encode([String: Int]()), as: UTF8.self), "{}")
        XCTAssertEqual(String(decoding: try GoJSON.encode([Inner]()), as: UTF8.self), "[]")
    }
}
