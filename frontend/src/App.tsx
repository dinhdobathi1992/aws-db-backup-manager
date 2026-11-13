import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  type FormEvent,
  type ReactNode,
} from "react";
import {
  Activity as ActivityIcon,
  Camera,
  Clock,
  Database as DatabaseIcon,
  LayoutDashboard,
  LogIn,
  Monitor,
  Moon,
  Plus,
  RefreshCw,
  Search,
  Settings as SettingsIcon,
  ShieldCheck,
  Sun,
} from "lucide-react";
import {
  CreateBackupPlan,
  CreateSnapshot,
  GetBackupPlan,
  ListAccounts,
  ListActivity,
  ListDatabases,
  ListSchedules,
  ListSnapshots,
  ModifyAutomatedBackup,
  Restore,
  SaveAccount,
  SsoLogin,
  StartBackupJob,
  TestAccount,
} from "../wailsjs/go/main/App";
import { model } from "../wailsjs/go/models";
import {
  AccountAvatar,
  Card,
  CommandPalette,
  EncryptedBadge,
  Empty,
  Modal,
  Pill,
  ProdBadge,
  ReadOnlyBadge,
  SourceBadge,
  Stat,
  Table,
  ToastProvider,
  WriteGuard,
  useToast,
  type PaletteEntry,
} from "./components";
import {
  MIN_AUTOMATED_RETENTION_DAYS,
  MIN_AWS_BACKUP_RETENTION_DAYS,
  ago,
  dateFull,
  engineLabel,
  isProd,
  kindLabel,
  regionsLabel,
  scheduleSourceLabels,
  sizeGB,
  slugify,
  sourceLabels,
  statusTone,
  suggestSnapshotName,
  uniqueId,
  type Account,
  type AccountStatus,
  type BackupPlanSummary,
  type Database,
  type RestoreSource,
  type Schedule,
  type Snapshot,
} from "./lib";

function msg(e: unknown): string {
  if (e instanceof Error) return e.message;
  return typeof e === "string" ? e : "Something went wrong.";
}

// ---------------------------------------------------------------------------
// Hash routing
// ---------------------------------------------------------------------------

type Tab = "overview" | "databases" | "backup-plans" | "schedules" | "snapshots" | "activity";
const TABS: { id: Tab; label: string; icon: typeof LayoutDashboard }[] = [
  { id: "overview", label: "Overview", icon: LayoutDashboard },
  { id: "databases", label: "Databases", icon: DatabaseIcon },
  { id: "backup-plans", label: "Backup plans", icon: ShieldCheck },
  { id: "schedules", label: "Schedules", icon: Clock },
  { id: "snapshots", label: "Snapshots", icon: Camera },
  { id: "activity", label: "Activity", icon: ActivityIcon },
];

type Route =
  | { view: "account"; accountId: string; tab: Tab; query: URLSearchParams }
  | { view: "settings" }
  | { view: "none" };

