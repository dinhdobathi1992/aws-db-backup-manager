// The backend contract: a port of internal/api/service.go. It is a closed
// set: there is no delete, remove, terminate or stop method, and no
// implementation may add one. The app and the CLI talk only to this.
import Foundation

public protocol BackendService: Sendable {
    // Accounts
    func listAccounts() async throws -> [Account]
    func saveAccount(_ account: Account) async throws -> Account
    func testAccount(_ accountId: String) async throws -> AccountStatus
    func ssoLogin(_ accountId: String) async throws -> AccountStatus

    // Inventory and backup read model
    func listDatabases(_ accountId: String) async throws -> [Database]
    func getBackupPlan(_ accountId: String, db: String) async throws -> BackupPlanSummary
    func listSnapshots(_ accountId: String, db: String) async throws -> [Snapshot]
    func listSchedules(_ accountId: String) async throws -> [Schedule]
    func listActivity(_ accountId: String, limit: Int) async throws -> [Activity]
    /// Forgets every cached read for the account, so the next reads go to AWS.
    func refresh(_ accountId: String) async

    // Define backup
    func createSnapshot(_ req: CreateSnapshotReq) async throws -> Snapshot
    func startBackupJob(_ req: StartBackupJobReq) async throws -> Activity
    func createBackupPlan(_ req: CreateBackupPlanReq) async throws -> BackupPlanSummary
    func modifyAutomatedBackup(_ req: ModifyAutomatedBackupReq) async throws -> Database

    // Restore (always into a new identifier)
    func restore(_ req: RestoreReq) async throws -> Activity
}

public struct ReadOnlyAccountError: Error, LocalizedError, Sendable {
    public let accountName: String
    public var errorDescription: String? {
        "account \"\(accountName)\" is read-only: write actions are disabled for it in Settings"
    }
}

/// The account-level write gate. Every write method calls this before any
/// credential is resolved or client is built.
public func requireWritable(_ account: Account) throws {
    if account.readOnly { throw ReadOnlyAccountError(accountName: account.name) }
}
