// Ports of internal/actions/{validate,backup,restore}_test.go, against the
// stub transport. Every write is checked for exactly the wire parameters
// v0.1 sent, and for the calls that must never happen.
import XCTest
@testable import ADBMCore

let region = "ap-southeast-1"
let acct1 = Account(id: "acct-1", name: "Test", profile: "shared-service-test", regions: [region])

func instanceXML(_ id: String, extra: String = "") -> String {
    "<DBInstances><DBInstance><DBInstanceIdentifier>\(id)</DBInstanceIdentifier>\(extra)</DBInstance></DBInstances>"
}

func clusterXML(_ id: String, extra: String = "") -> String {
    "<DBClusters><DBCluster><DBClusterIdentifier>\(id)</DBClusterIdentifier>\(extra)</DBCluster></DBClusters>"
}

/// Answers Describe* with `xml` only for `id`, not-found otherwise.
func onlyFor(_ param: String, _ id: String, _ op: AWSOperation, _ xml: String, notFound code: String) -> StubHandler {
    { c in c.form[param] == id ? (200, xmlResult(op, xml)) : xmlError(code, "not found") }
}

final class ValidateTests: XCTestCase {
    func testValidateIdentifier() {
        for (id, bad) in [("", true), ("my-db-1", false), ("1-leading-digit", true), ("has--double-hyphen", true),
                          ("trailing-hyphen-", true), ("has_underscore", true), ("UpperCamelDB", false),
                          (String(repeating: "\u{0}", count: 64), true), (String(repeating: "a", count: 64), true),
                          (String(repeating: "a", count: 63), false)] {
            if bad { XCTAssertThrowsError(try Validate.identifier(id), id) } else { XCTAssertNoThrow(try Validate.identifier(id), id) }
        }
    }

    func testNewTargetRejectsExistingIdentifier() async {
        let h = Harness()
        h.stub.on(.describeDBInstances) { c in (200, xmlResult(.describeDBInstances, instanceXML(c.form["DBInstanceIdentifier"] ?? ""))) }
        await assertThrows({ try await Validate.newTarget(h.client(), kind: .instance, source: "source-db", target: "already-exists") },
                           contains: "already exists")
    }

    func testNewTargetAllowsNewIdentifierWhenSourceNotFound() async throws {
        let h = Harness()
        try await Validate.newTarget(h.client(), kind: .instance, source: "source-db", target: "brand-new-db")
        try await Validate.newTarget(h.client(), kind: .cluster, source: "source-db", target: "brand-new-db")
    }

    func testNewTargetRejectsSameAsSource() async {
        let h = Harness()
        await assertThrows({ try await Validate.newTarget(h.client(), kind: .instance, source: "same-db", target: "same-db") })
        XCTAssertTrue(h.stub.calls.isEmpty)
    }

    func testNewTargetRejectsInvalidIdentifier() async {
        let h = Harness()
        await assertThrows({ try await Validate.newTarget(h.client(), kind: .instance, source: "source-db", target: "--bad") })
        XCTAssertTrue(h.stub.calls.isEmpty)
    }

    func testNewTargetPropagatesNonNotFoundErrors() async {
        let h = Harness()
        h.stub.on(.describeDBInstances) { _ in xmlError("InvalidDBInstanceState", "boom", status: 400) }
        await assertThrows({ try await Validate.newTarget(h.client(), kind: .instance, source: "source-db", target: "some-target") },
                           contains: "boom")
    }

    func testLookupSourceConfigInstance() async throws {
        let h = Harness()
        h.stub.onXML(.describeDBInstances, instanceXML("source-db", extra: """
            <DBInstanceClass>db.r6g.large</DBInstanceClass><Engine>postgres</Engine>
            <DBSubnetGroup><DBSubnetGroupName>subnet-group-a</DBSubnetGroupName></DBSubnetGroup>
            <DBParameterGroups><DBParameterGroup><DBParameterGroupName>param-group-a</DBParameterGroupName></DBParameterGroup></DBParameterGroups>
            <VpcSecurityGroups><VpcSecurityGroupMembership><VpcSecurityGroupId>sg-1</VpcSecurityGroupId></VpcSecurityGroupMembership>
            <VpcSecurityGroupMembership><VpcSecurityGroupId>sg-2</VpcSecurityGroupId></VpcSecurityGroupMembership></VpcSecurityGroups>
            """))
        let cfg = try await SourceConfig.lookup(h.client(), kind: .instance, identifier: "source-db")
        XCTAssertEqual(cfg.instanceClass, "db.r6g.large")
        XCTAssertEqual(cfg.engine, "postgres")
        XCTAssertEqual(cfg.subnetGroupName, "subnet-group-a")
        XCTAssertEqual(cfg.parameterGroupName, "param-group-a")
        XCTAssertEqual(cfg.securityGroupIds, ["sg-1", "sg-2"])
    }

