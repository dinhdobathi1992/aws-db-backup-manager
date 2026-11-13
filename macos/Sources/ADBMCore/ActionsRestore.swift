// Restores into a brand-new identifier from a snapshot, a point in time,
// or an AWS Backup recovery point: a port of internal/actions/restore.go.
// Validate.newTarget is the check every branch shares, and the backstop
// against this ever becoming a restore-over-existing-DB path.
import Foundation

extension Actions {
    public func restore(_ account: Account, _ req: RestoreReq) async throws -> Activity {
        if req.targetIdentifier.isEmpty { throw BackendError("targetIdentifier is required") }
        if req.sourceDbIdentifier.isEmpty { throw BackendError("sourceDbIdentifier is required") }

        let c = try await client(account, req.region)
        try await Validate.newTarget(c, kind: req.kind, source: req.sourceDbIdentifier, target: req.targetIdentifier)

        // Copying the source's networking is best-effort: a deleted source
        // falls back to the snapshot's own defaults rather than failing.
        let src = (try? await SourceConfig.lookup(c, kind: req.kind, identifier: req.sourceDbIdentifier)) ?? SourceConfig()
        let net = src.resolved(req)

        switch req.source {
        case .snapshot: return try await restoreFromSnapshot(c, account, req, net, sourceEngine: src.engine)
        case .pitr: return try await restoreFromPITR(c, account, req, net, sourceEngine: src.engine)
        case .recoveryPoint: return try await restoreFromRecoveryPoint(c, account, req)
        }
    }

    typealias Networking = (subnet: String, sgs: [String], paramGroup: String, instanceClass: String)

    /// Optional RDS Query parameters, omitted when empty (Go's optionalString/optionalSlice).
    static func networkParams(_ net: Networking, paramGroupKey: String, includeClass: Bool,
                              publiclyAccessible: Bool) -> [String: String] {
        var p: [String: String] = ["PubliclyAccessible": publiclyAccessible ? "true" : "false"]
        if !net.subnet.isEmpty { p["DBSubnetGroupName"] = net.subnet }
        for (i, sg) in net.sgs.enumerated() { p["VpcSecurityGroupIds.VpcSecurityGroupId.\(i + 1)"] = sg }
        if !net.paramGroup.isEmpty { p[paramGroupKey] = net.paramGroup }
        if includeClass && !net.instanceClass.isEmpty { p["DBInstanceClass"] = net.instanceClass }
        return p
    }

    func appActivity(_ target: String, _ message: String) -> Activity {
        Activity(time: nowRFC3339, source: .app, db: target, action: "restore", status: "pending", message: message)
    }

    func restoreFromSnapshot(_ c: AWSClient, _ account: Account, _ req: RestoreReq, _ net: Networking,
                             sourceEngine: String) async throws -> Activity {
        let snapshotId = req.snapshotId ?? ""
        if snapshotId.isEmpty { throw BackendError("snapshotId is required") }
        let target = req.targetIdentifier

        if req.kind == .cluster {
            let snap: XMLNode?
            do {
                snap = try await c.query(.describeDBClusterSnapshots, ["DBClusterSnapshotIdentifier": snapshotId])
                    .list("DBClusterSnapshots").first
            } catch { throw BackendError.wrap("describe db cluster snapshot \(goQuote(snapshotId))", error) }
            guard let s = snap else { throw BackendError("describe db cluster snapshot \(goQuote(snapshotId)): not found") }
            let engine = s.str("Engine"), engineVersion = s.str("EngineVersion")

            var p = Self.networkParams(net, paramGroupKey: "DBClusterParameterGroupName", includeClass: false,
                                       publiclyAccessible: req.publiclyAccessible)
            p["DBClusterIdentifier"] = target
            p["Engine"] = engine
            if !engineVersion.isEmpty { p["EngineVersion"] = engineVersion }
            p["SnapshotIdentifier"] = snapshotId
            do { _ = try await c.query(.restoreDBClusterFromSnapshot, p) }
            catch { throw BackendError.wrap("restore db cluster from snapshot", error) }
            recordAudit(account, arn: target, action: "RestoreDBClusterFromSnapshot", target: target, result: "pending")

            try await createClusterWriterInstance(c, account, cluster: target, engine: engine, instanceClass: net.instanceClass)
            return appActivity(target, "cluster \(goQuote(target)) restoring from snapshot \(goQuote(snapshotId))")
        }

        var p = Self.networkParams(net, paramGroupKey: "DBParameterGroupName", includeClass: true,
                                   publiclyAccessible: req.publiclyAccessible)
        p["DBInstanceIdentifier"] = target
        p["DBSnapshotIdentifier"] = snapshotId
        do { _ = try await c.query(.restoreDBInstanceFromDBSnapshot, p) }
        catch { throw BackendError.wrap("restore db instance from snapshot", error) }
        recordAudit(account, arn: target, action: "RestoreDBInstanceFromDBSnapshot", target: target, result: "pending")
        return appActivity(target, "instance \(goQuote(target)) restoring from snapshot \(goQuote(snapshotId))")
    }

