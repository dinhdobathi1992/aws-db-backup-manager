import ADBMCore
import SwiftUI

/// One table row: a database, or an instance inside a cluster.
struct DBRow: Identifiable, Hashable {
    let db: Database
    let member: ClusterMember?
    var id: String { member.map { "\(db.id)|member|\($0.identifier)" } ?? db.id }
}

struct DatabasesView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let databases: [Database]
    @State private var selected: DBRow.ID?
    @State private var showInspector = false
    @State private var search = ""
    @State private var collapsed: Set<Database.ID> = []

    private var filtered: [Database] { databases.filter { Fmt.matches($0, search) } }

    /// The database a row belongs to (a member row resolves to its cluster).
    private func database(for rowId: DBRow.ID?) -> Database? {
        guard let rowId else { return nil }
        return databases.first { rowId == $0.id || rowId.hasPrefix($0.id + "|member|") }
    }

    var body: some View {
        if databases.isEmpty {
            EmptyState(title: "No databases found", systemImage: "cylinder.split.1x2",
                       text: "This account has no RDS or Aurora databases in its configured regions.")
        } else {
            Table(of: DBRow.self, selection: $selected) {
                TableColumn("Database") { row in
                    if let m = row.member {
                        // Instance inside a cluster: a tree line, its role and its name on one line.
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption).foregroundStyle(.tertiary)
                            RoleBadge(isWriter: m.isWriter)
                            Text(m.identifier).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                        .help("\(m.isWriter ? "Writer" : "Reader") instance of \(row.db.identifier)")
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: row.db.kind == .cluster ? "square.stack.3d.up.fill" : "cylinder.fill")
                                .font(.body)
                                .foregroundStyle(row.db.kind == .cluster ? Color.accentColor : Color.secondary)
                                .frame(width: 20)
                                .help(Fmt.kind(row.db.kind))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.db.identifier).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                                HStack(spacing: 6) {
                                    Text(Fmt.kindDetail(row.db)).font(.caption).foregroundStyle(.secondary)
                                    if Fmt.isProd(row.db) { ProdBadge() }
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }.width(min: 240, ideal: 300)
                TableColumn("Engine") { row in
                    // Instances share the cluster's engine; repeating it only adds noise.
                    if row.member == nil { Text("\(Fmt.engine(row.db.engine)) \(row.db.engineVersion)").lineLimit(1) }
                }.width(min: 110, ideal: 160)
                TableColumn("Region / zone") { row in
                    if let m = row.member { Text(m.availabilityZone.isEmpty ? "—" : m.availabilityZone).monospacedDigit() }
                    else { Text(row.db.region) }
                }.width(min: 80, ideal: 105)
                TableColumn("Class") { row in
                    if let m = row.member { Text(m.class.isEmpty ? "—" : m.class) }
                    else { Text(Fmt.dbClass(row.db)).foregroundStyle(row.db.kind == .cluster ? .secondary : .primary) }
                }.width(min: 100, ideal: 130)
                TableColumn("Storage") { row in
                    if row.member == nil {
                        Text(Fmt.storage(row.db)).monospacedDigit()
                            .help(Fmt.storage(row.db) == "Auto" ? "Aurora storage grows automatically" : "")
                    }
                }.width(min: 55, ideal: 60)
                TableColumn("Retention") { row in
                    if row.member == nil { Text("\(row.db.backupRetentionDays)d").monospacedDigit() }
                }.width(min: 55, ideal: 60)
                TableColumn("Status") { row in StatusPill(status: row.member?.status ?? row.db.status) }.width(min: 80, ideal: 90)
                TableColumn("Encryption") { row in
                    if row.member == nil { EncryptedBadge(encrypted: row.db.encrypted) }
                }.width(min: 90, ideal: 95)
                TableColumn("Actions") { row in
                    if row.member == nil {
                        HStack(spacing: 6) {
                            Button("Back up now", systemImage: "camera") { model.open(.snapshot(accountId: account.id, db: row.db)) }
                                .labelStyle(.iconOnly)
                                .writeGuard(account.readOnly, help: "Back up now")
                            Button("Backup plan", systemImage: "checkmark.shield") { model.go(accountId: account.id, tab: .backupPlans, focus: row.db.identifier) }
                                .labelStyle(.iconOnly)
                                .help("Backup plan")
                        }
                        .buttonStyle(.borderless)
                    }
                }.width(min: 60, ideal: 64)
            } rows: {
                ForEach(filtered) { db in
                    if let ms = db.members, !ms.isEmpty {
                        DisclosureTableRow(DBRow(db: db, member: nil), isExpanded: expanded(db.id)) {
                            ForEach(ms) { m in TableRow(DBRow(db: db, member: m)) }
                        }
                    } else {
                        TableRow(DBRow(db: db, member: nil))
                    }
                }
            }
            .contextMenu(forSelectionType: DBRow.ID.self) { ids in
                if let db = database(for: ids.first) {
                    DatabaseActions(account: account, db: db)
                }
            } primaryAction: { ids in
                if let id = ids.first { selected = id; showInspector = true }
            }
            .onChange(of: selected) { _, new in if new != nil { showInspector = true } }
            .inspector(isPresented: $showInspector) {
                if let db = database(for: selected) {
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

    private func expanded(_ id: Database.ID) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(id) },
                set: { open in if open { collapsed.remove(id) } else { collapsed.insert(id) } })
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
            Section(db.kind == .cluster ? "Cluster" : "Instance") {
                LabeledContent("Region", value: db.region)
                LabeledContent("Class", value: Fmt.dbClass(db))
                LabeledContent("Storage", value: Fmt.storage(db))
                LabeledContent("Multi-AZ", value: db.multiAz ? "Yes" : "No")
                LabeledContent("Endpoint") { Text(db.endpoint).textSelection(.enabled).lineLimit(3).multilineTextAlignment(.trailing) }
            }
            if let ms = db.members, !ms.isEmpty {
                Section("Instances (\(ms.count))") {
                    ForEach(ms) { m in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(m.identifier).fontWeight(.medium).textSelection(.enabled)
                                Spacer()
                                StatusPill(status: m.status)
                            }
                            Text([m.isWriter ? "Writer" : "Reader", m.class, m.availabilityZone]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
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
