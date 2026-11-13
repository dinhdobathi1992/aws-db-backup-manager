// AWS response -> read model mapping: a port of the map* helpers in
// internal/inventory (databases.go, snapshots.go, activity.go, mapping.go)
// and the AWS Backup selection matcher in plans.go. Pure functions, so the
// tests exercise them directly with canned XML/JSON.
import Foundation

enum AWSTime {
    /// RFC3339 (seconds, UTC) or nil if absent, unparseable or the zero
    /// time AWS sometimes sends instead of omitting the field.
    static func ptr(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, let d = RFC3339.date(raw) else { return nil }
        if d.timeIntervalSince1970 <= -62_135_596_800 { return nil } // 0001-01-01T00:00:00Z
        return RFC3339.string(d)
    }
    static func str(_ raw: String?) -> String { ptr(raw) ?? "" }
    static func json(_ v: JSONValue?) -> String {
        guard let v, let s = v.timestamp else { return "" }
        return s == "0001-01-01T00:00:00Z" ? "" : s
    }
}

public enum InventoryMapping {
    static func tagMap(_ node: XMLNode) -> [String: String]? {
        let tags = node.list("TagList")
        if tags.isEmpty { return nil }
        var out: [String: String] = [:]
        for t in tags { out[t.str("Key")] = t.str("Value") }
        return out
    }

    public static func mapCluster(accountId: String, region: String, _ c: XMLNode) -> Database {
        Database(accountId: accountId, region: region, kind: .cluster, identifier: c.str("DBClusterIdentifier"),
                 engine: c.str("Engine"), engineVersion: c.str("EngineVersion"), class: c.str("DBClusterInstanceClass"),
                 status: c.str("Status"), endpoint: c.str("Endpoint"), multiAz: c.bool("MultiAZ"),
                 storageGb: c.int64("AllocatedStorage"), encrypted: c.bool("StorageEncrypted"),
                 backupRetentionDays: c.int("BackupRetentionPeriod"), preferredBackupWindow: c.str("PreferredBackupWindow"),
                 latestRestorableTime: AWSTime.ptr(c.optStr("LatestRestorableTime")), tags: tagMap(c))
    }

    public static func mapInstance(accountId: String, region: String, _ i: XMLNode) -> Database {
        Database(accountId: accountId, region: region, kind: .instance, identifier: i.str("DBInstanceIdentifier"),
                 engine: i.str("Engine"), engineVersion: i.str("EngineVersion"), class: i.str("DBInstanceClass"),
                 status: i.str("DBInstanceStatus"), endpoint: i["Endpoint", "Address"]?.text ?? "", multiAz: i.bool("MultiAZ"),
                 storageGb: i.int64("AllocatedStorage"), encrypted: i.bool("StorageEncrypted"),
                 backupRetentionDays: i.int("BackupRetentionPeriod"), preferredBackupWindow: i.str("PreferredBackupWindow"),
                 latestRestorableTime: AWSTime.ptr(i.optStr("LatestRestorableTime")), tags: tagMap(i))
    }

    /// RDS SnapshotType -> source. "awsbackup" snapshots return nil on
    /// purpose: they are reported once, as a recovery point.
    public static func snapshotSource(fromType t: String) -> SnapshotSource? {
        switch t.lowercased() {
        case "manual": .manual
        case "automated": .automated
        default: nil
        }
    }

    public static func mapInstanceSnapshot(_ s: XMLNode) -> Snapshot? {
        guard let source = snapshotSource(fromType: s.str("SnapshotType")) else { return nil }
        return Snapshot(id: s.str("DBSnapshotIdentifier"), arn: s.str("DBSnapshotArn"), dbIdentifier: s.str("DBInstanceIdentifier"),
                        kind: .instance, source: source, status: s.str("Status"), createdAt: AWSTime.str(s.optStr("SnapshotCreateTime")),
                        sizeGb: s.int64("AllocatedStorage"), encrypted: s.bool("Encrypted"), engine: s.str("Engine"))
    }

    public static func mapClusterSnapshot(_ s: XMLNode) -> Snapshot? {
        guard let source = snapshotSource(fromType: s.str("SnapshotType")) else { return nil }
        return Snapshot(id: s.str("DBClusterSnapshotIdentifier"), arn: s.str("DBClusterSnapshotArn"),
                        dbIdentifier: s.str("DBClusterIdentifier"), kind: .cluster, source: source, status: s.str("Status"),
                        createdAt: AWSTime.str(s.optStr("SnapshotCreateTime")), sizeGb: s.int64("AllocatedStorage"),
                        encrypted: s.bool("StorageEncrypted"), engine: s.str("Engine"))
    }

    /// ListRecoveryPointsByResource also returns RDS's own automated
    /// snapshots (ARN `snapshot:rds:...`, no vault). Those are already listed
    /// as Automated and are not AWS Backup protection, so only recovery points
    /// stored in a backup vault count as AWS Backup.
    public static func isVaultRecoveryPoint(_ rp: JSONValue) -> Bool {
        !(rp["BackupVaultName"]?.string ?? "").isEmpty
    }

