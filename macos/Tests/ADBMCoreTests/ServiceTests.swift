// Port of internal/api/readonly_test.go, plus the account flows of
// AWSBackendService. Settings live in a temp directory; AWS is the stub.
import XCTest
@testable import ADBMCore

final class ServiceTests: XCTestCase {
    struct Env {
        let stub = StubTransport()
        let creds = RecordingCredentials()
        let dir = tempDir()
        let svc: AWSBackendService
        init() {
            svc = AWSBackendService(settings: SettingsStore(directory: dir),
                                    clients: AWSClients(credentials: creds, transport: stub),
                                    audit: AuditLog(directory: dir), now: { fixedNow }, ssoLogin: { _ in })
        }
    }

    func testRequireWritable() {
        XCTAssertThrowsError(try requireWritable(Account(name: "prod", profile: "p", regions: [], readOnly: true)))
        XCTAssertNoThrow(try requireWritable(Account(name: "prod", profile: "p", regions: [], readOnly: false)))
    }

    func testWriteActionsRejectReadOnlyAccountBeforeAnyAWSCall() async throws {
        let e = Env()
        let a = try await e.svc.saveAccount(Account(name: "Read-Only Test Account", profile: "nope", regions: ["us-east-1"], readOnly: true))
        let msg = #"account "Read-Only Test Account" is read-only"#
        await assertThrows({ try await e.svc.createSnapshot(CreateSnapshotReq(accountId: a.id, region: "us-east-1", dbIdentifier: "db1")) }, contains: msg)
        await assertThrows({ try await e.svc.startBackupJob(StartBackupJobReq(accountId: a.id, region: "us-east-1", kind: .instance, dbIdentifier: "db1", vaultName: "")) }, contains: msg)
        await assertThrows({ try await e.svc.createBackupPlan(CreateBackupPlanReq(accountId: a.id, region: "us-east-1", kind: .instance, dbIdentifier: "db1",
            planName: "", ruleName: "", cron: "cron(0 5 * * ? *)", vaultName: "", retentionDays: 30)) }, contains: msg)
        await assertThrows({ try await e.svc.modifyAutomatedBackup(ModifyAutomatedBackupReq(accountId: a.id, region: "us-east-1", kind: .instance,
            dbIdentifier: "db1", retentionDays: 14)) }, contains: msg)
        await assertThrows({ try await e.svc.restore(RestoreReq(accountId: a.id, region: "us-east-1", kind: .instance, source: .snapshot,
            sourceDbIdentifier: "db1", snapshotId: "snap1", targetIdentifier: "db1-restored")) }, contains: msg)
        XCTAssertTrue(e.stub.calls.isEmpty, "a read-only account must make zero AWS calls")
        XCTAssertTrue(e.creds.resolved.isEmpty, "a read-only account must not even resolve credentials")
    }

    func testWriteActionsAllowedForWritableAccount() async throws {
        let e = Env()
        let a = try await e.svc.saveAccount(Account(name: "Writable", profile: "p", regions: ["us-east-1"]))
        e.stub.onXML(.createDBSnapshot, "<DBSnapshot><DBSnapshotIdentifier>s</DBSnapshotIdentifier><Status>creating</Status></DBSnapshot>")
        let snap = try await e.svc.createSnapshot(CreateSnapshotReq(accountId: a.id, region: "us-east-1", dbIdentifier: "db1", snapshotName: "s"))
        XCTAssertEqual(snap.status, "creating")
        XCTAssertEqual(e.stub.operations, [.createDBSnapshot])
    }

    func testUnknownAccount() async {
        let e = Env()
        await assertThrows({ try await e.svc.listDatabases("acct-missing") }, contains: #"account "acct-missing" not found"#)
    }

    func testSaveAccountAssignsIdReplacesAndForgetsProfile() async throws {
        let e = Env()
        var a = try await e.svc.saveAccount(Account(name: "One", profile: "p1", regions: ["us-east-1"]))
        XCTAssertTrue(a.id.hasPrefix("acct-"))
        XCTAssertEqual(UUID(uuidString: String(a.id.dropFirst(5)))?.uuidString.lowercased(), String(a.id.dropFirst(5)))
        a.name = "Renamed"
        _ = try await e.svc.saveAccount(a)
        let all = try await e.svc.listAccounts()
        XCTAssertEqual(all.map(\.name), ["Renamed"])
        XCTAssertEqual(e.creds.forgotten, ["p1", "p1"])
    }

    func testTestAccountOk() async throws {
        let e = Env()
        let a = try await e.svc.saveAccount(Account(name: "A", profile: "p", regions: ["us-east-1"], readOnly: true))
        let s = try await e.svc.testAccount(a.id)
        XCTAssertEqual(s, AccountStatus(accountId: a.id, arn: "arn:aws:iam::123456789012:user/test", awsAccountId: "123456789012",
                                        state: .ok, message: "ok"))
    }

    func testTestAccountExpiredAndError() async throws {
        let e = Env()
        let a = try await e.svc.saveAccount(Account(name: "A", profile: "p", regions: ["us-east-1"]))
        e.stub.on(.getCallerIdentity) { _ in xmlError("ExpiredToken", "The security token included in the request is expired", status: 403) }
        let expired = try await e.svc.testAccount(a.id)
        XCTAssertEqual(expired.state, .expired)
        e.stub.on(.getCallerIdentity) { _ in xmlError("AccessDenied", "nope", status: 403) }
        let failed = try await e.svc.testAccount(a.id)
        XCTAssertEqual(failed.state, .error)
        let noRegion = try await e.svc.saveAccount(Account(name: "B", profile: "p", regions: []))
        let s = try await e.svc.testAccount(noRegion.id)
        XCTAssertEqual(s.state, .error)
        XCTAssertEqual(s.message, "no region configured")
    }
}
