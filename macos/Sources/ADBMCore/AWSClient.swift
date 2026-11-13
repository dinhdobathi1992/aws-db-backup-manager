// The only place AWS requests are built. A port of internal/awsx/clients.go:
// one guarded client per (profile, region), with the account's read-only
// flag baked in for its lifetime. Every request goes through
// SafetyGuard.check before it is signed or sent.
import Foundation

/// A signed-or-unsigned HTTP request ready to send. Tests replace the
/// transport with a stub that returns canned XML/JSON, so the guard and the
/// request builders run exactly as in production.
public struct AWSRequest: Sendable {
    public var operation: AWSOperation
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data
}

public protocol AWSTransport: Sendable {
    func send(_ request: AWSRequest) async throws -> (status: Int, body: Data)
}

public struct URLSessionTransport: AWSTransport {
    public init() {}
    public func send(_ r: AWSRequest) async throws -> (status: Int, body: Data) {
        var req = URLRequest(url: r.url)
        req.httpMethod = r.method
        req.httpBody = r.body.isEmpty ? nil : r.body
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

struct BackupRoute {
    let method: String
    let path: String // {Name} placeholders are percent-encoded path params
}

extension AWSOperation {
    /// REST routes for AWS Backup (REST-JSON protocol).
    var backupRoute: BackupRoute? {
        switch self {
        case .listBackupPlans: .init(method: "GET", path: "/backup/plans/")
        case .getBackupPlan: .init(method: "GET", path: "/backup/plans/{BackupPlanId}/")
        case .listBackupSelections: .init(method: "GET", path: "/backup/plans/{BackupPlanId}/selections/")
        case .getBackupSelection: .init(method: "GET", path: "/backup/plans/{BackupPlanId}/selections/{SelectionId}")
        case .createBackupPlan: .init(method: "PUT", path: "/backup/plans/")
        case .createBackupSelection: .init(method: "PUT", path: "/backup/plans/{BackupPlanId}/selections/")
        case .listBackupJobs: .init(method: "GET", path: "/backup-jobs/")
        case .describeBackupJob: .init(method: "GET", path: "/backup-jobs/{BackupJobId}")
        case .startBackupJob: .init(method: "PUT", path: "/backup-jobs")
        case .listRestoreJobs: .init(method: "GET", path: "/restore-jobs/")
        case .describeRestoreJob: .init(method: "GET", path: "/restore-jobs/{RestoreJobId}")
        case .startRestoreJob: .init(method: "PUT", path: "/restore-jobs")
        case .listRecoveryPointsByResource: .init(method: "GET", path: "/resources/{ResourceArn}/recovery-points/")
        case .listBackupVaults: .init(method: "GET", path: "/backup-vaults/")
        case .describeBackupVault: .init(method: "GET", path: "/backup-vaults/{BackupVaultName}")
        case .getBackupVaultAccessPolicy: .init(method: "GET", path: "/backup-vaults/{BackupVaultName}/access-policy")
        case .getBackupVaultNotifications: .init(method: "GET", path: "/backup-vaults/{BackupVaultName}/notification-configuration")
        case .describeRecoveryPoint: .init(method: "GET", path: "/backup-vaults/{BackupVaultName}/recovery-points/{RecoveryPointArn}")
        case .getRecoveryPointRestoreMetadata: .init(method: "GET", path: "/backup-vaults/{BackupVaultName}/recovery-points/{RecoveryPointArn}/restore-metadata")
        case .listTags: .init(method: "GET", path: "/tags/{ResourceArn}/")
        default: nil
        }
    }
}

/// A guarded client for one (profile, region). There is no other way to
/// send an AWS request in this codebase.
public struct AWSClient: Sendable {
    public let profile: String
    public let region: String
    public let readOnly: Bool
    let credentials: any CredentialProvider
    let transport: any AWSTransport

    public init(profile: String, region: String, readOnly: Bool,
                credentials: any CredentialProvider, transport: any AWSTransport = URLSessionTransport()) {
        self.profile = profile; self.region = region; self.readOnly = readOnly
        self.credentials = credentials; self.transport = transport
    }

    // MARK: Query protocol (RDS, STS)

    /// Sends one RDS or STS Query call and returns the `<Op>Result` element.
    public func query(_ op: AWSOperation, _ params: [String: String] = [:]) async throws -> XMLNode {
        guard op.service != .backup else { throw AWSError.invalid("\(op.rawValue) is not a Query operation") }
        try SafetyGuard.check(op, readOnly: readOnly, params: .form(params))

        let (svc, version) = op.service == .rds ? ("rds", "2014-10-31") : ("sts", "2011-06-15")
        let host = "\(svc).\(region).amazonaws.com"
        var fields = params
        fields["Action"] = op.rawValue
        fields["Version"] = version
        let body = Data(fields.sorted { $0.key < $1.key }
            .map { "\(SigV4.encode($0.key))=\(SigV4.encode($0.value))" }.joined(separator: "&").utf8)
        let data = try await send(op, method: "POST", host: host, encodedPath: "/", query: [], body: body,
                                  contentType: "application/x-www-form-urlencoded; charset=utf-8", signingName: svc)
        let root = try XMLNode.parse(data)
        return root.child("\(op.rawValue)Result") ?? root
    }

    /// Follows Marker pagination; returns every member of `listName`.
    public func queryAll(_ op: AWSOperation, _ params: [String: String] = [:], list listName: String,
                         maxPages: Int = 50) async throws -> [XMLNode] {
        var out: [XMLNode] = []
        var p = params
        for _ in 0..<maxPages {
            let r = try await query(op, p)
            out += r.list(listName)
            guard let m = r.optStr("Marker") else { break }
            p["Marker"] = m
        }
        return out
    }

    // MARK: REST-JSON (AWS Backup)

    public func backup(_ op: AWSOperation, path pathParams: [String: String] = [:],
                       query: [(String, String)] = [], body: JSONValue? = nil) async throws -> JSONValue {
        guard let route = op.backupRoute else { throw AWSError.invalid("\(op.rawValue) is not an AWS Backup operation") }
        try SafetyGuard.check(op, readOnly: readOnly, params: .json(body))

        var path = route.path
        for (k, v) in pathParams { path = path.replacingOccurrences(of: "{\(k)}", with: SigV4.encode(v)) }
        if path.contains("{") { throw AWSError.invalid("missing path parameter for \(op.rawValue): \(path)") }
        let data = try await send(op, method: route.method, host: "backup.\(region).amazonaws.com", encodedPath: path,
                                  query: query, body: try body?.data() ?? Data(),
                                  contentType: body == nil ? nil : "application/json", signingName: "backup")
        return try JSONValue.parse(data)
    }

    /// Follows NextToken pagination; returns every element of `listKey`.
    public func backupAll(_ op: AWSOperation, path: [String: String] = [:], query: [(String, String)] = [],
                          list listKey: String, maxPages: Int = 50) async throws -> [JSONValue] {
        var out: [JSONValue] = []
        var token: String?
        for _ in 0..<maxPages {
            var q = query
            if let t = token { q.append(("nextToken", t)) }
            let r = try await backup(op, path: path, query: q)
            out += r[listKey]?.array ?? []
            guard let t = r["NextToken"]?.string, !t.isEmpty else { break }
            token = t
        }
        return out
    }

    // MARK: Transport

    private func send(_ op: AWSOperation, method: String, host: String, encodedPath: String,
                      query: [(String, String)], body: Data, contentType: String?, signingName: String) async throws -> Data {
        let creds = try await credentials.credentials(profile: profile)
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = host
        comps.percentEncodedPath = encodedPath
        if !query.isEmpty {
            comps.percentEncodedQuery = query.map { "\(SigV4.encode($0.0))=\(SigV4.encode($0.1))" }.joined(separator: "&")
        }
        guard let url = comps.url else { throw AWSError.invalid("bad URL for \(op.rawValue)") }
        var req = URLRequest(url: url)
        if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        SigV4.sign(request: &req, method: method, host: host, encodedPath: encodedPath, query: query, body: body,
                   service: signingName, region: region, credentials: creds)
        let headers = req.allHTTPHeaderFields ?? [:]
        let (status, data) = try await transport.send(AWSRequest(operation: op, method: method, url: url, headers: headers, body: body))
        guard (200..<300).contains(status) else { throw Self.decodeError(status: status, data: data) }
        return data
    }

    static func decodeError(status: Int, data: Data) -> AWSError {
        if let x = try? XMLNode.parse(data) {
            let code = x.find("Code")?.text ?? ""
            let msg = x.find("Message")?.text ?? ""
            if code.contains("ExpiredToken") { return .expired("AWS credentials have expired: \(msg)") }
            if code.hasSuffix("NotFound") || code.hasSuffix("NotFoundFault") { return .notFound("\(code): \(msg)") }
            return .http(status: status, code: code, message: msg)
        }
        if let j = try? JSONValue.parse(data) {
            let code = j["__type"]?.string ?? j["Code"]?.string ?? ""
            let msg = j["Message"]?.string ?? j["message"]?.string ?? ""
            if code.contains("ExpiredToken") { return .expired("AWS credentials have expired: \(msg)") }
            if code.contains("ResourceNotFound") { return .notFound("\(code): \(msg)") }
            return .http(status: status, code: code, message: msg)
        }
        return .http(status: status, code: "", message: String(decoding: data.prefix(300), as: UTF8.self))
    }
}

/// Caches guarded clients per (profile, region, readOnly). Saving an account
/// forgets its clients, so a settings change always rebuilds the guard.
public actor AWSClients {
    private var cache: [String: AWSClient] = [:]
    let credentials: any CredentialProvider
    let transport: any AWSTransport

    public init(credentials: any CredentialProvider = CLICredentialProvider(), transport: any AWSTransport = URLSessionTransport()) {
        self.credentials = credentials; self.transport = transport
    }

    public func client(profile: String, region: String, readOnly: Bool) throws -> AWSClient {
        guard !profile.isEmpty else { throw AWSError.invalid("aws profile is required") }
        guard !region.isEmpty else { throw AWSError.invalid("aws region is required") }
        let key = "\(profile)|\(region)|\(readOnly)"
        if let c = cache[key] { return c }
        let c = AWSClient(profile: profile, region: region, readOnly: readOnly, credentials: credentials, transport: transport)
        cache[key] = c
        return c
    }

    public func forget(profile: String) async {
        cache = cache.filter { !$0.key.hasPrefix("\(profile)|") }
        await credentials.forget(profile: profile)
    }
}
