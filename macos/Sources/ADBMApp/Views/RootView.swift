import ADBMCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            DetailView()
                .navigationTitle(model.title)
                .toolbar { MainToolbar() }
        }
        .overlay(alignment: .bottomTrailing) { ToastHost() }
        .sheet(item: $model.sheet) { sheet in
            SheetRouter(sheet: sheet).environment(model)
        }
        .sheet(isPresented: $model.paletteOpen) {
            CommandPalette().environment(model)
        }
        .task { await model.start() }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Jump to…", systemImage: "magnifyingglass") { model.paletteOpen = true }
                .help("Jump to… (⌘K)")
            if model.selection != .settings, model.selection != .fleet, model.activeAccountId != nil {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshActive() }
                    .help("Refresh (⌘R)")
            }
            Menu {
                Picker("Theme", selection: Bindable(model).theme) {
                    ForEach(ThemeSetting.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Theme", systemImage: model.theme.symbol)
            } primaryAction: {
                model.theme = model.theme.next
            }
            .help("Theme: \(model.theme.rawValue)")
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let err = model.accountsError {
                InlineError(message: "Could not load accounts: \(err)").padding()
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        if model.selection == .settings {
            SettingsView()
        } else if model.selection == .fleet {
            FleetView()
        } else if model.accounts == nil {
            ProgressView("Loading accounts…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let account = model.activeAccount {
            AccountDetail(account: account, tab: model.activeTab ?? .overview)
        } else if model.accounts?.isEmpty == true {
            EmptyState(title: "No accounts yet", systemImage: "person.crop.circle.badge.plus",
                       text: "Open Settings to add an AWS account.")
        } else {
            EmptyState(title: "Account not found", systemImage: "questionmark.circle",
                       text: "Open Settings to add it again.")
        }
    }
}

/// The per-account gate: expired SSO, unreachable account, loading, then the tab.
struct AccountDetail: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let tab: Tab

    var body: some View {
        let status = model.accountStatus[account.id]
        if status?.state == .expired {
            ContentUnavailableView {
                Label("Sign-in expired", systemImage: "person.badge.key")
            } description: {
                Text(status?.message.isEmpty == false ? status!.message
                     : "This account's AWS credentials need a fresh sign-in before it can be read.")
            } actions: {
                Button("Sign in with SSO", systemImage: "person.badge.key") { model.ssoLogin(account.id) }
                    .buttonStyle(.borderedProminent)
            }
        } else if status?.state == .error {
            VStack {
                InlineError(message: status?.message.isEmpty == false ? status!.message : "This account could not be reached.",
                            onSignIn: { model.ssoLogin(account.id) })
                Spacer()
            }.padding()
        } else if let dbs = model.databasesByAccount[account.id] {
            VStack(spacing: 0) {
                if let err = model.loadErrors[account.id] {
                    InlineError(message: err, onSignIn: { model.ssoLogin(account.id) }).padding([.horizontal, .top])
                }
                tabView(dbs)
            }
        } else if let err = model.loadErrors[account.id] {
            VStack {
                InlineError(message: err, onSignIn: { model.ssoLogin(account.id) })
                Button("Try again") { Task { await model.reload(account.id, announce: false) } }
                Spacer()
            }.padding()
        } else {
            ProgressView("Loading \(account.name)…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func tabView(_ dbs: [Database]) -> some View {
        switch tab {
        case .overview: OverviewView(account: account, databases: dbs)
        case .databases: DatabasesView(account: account, databases: dbs)
        case .backupPlans: BackupPlansView(account: account, databases: dbs)
        case .schedules: SchedulesView(account: account, databases: dbs)
        case .snapshots: SnapshotsView(account: account, databases: dbs)
        case .activity: ActivityView(account: account)
        }
    }
}