    func testLookupSourceConfigCluster() async throws {
        let h = Harness()
        h.stub.onXML(.describeDBClusters, clusterXML("source-cluster", extra: """
            <Engine>aurora-postgresql</Engine><DBSubnetGroup>subnet-group-b</DBSubnetGroup>
            <DBClusterParameterGroup>cluster-param-group-b</DBClusterParameterGroup>
            <VpcSecurityGroups><VpcSecurityGroupMembership><VpcSecurityGroupId>sg-9</VpcSecurityGroupId></VpcSecurityGroupMembership></VpcSecurityGroups>
            """))
        let cfg = try await SourceConfig.lookup(h.client(), kind: .cluster, identifier: "source-cluster")
        XCTAssertEqual(cfg.engine, "aurora-postgresql")
        XCTAssertEqual(cfg.subnetGroupName, "subnet-group-b")
        XCTAssertEqual(cfg.parameterGroupName, "cluster-param-group-b")
        XCTAssertEqual(cfg.securityGroupIds, ["sg-9"])
    }

    func testResolvedNetworkingOverridesWinOverSource() {
        let src = SourceConfig(subnetGroupName: "source-subnet", securityGroupIds: ["sg-source"],
                               parameterGroupName: "source-param-group", instanceClass: "db.r6g.large")
        let req = RestoreReq(accountId: "a", region: region, kind: .instance, source: .snapshot, sourceDbIdentifier: "s",
                             targetIdentifier: "t", instanceClass: "db.r6g.xlarge", subnetGroup: "override-subnet",
                             securityGroups: ["sg-override"])
        let r = src.resolved(req)
        XCTAssertEqual(r.subnet, "override-subnet")
        XCTAssertEqual(r.sgs, ["sg-override"])
        XCTAssertEqual(r.instanceClass, "db.r6g.xlarge")
        XCTAssertEqual(r.paramGroup, "source-param-group")
    }

    func testResolvedNetworkingFallsBackToSourceWhenNoOverride() {
        let src = SourceConfig(subnetGroupName: "source-subnet", securityGroupIds: ["sg-source"],
                               parameterGroupName: "source-param-group", instanceClass: "db.r6g.large")
        let r = src.resolved(RestoreReq(accountId: "a", region: region, kind: .instance, source: .snapshot,
                                        sourceDbIdentifier: "s", targetIdentifier: "t"))
        XCTAssertEqual(r.subnet, "source-subnet")
        XCTAssertEqual(r.sgs, ["sg-source"])
        XCTAssertEqual(r.instanceClass, "db.r6g.large")
        XCTAssertEqual(r.paramGroup, "source-param-group")
    }
}

final class BackupActionTests: XCTestCase {
    func testCreateSnapshotDefaultsNameForInstance() async throws {
        let h = Harness()
        h.stub.on(.createDBSnapshot) { c in
            (200, xmlResult(.createDBSnapshot, """
                <DBSnapshot><DBSnapshotIdentifier>\(c.form["DBSnapshotIdentifier"]!)</DBSnapshotIdentifier>
                <DBInstanceIdentifier>\(c.form["DBInstanceIdentifier"]!)</DBInstanceIdentifier>
                <DBSnapshotArn>arn:aws:rds:ap-southeast-1:123456789012:snapshot:x</DBSnapshotArn>
                <Status>creating</Status><Engine>postgres</Engine></DBSnapshot>
                """))
        }
        let snap = try await h.actions.createSnapshot(acct1, CreateSnapshotReq(accountId: "acct-1", region: region, kind: .instance, dbIdentifier: "prod-db"))
        XCTAssertEqual(h.stub.calls(.createDBSnapshot).first?.form["DBSnapshotIdentifier"], "prod-db-manual-20260115-1030")
        XCTAssertEqual(snap.id, "prod-db-manual-20260115-1030")
        XCTAssertEqual(snap.source, .manual)
        XCTAssertEqual(snap.kind, .instance)
        XCTAssertEqual(snap.status, "creating")
        let audit = try h.audit.readAll()
        XCTAssertEqual(audit.map(\.action), ["CreateSnapshot"])
        XCTAssertEqual(audit.first?.result, "creating")
        XCTAssertEqual(audit.first?.time, "2026-01-15T10:30:00Z")
    }

