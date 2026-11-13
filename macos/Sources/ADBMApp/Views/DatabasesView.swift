import ADBMCore
import SwiftUI

struct DatabasesView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let databases: [Database]
    @State private var selected: Database.ID?
    @State private var showInspector = false
    @State private var search = ""

    var body: some View {
        if databases.isEmpty {
            EmptyState(title: "No databases found", systemImage: "cylinder.split.1x2",
                       text: "This account has no RDS or Aurora databases in its configured regions.")
        } else {
            Table(databases.filter { Fmt.matches($0, search) }, selection: $selected) {
                TableColumn("Database") { db in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(db.identifier).fontWeight(.medium)
                        HStack(spacing: 4) {
                            Text(Fmt.kind(db.kind)).font(.caption).foregroundStyle(.secondary)
                            if Fmt.isProd(db) { ProdBadge() }
                        }
                    }
                }.width(min: 160, ideal: 190)
                TableColumn("Engine") { db in Text("\(Fmt.engine(db.engine)) \(db.engineVersion)") }.width(min: 110, ideal: 145)
                TableColumn("Region", value: \.region).width(min: 65, ideal: 75)
                TableColumn("Class", value: \.class).width(min: 85, ideal: 95)
                TableColumn("Storage") { db in Text(Fmt.size(db.storageGb)).monospacedDigit() }.width(min: 55, ideal: 60)
                TableColumn("Retention") { db in Text("\(db.backupRetentionDays)d").monospacedDigit() }.width(min: 55, ideal: 60)
                TableColumn("Status") { db in StatusPill(status: db.status) }.width(min: 80, ideal: 90)
                TableColumn("Encryption") { db in EncryptedBadge(encrypted: db.encrypted) }.width(min: 90, ideal: 95)
                TableColumn("Actions") { db in
                    HStack(spacing: 6) {
                        Button("Back up now", systemImage: "camera") { model.open(.snapshot(accountId: account.id, db: db)) }
                            .labelStyle(.iconOnly)
                            .writeGuard(account.readOnly, help: "Back up now")
                        Button("Backup plan", systemImage: "checkmark.shield") { model.go(accountId: account.id, tab: .backupPlans, focus: db.identifier) }
                            .labelStyle(.iconOnly)
                            .help("Backup plan")
                    }
                    .buttonStyle(.borderless)
                }.width(min: 60, ideal: 64)
            }
            .contextMenu(forSelectionType: Database.ID.self) { ids in
                if let db = databases.first(where: { ids.contains($0.id) }) {
                    DatabaseActions(account: account, db: db)
                }
            } primaryAction: { ids in
                if let id = ids.first { selected = id; showInspector = true }
            }
            .onChange(of: selected) { _, new in if new != nil { showInspector = true } }
            .inspector(isPresented: $showInspector) {
                if let db = databases.first(where: { $0.id == selected }) {
                    DatabaseInspector(account: account, db: db)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                } else {
                    EmptyState(title: "No selection", systemImage: "sidebar.right", text: "Select a database to see its details.")
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Filter databases")
            .toolbar {
                ToolbarItem {
                    Button("Details", systemImage: "sidebar.right") { showInspector.toggle() }
                        .help("Show database details")
                }
            }
        }
    }
}

/// Actions for one database, used in menus.
struct DatabaseActions: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let db: Database

    var body: some View {
        Button("Back up now…", systemImage: "camera") { model.open(.snapshot(accountId: account.id, db: db)) }
            .writeGuard(account.readOnly)
        Button("Start AWS Backup job…", systemImage: "checkmark.shield") {
            model.open(.backupJob(accountId: account.id, db: db, plan: model.plan(db)))
        }.writeGuard(account.readOnly)
        Button("Restore into a new database…", systemImage: "arrow.uturn.backward.circle") {
            model.openRestore(accountId: account.id, db: db, snapshot: nil)
        }.writeGuard(account.readOnly)
        Divider()
        Button("Backup plan", systemImage: "checkmark.shield") { model.go(accountId: account.id, tab: .backupPlans, focus: db.identifier) }
        Button("Snapshots", systemImage: "camera") {
            model.snapshotDbFilter = db.identifier
            model.go(accountId: account.id, tab: .snapshots)
        }
    }
}

struct DatabaseInspector: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let db: Database

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(db.identifier).font(.title3.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text("\(Fmt.kind(db.kind)) · \(Fmt.engine(db.engine)) \(db.engineVersion)").foregroundStyle(.secondary)
                        if Fmt.isProd(db) { ProdBadge() }
                    }
                    HStack { StatusPill(status: db.status); EncryptedBadge(encrypted: db.encrypted) }
                }
            }
            Section("Instance") {
                LabeledContent("Region", value: db.region)
                LabeledContent("Class", value: db.class)
                LabeledContent("Storage", value: Fmt.size(db.storageGb))
                LabeledContent("Multi-AZ", value: db.multiAz ? "Yes" : "No")
                LabeledContent("Endpoint") { Text(db.endpoint).textSelection(.enabled).lineLimit(3).multilineTextAlignment(.trailing) }
            }
            Section("Backups") {
                LabeledContent("Retention", value: "\(db.backupRetentionDays) days")
                LabeledContent("Backup window", value: db.preferredBackupWindow.isEmpty ? "—" : "\(db.preferredBackupWindow) UTC")
                LabeledContent("Latest restorable") { RelativeTime(value: db.latestRestorableTime) }
                LabeledContent("Snapshots", value: "\(model.snapshots(db)?.count ?? 0)")
            }
            if let tags = db.tags, !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags.keys.sorted(), id: \.self) { k in LabeledContent(k, value: tags[k] ?? "") }
                }
            }
            Section {
                Button("Back up now…", systemImage: "camera") { model.open(.snapshot(accountId: account.id, db: db)) }
                    .writeGuard(account.readOnly)
                Button("Restore into a new database…", systemImage: "arrow.uturn.backward.circle") {
                    model.openRestore(accountId: account.id, db: db, snapshot: nil)
                }.writeGuard(account.readOnly)
                Button("Backup plan", systemImage: "checkmark.shield") { model.go(accountId: account.id, tab: .backupPlans, focus: db.identifier) }
            }
        }
        .formStyle(.grouped)
    }
}
