import ADBMCore
import SwiftUI

struct BackupPlansView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let databases: [Database]
    @State private var highlighted: String?
    @State private var search = ""
    @State private var onlyIssues = false

    /// A card needs attention when it has no manual snapshot, keeps
    /// automated backups under 7 days, or no AWS Backup plan covers it.
    static func needsAttention(_ db: Database, _ plan: BackupPlanSummary?) -> Bool {
        guard let plan else { return db.backupRetentionDays < 7 }
        return plan.manual.count == 0 || plan.automated.retention < 7 || plan.awsBackup.isEmpty
    }

    private func focus(_ proxy: ScrollViewProxy) {
        guard let id = model.focusDb, databases.contains(where: { $0.identifier == id }) else { return }
        model.focusDb = nil
        highlighted = id
        withAnimation { proxy.scrollTo(id, anchor: .top) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if highlighted == id { highlighted = nil } }
        }
    }

    var body: some View {
        let shown = databases.filter {
            Fmt.matches($0, search) && (!onlyIssues || Self.needsAttention($0, model.plan($0)) || $0.identifier == model.focusDb)
        }
        if databases.isEmpty {
            EmptyState(title: "No databases to back up", systemImage: "checkmark.shield")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(spacing: 12) {
                        Toggle("Only databases that need attention", isOn: $onlyIssues).toggleStyle(.checkbox)
                            .help("No manual snapshot, retention under 7 days, or no AWS Backup plan")
                        Spacer()
                        Text("\(shown.count) of \(databases.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 20).padding(.top, 14)
                    if shown.isEmpty {
                        EmptyState(title: "Nothing matches", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    LazyVStack(spacing: 16) {
                        ForEach(shown) { db in
                            PlanCard(account: account, db: db, plan: model.plan(db))
                                .overlay {
                                    if highlighted == db.identifier {
                                        RoundedRectangle(cornerRadius: 14).strokeBorder(.tint, lineWidth: 2)
                                    }
                                }
                                .id(db.identifier)
                        }
                    }
                    .padding(20)
                }
                .onAppear { focus(proxy) }
                .onChange(of: model.focusDb) { focus(proxy) }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Filter databases")
            .toolbar {
                ToolbarItem {
                    Button("Export CSV…", systemImage: "square.and.arrow.up") { export(shown) }
                        .help("Save these backup plans as a CSV file")
                }
            }
        }
    }

    private func export(_ dbs: [Database]) {
        let rows = dbs.map { db -> [String] in
            let p = model.plan(db)
            return [db.identifier, Fmt.kind(db.kind), "\(Fmt.engine(db.engine)) \(db.engineVersion)", db.region,
                    Fmt.isProd(db) ? "yes" : "no", db.encrypted ? "yes" : "no",
                    "\(db.backupRetentionDays)", db.preferredBackupWindow,
                    p.map { "\($0.manual.count)" } ?? "", p?.manual.latest ?? "",
                    p?.automated.earliest ?? "", p?.automated.latest ?? db.latestRestorableTime ?? "",
                    p.map { $0.awsBackup.map { "\($0.planName)/\($0.ruleName) \($0.cron) \($0.lifecycle) → \($0.vault)" }.joined(separator: "; ") } ?? "",
                    Self.needsAttention(db, p) ? "yes" : "no"]
        }
        do {
            if let name = try CSVExport.save(
                suggestedName: "\(Fmt.slugify(account.name))-backup-plans-\(CSVExport.stamp()).csv",
                header: ["Database", "Kind", "Engine", "Region", "Prod", "Encrypted", "Retention days", "Backup window (UTC)",
                         "Manual snapshots", "Latest manual", "Earliest restore", "Latest restore", "AWS Backup rules", "Needs attention"],
                rows: rows) {
                model.toast(.success, "Saved \(name).")
            }
        } catch { model.toast(.error, errorMessage(error)) }
    }
}

struct PlanCard: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let db: Database
    let plan: BackupPlanSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 12) { manual; automated }
                .fixedSize(horizontal: false, vertical: true)
            awsBackup
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(cornerRadius: 14)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: db.kind == .cluster ? "server.rack" : "cylinder.split.1x2")
                .font(.title2).foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(db.identifier).font(.title3.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text("\(Fmt.kind(db.kind)) · \(Fmt.engine(db.engine)) · \(db.region)")
                        .font(.callout).foregroundStyle(.secondary)
                    if Fmt.isProd(db) { ProdBadge() }
                }
            }
            Spacer(minLength: 12)
            ViewThatFits(in: .horizontal) {
                actions(labels: true)
                actions(labels: false)
            }
        }
    }

    private func actions(labels: Bool) -> some View {
        HStack(spacing: 8) {
            actionButton("Snapshot now", "camera") { model.open(.snapshot(accountId: account.id, db: db)) }
            actionButton("Start AWS Backup job", "checkmark.shield") {
                model.open(.backupJob(accountId: account.id, db: db, plan: plan))
            }
            actionButton("Add backup plan", "plus") {
                model.open(.backupPlan(accountId: account.id, db: db, plan: plan))
            }
        }
        .controlSize(.large)
        .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
    }

    private func actionButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: action)
            .buttonStyle(.bordered)
            .writeGuard(account.readOnly, help: title)
    }

    // MARK: Columns

    private var manual: some View {
        Section3(title: "Manual snapshots", icon: "camera") {
            if let plan {
                Metric("Snapshots", "\(plan.manual.count)", tone: plan.manual.count == 0 ? .warn : .neutral)
                Metric("Latest", Fmt.ago(plan.manual.latest))
            } else { loading }
        }
    }

    private var automated: some View {
        Section3(title: "Automated backups", icon: "clock.arrow.circlepath") {
            if let plan {
                let r = plan.automated.retention
                Metric("Window", plan.automated.window.isEmpty ? "—" : plan.automated.window, mono: true)
                Metric("Retention", r == 0 ? "Off (0 days)" : r == 1 ? "1 day" : "\(r) days",
                       tone: r == 0 ? .danger : r < 7 ? .warn : .ok)
                Metric("Earliest restore", Fmt.ago(plan.automated.earliest))
                Metric("Latest restore", Fmt.ago(plan.automated.latest))
            } else { loading }
            Button("Change window / raise retention", systemImage: "slider.horizontal.3") {
                model.open(.automatedBackup(accountId: account.id, db: db))
            }
            .buttonStyle(.link)
            .padding(.top, 2)
            .writeGuard(account.readOnly)
        }
    }

    private var awsBackup: some View {
        Section3(title: "AWS Backup", icon: "checkmark.shield") {
            if let plan, !plan.awsBackup.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        ForEach(["Plan", "Rule", "Schedule", "Lifecycle", "Vault"], id: \.self) {
                            Text($0).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(plan.awsBackup, id: \.self) { r in
                        GridRow {
                            Text(r.planName).fontWeight(.medium)
                            Text(r.ruleName)
                            Text(r.cron).font(.body.monospaced())
                            Text(r.lifecycle)
                            Text(r.vault)
                        }
                        .lineLimit(1)
                    }
                }
                .textSelection(.enabled)
            } else if plan != nil {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No AWS Backup plan").font(.body.weight(.semibold))
                        Text("Add one to back this database up through AWS Backup.").foregroundStyle(.secondary)
                    }
                }
            } else { loading }
        }
    }

    private var loading: some View { ProgressView().controlSize(.small) }
}