    func testCreateSnapshotClusterUsesClusterCall() async throws {
        let h = Harness()
        h.stub.onXML(.createDBClusterSnapshot, """
            <DBClusterSnapshot><DBClusterSnapshotIdentifier>my-snap</DBClusterSnapshotIdentifier>
            <DBClusterIdentifier>prod-cluster</DBClusterIdentifier><Status>creating</Status></DBClusterSnapshot>
            """)
        let snap = try await h.actions.createSnapshot(acct1, CreateSnapshotReq(accountId: "acct-1", region: region, kind: .cluster,
                                                                               dbIdentifier: "prod-cluster", snapshotName: "my-snap"))
        XCTAssertEqual(h.stub.operations, [.createDBClusterSnapshot])
        XCTAssertEqual(h.stub.calls.first?.form["DBClusterIdentifier"], "prod-cluster")
        XCTAssertEqual(snap.kind, .cluster)
    }

    func testCreateSnapshotRejectsMissingDBIdentifierAndBadName() async {
        let h = Harness()
        await assertThrows({ try await h.actions.createSnapshot(acct1, CreateSnapshotReq(accountId: "acct-1", region: region, dbIdentifier: "")) },
                           contains: "dbIdentifier is required")
        await assertThrows({ try await h.actions.createSnapshot(acct1, CreateSnapshotReq(accountId: "acct-1", region: region, dbIdentifier: "db",
                                                                                         snapshotName: "bad_name")) })
        XCTAssertTrue(h.stub.calls.isEmpty)
    }

    func testStartBackupJobUsesDefaultVaultAndRole() async throws {
        let h = Harness()
        h.stub.onJSON(.startBackupJob, ["BackupJobId": "job-1", "CreationDate": 1_768_473_000])
        let a = try await h.actions.startBackupJob(acct1, StartBackupJobReq(accountId: "acct-1", region: region, kind: .instance,
                                                                            dbIdentifier: "prod-db", vaultName: ""))
        let body = try XCTUnwrap(h.stub.calls(.startBackupJob).first?.json)
        XCTAssertEqual(body["BackupVaultName"]?.string, "Default")
        XCTAssertEqual(body["IamRoleArn"]?.string, "arn:aws:iam::123456789012:role/service-role/AWSBackupDefaultServiceRole")
        XCTAssertEqual(body["ResourceArn"]?.string, "arn:aws:rds:ap-southeast-1:123456789012:db:prod-db")
        XCTAssertEqual(a.source, .backupJob)
        XCTAssertEqual(a.message, "backup job job-1 started in vault Default")
        XCTAssertEqual(a.time, "2026-01-15T10:30:00Z")
        XCTAssertEqual(h.stub.operations, [.getCallerIdentity, .startBackupJob])
    }

    func testCreateBackupPlanRejectsRetentionBelowMinimumAndMissingCron() async {
        let h = Harness()
        await assertThrows({ try await h.actions.createBackupPlan(acct1, CreateBackupPlanReq(accountId: "acct-1", region: region, kind: .instance,
            dbIdentifier: "prod-db", planName: "", ruleName: "", cron: "cron(0 5 * * ? *)", vaultName: "", retentionDays: 6)) },
                           contains: "retentionDays must be at least 7")
        await assertThrows({ try await h.actions.createBackupPlan(acct1, CreateBackupPlanReq(accountId: "acct-1", region: region, kind: .instance,
            dbIdentifier: "prod-db", planName: "", ruleName: "", cron: "", vaultName: "", retentionDays: 7)) },
                           contains: "cron schedule expression is required")
        XCTAssertTrue(h.stub.calls.isEmpty)
    }