    /// nil/empty means "latest restorable time".
    static func parseRestoreTime(_ raw: String?) throws -> Date? {
        guard let s = raw, !s.isEmpty else { return nil }
        guard let d = RFC3339.date(s) else {
            throw BackendError("restoreTime \(goQuote(s)) is not RFC3339: cannot parse \(goQuote(s))")
        }
        return d
    }

    func restoreFromPITR(_ c: AWSClient, _ account: Account, _ req: RestoreReq, _ net: Networking,
                         sourceEngine: String) async throws -> Activity {
        let time = try Self.parseRestoreTime(req.restoreTime)
        let target = req.targetIdentifier, source = req.sourceDbIdentifier

        if req.kind == .cluster {
            var p = Self.networkParams(net, paramGroupKey: "DBClusterParameterGroupName", includeClass: false,
                                       publiclyAccessible: req.publiclyAccessible)
            p["DBClusterIdentifier"] = target
            p["SourceDBClusterIdentifier"] = source
            if let t = time { p["RestoreToTime"] = RFC3339.string(t) } else { p["UseLatestRestorableTime"] = "true" }
            do { _ = try await c.query(.restoreDBClusterToPointInTime, p) }
            catch { throw BackendError.wrap("restore db cluster to point in time", error) }
            recordAudit(account, arn: target, action: "RestoreDBClusterToPointInTime", target: target, result: "pending")

            if sourceEngine.isEmpty {
                throw BackendError("could not determine engine for source cluster \(goQuote(source)); it may no longer exist")
            }
            try await createClusterWriterInstance(c, account, cluster: target, engine: sourceEngine, instanceClass: net.instanceClass)
            return appActivity(target, "cluster \(goQuote(target)) restoring to a point in time from \(goQuote(source))")
        }

        var p = Self.networkParams(net, paramGroupKey: "DBParameterGroupName", includeClass: true,
                                   publiclyAccessible: req.publiclyAccessible)
        p["TargetDBInstanceIdentifier"] = target
        p["SourceDBInstanceIdentifier"] = source
        if let t = time { p["RestoreTime"] = RFC3339.string(t) } else { p["UseLatestRestorableTime"] = "true" }
        do { _ = try await c.query(.restoreDBInstanceToPointInTime, p) }
        catch { throw BackendError.wrap("restore db instance to point in time", error) }
        recordAudit(account, arn: target, action: "RestoreDBInstanceToPointInTime", target: target, result: "pending")
        return appActivity(target, "instance \(goQuote(target)) restoring to a point in time from \(goQuote(source))")
    }

