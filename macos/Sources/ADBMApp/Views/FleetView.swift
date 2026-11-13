// Every account on one screen: how many databases each has and which
// backup settings need attention. Reads only each account's database list.
import ADBMCore
import SwiftUI

struct FleetRow: Identifiable {
    let account: Account
    let status: AccountStatus?
    let databases: [Database]?
    let error: String?
    let loading: Bool
    var id: String { account.id }

    var dbCount: Int? { databases?.count }
    var prod: Int? { databases?.filter(Fmt.isProd).count }
    var retentionOff: Int? { databases?.filter { $0.backupRetentionDays == 0 }.count }
    var retentionLow: Int? { databases?.filter { $0.backupRetentionDays > 0 && $0.backupRetentionDays < 7 }.count }
    var unencrypted: Int? { databases?.filter { !$0.encrypted }.count }
    var dbSort: Int { dbCount ?? -1 }
    var issues: Int { (retentionOff ?? 0) + (retentionLow ?? 0) + (unencrypted ?? 0) }
}

struct FleetView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var onlyIssues = false
    @State private var sortOrder = [KeyPathComparator(\FleetRow.issues, order: .reverse)]

    private var rows: [FleetRow] {
        (model.accounts ?? []).map { a in
            FleetRow(account: a, status: model.accountStatus[a.id], databases: model.databasesByAccount[a.id],
                     error: model.loadErrors[a.id], loading: model.fleetLoading.contains(a.id))
        }
    }

    var body: some View {
        let all = rows
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = all
            .filter { q.isEmpty || $0.account.name.lowercased().contains(q) || $0.account.profile.lowercased().contains(q)
                || $0.account.regions.contains { $0.contains(q) } }
            .filter { !onlyIssues || $0.issues > 0 || $0.error != nil }
            .sorted(using: sortOrder)
        let loaded = all.compactMap(\.databases)
        let dbs = loaded.flatMap { $0 }

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                StatCard(label: "Accounts", value: all.count, sub: "\(loaded.count) loaded")
                StatCard(label: "Databases", value: dbs.count)
                StatCard(label: "Automated backups off", value: dbs.filter { $0.backupRetentionDays == 0 }.count,
                         tone: dbs.contains { $0.backupRetentionDays == 0 } ? .danger : .ok)
                StatCard(label: "Retention under 7 days", value: dbs.filter { $0.backupRetentionDays > 0 && $0.backupRetentionDays < 7 }.count,
                         tone: dbs.contains { $0.backupRetentionDays > 0 && $0.backupRetentionDays < 7 } ? .warn : .ok)
                StatCard(label: "Unencrypted", value: dbs.filter { !$0.encrypted }.count,
                         tone: dbs.contains { !$0.encrypted } ? .warn : .ok)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding([.horizontal, .top], 16)

            HStack(spacing: 12) {
                Toggle("Only accounts that need attention", isOn: $onlyIssues).toggleStyle(.checkbox)
                if !model.fleetLoading.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Reading \(model.fleetLoading.count) account\(model.fleetLoading.count == 1 ? "" : "s")…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Table(shown, sortOrder: $sortOrder) {
                TableColumn("Account", value: \.account.name) { r in
                    HStack(spacing: 8) {
                        AccountAvatar(account: r.account, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(r.account.name).fontWeight(.medium).lineLimit(1)
                                if r.account.readOnly { ReadOnlyBadge(compact: true) }
                            }
                            Text(r.account.profile).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }.width(min: 200, ideal: 260)
                TableColumn("Regions") { r in Text(Fmt.regions(r.account.regions)).lineLimit(1) }.width(min: 90, ideal: 120)
                TableColumn("Status") { r in statusCell(r) }.width(min: 110, ideal: 150)
                TableColumn("Databases", value: \.dbSort) { r in count(r.dbCount, r) }.width(min: 70, ideal: 80)
                TableColumn("Prod") { r in count(r.prod, r) }.width(min: 45, ideal: 50)
                TableColumn("Backups off") { r in count(r.retentionOff, r, tone: .danger) }.width(min: 80, ideal: 85)
                TableColumn("Retention < 7d") { r in count(r.retentionLow, r, tone: .warn) }.width(min: 95, ideal: 100)
                TableColumn("Unencrypted") { r in count(r.unencrypted, r, tone: .warn) }.width(min: 80, ideal: 90)
                TableColumn("") { r in
                    Button("Open") { model.go(accountId: r.account.id, tab: .backupPlans) }
                        .buttonStyle(.borderless)
                }.width(min: 50, ideal: 55)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter accounts")
        .toolbar {
            ToolbarItem {
                Button("Export CSV…", systemImage: "square.and.arrow.up") { export(shown) }
                    .help("Save this table as a CSV file")
            }
        }
        .task { model.loadFleet() }
    }

    @ViewBuilder private func statusCell(_ r: FleetRow) -> some View {
        if r.loading {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Reading…").foregroundStyle(.secondary) }
        } else if r.status?.state == .expired {
            Button("Sign in", systemImage: "person.badge.key") { model.ssoLogin(r.account.id) }.buttonStyle(.borderless)
        } else if let e = r.error {
            Pill(text: "Error", tone: .danger).help(e)
        } else if r.databases != nil {
            Pill(text: "OK", tone: .ok)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func count(_ n: Int?, _ r: FleetRow, tone: Tone = .neutral) -> some View {
        if let n {
            Text("\(n)").monospacedDigit().fontWeight(n > 0 && tone != .neutral ? .semibold : .regular)
                .foregroundStyle(n > 0 && tone != .neutral ? tone.color : .primary)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func export(_ rows: [FleetRow]) {
        let n = { (v: Int?) in v.map(String.init) ?? "" }
        let data = rows.map { r in
            [r.account.name, r.account.profile, r.account.regions.joined(separator: " "), r.account.readOnly ? "yes" : "no",
             r.error ?? (r.databases == nil ? "not read" : "ok"),
             n(r.dbCount), n(r.prod), n(r.retentionOff), n(r.retentionLow), n(r.unencrypted)]
        }
        do {
            if let name = try CSVExport.save(suggestedName: "accounts-backup-health-\(CSVExport.stamp()).csv",
                                             header: ["Account", "Profile", "Regions", "Read-only", "Status", "Databases", "Prod",
                                                      "Automated backups off", "Retention under 7 days", "Unencrypted"],
                                             rows: data) {
                model.toast(.success, "Saved \(name).")
            }
        } catch { model.toast(.error, errorMessage(error)) }
    }
}