    func testCreateBackupPlanCreatesPlanAndSelectionByArn() async throws {
        let h = Harness()
        h.stub.onXML(.describeDBInstances, "<DBInstances></DBInstances>")
        h.stub.onXML(.describeDBClusters, "<DBClusters></DBClusters>")
        h.stub.onJSON(.createBackupPlan, ["BackupPlanId": "plan-1"])
        h.stub.onJSON(.createBackupSelection, ["SelectionId": "sel-1"])
        let summary = try await h.actions.createBackupPlan(acct1, CreateBackupPlanReq(accountId: "acct-1", region: region, kind: .instance,
            dbIdentifier: "prod-db", planName: "", ruleName: "", cron: "cron(0 5 * * ? *)", vaultName: "", retentionDays: 30))
        let plan = try XCTUnwrap(h.stub.calls(.createBackupPlan).first?.json?["BackupPlan"])
        XCTAssertEqual(plan["BackupPlanName"]?.string, "prod-db-plan")
        let rules = try XCTUnwrap(plan["Rules"]?.array)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0]["Lifecycle"]?["DeleteAfterDays"]?.int, 30)
        XCTAssertEqual(rules[0]["RuleName"]?.string, "default-rule")
        XCTAssertEqual(rules[0]["TargetBackupVaultName"]?.string, "Default")
        let selCall = try XCTUnwrap(h.stub.calls(.createBackupSelection).first)
        XCTAssertEqual(selCall.path, "/backup/plans/plan-1/selections/")
        let sel = try XCTUnwrap(selCall.json?["BackupSelection"])
        XCTAssertEqual(sel["Resources"]?.array?.compactMap(\.string), ["arn:aws:rds:ap-southeast-1:123456789012:db:prod-db"])
        XCTAssertEqual(sel["SelectionName"]?.string, "prod-db-plan-selection")
        // The database is not in inventory, so the fallback summary is returned.
        XCTAssertEqual(summary.db, "prod-db")
        XCTAssertEqual(summary.awsBackup, [AWSBackupPlanRef(planId: "plan-1", planName: "prod-db-plan", ruleName: "default-rule",
                                                            cron: "cron(0 5 * * ? *)", lifecycle: "30 day(s)", vault: "Default")])
        XCTAssertEqual(try h.audit.readAll().map(\.result), ["plan-1"])
    }

    func testModifyAutomatedBackupRejectsMissingFields() async {
        let h = Harness()
        await assertThrows({ try await h.actions.modifyAutomatedBackup(acct1, ModifyAutomatedBackupReq(accountId: "acct-1", region: region,
                                                                                                       kind: .instance, dbIdentifier: "prod-db")) },
                           contains: "window or retentionDays is required")
        XCTAssertTrue(h.stub.calls.isEmpty)
    }

    func testModifyAutomatedBackupBlocksLoweringRetention() async {
        let h = Harness()
        h.stub.onXML(.describeDBInstances, instanceXML("prod-db", extra: "<BackupRetentionPeriod>30</BackupRetentionPeriod>"))
        await assertThrows({ try await h.actions.modifyAutomatedBackup(acct1, ModifyAutomatedBackupReq(accountId: "acct-1", region: region,
            kind: .instance, dbIdentifier: "prod-db", retentionDays: 7)) },
                           contains: "retention can only be raised, not lowered: current is 30 day(s), requested 7")
        XCTAssertTrue(h.stub.calls(.modifyDBInstance).isEmpty)
    }

    func testModifyAutomatedBackupAllowsRaisingRetention() async throws {
        let h = Harness()
        let modified = Locked(false)
        h.stub.on(.describeDBInstances) { _ in
            let days = modified.value ? 45 : 7
            return (200, xmlResult(.describeDBInstances, instanceXML("prod-db", extra: "<BackupRetentionPeriod>\(days)</BackupRetentionPeriod>")))
        }
        h.stub.on(.modifyDBInstance) { _ in modified.value = true; return (200, xmlResult(.modifyDBInstance, "")) }
        h.stub.onXML(.describeDBClusters, "<DBClusters></DBClusters>")
        let db = try await h.actions.modifyAutomatedBackup(acct1, ModifyAutomatedBackupReq(accountId: "acct-1", region: region,
            kind: .instance, dbIdentifier: "prod-db", retentionDays: 45))
        let form = try XCTUnwrap(h.stub.calls(.modifyDBInstance).first?.form)
        XCTAssertEqual(form["BackupRetentionPeriod"], "45")
        XCTAssertEqual(form["ApplyImmediately"], "true")
        XCTAssertEqual(form["DBInstanceIdentifier"], "prod-db")
        XCTAssertNil(form["PreferredBackupWindow"])
        XCTAssertEqual(db.backupRetentionDays, 45)
    }

    func testCurrentRetentionCluster() async throws {
        let h = Harness()
        h.stub.onXML(.describeDBClusters, clusterXML("prod-cluster", extra: "<BackupRetentionPeriod>14</BackupRetentionPeriod>"))
        let r = try await Actions.currentRetention(h.client(), kind: .cluster, identifier: "prod-cluster")
        XCTAssertEqual(r, 14)
        XCTAssertEqual(h.stub.calls.first?.form["DBClusterIdentifier"], "prod-cluster")
    }
}