    public static func mapRecoveryPoint(dbIdentifier: String, kind: DBKind, _ rp: JSONValue) -> Snapshot {
        let size: Int64 = rp["BackupSizeBytes"]?.double.map { Int64($0) / (1024 * 1024 * 1024) } ?? 0
        let vault = rp["BackupVaultName"]?.string ?? ""
        let arn = rp["RecoveryPointArn"]?.string ?? ""
        let encrypted: Bool = { if let k = rp["EncryptionKeyArn"], k != .null { return true }; return false }()
        return Snapshot(id: arn, arn: arn, dbIdentifier: dbIdentifier, kind: kind, source: .awsBackup,
                        status: rp["Status"]?.string ?? "", createdAt: AWSTime.json(rp["CreationDate"]), sizeGb: size,
                        encrypted: encrypted, engine: "", vaultName: vault.isEmpty ? nil : vault)
    }

    /// The RDS resource ARN AWS Backup expects for a database.
    public static func resourceArn(region: String, accountNumber: String, kind: DBKind, identifier: String) -> String {
        "arn:aws:rds:\(region):\(accountNumber):\(kind == .cluster ? "cluster" : "db"):\(identifier)"
    }

    public static func mapRDSEvent(_ e: XMLNode) -> Activity {
        Activity(time: AWSTime.str(e.optStr("Date")), source: .rdsEvent, db: e.str("SourceIdentifier"),
                 action: e.str("SourceType"), status: "", message: e.str("Message"))
    }

    public static func mapBackupJob(_ j: JSONValue) -> Activity {
        Activity(time: AWSTime.json(j["CreationDate"]), source: .backupJob, db: j["ResourceName"]?.string ?? "",
                 action: "backup-job", status: j["State"]?.string ?? "", message: j["StatusMessage"]?.string ?? "")
    }

    public static func mapRestoreJob(_ j: JSONValue) -> Activity {
        Activity(time: AWSTime.json(j["CreationDate"]), source: .restoreJob, db: j["CreatedResourceArn"]?.string ?? "",
                 action: "restore-job", status: j["Status"]?.string ?? "", message: j["StatusMessage"]?.string ?? "")
    }

    // MARK: AWS Backup selection matching (plans.go)

    /// Whether a BackupSelection assigns the database to its plan: by ARN
    /// (with trailing-"*" wildcards) or by tag condition. NotResources
    /// excludes even if something else would match.
    public static func backupSelectionCovers(_ sel: JSONValue, resourceArn: String, tags: [String: String]?) -> Bool {
        let tags = tags ?? [:]
        for ex in sel["NotResources"]?.array ?? [] where resourceArnMatches(ex.string ?? "", resourceArn) { return false }
        for r in sel["Resources"]?.array ?? [] where resourceArnMatches(r.string ?? "", resourceArn) { return true }
        for c in sel["ListOfTags"]?.array ?? []
        where tagKeyValueMatches(c["ConditionKey"]?.string ?? "", c["ConditionValue"]?.string ?? "", tags) { return true }
        if let conds = sel["Conditions"], conds != .null {
            for c in conds["StringEquals"]?.array ?? [] where tagConditionMatches(c, tags, exact: true) { return true }
            for c in conds["StringLike"]?.array ?? [] where tagConditionMatches(c, tags, exact: false) { return true }
            // StringNotEquals/StringNotLike only narrow a positive match.
        }
        return false
    }

    public static func resourceArnMatches(_ pattern: String, _ arn: String) -> Bool {
        if pattern == "*" || pattern == arn { return true }
        return pattern.hasSuffix("*") && arn.hasPrefix(String(pattern.dropLast()))
    }

    static func stripTagPrefix(_ k: String) -> String {
        k.hasPrefix("aws:ResourceTag/") ? String(k.dropFirst("aws:ResourceTag/".count)) : k
    }

    static func tagKeyValueMatches(_ key: String, _ value: String, _ tags: [String: String]) -> Bool {
        guard let v = tags[stripTagPrefix(key)] else { return false }
        return v == value
    }

    static func tagConditionMatches(_ p: JSONValue, _ tags: [String: String], exact: Bool) -> Bool {
        guard let val = tags[stripTagPrefix(p["ConditionKey"]?.string ?? "")] else { return false }
        let pattern = p["ConditionValue"]?.string ?? ""
        return exact ? val == pattern : matchWildcard(val, pattern)
    }

    /// AWS Backup's "*" wildcard (any run of characters).
    public static func matchWildcard(_ value: String, _ pattern: String) -> Bool {
        guard pattern.contains("*") else { return value == pattern }
        let parts = pattern.components(separatedBy: "*")
        guard value.hasPrefix(parts[0]) else { return false }
        var rest = Substring(value.dropFirst(parts[0].count))
        for p in parts.dropFirst() where !p.isEmpty {
            guard let r = rest.range(of: p) else { return false }
            rest = rest[r.upperBound...]
        }
        return true
    }

    static func lifecycleText(_ l: JSONValue?) -> String {
        guard let d = l?["DeleteAfterDays"]?.double else { return "" }
        return "\(Int64(d)) day(s)"
    }

    static func lifecycleRetentionDays(_ l: JSONValue?) -> Int {
        l?["DeleteAfterDays"]?.int ?? 0
    }
}