function parseHash(hash: string): Route {
  const raw = hash.replace(/^#/, "");
  const [pathPart, queryPart] = raw.split("?");
  const parts = pathPart.split("/").filter(Boolean);
  const query = new URLSearchParams(queryPart || "");
  if (parts[0] === "settings") return { view: "settings" };
  if (parts[0] === "a" && parts[1]) {
    const tab = (TABS.find((t) => t.id === parts[2])?.id ?? "overview") as Tab;
    return { view: "account", accountId: parts[1], tab, query };
  }
  return { view: "none" };
}

function useRoute(): [Route, (path: string) => void] {
  const [route, setRoute] = useState<Route>(() => parseHash(window.location.hash));
  useEffect(() => {
    const onHash = () => setRoute(parseHash(window.location.hash));
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  const navigate = useCallback((path: string) => {
    window.location.hash = path;
  }, []);
  return [route, navigate];
}

// ---------------------------------------------------------------------------
// Modal state
// ---------------------------------------------------------------------------

type ModalState =
  | { kind: "account"; account?: Account }
  | { kind: "snapshot"; accountId: string; db: Database }
  | { kind: "backupJob"; accountId: string; db: Database; plan?: BackupPlanSummary }
  | { kind: "backupPlan"; accountId: string; db: Database; plan?: BackupPlanSummary }
  | { kind: "automatedBackup"; accountId: string; db: Database }
  | {
      kind: "restore";
      accountId: string;
      db: Database;
      snapshots: Snapshot[];
      allIdentifiers: string[];
      initialSnapshotId?: string;
    }
  | null;

// ---------------------------------------------------------------------------
// Root
// ---------------------------------------------------------------------------

export default function App() {
  return (
    <ToastProvider>
      <AppShell />
    </ToastProvider>
  );
}

function AppShell() {
  const toast = useToast();
  const [route, navigate] = useRoute();

  const [accounts, setAccounts] = useState<Account[] | null>(null);
  const [accountsError, setAccountsError] = useState<string | null>(null);
  const [accountStatus, setAccountStatus] = useState<Record<string, AccountStatus>>({});
  const [databasesByAccount, setDatabasesByAccount] = useState<Record<string, Database[]>>({});
  const [schedulesByAccount, setSchedulesByAccount] = useState<Record<string, Schedule[]>>({});
  const [activityByAccount, setActivityByAccount] = useState<Record<string, model.Activity[]>>({});
  const [snapshotsByDb, setSnapshotsByDb] = useState<Record<string, Snapshot[]>>({});
  const [plansByDb, setPlansByDb] = useState<Record<string, BackupPlanSummary>>({});
  const [modal, setModal] = useState<ModalState>(null);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [theme, setTheme] = useState<"system" | "light" | "dark">(
    () => (localStorage.getItem("adbm-theme") as "system" | "light" | "dark") || "system",
  );

  useEffect(() => {
    if (theme === "system") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = theme;
    localStorage.setItem("adbm-theme", theme);
  }, [theme]);

  // ---- initial load -------------------------------------------------------
  useEffect(() => {
    let alive = true;
    ListAccounts()
      .then((accs) => {
        if (!alive) return;
        setAccounts(accs);
        accs.forEach((a) => {
          TestAccount(a.id)
            .then((s) => alive && setAccountStatus((m) => ({ ...m, [a.id]: s })))
            .catch(() => {});
        });
      })
      .catch((e) => alive && setAccountsError(msg(e)));
    return () => {
      alive = false;
    };
  }, []);

  // redirect "/" once accounts are known
  useEffect(() => {
    if (route.view !== "none" || accounts === null) return;
    navigate(accounts.length > 0 ? `/a/${accounts[0].id}` : "/settings");
  }, [route, accounts, navigate]);

  const activeAccountId = route.view === "account" ? route.accountId : null;
  const activeAccount = accounts?.find((a) => a.id === activeAccountId) ?? null;

  const loadDatabases = useCallback(
    (accountId: string) =>
      ListDatabases(accountId).then((dbs) => {
        setDatabasesByAccount((m) => ({ ...m, [accountId]: dbs }));
        return dbs;
      }),
    [],
  );
  const loadSchedules = useCallback(
    (accountId: string) =>
      ListSchedules(accountId).then((s) => setSchedulesByAccount((m) => ({ ...m, [accountId]: s }))),
    [],
  );
  const loadActivity = useCallback(
    (accountId: string) =>
      ListActivity(accountId, 50).then((a) => setActivityByAccount((m) => ({ ...m, [accountId]: a }))),
    [],
  );
  const loadSnapshots = useCallback(
    (accountId: string, dbId: string) =>
      ListSnapshots(accountId, dbId).then((s) => setSnapshotsByDb((m) => ({ ...m, [dbId]: s }))),
    [],
  );
  const loadPlan = useCallback(
    (accountId: string, dbId: string) =>
      GetBackupPlan(accountId, dbId).then((p) => setPlansByDb((m) => ({ ...m, [dbId]: p }))),
    [],
  );

  // load account-scoped lists once per account
  useEffect(() => {
    if (!activeAccountId) return;
    if (!databasesByAccount[activeAccountId]) loadDatabases(activeAccountId).catch((e) => toast.push("error", msg(e)));
    if (!schedulesByAccount[activeAccountId]) loadSchedules(activeAccountId).catch((e) => toast.push("error", msg(e)));
    if (!activityByAccount[activeAccountId]) loadActivity(activeAccountId).catch((e) => toast.push("error", msg(e)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeAccountId]);

  // once databases for the account are known, load snapshots + plan per db
  const activeDatabases = activeAccountId ? databasesByAccount[activeAccountId] ?? [] : [];
  useEffect(() => {
    if (!activeAccountId || activeDatabases.length === 0) return;
    activeDatabases.forEach((db) => {
      if (!snapshotsByDb[db.identifier]) loadSnapshots(activeAccountId, db.identifier).catch(() => {});
      if (!plansByDb[db.identifier]) loadPlan(activeAccountId, db.identifier).catch(() => {});
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeAccountId, activeDatabases]);

  const refreshActive = useCallback(() => {
    if (!activeAccountId) return;
    toast.push("info", "Refreshing…");
    Promise.all([loadDatabases(activeAccountId), loadSchedules(activeAccountId), loadActivity(activeAccountId)])
      .then(([dbs]) =>
        Promise.all(dbs.flatMap((db) => [loadSnapshots(activeAccountId, db.identifier), loadPlan(activeAccountId, db.identifier)])),
      )
      .catch((e) => toast.push("error", msg(e)));
  }, [activeAccountId, loadDatabases, loadSchedules, loadActivity, loadSnapshots, loadPlan, toast]);

  // keyboard shortcuts: Cmd/Ctrl+K palette, Cmd/Ctrl+R refresh
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (!mod) return;
      if (e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen(true);
      } else if (e.key.toLowerCase() === "r") {
        e.preventDefault();
        refreshActive();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [refreshActive]);

  const allDatabases = useMemo(() => Object.values(databasesByAccount).flat(), [databasesByAccount]);

  const paletteEntries: PaletteEntry[] = useMemo(() => {
    const entries: PaletteEntry[] = (accounts ?? []).map((a) => ({
      id: "acct-" + a.id,
      group: "Account",
      label: a.name,
      sublabel: regionsLabel(a.regions),
      onSelect: () => navigate(`/a/${a.id}`),
    }));
    for (const [accountId, dbs] of Object.entries(databasesByAccount)) {
      for (const db of dbs) {
        entries.push({
          id: "db-" + db.identifier,
          group: "Database",
          label: db.identifier,
          sublabel: `${engineLabel(db.engine)} · ${db.region}`,
          onSelect: () => navigate(`/a/${accountId}/backup-plans`),
        });
      }
    }
    entries.push({
      id: "settings",
      group: "App",
      label: "Settings — manage AWS accounts",
      onSelect: () => navigate("/settings"),
    });
    return entries;
  }, [accounts, databasesByAccount, navigate]);

  const saveAccount = useCallback(
    async (account: Account) => {
      const saved = await SaveAccount(account);
      setAccounts((prev) => {
        const list = prev ?? [];
        const exists = list.some((a) => a.id === saved.id);
        return exists ? list.map((a) => (a.id === saved.id ? saved : a)) : [...list, saved];
      });
      TestAccount(saved.id)
        .then((s) => setAccountStatus((m) => ({ ...m, [saved.id]: s })))
        .catch(() => {});
      toast.push("success", `Saved “${saved.name}”.`);
      return saved;
    },
    [toast],
  );

  const testAccount = useCallback(
    (id: string) =>
      TestAccount(id)
        .then((s) => {
          setAccountStatus((m) => ({ ...m, [id]: s }));
          toast.push(s.state === "ok" ? "success" : "error", s.message || s.state);
        })
        .catch((e) => toast.push("error", msg(e))),
    [toast],
  );

  const ssoLogin = useCallback(
    (id: string) =>
      SsoLogin(id)
        .then((s) => {
          setAccountStatus((m) => ({ ...m, [id]: s }));
          toast.push(s.state === "ok" ? "success" : "error", s.message || "Signed in");
        })
        .catch((e) => toast.push("error", msg(e))),
    [toast],
  );

  return (
    <div className="shell">
      <Sidebar accounts={accounts} accountStatus={accountStatus} route={route} navigate={navigate} />
      <div className="main">
        <Topbar
          account={activeAccount}
          route={route}
          onPalette={() => setPaletteOpen(true)}
          onRefresh={refreshActive}
          theme={theme}
          setTheme={setTheme}
        />
        <div className="content">
          {accountsError && (
            <div className="banner tone-danger">Could not load accounts: {accountsError}</div>
          )}
          {route.view === "settings" && (
            <SettingsPage
              accounts={accounts}
              accountStatus={accountStatus}
              onAdd={() => setModal({ kind: "account" })}
              onEdit={(a) => setModal({ kind: "account", account: a })}
              onTest={testAccount}
              onSso={ssoLogin}
            />
          )}
          {route.view === "account" && accounts && !activeAccount && (
            <Empty title="Account not found" text="It may have been removed. Open Settings to add it again." />
          )}
          {route.view === "account" && activeAccount && (
            <AccountView
              route={route}
              navigate={navigate}
              account={activeAccount}
              status={accountStatus[activeAccount.id]}
              databases={databasesByAccount[activeAccount.id] ?? null}
              schedules={schedulesByAccount[activeAccount.id] ?? null}
              activity={activityByAccount[activeAccount.id] ?? null}
              snapshotsByDb={snapshotsByDb}
              plansByDb={plansByDb}
              allDatabases={allDatabases}
              onSso={() => ssoLogin(activeAccount.id)}
              openModal={setModal}
            />
          )}
        </div>
      </div>
      <CommandPalette open={paletteOpen} onClose={() => setPaletteOpen(false)} entries={paletteEntries} />
      <ModalRouter
        modal={modal}
        close={() => setModal(null)}
        accounts={accounts ?? []}
        onSaveAccount={saveAccount}
        onDataChange={(accountId, dbId) => {
          loadSnapshots(accountId, dbId).catch(() => {});
          loadPlan(accountId, dbId).catch(() => {});
          loadDatabases(accountId).catch(() => {});
          loadActivity(accountId).catch(() => {});
        }}
      />
    </div>
  );
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

function Sidebar({
  accounts,
  accountStatus,
  route,
  navigate,
}: {
  accounts: Account[] | null;
  accountStatus: Record<string, AccountStatus>;
  route: Route;
  navigate: (path: string) => void;
}) {
  const activeAccountId = route.view === "account" ? route.accountId : null;
  const activeTab = route.view === "account" ? route.tab : null;

  return (
    <aside className="sidebar">
      <div className="brand">
        <span className="brand-mark">◆</span>
        <span className="brand-name">AWS DB Backup Manager</span>
      </div>

      <nav className="account-nav">
        {accounts === null && <div className="nav-hint">Loading accounts…</div>}
        {accounts?.length === 0 && <div className="nav-hint">No accounts yet.</div>}
        {accounts?.map((a) => {
          const status = accountStatus[a.id];
          const active = a.id === activeAccountId;
          return (
            <div key={a.id} className={"account-group" + (active ? " active" : "")}>
              <button className="account-row" onClick={() => navigate(`/a/${a.id}`)}>
                <AccountAvatar name={a.name} color={a.color} size="sm" />
                <span className="account-row-text">
                  <span className="account-row-name">
                    {a.name}
                    {a.readOnly && <ReadOnlyBadge compact />}
                  </span>
                  <span className="account-row-sub">{regionsLabel(a.regions)}</span>
                </span>
                {status?.state === "expired" && <span className="dot tone-warn" title="Sign-in expired" />}
                {status?.state === "error" && <span className="dot tone-danger" title={status.message} />}
                {status?.state === "ok" && <span className="dot tone-ok" title="Connected" />}
              </button>
              {active && (
                <div className="tab-list">
                  {TABS.map((t) => {
                    const Icon = t.icon;
                    return (
                      <button
                        key={t.id}
                        className={"tab-row" + (activeTab === t.id ? " active" : "")}
                        onClick={() => navigate(`/a/${a.id}/${t.id}`)}
                      >
                        <Icon size={15} />
                        {t.label}
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
          );
        })}
      </nav>

      <button
        className={"settings-row" + (route.view === "settings" ? " active" : "")}
        onClick={() => navigate("/settings")}
      >
        <SettingsIcon size={15} />
        Settings
      </button>
    </aside>
  );
}

// ---------------------------------------------------------------------------
// Topbar
// ---------------------------------------------------------------------------

function Topbar({
  account,
  route,
  onPalette,
  onRefresh,
  theme,
  setTheme,
}: {
  account: Account | null;
  route: Route;
  onPalette: () => void;
  onRefresh: () => void;
  theme: "system" | "light" | "dark";
  setTheme: (t: "system" | "light" | "dark") => void;
}) {
  const title =
    route.view === "settings"
      ? "Settings"
      : account
        ? `${account.name} · ${TABS.find((t) => t.id === (route.view === "account" ? route.tab : "overview"))?.label ?? "Overview"}`
        : "AWS DB Backup Manager";

  const cycleTheme = () => setTheme(theme === "system" ? "light" : theme === "light" ? "dark" : "system");
  const ThemeIcon = theme === "system" ? Monitor : theme === "light" ? Sun : Moon;

  return (
    <header className="topbar">
      <h1>{title}</h1>
      <div className="topbar-actions">
        <button className="icon-btn" onClick={onPalette} title="Jump to… (⌘K)">
          <Search size={16} />
        </button>
        {route.view === "account" && (
          <button className="icon-btn" onClick={onRefresh} title="Refresh (⌘R)">
            <RefreshCw size={16} />
          </button>
        )}
        <button className="icon-btn" onClick={cycleTheme} title={`Theme: ${theme}`}>
          <ThemeIcon size={16} />
        </button>
      </div>
    </header>
  );
}

// ---------------------------------------------------------------------------
// Account view (tabs)
// ---------------------------------------------------------------------------

function AccountView({
  route,
  navigate,
  account,
  status,
  databases,
  schedules,
  activity,
  snapshotsByDb,
  plansByDb,
  allDatabases,
  onSso,
  openModal,
}: {
  route: Route & { view: "account" };
  navigate: (path: string) => void;
  account: Account;
  status?: AccountStatus;
  databases: Database[] | null;
  schedules: Schedule[] | null;
  activity: model.Activity[] | null;
  snapshotsByDb: Record<string, Snapshot[]>;
  plansByDb: Record<string, BackupPlanSummary>;
  allDatabases: Database[];
  onSso: () => void;
  openModal: (m: ModalState) => void;
}) {
  if (status?.state === "expired") {
    return (
      <Card>
        <Empty
          icon={<LogIn size={28} />}
          title="Sign-in expired"
          text={status.message || "This account's AWS credentials need a fresh sign-in before it can be read."}
          action={
            <button className="primary" onClick={onSso}>
              <LogIn size={14} /> Sign in with SSO
            </button>
          }
        />
      </Card>
    );
  }
  if (status?.state === "error") {
    return <div className="banner tone-danger">{status.message || "This account could not be reached."}</div>;
  }
  if (!databases) {
    return <div className="loading-page">Loading {account.name}…</div>;
  }

  switch (route.tab) {
    case "overview":
      return (
        <OverviewPage
          account={account}
          databases={databases}
          schedules={schedules ?? []}
          activity={activity ?? []}
          snapshotsByDb={snapshotsByDb}
          onCreateSnapshot={(db) => openModal({ kind: "snapshot", accountId: account.id, db })}
          onViewDatabases={() => navigate(`/a/${account.id}/databases`)}
        />
      );
    case "databases":
      return (
        <DatabasesPage
          account={account}
          databases={databases}
          onBackUpNow={(db) => openModal({ kind: "snapshot", accountId: account.id, db })}
          onViewPlan={(db) => navigate(`/a/${account.id}/backup-plans`)}
        />
      );
    case "backup-plans":
      return (
        <BackupPlansPage
          account={account}
          databases={databases}
          plansByDb={plansByDb}
          onSnapshotNow={(db) => openModal({ kind: "snapshot", accountId: account.id, db })}
          onStartBackupJob={(db) => openModal({ kind: "backupJob", accountId: account.id, db, plan: plansByDb[db.identifier] })}
          onCreatePlan={(db) => openModal({ kind: "backupPlan", accountId: account.id, db, plan: plansByDb[db.identifier] })}
          onModifyAutomated={(db) => openModal({ kind: "automatedBackup", accountId: account.id, db })}
        />
      );
    case "schedules":
      return <SchedulesPage schedules={schedules ?? []} databases={databases} />;
    case "snapshots":
      return (
        <SnapshotsPage
          account={account}
          databases={databases}
          snapshotsByDb={snapshotsByDb}
          focusDb={route.query.get("db")}
          onRestore={(db, snapshot) =>
            openModal({
              kind: "restore",
              accountId: account.id,
              db,
              snapshots: (snapshotsByDb[db.identifier] ?? []).filter((s) => s.status === "available"),
              allIdentifiers: allDatabases.map((d) => d.identifier),
              initialSnapshotId: snapshot?.id,
            })
          }
        />
      );
    case "activity":
      return <ActivityPage activity={activity ?? []} />;
  }
}

// ---------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------

function OverviewPage({
  account,
  databases,
  schedules,
  activity,
  snapshotsByDb,
  onCreateSnapshot,
  onViewDatabases,
}: {
  account: Account;
  databases: Database[];
  schedules: Schedule[];
  activity: model.Activity[];
  snapshotsByDb: Record<string, Snapshot[]>;
  onCreateSnapshot: (db: Database) => void;
  onViewDatabases: () => void;
}) {
  const totalSnapshots = databases.reduce((n, db) => n + (snapshotsByDb[db.identifier]?.length ?? 0), 0);
  const unencrypted = databases.filter((db) => !db.encrypted);
  const lowRetention = databases.filter((db) => db.backupRetentionDays < 7);
  const recentSnapshots = databases
    .flatMap((db) => snapshotsByDb[db.identifier] ?? [])
    .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime())
    .slice(0, 6);
  const recentActivity = activity.slice(0, 6);

  return (
    <>
      <div className="stat-grid">
        <Stat label="Databases" value={databases.length} sub={regionsLabel(account.regions)} />
        <Stat label="Snapshots tracked" value={totalSnapshots} />
        <Stat
          label="Unencrypted databases"
          value={unencrypted.length}
          tone={unencrypted.length ? "warn" : "ok"}
        />
        <Stat
          label="Retention under 7 days"
          value={lowRetention.length}
          tone={lowRetention.length ? "warn" : "ok"}
        />
      </div>

      <div className="columns">
        <div className="col-main">
          <Card title="Recent snapshots">
            {recentSnapshots.length === 0 ? (
              <Empty title="No snapshots yet" text="Back up a database to see it here." />
            ) : (
              <Table>
                <thead>
                  <tr>
                    <th>Database</th>
                    <th>Source</th>
                    <th>Status</th>
                    <th>Created</th>
                  </tr>
                </thead>
                <tbody>
                  {recentSnapshots.map((s) => (
                    <tr key={s.id}>
                      <td>{s.dbIdentifier}</td>
                      <td>
                        <SourceBadge source={s.source} label={sourceLabels[s.source as keyof typeof sourceLabels] ?? s.source} />
                      </td>
                      <td>
                        <Pill tone={statusTone(s.status)}>{s.status}</Pill>
                      </td>
                      <td title={dateFull(s.createdAt)}>{ago(s.createdAt)}</td>
                    </tr>
                  ))}
                </tbody>
              </Table>
            )}
          </Card>

          <Card title="Recent activity">
            {recentActivity.length === 0 ? (
              <Empty title="No activity yet" />
            ) : (
              <ul className="activity-feed">
                {recentActivity.map((a, i) => (
                  <li key={i}>
                    <Pill tone={statusTone(a.status)}>{a.status}</Pill>
                    <span className="activity-text">
                      <strong>{a.db}</strong> — {a.action}
                    </span>
                    <span className="activity-time" title={dateFull(a.time)}>
                      {ago(a.time)}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </div>

        <div className="col-rail">
          <Card title="Quick actions">
            <div className="quick-actions">
              {databases.slice(0, 5).map((db) => (
                <WriteGuard key={db.identifier} disabled={account.readOnly}>
                  <button
                    className="secondary"
                    disabled={account.readOnly}
                    onClick={() => onCreateSnapshot(db)}
                  >
                    <Camera size={14} /> Back up {db.identifier}
                  </button>
                </WriteGuard>
              ))}
              <button className="secondary" onClick={onViewDatabases}>
                <DatabaseIcon size={14} /> View all databases
              </button>
            </div>
          </Card>

          <Card title="Account">
            <dl className="kv">
              <dt>AWS profile</dt>
              <dd>{account.profile}</dd>
              <dt>Regions</dt>
              <dd>{regionsLabel(account.regions)}</dd>
              <dt>Scheduled rules</dt>
              <dd>{schedules.length}</dd>
            </dl>
          </Card>
        </div>
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Databases
// ---------------------------------------------------------------------------

function DatabasesPage({
  account,
  databases,
  onBackUpNow,
  onViewPlan,
}: {
  account: Account;
  databases: Database[];
  onBackUpNow: (db: Database) => void;
  onViewPlan: (db: Database) => void;
}) {
  if (databases.length === 0) return <Empty title="No databases found" text="This account has no RDS or Aurora databases in its configured regions." />;
  return (
    <Card>
      <Table>
        <thead>
          <tr>
            <th>Database</th>
            <th>Engine</th>
            <th>Region</th>
            <th>Class</th>
            <th>Storage</th>
            <th>Retention</th>
            <th>Status</th>
            <th>Encryption</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {databases.map((db) => (
            <tr key={db.identifier}>
              <td>
                <div className="cell-main">{db.identifier}</div>
                <div className="cell-sub">
                  {kindLabel(db.kind)}
                  {isProd(db) && (
                    <>
                      {" "}
                      <ProdBadge />
                    </>
                  )}
                </div>
              </td>
              <td>
                {engineLabel(db.engine)} {db.engineVersion}
              </td>
              <td>{db.region}</td>
              <td>{db.class}</td>
              <td>{sizeGB(db.storageGb)}</td>
              <td>{db.backupRetentionDays}d</td>
              <td>
                <Pill tone={statusTone(db.status)}>{db.status}</Pill>
              </td>
              <td>
                <EncryptedBadge encrypted={db.encrypted} />
              </td>
              <td className="row-actions">
                <WriteGuard disabled={account.readOnly}>
                  <button className="link-btn" disabled={account.readOnly} onClick={() => onBackUpNow(db)}>
                    Back up now
                  </button>
                </WriteGuard>
                <button className="link-btn" onClick={() => onViewPlan(db)}>
                  Backup plan
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </Table>
    </Card>
  );
}

// ---------------------------------------------------------------------------
// Backup plans (grouped by database)
// ---------------------------------------------------------------------------

function BackupPlansPage({
  account,
  databases,
  plansByDb,
  onSnapshotNow,
  onStartBackupJob,
  onCreatePlan,
  onModifyAutomated,
}: {
  account: Account;
  databases: Database[];
  plansByDb: Record<string, BackupPlanSummary>;
  onSnapshotNow: (db: Database) => void;
  onStartBackupJob: (db: Database) => void;
  onCreatePlan: (db: Database) => void;
  onModifyAutomated: (db: Database) => void;
}) {
  if (databases.length === 0) return <Empty title="No databases to back up" />;
  return (
    <div className="plan-list">
      {databases.map((db) => {
        const plan = plansByDb[db.identifier];
        return (
          <Card key={db.identifier}>
            <div className="plan-head">
              <div>
                <div className="cell-main">{db.identifier}</div>
                <div className="cell-sub">
                  {kindLabel(db.kind)} · {engineLabel(db.engine)} · {db.region}
                  {isProd(db) && (
                    <>
                      {" "}
                      <ProdBadge />
                    </>
                  )}
                </div>
              </div>
              <div className="plan-actions">
                <WriteGuard disabled={account.readOnly}>
                  <button className="secondary" disabled={account.readOnly} onClick={() => onSnapshotNow(db)}>
                    <Camera size={14} /> Snapshot now
                  </button>
                </WriteGuard>
                <WriteGuard disabled={account.readOnly}>
                  <button className="secondary" disabled={account.readOnly} onClick={() => onStartBackupJob(db)}>
                    <ShieldCheck size={14} /> Start AWS Backup job
                  </button>
                </WriteGuard>
                <WriteGuard disabled={account.readOnly}>
                  <button className="secondary" disabled={account.readOnly} onClick={() => onCreatePlan(db)}>
                    <Plus size={14} /> Add backup plan
                  </button>
                </WriteGuard>
              </div>
            </div>

            <div className="plan-grid">
              <div className="plan-col">
                <h4>Manual</h4>
                {plan ? (
                  <dl className="kv">
                    <dt>Snapshots</dt>
                    <dd>{plan.manual.count}</dd>
                    <dt>Latest</dt>
                    <dd title={dateFull(plan.manual.latest)}>{ago(plan.manual.latest)}</dd>
                  </dl>
                ) : (
                  <span className="muted">Loading…</span>
                )}
              </div>

              <div className="plan-col">
                <h4>Automated</h4>
                {plan ? (
                  <dl className="kv">
                    <dt>Window</dt>
                    <dd>{plan.automated.window || "—"}</dd>
                    <dt>Retention</dt>
                    <dd>{plan.automated.retention}d</dd>
                    <dt>Latest</dt>
                    <dd title={dateFull(plan.automated.latest)}>{ago(plan.automated.latest)}</dd>
                  </dl>
                ) : (
                  <span className="muted">Loading…</span>
                )}
                <WriteGuard disabled={account.readOnly}>
                  <button className="link-btn" disabled={account.readOnly} onClick={() => onModifyAutomated(db)}>
                    Change window / raise retention
                  </button>
                </WriteGuard>
              </div>

              <div className="plan-col">
                <h4>AWS Backup</h4>
                {plan && plan.awsBackup.length > 0 ? (
                  <Table>
                    <thead>
                      <tr>
                        <th>Plan</th>
                        <th>Rule</th>
                        <th>Schedule</th>
                        <th>Lifecycle</th>
                        <th>Vault</th>
                      </tr>
                    </thead>
                    <tbody>
                      {plan.awsBackup.map((r) => (
                        <tr key={r.planId + r.ruleName}>
                          <td>{r.planName}</td>
                          <td>{r.ruleName}</td>
                          <td>
                            <code>{r.cron}</code>
                          </td>
                          <td>{r.lifecycle}</td>
                          <td>{r.vault}</td>
                        </tr>
                      ))}
                    </tbody>
                  </Table>
                ) : plan ? (
                  <Empty title="No AWS Backup plan" text="Add one to back this database up through AWS Backup." />
                ) : (
                  <span className="muted">Loading…</span>
                )}
              </div>
            </div>
          </Card>
        );
      })}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Schedules
// ---------------------------------------------------------------------------

function SchedulesPage({ schedules, databases }: { schedules: Schedule[]; databases: Database[] }) {
  if (schedules.length === 0) return <Empty title="No schedules" text="Automated backup windows and AWS Backup rules will appear here." />;
  const dbByIdent = new Map(databases.map((d) => [d.identifier, d]));
  return (
    <Card>
      <Table>
        <thead>
          <tr>
            <th>Source</th>
            <th>Database</th>
            <th>Schedule</th>
            <th>Next run</th>
            <th>Retention</th>
          </tr>
        </thead>
        <tbody>
          {schedules.map((s, i) => (
            <tr key={i}>
              <td>
                <Pill tone={s.source === "aws-backup-rule" ? "ok" : "info"}>
                  {scheduleSourceLabels[s.source as keyof typeof scheduleSourceLabels] ?? s.source}
                </Pill>
              </td>
              <td>
                {s.db}
                {dbByIdent.get(s.db) && isProd(dbByIdent.get(s.db)!) && (
                  <>
                    {" "}
                    <ProdBadge />
                  </>
                )}
              </td>
              <td>
                <code>{s.expression}</code>
              </td>
              <td title={dateFull(s.nextRun)}>{ago(s.nextRun)}</td>
              <td>{s.retention}d</td>
            </tr>
          ))}
        </tbody>
      </Table>
    </Card>
  );
}

// ---------------------------------------------------------------------------
// Snapshots
// ---------------------------------------------------------------------------

function SnapshotsPage({
  account,
  databases,
  snapshotsByDb,
  focusDb,
  onRestore,
}: {
  account: Account;
  databases: Database[];
  snapshotsByDb: Record<string, Snapshot[]>;
  focusDb: string | null;
  onRestore: (db: Database, snapshot: Snapshot) => void;
}) {
  const [dbFilter, setDbFilter] = useState(focusDb ?? "");
  const [sourceFilter, setSourceFilter] = useState<"" | "manual" | "automated" | "aws-backup">("");

  const dbByIdent = new Map(databases.map((d) => [d.identifier, d]));
  const rows = databases
    .filter((db) => !dbFilter || db.identifier === dbFilter)
    .flatMap((db) => (snapshotsByDb[db.identifier] ?? []).map((s) => ({ db, snapshot: s })))
    .filter((r) => !sourceFilter || r.snapshot.source === sourceFilter)
    .sort((a, b) => new Date(b.snapshot.createdAt).getTime() - new Date(a.snapshot.createdAt).getTime());

  return (
    <Card>
      <div className="filter-row">
        <select value={dbFilter} onChange={(e) => setDbFilter(e.target.value)}>
          <option value="">All databases</option>
          {databases.map((db) => (
            <option key={db.identifier} value={db.identifier}>
              {db.identifier}
            </option>
          ))}
        </select>
        <div className="chip-filter">
          {(["", "manual", "automated", "aws-backup"] as const).map((s) => (
            <button
              key={s}
              className={"chip-toggle" + (sourceFilter === s ? " active" : "")}
              onClick={() => setSourceFilter(s)}
            >
              {s === "" ? "All sources" : sourceLabels[s]}
            </button>
          ))}
        </div>
      </div>

      {rows.length === 0 ? (
        <Empty title="No snapshots" text="Create one from the Databases or Backup plans page." />
      ) : (
        <Table>
          <thead>
            <tr>
              <th>Database</th>
              <th>Source</th>
              <th>Status</th>
              <th>Created</th>
              <th>Size</th>
              <th>Encryption</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {rows.map(({ db, snapshot: s }) => (
              <tr key={s.id}>
                <td>
                  {s.dbIdentifier}
                  {isProd(db) && (
                    <>
                      {" "}
                      <ProdBadge />
                    </>
                  )}
                </td>
                <td>
                  <SourceBadge source={s.source} label={sourceLabels[s.source as keyof typeof sourceLabels] ?? s.source} />
                </td>
                <td>
                  <Pill tone={statusTone(s.status)}>{s.status}</Pill>
                </td>
                <td title={dateFull(s.createdAt)}>{ago(s.createdAt)}</td>
                <td>{sizeGB(s.sizeGb)}</td>
                <td>
                  <EncryptedBadge encrypted={s.encrypted} />
                </td>
                <td className="row-actions">
                  <WriteGuard disabled={account.readOnly}>
                    <button
                      className="link-btn"
                      disabled={s.status !== "available" || account.readOnly}
                      onClick={() => onRestore(db, s)}
                    >
                      Restore…
                    </button>
                  </WriteGuard>
                </td>
              </tr>
            ))}
          </tbody>
        </Table>
      )}
    </Card>
  );
}

// ---------------------------------------------------------------------------
// Activity
// ---------------------------------------------------------------------------

function ActivityPage({ activity }: { activity: model.Activity[] }) {
  if (activity.length === 0) return <Empty title="No activity yet" />;
  return (
    <Card>
      <ul className="activity-feed activity-feed-lg">
        {activity.map((a, i) => (
          <li key={i}>
            <Pill tone={statusTone(a.status)}>{a.status}</Pill>
            <span className="activity-text">
              <strong>{a.db}</strong> — {a.action}
              {a.message && <div className="activity-message">{a.message}</div>}
            </span>
            <span className="activity-time" title={dateFull(a.time)}>
              {ago(a.time)}
            </span>
          </li>
        ))}
      </ul>
    </Card>
  );
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

function SettingsPage({
  accounts,
  accountStatus,
  onAdd,
  onEdit,
  onTest,
  onSso,
}: {
  accounts: Account[] | null;
  accountStatus: Record<string, AccountStatus>;
  onAdd: () => void;
  onEdit: (a: Account) => void;
  onTest: (id: string) => void;
  onSso: (id: string) => void;
}) {
  return (
    <Card
      title="AWS accounts"
      action={
        <button className="primary" onClick={onAdd}>
          <Plus size={14} /> Add account
        </button>
      }
    >
      <p className="muted">
        Each account uses a local AWS profile already configured on this Mac. Credentials are never stored by this
        app — only the account name, profile, regions, and colour.
      </p>
      {accounts === null && <div className="loading-page">Loading…</div>}
      {accounts?.length === 0 && <Empty title="No accounts yet" text="Add one to get started." action={<button className="primary" onClick={onAdd}><Plus size={14}/> Add account</button>} />}
      <div className="account-cards">
        {accounts?.map((a) => {
          const status = accountStatus[a.id];
          return (
            <div key={a.id} className="account-card">
              <AccountAvatar name={a.name} color={a.color} size="lg" />
              <div className="account-card-body">
                <div className="account-card-name">
                  {a.name}
                  {a.readOnly && <ReadOnlyBadge />}
                </div>
                <div className="account-card-sub">
                  Profile <code>{a.profile}</code> · {regionsLabel(a.regions)}
                </div>
                {status && (
                  <div className="account-card-status">
                    <Pill tone={status.state === "ok" ? "ok" : status.state === "expired" ? "warn" : "danger"}>
                      {status.state}
                    </Pill>
                    {status.message && <span className="muted">{status.message}</span>}
                  </div>
                )}
              </div>
              <div className="account-card-actions">
                {status?.state === "expired" && (
                  <button className="secondary" onClick={() => onSso(a.id)}>
                    <LogIn size={14} /> Sign in with SSO
                  </button>
                )}
                <button className="secondary" onClick={() => onTest(a.id)}>
                  Test
                </button>
                <button className="link-btn" onClick={() => onEdit(a)}>
                  Edit
                </button>
              </div>
            </div>
          );
        })}
      </div>
    </Card>
  );
}

// ---------------------------------------------------------------------------
// Modal router
// ---------------------------------------------------------------------------

function ModalRouter({
  modal,
  close,
  accounts,
  onSaveAccount,
  onDataChange,
}: {
  modal: ModalState;
  close: () => void;
  accounts: Account[];
  onSaveAccount: (a: Account) => Promise<Account>;
  onDataChange: (accountId: string, dbId: string) => void;
}) {
  const toast = useToast();
  if (!modal) return null;

  switch (modal.kind) {
    case "account":
      return (
        <Modal title={modal.account ? "Edit account" : "Add account"} close={close}>
          <AccountForm
            initial={modal.account}
            existingIds={accounts.map((a) => a.id)}
            onCancel={close}
            onSave={async (a) => {
              await onSaveAccount(a);
              close();
            }}
          />
        </Modal>
      );

    case "snapshot":
      return (
        <Modal title={`Back up ${modal.db.identifier}`} close={close}>
          <SnapshotForm
            accountId={modal.accountId}
            db={modal.db}
            onCancel={close}
            onDone={() => {
              onDataChange(modal.accountId, modal.db.identifier);
              close();
            }}
          />
        </Modal>
      );

    case "backupJob":
      return (
        <Modal title={`Start AWS Backup job for ${modal.db.identifier}`} close={close}>
          <BackupJobForm
            accountId={modal.accountId}
            db={modal.db}
            plan={modal.plan}
            onCancel={close}
            onDone={() => {
              onDataChange(modal.accountId, modal.db.identifier);
              close();
            }}
          />
        </Modal>
      );

    case "backupPlan":
      return (
        <Modal title={`Add a backup plan for ${modal.db.identifier}`} close={close}>
          <BackupPlanForm
            accountId={modal.accountId}
            db={modal.db}
            plan={modal.plan}
            onCancel={close}
            onDone={() => {
              onDataChange(modal.accountId, modal.db.identifier);
              close();
            }}
          />
        </Modal>
      );

    case "automatedBackup":
      return (
        <Modal title={`Automated backups for ${modal.db.identifier}`} close={close}>
          <AutomatedBackupForm
            accountId={modal.accountId}
            db={modal.db}
            onCancel={close}
            onDone={() => {
              onDataChange(modal.accountId, modal.db.identifier);
              close();
            }}
          />
        </Modal>
      );

    case "restore":
      return (
        <Modal title={`Restore ${modal.db.identifier}`} close={close} wide>
          <RestoreWizard
            accountId={modal.accountId}
            db={modal.db}
            snapshots={modal.snapshots}
            allIdentifiers={modal.allIdentifiers}
            initialSnapshotId={modal.initialSnapshotId}
            onCancel={close}
            onDone={(activity) => {
              toast.push("success", `Restore started: ${activity.action}`);
              onDataChange(modal.accountId, modal.db.identifier);
              close();
            }}
          />
        </Modal>
      );
  }
}

// ---------------------------------------------------------------------------
// Forms
// ---------------------------------------------------------------------------

function FormError({ error }: { error: string | null }) {
  if (!error) return null;
  return <div className="form-error">{error}</div>;
}

function AccountForm({
  initial,
  existingIds,
  onCancel,
  onSave,
}: {
  initial?: Account;
  existingIds: string[];
  onCancel: () => void;
  onSave: (a: Account) => Promise<void>;
}) {
  const [name, setName] = useState(initial?.name ?? "");
  const [profile, setProfile] = useState(initial?.profile ?? "");
  const [regionsText, setRegionsText] = useState((initial?.regions ?? ["us-east-1"]).join(", "));
  const [color, setColor] = useState(initial?.color ?? "");
  const [readOnly, setReadOnly] = useState(initial?.readOnly ?? false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const palette = ["#2563eb", "#16a34a", "#d97706", "#7c3aed", "#0891b2", "#db2777", "#64748b"];

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const regions = regionsText.split(",").map((r) => r.trim()).filter(Boolean);
    if (!name.trim() || !profile.trim() || regions.length === 0) {
      setError("Name, AWS profile, and at least one region are required.");
      return;
    }
    setError(null);
    setSaving(true);
    try {
      const id = initial?.id ?? uniqueId(slugify(name), new Set(existingIds));
      await onSave({ id, name: name.trim(), profile: profile.trim(), regions, color, readOnly } as Account);
    } catch (err) {
      setError(msg(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form className="form" onSubmit={submit}>
      <label>
        Display name
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Production" autoFocus />
      </label>
      <label>
        AWS profile
        <input value={profile} onChange={(e) => setProfile(e.target.value)} placeholder="prod" />
      </label>
      <label>
        Regions
        <input value={regionsText} onChange={(e) => setRegionsText(e.target.value)} placeholder="us-east-1, us-west-2" />
      </label>
      <label>
        Colour
        <div className="swatches">
          {palette.map((c) => (
            <button
              key={c}
              type="button"
              className={"swatch" + (color === c ? " selected" : "")}
              style={{ background: c }}
              onClick={() => setColor(c)}
              aria-label={c}
            />
          ))}
          <button type="button" className={"swatch swatch-auto" + (color === "" ? " selected" : "")} onClick={() => setColor("")}>
            auto
          </button>
        </div>
      </label>
      <label className="checkbox-row">
        <input type="checkbox" checked={readOnly} onChange={(e) => setReadOnly(e.target.checked)} />
        Read-only — disable backups, plans and restores for this account
      </label>
      {readOnly && (
        <div className="field-hint">
          Write actions will be refused by the app and the backend for this account, even if the AWS profile allows
          them.
        </div>
      )}
      <FormError error={error} />
      <div className="form-actions">
        <button type="button" className="secondary" onClick={onCancel}>
          Cancel
        </button>
        <button type="submit" className="primary" disabled={saving}>
          {saving ? "Saving…" : "Save account"}
        </button>
      </div>
    </form>
  );
}

function SnapshotForm({
  accountId,
  db,
  onCancel,
  onDone,
}: {
  accountId: string;
  db: Database;
  onCancel: () => void;
  onDone: () => void;
}) {
  const toast = useToast();
  const [snapshotName, setSnapshotName] = useState(() => suggestSnapshotName(db.identifier));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!snapshotName.trim()) {
      setError("Snapshot name is required.");
      return;
    }
    setError(null);
    setSaving(true);
    try {
      await CreateSnapshot({
        accountId,
        region: db.region,
        kind: db.kind,
        dbIdentifier: db.identifier,
        snapshotName: snapshotName.trim(),
      });
      toast.push("success", `Snapshot “${snapshotName.trim()}” is being created.`);
      onDone();
    } catch (err) {
      setError(msg(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form className="form" onSubmit={submit}>
      <p className="muted">
        Creates a manual snapshot of <strong>{db.identifier}</strong> ({kindLabel(db.kind)}) in {db.region}.
      </p>
      <label>
        Snapshot name
        <input value={snapshotName} onChange={(e) => setSnapshotName(e.target.value)} autoFocus />
      </label>
      <FormError error={error} />
      <div className="form-actions">
        <button type="button" className="secondary" onClick={onCancel}>
          Cancel
        </button>
        <button type="submit" className="primary" disabled={saving}>
          {saving ? "Starting…" : "Create snapshot"}
        </button>
      </div>
    </form>
  );
}

function BackupJobForm({
  accountId,
  db,
  plan,
  onCancel,
  onDone,
}: {
  accountId: string;
  db: Database;
  plan?: BackupPlanSummary;
  onCancel: () => void;
  onDone: () => void;
}) {
  const toast = useToast();
  const [vaultName, setVaultName] = useState(plan?.awsBackup[0]?.vault ?? "default");
  const [iamRoleArn, setIamRoleArn] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!vaultName.trim() || !iamRoleArn.trim()) {
      setError("Vault name and IAM role ARN are required.");
      return;
    }
    setError(null);
    setSaving(true);
    try {
      await StartBackupJob({
        accountId,
        region: db.region,
        kind: db.kind,
        dbIdentifier: db.identifier,
        vaultName: vaultName.trim(),
        iamRoleArn: iamRoleArn.trim(),
      });
      toast.push("success", "AWS Backup job started.");
      onDone();
    } catch (err) {
      setError(msg(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form className="form" onSubmit={submit}>
      <p className="muted">
        Starts an on-demand AWS Backup job for <strong>{db.identifier}</strong>.
      </p>
      <label>
        Backup vault
        <input value={vaultName} onChange={(e) => setVaultName(e.target.value)} />
      </label>
      <label>
        IAM role ARN
        <input value={iamRoleArn} onChange={(e) => setIamRoleArn(e.target.value)} placeholder="arn:aws:iam::123456789012:role/AWSBackupRole" />
      </label>
      <FormError error={error} />
      <div className="form-actions">
        <button type="button" className="secondary" onClick={onCancel}>
          Cancel
        </button>
        <button type="submit" className="primary" disabled={saving}>
          {saving ? "Starting…" : "Start backup job"}
        </button>
      </div>
    </form>
  );
}

function BackupPlanForm({
  accountId,
  db,
  plan,
  onCancel,
  onDone,
}: {
  accountId: string;
  db: Database;
  plan?: BackupPlanSummary;
  onCancel: () => void;
  onDone: () => void;
}) {
  const toast = useToast();
  const [planName, setPlanName] = useState(`${db.identifier}-plan`);
  const [ruleName, setRuleName] = useState("daily-3am");
  const [cron, setCron] = useState("cron(0 3 * * ? *)");
  const [vaultName, setVaultName] = useState(plan?.awsBackup[0]?.vault ?? "default");
  const [retentionDays, setRetentionDays] = useState(MIN_AWS_BACKUP_RETENTION_DAYS);
  const [iamRoleArn, setIamRoleArn] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!planName.trim() || !ruleName.trim() || !cron.trim() || !vaultName.trim() || !iamRoleArn.trim()) {
      setError("All fields are required.");
      return;
    }
    if (retentionDays < MIN_AWS_BACKUP_RETENTION_DAYS) {
      setError(`Retention must be at least ${MIN_AWS_BACKUP_RETENTION_DAYS} days.`);
      return;
    }
    setError(null);
    setSaving(true);
    try {
      await CreateBackupPlan({
        accountId,
        region: db.region,
        kind: db.kind,
        dbIdentifier: db.identifier,
        planName: planName.trim(),
        ruleName: ruleName.trim(),
        cron: cron.trim(),
        vaultName: vaultName.trim(),
        retentionDays,
        iamRoleArn: iamRoleArn.trim(),
      });
      toast.push("success", `Backup plan “${planName.trim()}” created.`);
      onDone();
    } catch (err) {
      setError(msg(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form className="form" onSubmit={submit}>
      <p className="muted">
        Creates an AWS Backup plan and rule covering <strong>{db.identifier}</strong>.
      </p>
      <label>
        Plan name
        <input value={planName} onChange={(e) => setPlanName(e.target.value)} />
      </label>
      <label>
        Rule name
        <input value={ruleName} onChange={(e) => setRuleName(e.target.value)} />
      </label>
      <label>
        Schedule (cron)
        <input value={cron} onChange={(e) => setCron(e.target.value)} />
      </label>
      <label>
        Backup vault
        <input value={vaultName} onChange={(e) => setVaultName(e.target.value)} />
      </label>
      <label>
        Retention (days)
        <input
          type="number"
          min={MIN_AWS_BACKUP_RETENTION_DAYS}
          value={retentionDays}
          onChange={(e) => setRetentionDays(Math.max(MIN_AWS_BACKUP_RETENTION_DAYS, Number(e.target.value)))}
        />
        <span className="field-hint">AWS Backup plans must keep recovery points for at least {MIN_AWS_BACKUP_RETENTION_DAYS} days.</span>
      </label>
      <label>
        IAM role ARN
        <input value={iamRoleArn} onChange={(e) => setIamRoleArn(e.target.value)} placeholder="arn:aws:iam::123456789012:role/AWSBackupRole" />
      </label>
      <FormError error={error} />
      <div className="form-actions">
        <button type="button" className="secondary" onClick={onCancel}>
          Cancel
        </button>
        <button type="submit" className="primary" disabled={saving}>
          {saving ? "Creating…" : "Create plan"}
        </button>
      </div>
    </form>
  );
}

function AutomatedBackupForm({
  accountId,
  db,
  onCancel,
  onDone,
}: {
  accountId: string;
  db: Database;
  onCancel: () => void;
  onDone: () => void;
}) {
  const toast = useToast();
  const [window, setWindow] = useState(db.preferredBackupWindow);
  const [retentionDays, setRetentionDays] = useState(db.backupRetentionDays);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const minRetention = Math.max(MIN_AUTOMATED_RETENTION_DAYS, db.backupRetentionDays);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (retentionDays < minRetention) {
      setError(`Retention can only be raised — it is currently ${db.backupRetentionDays} days and can never be lowered.`);
      return;
    }
    setError(null);
    setSaving(true);
    try {
      await ModifyAutomatedBackup({
        accountId,
        region: db.region,
        kind: db.kind,
        dbIdentifier: db.identifier,
        window: window.trim() || undefined,
        retentionDays,
      });
      toast.push("success", "Automated backup settings updated.");
      onDone();
    } catch (err) {
      setError(msg(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form className="form" onSubmit={submit}>
      <p className="muted">
        Current retention is <strong>{db.backupRetentionDays} days</strong>. It can be raised, but — to protect your data —
        never lowered or disabled from this app.
      </p>
      <label>
        Preferred backup window (UTC)
        <input value={window} onChange={(e) => setWindow(e.target.value)} placeholder="03:00-03:30" />
      </label>
      <label>
        Retention (days)
        <input
          type="number"
          min={minRetention}
          value={retentionDays}
          onChange={(e) => setRetentionDays(Math.max(minRetention, Number(e.target.value)))}
        />
      </label>
      <FormError error={error} />
      <div className="form-actions">
        <button type="button" className="secondary" onClick={onCancel}>
          Cancel
        </button>
        <button type="submit" className="primary" disabled={saving}>
          {saving ? "Saving…" : "Save"}
        </button>
      </div>
    </form>
  );
}

// ---------------------------------------------------------------------------
// Restore wizard (3 steps, always creates a new database)
// ---------------------------------------------------------------------------

function RestoreWizard({
  accountId,
  db,
  snapshots,
  allIdentifiers,
  initialSnapshotId,
  onCancel,
  onDone,
}: {
  accountId: string;
  db: Database;
  snapshots: Snapshot[];
  allIdentifiers: string[];
  initialSnapshotId?: string;
  onCancel: () => void;
  onDone: (activity: model.Activity) => void;
}) {
  const [step, setStep] = useState(1);
  const [source, setSource] = useState<RestoreSource>(
    snapshots.some((s) => s.source !== "aws-backup") ? "snapshot" : "recovery-point",
  );
  const [snapshotId, setSnapshotId] = useState(initialSnapshotId ?? snapshots[0]?.id ?? "");
  const [restoreTime, setRestoreTime] = useState("");
  const [targetIdentifier, setTargetIdentifier] = useState(`${db.identifier}-restored`);
  const [instanceClass, setInstanceClass] = useState(db.class);
  const [subnetGroup, setSubnetGroup] = useState("");
  const [securityGroups, setSecurityGroups] = useState("");
  const [publiclyAccessible, setPubliclyAccessible] = useState(false);
  const [confirmText, setConfirmText] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const existing = new Set(allIdentifiers);
  const snapshotChoices = snapshots.filter((s) => s.source !== "aws-backup");
  const recoveryPointChoices = snapshots.filter((s) => s.source === "aws-backup");
  const selectedSnapshot = snapshots.find((s) => s.id === snapshotId);
  const prod = isProd(db);

  const step1Valid =
    (source === "snapshot" && !!snapshotId) ||
    (source === "pitr" && !!restoreTime) ||
    (source === "recovery-point" && !!snapshotId);

  const step2Error = !targetIdentifier.trim()
    ? "A target database identifier is required."
    : targetIdentifier.trim() === db.identifier
      ? "The restore target must be a new identifier — it cannot overwrite the source database."
      : existing.has(targetIdentifier.trim())
        ? "That identifier is already in use. Choose a different one."
        : null;

  const step3Ready = !prod || confirmText.trim() === db.identifier;

  const submit = async () => {
    setError(null);
    setSaving(true);
    try {
      const activity = await Restore(new model.RestoreReq({
        accountId,
        region: db.region,
        kind: db.kind,
        source,
        sourceDbIdentifier: db.identifier,
        snapshotId: source !== "pitr" ? snapshotId : undefined,
        recoveryPointArn: source === "recovery-point" ? selectedSnapshot?.arn : undefined,
        restoreTime: source === "pitr" ? new Date(restoreTime).toISOString() : undefined,
        targetIdentifier: targetIdentifier.trim(),
        instanceClass: instanceClass.trim() || undefined,
        subnetGroup: subnetGroup.trim() || undefined,
        securityGroups: securityGroups
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean),
        publiclyAccessible,
      }));
      onDone(activity);
    } catch (err) {
      setError(msg(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="wizard">
      <div className="wizard-steps">
        {["Source", "Target settings", "Review"].map((label, i) => (
          <div key={label} className={"wizard-step" + (step === i + 1 ? " active" : step > i + 1 ? " done" : "")}>
            <span className="wizard-step-dot">{i + 1}</span>
            {label}
          </div>
        ))}
      </div>

      {step === 1 && (
        <div className="wizard-body">
          <p className="muted">
            Restoring always creates a brand-new database — <strong>{db.identifier}</strong> itself is never changed or
            removed.
          </p>
          <div className="radio-group">
            {snapshotChoices.length > 0 && (
              <label>
                <input type="radio" checked={source === "snapshot"} onChange={() => setSource("snapshot")} />
                From a snapshot
              </label>
            )}
            <label>
              <input type="radio" checked={source === "pitr"} onChange={() => setSource("pitr")} />
              Point in time
            </label>
            {recoveryPointChoices.length > 0 && (
              <label>
                <input type="radio" checked={source === "recovery-point"} onChange={() => setSource("recovery-point")} />
                AWS Backup recovery point
              </label>
            )}
          </div>

          {source === "snapshot" && (
            <label>
              Snapshot
              <select value={snapshotId} onChange={(e) => setSnapshotId(e.target.value)}>
                {snapshotChoices.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.id} — {sourceLabels[s.source as keyof typeof sourceLabels] ?? s.source} — {dateFull(s.createdAt)}
                  </option>
                ))}
              </select>
            </label>
          )}
          {source === "recovery-point" && (
            <label>
              Recovery point
              <select value={snapshotId} onChange={(e) => setSnapshotId(e.target.value)}>
                {recoveryPointChoices.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.id} — {dateFull(s.createdAt)} ({s.vaultName})
                  </option>
                ))}
              </select>
            </label>
          )}
          {source === "pitr" && (
            <label>
              Restore to
              <input
                type="datetime-local"
                value={restoreTime}
                max={db.latestRestorableTime ? db.latestRestorableTime.slice(0, 16) : undefined}
                onChange={(e) => setRestoreTime(e.target.value)}
              />
              <span className="field-hint">
                Latest restorable time: {db.latestRestorableTime ? dateFull(db.latestRestorableTime) : "unavailable"}
              </span>
            </label>
          )}

          <div className="form-actions">
            <button type="button" className="secondary" onClick={onCancel}>
              Cancel
            </button>
            <button type="button" className="primary" disabled={!step1Valid} onClick={() => setStep(2)}>
              Next
            </button>
          </div>
        </div>
      )}

      {step === 2 && (
        <div className="wizard-body">
          <label>
            New database identifier
            <input value={targetIdentifier} onChange={(e) => setTargetIdentifier(e.target.value)} autoFocus />
          </label>
          <label>
            Instance class
            <input value={instanceClass} onChange={(e) => setInstanceClass(e.target.value)} />
          </label>
          <label>
            Subnet group (optional)
            <input value={subnetGroup} onChange={(e) => setSubnetGroup(e.target.value)} />
          </label>
          <label>
            Security groups (optional, comma-separated)
            <input value={securityGroups} onChange={(e) => setSecurityGroups(e.target.value)} />
          </label>
          <label className="checkbox-row">
            <input type="checkbox" checked={publiclyAccessible} onChange={(e) => setPubliclyAccessible(e.target.checked)} />
            Publicly accessible
          </label>
          <FormError error={step2Error && targetIdentifier.trim() ? step2Error : null} />
          <div className="form-actions">
            <button type="button" className="secondary" onClick={() => setStep(1)}>
              Back
            </button>
            <button type="button" className="primary" disabled={!!step2Error} onClick={() => setStep(3)}>
              Next
            </button>
          </div>
        </div>
      )}

      {step === 3 && (
        <div className="wizard-body">
          <dl className="kv">
            <dt>Source database</dt>
            <dd>{db.identifier}</dd>
            <dt>Restore source</dt>
            <dd>
              {source === "pitr" ? `Point in time — ${restoreTime}` : `${selectedSnapshot?.id ?? "—"}`}
            </dd>
            <dt>New database identifier</dt>
            <dd>{targetIdentifier.trim()}</dd>
            <dt>Instance class</dt>
            <dd>{instanceClass || "—"}</dd>
            <dt>Publicly accessible</dt>
            <dd>{publiclyAccessible ? "Yes" : "No"}</dd>
          </dl>

          {prod && (
            <label>
              This is a production database. Type <code>{db.identifier}</code> to confirm the restore.
              <input value={confirmText} onChange={(e) => setConfirmText(e.target.value)} placeholder={db.identifier} />
            </label>
          )}

          <FormError error={error} />
          <div className="form-actions">
            <button type="button" className="secondary" onClick={() => setStep(2)}>
              Back
            </button>
            <button type="button" className="primary" disabled={!step3Ready || saving} onClick={submit}>
              {saving ? "Starting restore…" : "Start restore"}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
