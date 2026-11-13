import ADBMCore
import SwiftUI

struct SnapshotsView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let databases: [Database]
    @State private var sourceFilter: SnapshotSource? = nil
    @State private var search = ""

    private struct Row: Identifiable { let db: Database; let s: Snapshot; var id: String { s.id } }

    /// Recovery points report "completed"; RDS snapshots report "available".
    static func restorable(_ s: Snapshot) -> Bool {
        s.status == "available" || (s.source == .awsBackup && s.status == "completed")
    }

    var body: some View {
        @Bindable var model = model
        let dbFilter = model.snapshotDbFilter
        let rows = databases
            .filter { dbFilter == nil || $0.identifier == dbFilter }
            .flatMap { db in (model.snapshots(db) ?? []).map { Row(db: db, s: $0) } }
            .filter { sourceFilter == nil || $0.s.source == sourceFilter }
            .filter { search.isEmpty || Fmt.matches($0.db, search) || $0.s.id.lowercased().contains(search.lowercased()) }
            .sorted { (Fmt.parse($0.s.createdAt) ?? .distantPast) > (Fmt.parse($1.s.createdAt) ?? .distantPast) }

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Database", selection: $model.snapshotDbFilter) {
                    Text("All databases").tag(String?.none)
                    Divider()
                    ForEach(databases) { Text($0.identifier).tag(Optional($0.identifier)) }
                }
                .frame(maxWidth: 300)
                Picker("Source", selection: $sourceFilter) {
                    Text("All sources").tag(SnapshotSource?.none)
                    Text("Manual").tag(Optional(SnapshotSource.manual))
                    Text("Automated").tag(Optional(SnapshotSource.automated))
                    Text("AWS Backup").tag(Optional(SnapshotSource.awsBackup))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            if rows.isEmpty {
                EmptyState(title: "No snapshots", systemImage: "camera", text: "Create one from the Databases or Backup plans page.")
            } else {
                Table(rows) {
                    TableColumn("Database") { r in
                        HStack(spacing: 6) { Text(r.s.dbIdentifier); if Fmt.isProd(r.db) { ProdBadge() } }
                    }.width(min: 170, ideal: 180)
                    TableColumn("Snapshot") { r in Text(r.s.id).font(.callout).foregroundStyle(.secondary).help(r.s.arn) }
                        .width(min: 140, ideal: 185)
                    TableColumn("Source") { r in SourceBadge(source: r.s.source) }.width(min: 90, ideal: 100)
                    TableColumn("Status") { r in StatusPill(status: r.s.status) }.width(min: 85, ideal: 95)
                    TableColumn("Created") { r in RelativeTime(value: r.s.createdAt) }.width(min: 60, ideal: 65)
                    TableColumn("Size") { r in Text(Fmt.size(r.s.sizeGb)).monospacedDigit() }.width(min: 55, ideal: 60)
                    TableColumn("Encryption") { r in EncryptedBadge(encrypted: r.s.encrypted) }.width(min: 90, ideal: 95)
                    TableColumn("") { r in
                        Button("Restore…") { model.openRestore(accountId: account.id, db: r.db, snapshot: r.s) }
                            .buttonStyle(.link)
                            .disabled(account.readOnly || !Self.restorable(r.s))
                            .help(account.readOnly ? Fmt.readOnlyHelp : Self.restorable(r.s) ? "Restore into a new database" : "Snapshot is not available yet")
                    }.width(min: 60, ideal: 65)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter snapshots")
    }
}
