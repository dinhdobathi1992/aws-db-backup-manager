// Model types: a field-for-field port of internal/model/types.go, with the
// same JSON keys, so settings.json and CLI output stay identical to v0.1.
import Foundation

public enum AccountState: String, Codable, Sendable { case ok, expired, error }
public enum DBKind: String, Codable, Sendable, CaseIterable { case instance, cluster }
public enum SnapshotSource: String, Codable, Sendable {
    case manual, automated
    case awsBackup = "aws-backup"
}
public enum ScheduleSource: String, Codable, Sendable {
    case automatedWindow = "automated-window"
    case awsBackupRule = "aws-backup-rule"
}
public enum ActivitySource: String, Codable, Sendable {
    case rdsEvent = "rds-event"
    case backupJob = "backup-job"
    case restoreJob = "restore-job"
    case app
}
public enum RestoreSource: String, Codable, Sendable {
    case snapshot, pitr
    case recoveryPoint = "recovery-point"
}

/// A user-configured account. Credentials are never stored: `profile` only
/// names a local AWS CLI profile.
public struct Account: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var profile: String
    public var regions: [String]
    public var color: String
    public var readOnly: Bool

    public init(id: String = "", name: String, profile: String, regions: [String], color: String = "", readOnly: Bool = false) {
        self.id = id; self.name = name; self.profile = profile
        self.regions = regions; self.color = color; self.readOnly = readOnly
    }

    // Tolerant decode: v0.1 may write `null` for an empty regions list and
    // older files may lack color/readOnly.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
        regions = try c.decodeIfPresent([String].self, forKey: .regions) ?? []
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }
}

public struct AccountStatus: Codable, Sendable, Hashable {
    public var accountId: String
    public var arn: String
    public var awsAccountId: String
    public var state: AccountState
    public var message: String
    public init(accountId: String, arn: String = "", awsAccountId: String = "", state: AccountState, message: String = "") {
        self.accountId = accountId; self.arn = arn; self.awsAccountId = awsAccountId; self.state = state; self.message = message
    }
}

public struct Database: Codable, Sendable, Hashable, Identifiable {
    public var accountId: String
    public var region: String
    public var kind: DBKind
    public var identifier: String
    public var engine: String
    public var engineVersion: String
    public var `class`: String
    public var status: String
    public var endpoint: String
    public var multiAz: Bool
    public var storageGb: Int64
    public var encrypted: Bool
    public var backupRetentionDays: Int
    public var preferredBackupWindow: String
    public var latestRestorableTime: String?
    public var tags: [String: String]?

    public var id: String { "\(accountId)|\(region)|\(kind.rawValue)|\(identifier)" }

    public init(accountId: String, region: String, kind: DBKind, identifier: String, engine: String = "",
                engineVersion: String = "", class cls: String = "", status: String = "", endpoint: String = "",
                multiAz: Bool = false, storageGb: Int64 = 0, encrypted: Bool = false, backupRetentionDays: Int = 0,
                preferredBackupWindow: String = "", latestRestorableTime: String? = nil, tags: [String: String]? = nil) {
        self.accountId = accountId; self.region = region; self.kind = kind; self.identifier = identifier
        self.engine = engine; self.engineVersion = engineVersion; self.class = cls; self.status = status
        self.endpoint = endpoint; self.multiAz = multiAz; self.storageGb = storageGb; self.encrypted = encrypted
        self.backupRetentionDays = backupRetentionDays; self.preferredBackupWindow = preferredBackupWindow
        self.latestRestorableTime = latestRestorableTime; self.tags = tags
    }
}

public struct Snapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var arn: String
    public var dbIdentifier: String
    public var kind: DBKind
    public var source: SnapshotSource
    public var status: String
    public var createdAt: String
    public var sizeGb: Int64
    public var encrypted: Bool
    public var engine: String
    public var vaultName: String?

    public init(id: String, arn: String = "", dbIdentifier: String, kind: DBKind, source: SnapshotSource,
                status: String = "", createdAt: String = "", sizeGb: Int64 = 0, encrypted: Bool = false,
                engine: String = "", vaultName: String? = nil) {
        self.id = id; self.arn = arn; self.dbIdentifier = dbIdentifier; self.kind = kind; self.source = source
        self.status = status; self.createdAt = createdAt; self.sizeGb = sizeGb; self.encrypted = encrypted
        self.engine = engine; self.vaultName = vaultName
    }
}

public struct ManualBackupSummary: Codable, Sendable, Hashable {
    public var count: Int
    public var latest: String?
    public init(count: Int = 0, latest: String? = nil) { self.count = count; self.latest = latest }
}

public struct AutomatedBackupSummary: Codable, Sendable, Hashable {
    public var retention: Int
    public var window: String
    public var earliest: String?
    public var latest: String?
    public init(retention: Int = 0, window: String = "", earliest: String? = nil, latest: String? = nil) {
        self.retention = retention; self.window = window; self.earliest = earliest; self.latest = latest
    }
}

public struct AWSBackupPlanRef: Codable, Sendable, Hashable {
    public var planId: String
    public var planName: String
    public var ruleName: String
    public var cron: String
    public var lifecycle: String
    public var vault: String
    public init(planId: String, planName: String, ruleName: String, cron: String, lifecycle: String, vault: String) {
        self.planId = planId; self.planName = planName; self.ruleName = ruleName
        self.cron = cron; self.lifecycle = lifecycle; self.vault = vault
    }
}