final class RestoreActionTests: XCTestCase {
    func req(_ kind: DBKind, _ source: RestoreSource, src: String, target: String, snapshot: String? = nil,
             rp: String? = nil, time: String? = nil, cls: String? = nil) -> RestoreReq {
        RestoreReq(accountId: "acct-1", region: region, kind: kind, source: source, sourceDbIdentifier: src, snapshotId: snapshot,
                   recoveryPointArn: rp, restoreTime: time, targetIdentifier: target, instanceClass: cls)
    }

    func testWriterInstanceIdentifier() {
        XCTAssertEqual(Actions.writerInstanceIdentifier("my-cluster"), "my-cluster-1")
        let long = Actions.writerInstanceIdentifier(String(repeating: "a", count: 70))
        XCTAssertLessThanOrEqual(long.count, 63)
        XCTAssertTrue(long.hasSuffix("-1"))
        // A cut landing on a hyphen must not produce "--1".
        XCTAssertEqual(Actions.writerInstanceIdentifier(String(repeating: "a", count: 60) + "-bbbb"), String(repeating: "a", count: 60) + "-1")
    }

    func testParseRestoreTime() throws {
        XCTAssertNil(try Actions.parseRestoreTime(nil))
        XCTAssertNil(try Actions.parseRestoreTime(""))
        XCTAssertEqual(try Actions.parseRestoreTime("2026-01-02T03:04:05Z"), RFC3339.date("2026-01-02T03:04:05Z"))
        XCTAssertThrowsError(try Actions.parseRestoreTime("not-a-time"))
    }

    func testRestoreRejectsExistingTarget() async {
        let h = Harness()
        h.stub.on(.describeDBInstances) { c in (200, xmlResult(.describeDBInstances, instanceXML(c.form["DBInstanceIdentifier"] ?? ""))) }
        await assertThrows({ try await h.actions.restore(acct1, self.req(.instance, .snapshot, src: "prod-db", target: "prod-db-restored",
                                                                         snapshot: "prod-db-manual-20261113-0900")) })
        XCTAssertTrue(h.stub.calls(.restoreDBInstanceFromDBSnapshot).isEmpty)
    }

    func testRestoreRejectsMissingTargetIdentifier() async {
        let h = Harness()
        await assertThrows({ try await h.actions.restore(acct1, self.req(.instance, .snapshot, src: "prod-db", target: "", snapshot: "s")) },
                           contains: "targetIdentifier is required")
        XCTAssertTrue(h.stub.calls.isEmpty)
    }

