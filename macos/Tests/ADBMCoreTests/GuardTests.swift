// Port of internal/awsx/guard_test.go: the allowlist, the destructive-name
// block, the backup-settings-only modify rule, the 7-day plan floor and the
// read-only backstop. Also checks the guard runs before any byte is sent.
import XCTest
@testable import ADBMCore

final class GuardTests: XCTestCase {
    func testAllowsReadOnlyAndSafeMutatingCalls() throws {
        for (svc, op) in [("RDS", "DescribeDBInstances"), ("RDS", "DescribeDBClusters"), ("RDS", "DescribeDBSnapshots"),
                          ("RDS", "ListTagsForResource"), ("RDS", "CreateDBSnapshot"), ("RDS", "RestoreDBInstanceFromDBSnapshot"),
                          ("Backup", "ListRecoveryPointsByResource"), ("Backup", "StartBackupJob"), ("STS", "GetCallerIdentity")] {
            XCTAssertNoThrow(try SafetyGuard.checkName(svc, op, readOnly: false), "\(svc)/\(op)")
        }
    }

    func testBlocksEveryDestructiveOperation() {
        let cases = [("RDS", "DeleteDBInstance"), ("RDS", "DeleteDBCluster"), ("RDS", "DeleteDBSnapshot"),
                     ("RDS", "DeleteDBClusterSnapshot"), ("RDS", "StopDBInstance"), ("RDS", "StopDBCluster"),
                     ("RDS", "RebootDBInstance"), ("RDS", "FailoverDBCluster"), ("RDS", "ModifyDBSnapshotAttribute"),
                     ("RDS", "ModifyDBClusterSnapshotAttribute"), ("Backup", "DeleteBackupPlan"), ("Backup", "DeleteBackupVault"),
                     ("Backup", "DeleteRecoveryPoint"), ("Backup", "DeleteBackupSelection"), ("Backup", "UpdateBackupPlan"),
                     ("Backup", "PutBackupVaultAccessPolicy"), ("Backup", "PutBackupVaultLockConfiguration"),
                     // Not forbidden by name, just never allowlisted.
                     ("RDS", "ModifyDBInstanceToMaintenanceWindow"), ("RDS", "SomeFutureOperation"), ("EC2", "DescribeInstances"),
                     // Right name, wrong service.
                     ("Backup", "DescribeDBInstances")]
        for (svc, op) in cases {
            XCTAssertThrowsError(try SafetyGuard.checkName(svc, op, readOnly: false), "\(svc)/\(op)") {
                XCTAssertTrue($0 is OperationForbidden, "\(svc)/\(op): \(type(of: $0))")
            }
        }
    }

    func testModifyDBInstanceOnlyAllowsBackupSettings() {
        let id = ["DBInstanceIdentifier": "my-db"]
        for extra in [["BackupRetentionPeriod": "14"], ["PreferredBackupWindow": "03:00-03:30"],
                      ["ApplyImmediately": "true", "BackupRetentionPeriod": "7"]] {
            XCTAssertNoThrow(try SafetyGuard.check(.modifyDBInstance, readOnly: false, params: .form(id.merging(extra) { $1 })), "\(extra)")
        }
        for extra in [["DeletionProtection": "false"], ["MasterUserPassword": "hunter2"], ["EngineVersion": "15.4"],
                      ["AllocatedStorage": "999"], ["BackupRetentionPeriod": "0"]] {
            XCTAssertThrowsError(try SafetyGuard.check(.modifyDBInstance, readOnly: false, params: .form(id.merging(extra) { $1 })), "\(extra)")
        }
    }

    func testModifyDBClusterOnlyAllowsBackupSettings() {
        let id = ["DBClusterIdentifier": "my-cluster"]
        XCTAssertNoThrow(try SafetyGuard.check(.modifyDBCluster, readOnly: false, params: .form(id.merging(["BackupRetentionPeriod": "30"]) { $1 })))
        XCTAssertThrowsError(try SafetyGuard.check(.modifyDBCluster, readOnly: false, params: .form(id.merging(["DeletionProtection": "false"]) { $1 })))
        XCTAssertThrowsError(try SafetyGuard.check(.modifyDBCluster, readOnly: false, params: .form(id.merging(["BackupRetentionPeriod": "0"]) { $1 })))
    }

    func testCreateBackupPlanEnforcesMinimumLifecycle() {
        func plan(_ days: Int?) -> GuardParams {
            var rule: [String: JSONValue] = ["RuleName": .string("daily-rule"), "TargetBackupVaultName": .string("vault")]
            rule["Lifecycle"] = .object(days.map { ["DeleteAfterDays": .number(Double($0))] } ?? [:])
            return .json(.object(["BackupPlan": .object(["BackupPlanName": .string("daily"), "Rules": .array([.object(rule)])])]))
        }
        XCTAssertNoThrow(try SafetyGuard.check(.createBackupPlan, readOnly: false, params: plan(35)))
        XCTAssertNoThrow(try SafetyGuard.check(.createBackupPlan, readOnly: false, params: plan(7)))
        XCTAssertThrowsError(try SafetyGuard.check(.createBackupPlan, readOnly: false, params: plan(1)))
        XCTAssertNoThrow(try SafetyGuard.check(.createBackupPlan, readOnly: false, params: plan(nil)))
    }

    func testReadOnlyBlocksEveryWriteButAllowsReads() {
        for (svc, op) in [("RDS", "DescribeDBInstances"), ("RDS", "DescribeDBClusters"), ("RDS", "DescribeDBSnapshots"),
                          ("RDS", "ListTagsForResource"), ("Backup", "ListRecoveryPointsByResource"), ("Backup", "GetBackupPlan"),
                          ("STS", "GetCallerIdentity")] {
            XCTAssertNoThrow(try SafetyGuard.checkName(svc, op, readOnly: true), "\(svc)/\(op)")
        }
        let writes = AWSOperation.allCases.filter { !$0.isRead }
        XCTAssertEqual(Set(writes.map(\.rawValue)), ["CreateDBSnapshot", "CreateDBClusterSnapshot", "CreateDBInstance",
            "RestoreDBInstanceFromDBSnapshot", "RestoreDBClusterFromSnapshot", "RestoreDBInstanceToPointInTime",
            "RestoreDBClusterToPointInTime", "ModifyDBInstance", "ModifyDBCluster", "AddTagsToResource", "StartBackupJob",
            "StartRestoreJob", "CreateBackupPlan", "CreateBackupSelection"])
        for op in writes {
            XCTAssertThrowsError(try SafetyGuard.checkName(op.service.rawValue, op.rawValue, readOnly: true), op.rawValue)
        }
    }

    /// The guard sits in front of the transport: a blocked call sends nothing.
    func testBlockedCallNeverReachesTransport() async {
        let h = Harness()
        await assertThrows({ try await h.client(readOnly: true).query(.createDBSnapshot, ["DBSnapshotIdentifier": "x", "DBInstanceIdentifier": "y"]) },
                           contains: "read-only")
        await assertThrows({ try await h.client().query(.modifyDBInstance, ["DBInstanceIdentifier": "x", "DeletionProtection": "false"]) },
                           contains: "DeletionProtection")
        XCTAssertTrue(h.stub.calls.isEmpty)
    }

    func testEveryAllowlistedNameIsNotDestructive() {
        for op in AWSOperation.allCases {
            XCTAssertNil(op.rawValue.firstMatch(of: SafetyGuard.forbiddenPattern), op.rawValue)
        }
    }
}
