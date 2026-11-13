import ADBMCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach(model.accounts ?? []) { a in
                    AccountSettingsRow(account: a, status: model.accountStatus[a.id])
                }
                if model.accounts?.isEmpty == true {
                    EmptyState(title: "No accounts yet", systemImage: "person.crop.circle.badge.plus", text: "Add one to get started.")
                }
            } header: {
                HStack {
                    Text("AWS accounts")
                    Spacer()
                    Button("Add account", systemImage: "plus") { model.open(.account(nil)) }
                }
            } footer: {
                Text("Each account uses a local AWS profile already configured on this Mac. Credentials are never stored by this app — only the account name, profile, regions, and colour.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Theme", selection: $model.theme) {
                    ForEach(ThemeSetting.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if ServiceFactory.usesFixtures {
                Section {
                    Label("Showing fixture data (ADBM_FIXTURES=1). No AWS calls are made.", systemImage: "testtube.2")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { model.refreshAllStatuses() }
    }
}

struct AccountSettingsRow: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let status: AccountStatus?
    @State private var testing = false

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatar(account: account, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.name).font(.headline)
                    if account.readOnly { ReadOnlyBadge() }
                }
                (Text("Profile ") + Text(account.profile).font(.callout.monospaced()) + Text(" · \(Fmt.regions(account.regions))"))
                    .font(.callout).foregroundStyle(.secondary)
                if let status {
                    HStack(spacing: 6) {
                        Pill(text: status.state.rawValue, tone: status.state == .ok ? .ok : status.state == .expired ? .warn : .danger)
                        if !status.message.isEmpty { Text(status.message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
            Spacer()
            if status?.state == .expired {
                Button("Sign in with SSO", systemImage: "person.badge.key") { model.ssoLogin(account.id) }
            }
            Button {
                testing = true
                Task { await model.refreshStatus(account.id, announce: true); testing = false }
            } label: {
                if testing { ProgressView().controlSize(.small) } else { Text("Test connection") }
            }
            .disabled(testing)
            Button("Edit…") { model.open(.account(account)) }
        }
        .padding(.vertical, 4)
    }
}
