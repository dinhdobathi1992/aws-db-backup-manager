import ADBMCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<SidebarItem?>(get: { model.selection }, set: { model.select($0) })
        List(selection: selection) {
            if model.activeAccount != nil {
                Section {
                    ForEach(Tab.allCases) { t in
                        Label(t.label, systemImage: t.symbol).tag(SidebarItem.tab(t))
                    }
                }
            }
            Section {
                if (model.accounts?.count ?? 0) > 1 {
                    Label("All accounts", systemImage: "rectangle.stack").tag(SidebarItem.fleet)
                }
                Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            AccountSwitcher().padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
        }
    }
}

/// One dropdown for every account, instead of a list that grows with each account.
struct AccountSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if let accounts = model.accounts, !accounts.isEmpty {
                Section("Switch account") {
                    ForEach(accounts) { a in
                        Button { model.select(.account(a.id)) } label: {
                            if a.id == model.activeAccountId {
                                Label(menuTitle(a), systemImage: "checkmark")
                            } else {
                                Text(menuTitle(a))
                            }
                        }
                    }
                }
            }
            Divider()
            Button("All accounts", systemImage: "rectangle.stack") { model.select(.fleet) }
            Button("Add account…", systemImage: "plus") { model.open(.account(nil)) }
            Button("Manage accounts…", systemImage: "gearshape") { model.select(.settings) }
        } label: {
            HStack(spacing: 10) {
                if let a = model.activeAccount {
                    AccountAvatar(account: a, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 5) {
                            StatusDot(status: model.accountStatus[a.id])
                            Text(Fmt.regions(a.regions)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if a.readOnly { ReadOnlyBadge(compact: true) }
                        }
                    }
                    .layoutPriority(1)
                } else {
                    Image(systemName: "person.crop.circle.badge.plus").font(.title2).foregroundStyle(.secondary)
                    Text(model.accounts == nil ? "Loading accounts…" : "No account").foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(.rect)
            .surface(cornerRadius: 10)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Switch account")
    }

    private func menuTitle(_ a: Account) -> String {
        "\(a.name)  ·  \(Fmt.regions(a.regions))\(a.readOnly ? "  ·  read-only" : "")"
    }
}
