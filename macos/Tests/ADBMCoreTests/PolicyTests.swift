// Port of internal/awsx/policy_test.go: docs/iam-policy.json and the native
// allowlist (AWSOperation) must stay in lockstep.
import XCTest
@testable import ADBMCore

final class PolicyTests: XCTestCase {
    struct Statement {
        let sid: String, effect: String, actions: [String], resources: [String]
        let hasNotAction: Bool, hasNotResource: Bool, hasCondition: Bool
    }

    func loadPolicy() throws -> [Statement] {
        let data = try Data(contentsOf: RepoPath.root.appendingPathComponent("docs/iam-policy.json"))
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try XCTUnwrap(doc["Statement"] as? [[String: Any]])
        func strings(_ v: Any?) -> [String] { (v as? [String]) ?? ((v as? String).map { [$0] } ?? []) }
        return list.map { st in
            Statement(sid: st["Sid"] as? String ?? "", effect: st["Effect"] as? String ?? "",
                      actions: strings(st["Action"]), resources: strings(st["Resource"]),
                      hasNotAction: st["NotAction"] != nil, hasNotResource: st["NotResource"] != nil,
                      hasCondition: st["Condition"] != nil)
        }
    }

    var allowlist: Set<String> { Set(AWSOperation.allCases.map(\.iamAction)) }

    func testPolicyMatchesAllowlist() throws {
        var got = Set<String>()
        for st in try loadPolicy() where st.effect == "Allow" && st.sid.hasPrefix("AppGuardAllowlist") {
            for a in st.actions {
                XCTAssertFalse(a.contains("*"), "allowlist statement \(st.sid) uses a wildcard action \(a)")
                got.insert(a)
            }
        }
        XCTAssertEqual(allowlist.subtracting(got).sorted(), [], "policy lacks guard-allowed actions")
        XCTAssertEqual(got.subtracting(allowlist).sorted(), [], "policy grants actions the guard does not allow")
        XCTAssertEqual(got.count, 49)
    }

    func testPolicyOtherAllowsAreDependenciesOnly() throws {
        let permitted: Set = ["iam:PassRole", "kms:CreateGrant", "kms:DescribeKey"]
        for st in try loadPolicy() where st.effect == "Allow" && !st.sid.hasPrefix("AppGuardAllowlist") {
            for a in st.actions { XCTAssertTrue(permitted.contains(a), "statement \(st.sid) allows unexpected action \(a)") }
        }
    }

    func testPolicyDenyCoversForbiddenPatternAndNeverHitsAllowlist() throws {
        let deny = try loadPolicy().filter { $0.effect == "Deny" }.flatMap(\.actions)
        XCTAssertFalse(deny.isEmpty, "policy has no explicit Deny statement")
        func denied(_ action: String) -> Bool {
            deny.contains { pattern in
                let re = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
                return action.range(of: re, options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
        for a in allowlist { XCTAssertFalse(denied(a), "explicit Deny blocks guard-allowed action \(a)") }
        let mustDeny = [
            "rds:DeleteDBInstance", "rds:DeleteDBCluster", "rds:DeleteDBSnapshot", "rds:DeleteDBClusterSnapshot",
            "rds:DeleteDBInstanceAutomatedBackup", "rds:DeleteDBClusterAutomatedBackup",
            "rds:StopDBInstance", "rds:StopDBCluster", "rds:RebootDBInstance", "rds:RebootDBCluster",
            "rds:FailoverDBCluster", "rds:FailoverGlobalCluster", "rds:RemoveFromGlobalCluster",
            "rds:ModifyDBSnapshotAttribute", "rds:ModifyDBClusterSnapshotAttribute",
            "backup:DeleteRecoveryPoint", "backup:DeleteBackupVault", "backup:DeleteBackupPlan", "backup:DeleteBackupSelection",
            "backup:DeleteBackupVaultLockConfiguration", "backup:StopBackupJob", "backup:DisassociateRecoveryPoint",
            "backup:UpdateBackupPlan", "backup:UpdateRecoveryPointLifecycle", "backup:StartCopyJob",
            "rds:BacktrackDBCluster", "rds:StartExportTask",
            "backup:PutBackupVaultAccessPolicy", "backup:PutBackupVaultLockConfiguration",
        ]
        for a in mustDeny { XCTAssertTrue(denied(a), "explicit Deny does not cover destructive action \(a)") }
    }

    func testPolicyStatementShape() throws {
        for st in try loadPolicy() {
            XCTAssertFalse(st.hasNotAction || st.hasNotResource, "statement \(st.sid) uses NotAction/NotResource")
            if st.effect == "Deny" {
                XCTAssertFalse(st.hasCondition, "Deny statement \(st.sid) has a Condition")
                XCTAssertEqual(st.resources, ["*"], "Deny statement \(st.sid) must apply to Resource \"*\"")
            }
        }
    }
}