/// A titled block inside a plan card, on a slightly raised background.
private struct Section3<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// One label/value line, value right-aligned and coloured when it needs attention.
private struct Metric: View {
    let label: String
    let value: String
    var tone: Tone = .neutral
    var mono = false

    init(_ label: String, _ value: String, tone: Tone = .neutral, mono: Bool = false) {
        self.label = label; self.value = value; self.tone = tone; self.mono = mono
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                if tone == .warn || tone == .danger { Image(systemName: tone.symbol).font(.caption) }
                Text(value).font(mono ? .body.monospacedDigit().weight(.medium) : .body.weight(.medium)).monospacedDigit()
            }
            .foregroundStyle(tone == .neutral || tone == .ok ? Color.primary : tone.color)
            .textSelection(.enabled)
        }
        .font(.body)
    }
}

struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(Label($0).labelStyle(style)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let databases: [Database]

    private struct Row: Identifiable { let id: Int; let s: Schedule }

    var body: some View {
        let rows = (model.schedulesByAccount[account.id] ?? []).enumerated().map { Row(id: $0.offset, s: $0.element) }
        let prodIds = Set(databases.filter(Fmt.isProd).map(\.identifier))
        if rows.isEmpty {
            EmptyState(title: "No schedules", systemImage: "clock",
                       text: "Automated backup windows and AWS Backup rules will appear here.")
        } else {
            Table(rows) {
                TableColumn("Source") { r in
                    Pill(text: Fmt.scheduleSource(r.s.source), tone: r.s.source == .awsBackupRule ? .ok : .info)
                }.width(min: 140, ideal: 160)
                TableColumn("Database") { r in
                    HStack(spacing: 6) { Text(r.s.db); if prodIds.contains(r.s.db) { ProdBadge() } }
                }.width(min: 200, ideal: 260)
                TableColumn("Schedule") { r in Text(r.s.expression).font(.body.monospaced()) }
                TableColumn("Next run") { r in RelativeTime(value: r.s.nextRun) }.width(min: 80, ideal: 100)
                TableColumn("Retention") { r in Text("\(r.s.retention)d").monospacedDigit() }.width(min: 70, ideal: 80)
            }
        }
    }
}
