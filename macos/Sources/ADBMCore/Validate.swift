// Identifier and restore-target validation: a port of
// internal/actions/validate.go. ValidateNewTarget is the backstop against
// ever restoring over an existing database.
import Foundation

public enum Validate {
    /// RDS DB/snapshot identifier rules: 1-63 characters, starts with a
    /// letter, letters/digits/hyphens only, no "--", no trailing hyphen.
    public static func identifier(_ id: String) throws {
        if id.isEmpty { throw BackendError("identifier is required") }
        let n = id.utf8.count
        if n > 63 { throw BackendError("identifier \(goQuote(id)) is \(n) characters; the limit is 63") }
        if id.wholeMatch(of: #/[A-Za-z][A-Za-z0-9-]*/#) == nil {
            throw BackendError("identifier \(goQuote(id)) must start with a letter and contain only letters, digits, and hyphens")
        }
        if id.contains("--") { throw BackendError("identifier \(goQuote(id)) cannot contain two consecutive hyphens") }
        if id.hasSuffix("-") { throw BackendError("identifier \(goQuote(id)) cannot end with a hyphen") }
    }

    /// The target must be a valid identifier, differ from the source, and
    /// not already name an instance or cluster in this account/region.
    public static func newTarget(_ c: AWSClient, kind: DBKind, source: String, target: String) async throws {
        try identifier(target)
        if target == source {
            throw BackendError("target identifier \(goQuote(target)) must differ from the source \(goQuote(source))")
        }
        if try await dbExists(c, kind: kind, identifier: target) {
            throw BackendError("a \(kind.rawValue) named \(goQuote(target)) already exists; restore must target a new identifier")
        }
    }

    /// Only AWS's own not-found fault is a "no"; every other error
    /// (credentials, permissions) propagates rather than meaning "safe".
    static func dbExists(_ c: AWSClient, kind: DBKind, identifier: String) async throws -> Bool {
        let (op, param, label) = kind == .cluster
            ? (AWSOperation.describeDBClusters, "DBClusterIdentifier", "cluster")
            : (AWSOperation.describeDBInstances, "DBInstanceIdentifier", "instance")
        do {
            _ = try await c.query(op, [param: identifier])
            return true
        } catch let AWSError.notFound(msg) where isNotFoundFault(msg, kind: kind) {
            return false
        } catch {
            throw BackendError.wrap("check existing \(label) \(goQuote(identifier))", error)
        }
    }

    static func isNotFoundFault(_ msg: String, kind: DBKind) -> Bool {
        msg.hasPrefix(kind == .cluster ? "DBClusterNotFoundFault" : "DBInstanceNotFound")
    }
}

/// What a restore copies from the live source unless overridden.
struct SourceConfig: Sendable {
    var subnetGroupName = ""
    var securityGroupIds: [String] = []
    var parameterGroupName = ""
    var instanceClass = ""
    var engine = ""

    static func lookup(_ c: AWSClient, kind: DBKind, identifier: String) async throws -> SourceConfig {
        if kind == .cluster {
            let r = try? await c.query(.describeDBClusters, ["DBClusterIdentifier": identifier])
            guard let n = r?.list("DBClusters").first else { throw BackendError("source cluster \(goQuote(identifier)) not found") }
            return SourceConfig(subnetGroupName: n.str("DBSubnetGroup"),
                                securityGroupIds: n.list("VpcSecurityGroups").map { $0.str("VpcSecurityGroupId") },
                                parameterGroupName: n.str("DBClusterParameterGroup"), engine: n.str("Engine"))
        }
        let r = try? await c.query(.describeDBInstances, ["DBInstanceIdentifier": identifier])
        guard let n = r?.list("DBInstances").first else { throw BackendError("source instance \(goQuote(identifier)) not found") }
        return SourceConfig(subnetGroupName: n["DBSubnetGroup", "DBSubnetGroupName"]?.text ?? "",
                            securityGroupIds: n.list("VpcSecurityGroups").map { $0.str("VpcSecurityGroupId") },
                            parameterGroupName: n.list("DBParameterGroups").first?.str("DBParameterGroupName") ?? "",
                            instanceClass: n.str("DBInstanceClass"), engine: n.str("Engine"))
    }

    /// "Copy source unless overridden"; the parameter group always comes
    /// from the source (the request has no override for it).
    func resolved(_ req: RestoreReq) -> (subnet: String, sgs: [String], paramGroup: String, instanceClass: String) {
        let subnet = (req.subnetGroup ?? "").isEmpty ? subnetGroupName : req.subnetGroup!
        let sgs = (req.securityGroups ?? []).isEmpty ? securityGroupIds : req.securityGroups!
        let cls = (req.instanceClass ?? "").isEmpty ? instanceClass : req.instanceClass!
        return (subnet, sgs, parameterGroupName, cls)
    }
}