public struct BackupPlanSummary: Codable, Sendable, Hashable {
    public var db: String
    public var manual: ManualBackupSummary
    public var automated: AutomatedBackupSummary
    public var awsBackup: [AWSBackupPlanRef]
    public init(db: String, manual: ManualBackupSummary = .init(), automated: AutomatedBackupSummary = .init(), awsBackup: [AWSBackupPlanRef] = []) {
        self.db = db; self.manual = manual; self.automated = automated; self.awsBackup = awsBackup
    }
}

public struct Schedule: Codable, Sendable, Hashable {
    public var source: ScheduleSource
    public var db: String
    public var expression: String
    public var nextRun: String?
    public var retention: Int
    public init(source: ScheduleSource, db: String, expression: String, nextRun: String? = nil, retention: Int) {
        self.source = source; self.db = db; self.expression = expression; self.nextRun = nextRun; self.retention = retention
    }
}

public struct Activity: Codable, Sendable, Hashable {
    public var time: String
    public var source: ActivitySource
    public var db: String
    public var action: String
    public var status: String
    public var message: String
    public init(time: String, source: ActivitySource, db: String, action: String, status: String, message: String) {
        self.time = time; self.source = source; self.db = db; self.action = action; self.status = status; self.message = message
    }
}

public struct CreateSnapshotReq: Codable, Sendable {
    public var accountId: String
    public var region: String
    public var kind: DBKind
    public var dbIdentifier: String
    public var snapshotName: String
    public init(accountId: String, region: String = "", kind: DBKind = .instance, dbIdentifier: String, snapshotName: String = "") {
        self.accountId = accountId; self.region = region; self.kind = kind; self.dbIdentifier = dbIdentifier; self.snapshotName = snapshotName
    }
}

public struct StartBackupJobReq: Codable, Sendable {
    public var accountId: String
    public var region: String
    public var kind: DBKind
    public var dbIdentifier: String
    public var vaultName: String
    public var iamRoleArn: String
    public init(accountId: String, region: String, kind: DBKind, dbIdentifier: String, vaultName: String, iamRoleArn: String = "") {
        self.accountId = accountId; self.region = region; self.kind = kind; self.dbIdentifier = dbIdentifier
        self.vaultName = vaultName; self.iamRoleArn = iamRoleArn
    }
}

public struct CreateBackupPlanReq: Codable, Sendable {
    public var accountId: String
    public var region: String
    public var kind: DBKind
    public var dbIdentifier: String
    public var planName: String
    public var ruleName: String
    public var cron: String
    public var vaultName: String
    public var retentionDays: Int
    public var iamRoleArn: String
    public init(accountId: String, region: String, kind: DBKind, dbIdentifier: String, planName: String, ruleName: String,
                cron: String, vaultName: String, retentionDays: Int, iamRoleArn: String = "") {
        self.accountId = accountId; self.region = region; self.kind = kind; self.dbIdentifier = dbIdentifier
        self.planName = planName; self.ruleName = ruleName; self.cron = cron; self.vaultName = vaultName
        self.retentionDays = retentionDays; self.iamRoleArn = iamRoleArn
    }
}

public struct ModifyAutomatedBackupReq: Codable, Sendable {
    public var accountId: String
    public var region: String
    public var kind: DBKind
    public var dbIdentifier: String
    public var window: String?
    public var retentionDays: Int?
    public init(accountId: String, region: String, kind: DBKind, dbIdentifier: String, window: String? = nil, retentionDays: Int? = nil) {
        self.accountId = accountId; self.region = region; self.kind = kind; self.dbIdentifier = dbIdentifier
        self.window = window; self.retentionDays = retentionDays
    }
}

public struct RestoreReq: Codable, Sendable {
    public var accountId: String
    public var region: String
    public var kind: DBKind
    public var source: RestoreSource
    public var sourceDbIdentifier: String
    public var snapshotId: String?
    public var recoveryPointArn: String?
    public var restoreTime: String?
    public var targetIdentifier: String
    public var instanceClass: String?
    public var subnetGroup: String?
    public var securityGroups: [String]?
    public var publiclyAccessible: Bool
    public init(accountId: String, region: String, kind: DBKind, source: RestoreSource, sourceDbIdentifier: String,
                snapshotId: String? = nil, recoveryPointArn: String? = nil, restoreTime: String? = nil,
                targetIdentifier: String, instanceClass: String? = nil, subnetGroup: String? = nil,
                securityGroups: [String]? = nil, publiclyAccessible: Bool = false) {
        self.accountId = accountId; self.region = region; self.kind = kind; self.source = source
        self.sourceDbIdentifier = sourceDbIdentifier; self.snapshotId = snapshotId; self.recoveryPointArn = recoveryPointArn
        self.restoreTime = restoreTime; self.targetIdentifier = targetIdentifier; self.instanceClass = instanceClass
        self.subnetGroup = subnetGroup; self.securityGroups = securityGroups; self.publiclyAccessible = publiclyAccessible
    }
}

/// Seconds-precision RFC3339 in UTC, matching Go's time.RFC3339 output.
public enum RFC3339 {
    // ISO8601DateFormatter is thread-safe and costly to create; list views
    // parse a timestamp per row on every sort, so the formatters are shared.
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public static func string(_ date: Date) -> String { plain.string(from: date) }
    public static func date(_ s: String) -> Date? { fractional.date(from: s) ?? plain.date(from: s) }
}