    /// StartRestoreJob seeded from GetRecoveryPointRestoreMetadata; only the
    /// target identifier and explicit overrides change.
    func restoreFromRecoveryPoint(_ c: AWSClient, _ account: Account, _ req: RestoreReq) async throws -> Activity {
        let rpArn = req.recoveryPointArn ?? ""
        if rpArn.isEmpty { throw BackendError("recoveryPointArn is required") }

        let snaps: [Snapshot]
        do { snaps = try await inventory.listSnapshotsUncached(account, region: req.region, kind: req.kind, db: req.sourceDbIdentifier) }
        catch { throw BackendError.wrap("list recovery points for \(goQuote(req.sourceDbIdentifier))", error) }
        let vault = snaps.first(where: { $0.arn == rpArn })?.vaultName ?? ""
        if vault.isEmpty {
            throw BackendError("recovery point \(goQuote(rpArn)) not found for database \(goQuote(req.sourceDbIdentifier)); cannot determine its backup vault")
        }

        let meta: JSONValue
        do {
            meta = try await c.backup(.getRecoveryPointRestoreMetadata,
                                      path: ["BackupVaultName": vault, "RecoveryPointArn": rpArn])
        } catch { throw BackendError.wrap("get recovery point restore metadata", error) }

        var metadata = meta["RestoreMetadata"]?.object ?? [:]
        metadata[req.kind == .cluster ? "DBClusterIdentifier" : "DBInstanceIdentifier"] = .string(req.targetIdentifier)
        if let sg = req.subnetGroup, !sg.isEmpty { metadata["DBSubnetGroupName"] = .string(sg) }
        if let sgs = req.securityGroups, !sgs.isEmpty { metadata["VpcSecurityGroupIds"] = .string(sgs.joined(separator: ",")) }

        let acct = try await Self.resolveAccountNumber(c)
        var body: [String: JSONValue] = [
            "Metadata": .object(metadata), "RecoveryPointArn": .string(rpArn),
            "IamRoleArn": .string(Self.defaultBackupRoleArn(acct)),
        ]
        if let rt = meta["ResourceType"]?.string { body["ResourceType"] = .string(rt) }

        let out: JSONValue
        do { out = try await c.backup(.startRestoreJob, body: .object(body)) }
        catch { throw BackendError.wrap("start restore job", error) }

        recordAudit(account, arn: rpArn, action: "StartRestoreJob", target: req.targetIdentifier, result: "pending")
        let jobId = out["RestoreJobId"]?.string ?? ""
        return Activity(time: nowRFC3339, source: .restoreJob, db: req.targetIdentifier, action: "restore", status: "pending",
                        message: "restore job \(jobId) started from recovery point \(goQuote(rpArn))")
    }

    /// The one CreateDBInstance this app makes: the writer for a cluster this
    /// same restore just created.
    func createClusterWriterInstance(_ c: AWSClient, _ account: Account, cluster: String, engine: String,
                                     instanceClass: String) async throws {
        if instanceClass.isEmpty {
            throw BackendError("an instance class is required to create cluster \(goQuote(cluster))'s writer instance; the source cluster's class could not be determined")
        }
        let instanceId = Self.writerInstanceIdentifier(cluster)
        do {
            _ = try await c.query(.createDBInstance, ["DBInstanceClass": instanceClass, "DBInstanceIdentifier": instanceId,
                                                      "Engine": engine, "DBClusterIdentifier": cluster])
        } catch { throw BackendError.wrap("create writer instance for cluster \(goQuote(cluster))", error) }
        recordAudit(account, arn: instanceId, action: "CreateDBInstance", target: cluster, result: "pending")
    }

    /// cluster + "-1", truncated so the result fits RDS's 63-char limit.
    static func writerInstanceIdentifier(_ cluster: String) -> String {
        var base = cluster
        if base.utf8.count + 2 > 63 {
            base = String(base.prefix(61))
            while base.hasSuffix("-") { base.removeLast() }
        }
        return base + "-1"
    }
}