    func testRestoreFromSnapshotInstance() async throws {
        let h = Harness()
        h.stub.on(.describeDBInstances, onlyFor("DBInstanceIdentifier", "prod-db", .describeDBInstances,
            instanceXML("prod-db", extra: "<DBInstanceClass>db.r6g.large</DBInstanceClass><Engine>postgres</Engine>"), notFound: "DBInstanceNotFound"))
        h.stub.onXML(.restoreDBInstanceFromDBSnapshot, "")
        let a = try await h.actions.restore(acct1, req(.instance, .snapshot, src: "prod-db", target: "prod-db-restored",
                                                       snapshot: "prod-db-manual-20261113-0900"))
        let form = try XCTUnwrap(h.stub.calls(.restoreDBInstanceFromDBSnapshot).first?.form)
        XCTAssertEqual(form["DBInstanceIdentifier"], "prod-db-restored")
        XCTAssertEqual(form["DBSnapshotIdentifier"], "prod-db-manual-20261113-0900")
        XCTAssertEqual(form["DBInstanceClass"], "db.r6g.large")
        XCTAssertEqual(form["PubliclyAccessible"], "false")
        XCTAssertNil(form["DBSubnetGroupName"])
        XCTAssertEqual(a.db, "prod-db-restored")
        XCTAssertEqual(a.message, #"instance "prod-db-restored" restoring from snapshot "prod-db-manual-20261113-0900""#)
        XCTAssertEqual(a.source, .app)
    }

    func testRestoreFromSnapshotClusterCreatesWriterInstance() async throws {
        let h = Harness()
        h.stub.on(.describeDBClusters, onlyFor("DBClusterIdentifier", "prod-cluster", .describeDBClusters,
            clusterXML("prod-cluster", extra: """
                <Engine>aurora-postgresql</Engine><VpcSecurityGroups><VpcSecurityGroupMembership><VpcSecurityGroupId>sg-1</VpcSecurityGroupId>
                </VpcSecurityGroupMembership><VpcSecurityGroupMembership><VpcSecurityGroupId>sg-2</VpcSecurityGroupId></VpcSecurityGroupMembership></VpcSecurityGroups>
                """), notFound: "DBClusterNotFoundFault"))
        h.stub.onXML(.describeDBClusterSnapshots, """
            <DBClusterSnapshots><DBClusterSnapshot><DBClusterSnapshotIdentifier>s</DBClusterSnapshotIdentifier>
            <Engine>aurora-postgresql</Engine><EngineVersion>15.4</EngineVersion></DBClusterSnapshot></DBClusterSnapshots>
            """)
        h.stub.onXML(.restoreDBClusterFromSnapshot, "")
        h.stub.onXML(.createDBInstance, "")
        _ = try await h.actions.restore(acct1, req(.cluster, .snapshot, src: "prod-cluster", target: "prod-cluster-restored",
                                                   snapshot: "prod-cluster-manual-20261113-0900", cls: "db.r6g.large"))
        XCTAssertEqual(h.stub.operations.filter { !$0.isRead }, [.restoreDBClusterFromSnapshot, .createDBInstance])
        let restore = try XCTUnwrap(h.stub.calls(.restoreDBClusterFromSnapshot).first?.form)
        XCTAssertEqual(restore["Engine"], "aurora-postgresql")
        XCTAssertEqual(restore["EngineVersion"], "15.4")
        XCTAssertEqual(restore["VpcSecurityGroupIds.VpcSecurityGroupId.1"], "sg-1")
        XCTAssertEqual(restore["VpcSecurityGroupIds.VpcSecurityGroupId.2"], "sg-2")
        let create = try XCTUnwrap(h.stub.calls(.createDBInstance).first?.form)
        XCTAssertEqual(create["DBClusterIdentifier"], "prod-cluster-restored")
        XCTAssertEqual(create["DBInstanceIdentifier"], "prod-cluster-restored-1")
        XCTAssertEqual(create["DBInstanceClass"], "db.r6g.large")
        XCTAssertEqual(try h.audit.readAll().map(\.action), ["RestoreDBClusterFromSnapshot", "CreateDBInstance"])
    }

    func testRestoreFromPITRClusterUsesSourceEngine() async throws {
        let h = Harness()
        h.stub.on(.describeDBClusters, onlyFor("DBClusterIdentifier", "prod-cluster", .describeDBClusters,
            clusterXML("prod-cluster", extra: "<Engine>aurora-mysql</Engine>"), notFound: "DBClusterNotFoundFault"))
        h.stub.onXML(.restoreDBClusterToPointInTime, "")
        h.stub.onXML(.createDBInstance, "")
        let a = try await h.actions.restore(acct1, req(.cluster, .pitr, src: "prod-cluster", target: "prod-cluster-pitr", cls: "db.r6g.large"))
        let restore = try XCTUnwrap(h.stub.calls(.restoreDBClusterToPointInTime).first?.form)
        XCTAssertEqual(restore["UseLatestRestorableTime"], "true")
        XCTAssertNil(restore["RestoreToTime"])
        XCTAssertEqual(h.stub.calls(.createDBInstance).first?.form["Engine"], "aurora-mysql")
        XCTAssertEqual(a.message, #"cluster "prod-cluster-pitr" restoring to a point in time from "prod-cluster""#)
    }

    func testRestorePITRInstanceWithExplicitTime() async throws {
        let h = Harness()
        h.stub.onXML(.restoreDBInstanceToPointInTime, "")
        _ = try await h.actions.restore(acct1, req(.instance, .pitr, src: "prod-db", target: "prod-db-pitr", time: "2026-01-02T03:04:05Z"))
        let form = try XCTUnwrap(h.stub.calls(.restoreDBInstanceToPointInTime).first?.form)
        XCTAssertEqual(form["RestoreTime"], "2026-01-02T03:04:05Z")
        XCTAssertEqual(form["TargetDBInstanceIdentifier"], "prod-db-pitr")
        XCTAssertEqual(form["SourceDBInstanceIdentifier"], "prod-db")
        XCTAssertNil(form["UseLatestRestorableTime"])
        XCTAssertNil(form["DBInstanceClass"], "source lookup failed and no override: AWS defaults apply")
    }

    func testRestorePITRClusterWithoutSourceEngineFailsAfterRestore() async {
        let h = Harness()
        h.stub.onXML(.restoreDBClusterToPointInTime, "")
        await assertThrows({ try await h.actions.restore(acct1, self.req(.cluster, .pitr, src: "gone", target: "new-c", cls: "db.r6g.large")) },
                           contains: "could not determine engine for source cluster \"gone\"")
        XCTAssertTrue(h.stub.calls(.createDBInstance).isEmpty)
    }

    func testRestoreFromRecoveryPointUsesVaultFromInventoryAndMetadataResourceType() async throws {
        let h = Harness()
        let rp = "arn:aws:backup:ap-southeast-1:123456789012:recovery-point:abc"
        h.stub.onXML(.describeDBSnapshots, "<DBSnapshots></DBSnapshots>")
        h.stub.onJSON(.listRecoveryPointsByResource, ["RecoveryPoints": [[
            "RecoveryPointArn": rp, "BackupVaultName": "prod-vault", "Status": "COMPLETED", "CreationDate": 1_768_400_000,
        ]]])
        h.stub.onJSON(.getRecoveryPointRestoreMetadata, ["ResourceType": "RDS", "RestoreMetadata": ["Engine": "postgres"]])
        h.stub.onJSON(.startRestoreJob, ["RestoreJobId": "restore-1"])
        let a = try await h.actions.restore(acct1, req(.instance, .recoveryPoint, src: "prod-db", target: "prod-db-from-rp", rp: rp))
        let meta = try XCTUnwrap(h.stub.calls(.getRecoveryPointRestoreMetadata).first)
        XCTAssertTrue(meta.path.hasPrefix("/backup-vaults/prod-vault/recovery-points/"))
        let body = try XCTUnwrap(h.stub.calls(.startRestoreJob).first?.json)
        XCTAssertEqual(body["ResourceType"]?.string, "RDS")
        XCTAssertEqual(body["Metadata"]?["DBInstanceIdentifier"]?.string, "prod-db-from-rp")
        XCTAssertEqual(body["Metadata"]?["Engine"]?.string, "postgres")
        XCTAssertEqual(body["IamRoleArn"]?.string, "arn:aws:iam::123456789012:role/service-role/AWSBackupDefaultServiceRole")
        XCTAssertEqual(a.source, .restoreJob)
        XCTAssertEqual(a.message, "restore job restore-1 started from recovery point \"\(rp)\"")
    }

    func testRestoreFromRecoveryPointRejectsUnknownArn() async {
        let h = Harness()
        h.stub.onXML(.describeDBSnapshots, "<DBSnapshots></DBSnapshots>")
        await assertThrows({ try await h.actions.restore(acct1, self.req(.instance, .recoveryPoint, src: "prod-db", target: "prod-db-from-rp",
                                                                         rp: "arn:aws:backup:ap-southeast-1:123456789012:recovery-point:unknown")) },
                           contains: "cannot determine its backup vault")
        XCTAssertTrue(h.stub.calls(.startRestoreJob).isEmpty)
    }

    /// No restore path ever modifies, or creates anything other than, the
    /// brand-new target.
    func testRestoreNeverTouchesSource() async throws {
        let h = Harness()
        h.stub.onXML(.restoreDBInstanceToPointInTime, "")
        _ = try await h.actions.restore(acct1, req(.instance, .pitr, src: "prod-db", target: "prod-db-copy"))
        let writes = h.stub.calls.filter { !$0.op.isRead }
        XCTAssertEqual(writes.map(\.op), [.restoreDBInstanceToPointInTime])
        XCTAssertFalse(writes.flatMap { $0.form.filter { $0.key.hasSuffix("Identifier") && !$0.key.hasPrefix("Source") }.map(\.value) }.contains("prod-db"))
    }
}

/// A tiny lock-protected box for state shared with @Sendable stub handlers.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
