// App state: a port of AppShell's state and loaders in frontend/src/App.tsx.
// Every backend call goes through `BackendService`; nothing else is reachable.
import ADBMCore
import AppKit
import Observation
import SwiftUI

enum Tab: String, CaseIterable, Hashable, Identifiable {
    case overview, databases, backupPlans = "backup-plans", schedules, snapshots, activity
    var id: String { rawValue }
    var label: String {
        switch self {
        case .overview: "Overview"
        case .databases: "Databases"
        case .backupPlans: "Backup plans"
        case .schedules: "Schedules"
        case .snapshots: "Snapshots"
        case .activity: "Activity"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .databases: "cylinder.split.1x2"
        case .backupPlans: "checkmark.shield"
        case .schedules: "clock"
        case .snapshots: "camera"
        case .activity: "waveform.path.ecg"
        }
    }
}

enum SidebarItem: Hashable {
    case account(String)
    case tab(Tab)
    case fleet
    case settings
}

enum ThemeSetting: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .system: "desktopcomputer"; case .light: "sun.max"; case .dark: "moon" }
    }
    var next: ThemeSetting {
        switch self { case .system: .light; case .light: .dark; case .dark: .system }
    }
    /// Applied app-wide through NSApp.appearance so "System" reliably
    /// returns to following the OS (preferredColorScheme(nil) does not).
    @MainActor func apply() {
        switch self {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum ActiveSheet: Identifiable {
    case account(Account?)
    case snapshot(accountId: String, db: Database)
    case backupJob(accountId: String, db: Database, plan: BackupPlanSummary?)
    case backupPlan(accountId: String, db: Database, plan: BackupPlanSummary?)
    case automatedBackup(accountId: String, db: Database)
    case restore(accountId: String, db: Database, snapshots: [Snapshot], allIdentifiers: [String], initialSnapshotId: String?)

    var id: String {
        switch self {
        case .account(let a): "account-\(a?.id ?? "new")"
        case .snapshot(_, let db): "snapshot-\(db.id)"
        case .backupJob(_, let db, _): "job-\(db.id)"
        case .backupPlan(_, let db, _): "plan-\(db.id)"
        case .automatedBackup(_, let db): "auto-\(db.id)"
        case .restore(_, let db, _, _, _): "restore-\(db.id)"
        }
    }
}

struct Toast: Identifiable, Equatable {
    enum Kind { case success, error, info }
    let id = UUID()
    let kind: Kind
    let message: String
}

func errorMessage(_ e: Error) -> String {
    if let l = e as? LocalizedError, let d = l.errorDescription { return d }
    let s = (e as NSError).localizedDescription
    return s.isEmpty ? "Something went wrong." : s
}

/// True when an error reads like expired / missing SSO credentials, so the
/// inline error can offer "Sign in".
func looksLikeExpiredSignIn(_ message: String) -> Bool {
    let m = message.lowercased()
    return m.contains("expired") || m.contains("sso") || m.contains("token has expired") || m.contains("sign in")
}

@MainActor @Observable
final class AppModel {
    let service: any BackendService

    var accounts: [Account]? = nil
    var accountsError: String? = nil
    var accountStatus: [String: AccountStatus] = [:]
    var databasesByAccount: [String: [Database]] = [:]
    var schedulesByAccount: [String: [Schedule]] = [:]
    var activityByAccount: [String: [Activity]] = [:]
    /// Keyed by `dbKey(accountId, identifier)`: identifiers repeat across accounts.
    var snapshotsByDb: [String: [Snapshot]] = [:]
    var plansByDb: [String: BackupPlanSummary] = [:]
    /// Inline load errors per account (databases, schedules, activity).
    var loadErrors: [String: String] = [:]

    var activeAccountId: String? = nil
    var selection: SidebarItem? = .tab(.overview)
    var lastTab: Tab = .overview
    var snapshotDbFilter: String? = nil

    var sheet: ActiveSheet? = nil
    var paletteOpen = false
    var toasts: [Toast] = []

    var theme: ThemeSetting {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "adbm-theme"); theme.apply() }
    }

    init(service: any BackendService) {
        self.service = service
        theme = ThemeSetting(rawValue: UserDefaults.standard.string(forKey: "adbm-theme") ?? "") ?? .system
    }

    // MARK: Derived

    var activeAccount: Account? { accounts?.first { $0.id == activeAccountId } }

    nonisolated static func dbKey(_ accountId: String, _ db: String) -> String { "\(accountId)|\(db)" }
    func snapshots(_ db: Database) -> [Snapshot]? { snapshotsByDb[Self.dbKey(db.accountId, db.identifier)] }
    func plan(_ db: Database) -> BackupPlanSummary? { plansByDb[Self.dbKey(db.accountId, db.identifier)] }
    var activeTab: Tab? { if case .tab(let t) = selection { t } else { nil } }
    var allDatabases: [Database] { databasesByAccount.values.flatMap { $0 } }

    var title: String {
        if selection == .settings { return "Settings" }
        if selection == .fleet { return "All accounts" }
        if let a = activeAccount, let t = activeTab { return "\(a.name) · \(t.label)" }
        return "AWS DB Backup Manager"
    }

    // MARK: Navigation

    func select(_ item: SidebarItem?) {
        switch item {
        case .account(let id):
            activeAccountId = id
            selection = .tab(lastTab)
            loadAccountIfNeeded(id)
            if accountStatus[id] == nil { Task { await refreshStatus(id, announce: false) } }
        case .tab(let t):
            lastTab = t
            selection = item
        case .fleet:
            selection = item
            loadFleet()
        case .settings, .none:
            selection = item
        }
    }

    /// Database the next view should scroll to and highlight (set by row actions).
    var focusDb: String? = nil

    func go(accountId: String, tab: Tab, focus db: String? = nil) {
        focusDb = db
        activeAccountId = accountId
        lastTab = tab
        selection = .tab(tab)
        loadAccountIfNeeded(accountId)
    }

    // MARK: Toasts

    func toast(_ kind: Toast.Kind, _ message: String) {
        let t = Toast(kind: kind, message: message)
        toasts.append(t)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            self.toasts = self.toasts.filter { $0.id != t.id }
        }
    }

    func dismissToast(_ t: Toast) { toasts = toasts.filter { $0.id != t.id } }

    // MARK: Loading

    func start() async {
        do {
            let accs = try await service.listAccounts()
            accounts = accs
            if let first = accs.first {
                if activeAccountId == nil { activeAccountId = first.id }
                loadAccountIfNeeded(activeAccountId!)
            } else {
                selection = .settings
            }
            // Only the open account is checked now: each check can start an
            // AWS CLI process, so the rest are checked when opened or when
            // Settings is shown.
            if let id = activeAccountId { Task { await self.refreshStatus(id, announce: false) } }
            applyFixtureStartScreen()
        } catch {
            accountsError = errorMessage(error)
        }
    }

    func refreshStatus(_ id: String, announce: Bool) async {
        do {
            let s = try await service.testAccount(id)
            accountStatus[id] = s
            if announce { toast(s.state == .ok ? .success : .error, s.message.isEmpty ? s.state.rawValue : s.message) }
        } catch {
            if announce { toast(.error, errorMessage(error)) }
        }
    }

    /// Accounts whose full read (schedules, activity, details) has run; the
    /// All accounts view may have read only their databases.
    var loadedAccounts: Set<String> = []
    /// Accounts the All accounts view is reading right now.
    var fleetLoading: Set<String> = []

    func loadAccountIfNeeded(_ id: String) {
        guard !loadedAccounts.contains(id) else { return }
        loadedAccounts.insert(id)
        Task { await reload(id, announce: false) }
    }

    /// Checks every account not yet checked, three at a time (Settings).
    func refreshAllStatuses() {
        let ids = (accounts ?? []).map(\.id).filter { accountStatus[$0] == nil }
        guard !ids.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { g in
                var next = 0
                func launch() { let id = ids[next]; next += 1; g.addTask { await self.refreshStatus(id, announce: false) } }
                while next < min(3, ids.count) { launch() }
                while await g.next() != nil { if next < ids.count { launch() } }
            }
        }
    }

    func refreshActive() {
        guard let id = activeAccountId else { return }
        toast(.info, "Refreshing…")
        Task {
            await service.refresh(id)
            await reload(id, announce: true)
        }
    }

    /// Databases and sign-in status for every account, three accounts at a
    /// time: enough for the All accounts health table, nothing per database.
    func loadFleet() {
        let ids = (accounts ?? []).map(\.id).filter { databasesByAccount[$0] == nil && !fleetLoading.contains($0) }
        guard !ids.isEmpty else { return }
        fleetLoading.formUnion(ids)
        let service = self.service
        Task {
            await withTaskGroup(of: (String, Result<[Database], Error>, AccountStatus?).self) { g in
                var next = 0
                func launch() {
                    let id = ids[next]; next += 1
                    g.addTask {
                        let status = try? await service.testAccount(id)
                        guard status?.state != .expired else { return (id, .failure(BackendError(status?.message ?? "Sign-in expired")), status) }
                        do { return (id, .success(try await service.listDatabases(id)), status) }
                        catch { return (id, .failure(error), status) }
                    }
                }
                while next < min(3, ids.count) { launch() }
                while let (id, r, status) = await g.next() {
                    if let status { accountStatus[id] = status }
                    switch r {
                    case .success(let dbs): if databasesByAccount[id] == nil { databasesByAccount[id] = dbs }
                    case .failure(let e): if loadErrors[id] == nil { loadErrors[id] = errorMessage(e) }
                    }
                    fleetLoading.remove(id)
                    if next < ids.count { launch() }
                }
            }
        }
    }

    func reload(_ id: String, announce: Bool) async {
        loadedAccounts.insert(id)
        loadErrors[id] = nil
        async let dbs = service.listDatabases(id)
        async let schedules = service.listSchedules(id)
        async let activity = service.listActivity(id, limit: 50)
        do {
            let list = try await dbs
            databasesByAccount[id] = list
            Task { await self.loadDetails(id, list) }
        } catch {
            loadErrors[id] = errorMessage(error)
        }
        do { schedulesByAccount[id] = try await schedules } catch { recordLoadError(id, error) }
        do { activityByAccount[id] = try await activity } catch { recordLoadError(id, error) }
    }

    private func recordLoadError(_ id: String, _ e: Error) {
        if loadErrors[id] == nil { loadErrors[id] = errorMessage(e) }
    }

    func loadDbDetail(_ accountId: String, _ db: String) async {
        let key = Self.dbKey(accountId, db)
        if let s = try? await service.listSnapshots(accountId, db: db) { snapshotsByDb[key] = s }
        if let p = try? await service.getBackupPlan(accountId, db: db) { plansByDb[key] = p }
    }

    /// Every database's snapshots and plan, eight at a time, published in
    /// batches: one screen update per batch instead of two per database.
    func loadDetails(_ accountId: String, _ dbs: [Database]) async {
        let service = self.service
        let ids = dbs.map(\.identifier)
        typealias Detail = (key: String, snaps: [Snapshot]?, plan: BackupPlanSummary?)
        var pendingSnaps: [String: [Snapshot]] = [:]
        var pendingPlans: [String: BackupPlanSummary] = [:]
        var lastFlush = ContinuousClock.now
        func flush() {
            if !pendingSnaps.isEmpty { snapshotsByDb.merge(pendingSnaps) { $1 }; pendingSnaps = [:] }
            if !pendingPlans.isEmpty { plansByDb.merge(pendingPlans) { $1 }; pendingPlans = [:] }
            lastFlush = .now
        }
        await withTaskGroup(of: Detail.self) { g in
            var next = 0
            func launch() {
                let db = ids[next]; next += 1
                g.addTask {
                    async let s = try? service.listSnapshots(accountId, db: db)
                    async let p = try? service.getBackupPlan(accountId, db: db)
                    return (Self.dbKey(accountId, db), await s, await p)
                }
            }
            while next < min(8, ids.count) { launch() }
            while let d = await g.next() {
                if let s = d.snaps { pendingSnaps[d.key] = s }
                if let p = d.plan { pendingPlans[d.key] = p }
                if ContinuousClock.now - lastFlush > .milliseconds(250) { flush() }
                if next < ids.count { launch() }
            }
        }
        flush()
    }

    /// After a write: refresh what it could have changed (same as onDataChange in v0.1).
    func dataChanged(_ accountId: String, _ db: String) {
        Task {
            await loadDbDetail(accountId, db)
            if let d = try? await service.listDatabases(accountId) { databasesByAccount[accountId] = d }
            if let a = try? await service.listActivity(accountId, limit: 50) { activityByAccount[accountId] = a }
        }
    }

    // MARK: Accounts

    func saveAccount(_ account: Account) async throws {
        let saved = try await service.saveAccount(account)
        var list = accounts ?? []
        if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
        accounts = list
        if activeAccountId == nil { activeAccountId = saved.id; loadAccountIfNeeded(saved.id) }
        Task { await refreshStatus(saved.id, announce: false) }
        toast(.success, "Saved “\(saved.name)”.")
    }

    func ssoLogin(_ id: String) {
        Task {
            do {
                let s = try await service.ssoLogin(id)
                accountStatus[id] = s
                toast(s.state == .ok ? .success : .error, s.message.isEmpty ? "Signed in" : s.message)
                if s.state == .ok { await reload(id, announce: false) }
            } catch {
                toast(.error, errorMessage(error))
            }
        }
    }

    // MARK: Sheets (write actions are refused up front for read-only accounts)

    /// Sample-data runs only: ADBM_START=<tab>|settings|fleet|add-account opens that
    /// screen at launch, so screenshots and QA passes are repeatable.
    private func applyFixtureStartScreen() {
        guard ServiceFactory.usesFixtures, let start = ProcessInfo.processInfo.environment["ADBM_START"] else { return }
        if let t = Tab(rawValue: start) { select(.tab(t)) }
        else if start == "settings" { select(.settings) }
        else if start == "fleet" { select(.fleet) }
        else if start == "add-account" { open(.account(nil)) }
    }

    func open(_ sheet: ActiveSheet) {
        switch sheet {
        case .account: break
        case .snapshot(let id, _), .backupJob(let id, _, _), .backupPlan(let id, _, _),
             .automatedBackup(let id, _), .restore(let id, _, _, _, _):
            if accounts?.first(where: { $0.id == id })?.readOnly == true {
                toast(.error, Fmt.readOnlyHelp)
                return
            }
        }
        self.sheet = sheet
    }

    func openRestore(accountId: String, db: Database, snapshot: Snapshot?) {
        open(.restore(accountId: accountId, db: db,
                      snapshots: (snapshots(db) ?? []).filter { $0.status == "available" || $0.status == "completed" },
                      allIdentifiers: allDatabases.map(\.identifier),
                      initialSnapshotId: snapshot?.id))
    }
}
