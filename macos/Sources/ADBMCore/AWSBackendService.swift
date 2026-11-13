// The real BackendService, backed by the Mac's own AWS CLI profiles: a port
// of internal/api/awsservice.go. It never stores or accepts raw
// credentials. Every write checks the account's read-only flag before any
// credential is resolved or client is built; SafetyGuard inside AWSClient
// is the independent backstop.
import Foundation

public final class AWSBackendService: BackendService, Sendable {
    public let settings: SettingsStore
    public let clients: AWSClients
    public let inventory: Inventory
    let actions: Actions
    let ssoLoginRunner: @Sendable (String) async throws -> Void

    public init(settings: SettingsStore = SettingsStore(), clients: AWSClients = AWSClients(),
                audit: AuditLog = AuditLog(), cache: TTLCache = TTLCache(),
                now: @escaping @Sendable () -> Date = { Date() },
                ssoLogin: @escaping @Sendable (String) async throws -> Void = { try await AWSCLI.ssoLogin(profile: $0) }) {
        self.settings = settings
        self.clients = clients
        self.inventory = Inventory(clients: clients, audit: audit, cache: cache, now: now)
        self.actions = Actions(inventory: inventory)
        self.ssoLoginRunner = ssoLogin
    }

    func account(_ id: String) throws -> Account {
        if let a = try settings.load().accounts.first(where: { $0.id == id }) { return a }
        throw BackendError("account \(goQuote(id)) not found")
    }

    /// Resolves region and kind for methods keyed only on account + db.
    func findDatabase(_ account: Account, _ db: String) async throws -> Database {
        if let d = try await inventory.listDatabases(account).first(where: { $0.identifier == db }) { return d }
        throw BackendError("database \(goQuote(db)) not found in account \(goQuote(account.id))")
    }

    // MARK: Accounts

    public func listAccounts() async throws -> [Account] { try settings.load().accounts }

    public func saveAccount(_ account: Account) async throws -> Account {
        var cfg = try settings.load()
        var account = account
        if account.id.isEmpty { account.id = "acct-" + UUID().uuidString.lowercased() }
        if let i = cfg.accounts.firstIndex(where: { $0.id == account.id }) { cfg.accounts[i] = account }
        else { cfg.accounts.append(account) }
        try settings.save(cfg)
        // The profile or regions may have changed: drop stale clients.
        await clients.forget(profile: account.profile)
        return account
    }

    public func testAccount(_ accountId: String) async throws -> AccountStatus {
        try await testAccount(account(accountId))
    }

    func testAccount(_ account: Account) async -> AccountStatus {
        guard let region = account.regions.first, !region.isEmpty else {
            return AccountStatus(accountId: account.id, state: .error, message: "no region configured")
        }
        let c: AWSClient
        do { c = try await clients.client(profile: account.profile, region: region, readOnly: account.readOnly) }
        catch { return AccountStatus(accountId: account.id, state: .error, message: error.localizedDescription) }
        do {
            let r = try await c.query(.getCallerIdentity)
            return AccountStatus(accountId: account.id, arn: r.str("Arn"), awsAccountId: r.str("Account"), state: .ok, message: "ok")
        } catch {
            let msg = error.localizedDescription
            var expired = msg.lowercased().contains("expired")
            if case AWSError.expired = error { expired = true }
            return AccountStatus(accountId: account.id, state: expired ? .expired : .error, message: msg)
        }
    }

    public func ssoLogin(_ accountId: String) async throws -> AccountStatus {
        let account = try account(accountId)
        do { try await ssoLoginRunner(account.profile) }
        catch { return AccountStatus(accountId: account.id, state: .error, message: error.localizedDescription) }
        // SSO just refreshed the token cache; forget clients built before it.
        await clients.forget(profile: account.profile)
        return await testAccount(account)
    }

    // MARK: Read model

    public func listDatabases(_ accountId: String) async throws -> [Database] {
        try await inventory.listDatabases(account(accountId))
    }

    public func getBackupPlan(_ accountId: String, db: String) async throws -> BackupPlanSummary {
        let a = try account(accountId)
        return try await inventory.getBackupPlan(a, db: findDatabase(a, db))
    }

    public func listSnapshots(_ accountId: String, db: String) async throws -> [Snapshot] {
        let a = try account(accountId)
        let d = try await findDatabase(a, db)
        return try await inventory.listSnapshots(a, region: d.region, kind: d.kind, db: db)
    }

    public func listSchedules(_ accountId: String) async throws -> [Schedule] {
        try await inventory.listSchedules(account(accountId))
    }

    public func listActivity(_ accountId: String, limit: Int) async throws -> [Activity] {
        try await inventory.listActivity(account(accountId), limit: limit)
    }

    public func refresh(_ accountId: String) async {
        if let a = try? account(accountId) { inventory.refreshAccount(a) }
    }

    // MARK: Writes (requireWritable first, always)

    func writable(_ accountId: String) throws -> Account {
        let a = try account(accountId)
        try requireWritable(a)
        return a
    }

    public func createSnapshot(_ req: CreateSnapshotReq) async throws -> Snapshot {
        let a = try writable(req.accountId)
        let s = try await actions.createSnapshot(a, req)
        inventory.refreshSnapshots(a, region: req.region, db: req.dbIdentifier)
        return s
    }

    public func startBackupJob(_ req: StartBackupJobReq) async throws -> Activity {
        let a = try writable(req.accountId)
        let r = try await actions.startBackupJob(a, req)
        inventory.refreshSnapshots(a, region: req.region, db: req.dbIdentifier)
        return r
    }

    public func createBackupPlan(_ req: CreateBackupPlanReq) async throws -> BackupPlanSummary {
        let a = try writable(req.accountId)
        let r = try await actions.createBackupPlan(a, req)
        inventory.refreshSnapshots(a, region: req.region, db: req.dbIdentifier)
        return r
    }

    public func modifyAutomatedBackup(_ req: ModifyAutomatedBackupReq) async throws -> Database {
        let a = try writable(req.accountId)
        let r = try await actions.modifyAutomatedBackup(a, req)
        inventory.refreshDatabases(a)
        return r
    }

    public func restore(_ req: RestoreReq) async throws -> Activity {
        let a = try writable(req.accountId)
        let r = try await actions.restore(a, req)
        inventory.refreshDatabases(a)
        return r
    }
}
