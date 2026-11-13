// The safety guard: a port of internal/awsx/guard.go.
//
// Layer 1 (structural): `AWSOperation` is the closed set of operations the
// AWS client can send. It equals the Allow list in docs/iam-policy.json
// (49 actions, checked by PolicyTests). No destructive operation has a case,
// so no code path can even express one.
// Layer 2 (runtime): `SafetyGuard.check` runs before every request is
// signed: a destructive-name pattern, the read-only account rule, and the
// parameter guards on the few mutating calls.
import Foundation

public enum AWSService: String, Sendable, CaseIterable {
    case rds = "RDS", backup = "Backup", sts = "STS"
    /// IAM action prefix used in docs/iam-policy.json.
    public var iamPrefix: String {
        switch self { case .rds: "rds"; case .backup: "backup"; case .sts: "sts" }
    }
}

public enum AWSOperation: String, Sendable, CaseIterable {
    // RDS, read-only.
    case describeDBInstances = "DescribeDBInstances"
    case describeDBClusters = "DescribeDBClusters"
    case describeDBSnapshots = "DescribeDBSnapshots"
    case describeDBClusterSnapshots = "DescribeDBClusterSnapshots"
    case describeDBSnapshotAttributes = "DescribeDBSnapshotAttributes"
    case describeDBClusterSnapshotAttributes = "DescribeDBClusterSnapshotAttributes"
    case describeEvents = "DescribeEvents"
    case describeEventSubscriptions = "DescribeEventSubscriptions"
    case describeDBInstanceAutomatedBackups = "DescribeDBInstanceAutomatedBackups"
    case describeDBSubnetGroups = "DescribeDBSubnetGroups"
    case describeDBParameterGroups = "DescribeDBParameterGroups"
    case describeDBClusterParameterGroups = "DescribeDBClusterParameterGroups"
    case describeOrderableDBInstanceOptions = "DescribeOrderableDBInstanceOptions"
    case describeDBEngineVersions = "DescribeDBEngineVersions"
    case describeAccountAttributes = "DescribeAccountAttributes"
    case describeValidDBInstanceModifications = "DescribeValidDBInstanceModifications"
    case describePendingMaintenanceActions = "DescribePendingMaintenanceActions"
    case listTagsForResource = "ListTagsForResource"
    // RDS, creates a new resource; never touches an existing one.
    case createDBSnapshot = "CreateDBSnapshot"
    case createDBClusterSnapshot = "CreateDBClusterSnapshot"
    // RDS, restore into a brand-new identifier (verified by the actions layer).
    case restoreDBInstanceFromDBSnapshot = "RestoreDBInstanceFromDBSnapshot"
    case restoreDBClusterFromSnapshot = "RestoreDBClusterFromSnapshot"
    case restoreDBInstanceToPointInTime = "RestoreDBInstanceToPointInTime"
    case restoreDBClusterToPointInTime = "RestoreDBClusterToPointInTime"
    case createDBInstance = "CreateDBInstance" // Aurora cluster restore's writer instance only.
    // RDS, backup-settings-only modify; parameter-guarded below.
    case modifyDBInstance = "ModifyDBInstance"
    case modifyDBCluster = "ModifyDBCluster"
    case addTagsToResource = "AddTagsToResource"

    // AWS Backup.
    case listBackupPlans = "ListBackupPlans"
    case listBackupSelections = "ListBackupSelections"
    case listBackupJobs = "ListBackupJobs"
    case listRestoreJobs = "ListRestoreJobs"
    case listRecoveryPointsByResource = "ListRecoveryPointsByResource"
    case listBackupVaults = "ListBackupVaults"
    case listTags = "ListTags"
    case getBackupPlan = "GetBackupPlan"
    case getBackupSelection = "GetBackupSelection"
    case getRecoveryPointRestoreMetadata = "GetRecoveryPointRestoreMetadata"
    case getBackupVaultAccessPolicy = "GetBackupVaultAccessPolicy"
    case getBackupVaultNotifications = "GetBackupVaultNotifications"
    case describeBackupJob = "DescribeBackupJob"
    case describeRestoreJob = "DescribeRestoreJob"
    case describeRecoveryPoint = "DescribeRecoveryPoint"
    case describeBackupVault = "DescribeBackupVault"
    case startBackupJob = "StartBackupJob"
    case startRestoreJob = "StartRestoreJob"
    case createBackupPlan = "CreateBackupPlan"
    case createBackupSelection = "CreateBackupSelection"

    // STS.
    case getCallerIdentity = "GetCallerIdentity"

    public var name: String { rawValue }

