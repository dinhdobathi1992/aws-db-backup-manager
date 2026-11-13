// Shared test plumbing: a stub transport that never touches the network
// and records every operation it receives, plus helpers for canned
// RDS/STS XML and AWS Backup JSON. A port of internal/actions/awsstub_test.go:
// unstubbed calls fall back to the same defaults (instances/clusters not
// found, empty lists, a fixed caller identity) and anything else fails
// loudly with "unexpected call to X".
import Foundation
import XCTest
@testable import ADBMCore

/// One request as the stub saw it.
struct RecordedCall: Sendable {
    let op: AWSOperation
    let method: String
    let path: String
    let query: [String: String]
    let form: [String: String]   // Query protocol body fields (RDS/STS)
    let json: JSONValue?         // REST-JSON body (Backup)
}

typealias StubHandler = @Sendable (RecordedCall) throws -> (Int, Data)

final class StubTransport: AWSTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [AWSOperation: StubHandler] = [:]
    private var _calls: [RecordedCall] = []

    var calls: [RecordedCall] { lock.withLock { _calls } }
    var operations: [AWSOperation] { calls.map(\.op) }
    func calls(_ op: AWSOperation) -> [RecordedCall] { calls.filter { $0.op == op } }

    func on(_ op: AWSOperation, _ h: @escaping StubHandler) { lock.withLock { handlers[op] = h } }
    /// Canned Query-protocol success: `inner` is the XML inside <OpResult>.
    func onXML(_ op: AWSOperation, _ inner: String) { on(op) { _ in (200, xmlResult(op, inner)) } }
    func onJSON(_ op: AWSOperation, _ obj: [String: Any]) { let d = jsonData(obj); on(op) { _ in (200, d) } }

    func send(_ r: AWSRequest) async throws -> (status: Int, body: Data) {
        let comps = URLComponents(url: r.url, resolvingAgainstBaseURL: false)
        var q: [String: String] = [:]
        for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }
        let isQuery = r.operation.service != .backup
        let call = RecordedCall(op: r.operation, method: r.method, path: comps?.percentEncodedPath ?? "",
                                query: q, form: isQuery ? parseForm(r.body) : [:],
                                json: !isQuery && !r.body.isEmpty ? try? JSONValue.parse(r.body) : nil)
        let h = lock.withLock { () -> StubHandler? in _calls.append(call); return handlers[r.operation] }
        if let h { return try h(call) }
        return try Self.defaultResponse(call)
    }

    static func defaultResponse(_ c: RecordedCall) throws -> (Int, Data) {
        switch c.op {
        case .describeDBInstances: return xmlError("DBInstanceNotFound", "DBInstance not found")
        case .describeDBClusters: return xmlError("DBClusterNotFoundFault", "DBCluster not found")
        case .describeDBInstanceAutomatedBackups:
            return (200, xmlResult(c.op, "<DBInstanceAutomatedBackups></DBInstanceAutomatedBackups>"))
        case .getCallerIdentity:
            return (200, xmlResult(c.op, "<Arn>arn:aws:iam::123456789012:user/test</Arn><Account>123456789012</Account>"))
        case .listBackupPlans: return (200, jsonData(["BackupPlansList": []]))
        case .listBackupSelections: return (200, jsonData(["BackupSelectionsList": []]))
        case .listBackupJobs: return (200, jsonData(["BackupJobs": []]))
        case .listRestoreJobs: return (200, jsonData(["RestoreJobs": []]))
        case .listRecoveryPointsByResource: return (200, jsonData(["RecoveryPoints": []]))
        default: throw StubError("unexpected call to \(c.op.rawValue)")
        }
    }
}

struct StubError: Error, LocalizedError { let m: String; init(_ m: String) { self.m = m }; var errorDescription: String? { m } }

func parseForm(_ body: Data) -> [String: String] {
    var out: [String: String] = [:]
    for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
        let k = kv[0].removingPercentEncoding ?? kv[0]
        let v = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
        out[k] = v
    }
    return out
}

func xmlResult(_ op: AWSOperation, _ inner: String) -> Data {
    Data("<\(op.rawValue)Response><\(op.rawValue)Result>\(inner)</\(op.rawValue)Result></\(op.rawValue)Response>".utf8)
}

func xmlError(_ code: String, _ message: String, status: Int = 404) -> (Int, Data) {
    (status, Data("<ErrorResponse><Error><Type>Sender</Type><Code>\(code)</Code><Message>\(message)</Message></Error></ErrorResponse>".utf8))
}

func jsonData(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

/// Fixed credentials: no AWS CLI, no network.
struct StaticCredentials: CredentialProvider {
    func credentials(profile: String) async throws -> AWSCredentials {
        AWSCredentials(accessKeyId: "AKIDTEST", secretAccessKey: "secret", sessionToken: nil, expiration: nil)
    }
    func forget(profile: String) async {}
}

/// Records forget() calls, to prove saveAccount/ssoLogin drop clients.
final class RecordingCredentials: CredentialProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _forgotten: [String] = []
    private var _resolved: [String] = []
    var forgotten: [String] { lock.withLock { _forgotten } }
    var resolved: [String] { lock.withLock { _resolved } }
    func credentials(profile: String) async throws -> AWSCredentials {
        lock.withLock { _resolved.append(profile) }
        return AWSCredentials(accessKeyId: "AKIDTEST", secretAccessKey: "secret", sessionToken: nil, expiration: nil)
    }
    func forget(profile: String) async { lock.withLock { _forgotten.append(profile) } }
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("adbm-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// 2026-01-15T10:30:00Z: every test runs against the same clock.
let fixedNow = Date(timeIntervalSince1970: 1_768_473_000)

let testAccount = Account(id: "acct-test", name: "Test", profile: "test-profile", regions: ["us-east-1"], readOnly: false)

struct Harness {
    let stub = StubTransport()
    let dir = tempDir()
    let inventory: Inventory
    let actions: Actions
    var audit: AuditLog { inventory.audit }

    init(now: Date = fixedNow) {
        let clients = AWSClients(credentials: StaticCredentials(), transport: stub)
        inventory = Inventory(clients: clients, audit: AuditLog(directory: dir), now: { now })
        actions = Actions(inventory: inventory)
    }

    func client(readOnly: Bool = false, region: String = "us-east-1") -> AWSClient {
        AWSClient(profile: "test-profile", region: region, readOnly: readOnly, credentials: StaticCredentials(), transport: stub)
    }
}

func assertThrows<T>(_ body: () async throws -> T, contains needle: String? = nil,
                     file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await body()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        if let needle, !error.localizedDescription.contains(needle) {
            XCTFail("error \"\(error.localizedDescription)\" does not contain \"\(needle)\"", file: file, line: line)
        }
    }
}

/// Repository paths, resolved from this file so tests run from any cwd.
enum RepoPath {
    static let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let root = macos.deletingLastPathComponent()
}