    public var service: AWSService {
        switch self {
        case .listBackupPlans, .listBackupSelections, .listBackupJobs, .listRestoreJobs,
             .listRecoveryPointsByResource, .listBackupVaults, .listTags, .getBackupPlan,
             .getBackupSelection, .getRecoveryPointRestoreMetadata, .getBackupVaultAccessPolicy,
             .getBackupVaultNotifications, .describeBackupJob, .describeRestoreJob,
             .describeRecoveryPoint, .describeBackupVault, .startBackupJob, .startRestoreJob,
             .createBackupPlan, .createBackupSelection:
            return .backup
        case .getCallerIdentity:
            return .sts
        default:
            return .rds
        }
    }

    /// The IAM action string, e.g. "rds:DescribeDBInstances".
    public var iamAction: String { "\(service.iamPrefix):\(rawValue)" }

    /// True for List/Describe/Get calls: the only ones a read-only account may send.
    public var isRead: Bool {
        rawValue.hasPrefix("List") || rawValue.hasPrefix("Describe") || rawValue.hasPrefix("Get")
    }
}

public struct OperationForbidden: Error, LocalizedError, Equatable, Sendable {
    public let service: String
    public let operation: String
    public let reason: String
    public var errorDescription: String? {
        reason.isEmpty
            ? "blocked op=\(operation) service=\(service): not on the safety allowlist"
            : "blocked op=\(operation) service=\(service): \(reason)"
    }
}

/// Parameters as they will go on the wire: RDS/STS form fields, or a
/// Backup JSON body.
public enum GuardParams: Sendable {
    case form([String: String])
    case json(JSONValue?)
    case none
}

public enum SafetyGuard {
    /// Minimum DeleteAfterDays on an AWS Backup rule.
    public static let minBackupPlanRetentionDays = 7

    /// Independent second line of defence: the shape of every destructive
    /// operation name. StaticGuardTests also asserts no source file names one.
    nonisolated(unsafe) static let forbiddenPattern = try! Regex(
        #"^(Delete|Remove|Stop|Reboot|Failover|Terminate)|^(UpdateBackupPlan|PutBackupVaultAccessPolicy|PutBackupVaultLockConfiguration|ModifyDBSnapshotAttribute|ModifyDBClusterSnapshotAttribute)$"#
    )

    /// Checks a raw operation name (used by tests and by `check`).
    public static func checkName(_ service: String, _ operation: String, readOnly: Bool) throws {
        if operation.firstMatch(of: forbiddenPattern) != nil {
            throw OperationForbidden(service: service, operation: operation, reason: "matches a destructive operation pattern")
        }
        guard let op = AWSOperation(rawValue: operation), op.service.rawValue == service else {
            throw OperationForbidden(service: service, operation: operation, reason: "")
        }
        if readOnly && !op.isRead {
            throw OperationForbidden(service: service, operation: operation,
                                     reason: "account is configured as read-only; only List/Describe/Get calls are allowed")
        }
    }

    /// Runs before every request is signed.
    public static func check(_ op: AWSOperation, readOnly: Bool, params: GuardParams) throws {
        try checkName(op.service.rawValue, op.rawValue, readOnly: readOnly)
        switch (op, params) {
        case (.modifyDBInstance, .form(let f)): try checkModify(op, f, identifier: "DBInstanceIdentifier")
        case (.modifyDBCluster, .form(let f)): try checkModify(op, f, identifier: "DBClusterIdentifier")
        case (.createBackupPlan, .json(let body)): try checkBackupPlanLifecycle(body)
        default: break
        }
    }

    static let modifyAllowedFields: Set<String> = ["ApplyImmediately", "BackupRetentionPeriod", "PreferredBackupWindow"]

    static func checkModify(_ op: AWSOperation, _ fields: [String: String], identifier: String) throws {
        for (key, value) in fields where key != identifier && !modifyAllowedFields.contains(key) && !value.isEmpty {
            throw OperationForbidden(service: op.service.rawValue, operation: op.rawValue,
                                     reason: "field \"\(key)\" is not allowed on a backup-settings-only modify call")
        }
        if let raw = fields["BackupRetentionPeriod"] {
            guard let days = Int(raw), days >= 1 else {
                throw OperationForbidden(service: op.service.rawValue, operation: op.rawValue,
                                         reason: "BackupRetentionPeriod must be at least 1 day; automated backups can never be disabled")
            }
        }
    }

    static func checkBackupPlanLifecycle(_ body: JSONValue?) throws {
        guard let rules = body?["BackupPlan"]?["Rules"]?.array else { return }
        for rule in rules {
            guard let days = rule["Lifecycle"]?["DeleteAfterDays"]?.int else { continue }
            if days < minBackupPlanRetentionDays {
                let name = rule["RuleName"]?.string ?? ""
                throw OperationForbidden(service: "Backup", operation: "CreateBackupPlan",
                                         reason: "rule \"\(name)\" keeps recovery points for only \(days) day(s); the minimum is \(minBackupPlanRetentionDays)")
            }
        }
    }
}
