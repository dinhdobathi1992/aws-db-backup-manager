import ADBMCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let databases: [Database]

    var body: some View {
        let snapshots = databases.flatMap { model.snapshots($0) ?? [] }
        let unencrypted = databases.filter { !$0.encrypted }.count
        let lowRetention = databases.filter { $0.backupRetentionDays < 7 }.count
        let recent = snapshots.sorted { (Fmt.parse($0.createdAt) ?? .distantPast) > (Fmt.parse($1.createdAt) ?? .distantPast) }.prefix(6)
        let activity = (model.activityByAccount[account.id] ?? []).prefix(6)
        let schedules = model.schedulesByAccount[account.id] ?? []

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatCard(label: "Databases", value: databases.count, sub: Fmt.regions(account.regions))
                    StatCard(label: "Snapshots tracked", value: snapshots.count)
                    StatCard(label: "Unencrypted databases", value: unencrypted, tone: unencrypted > 0 ? .warn : .ok)
                    StatCard(label: "Retention under 7 days", value: lowRetention, tone: lowRetention > 0 ? .warn : .ok)
                }
                .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        Panel("Recent snapshots") {
                            if recent.isEmpty {
                                EmptyState(title: "No snapshots yet", systemImage: "camera", text: "Back up a database to see it here.")
                            } else {
                                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                                    GridRow {
                                        ForEach(["Database", "Source", "Status", "Created"], id: \.self) {
                                            Text($0.uppercased()).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Divider()
                                    ForEach(Array(recent), id: \.id) { s in
                                        GridRow {
                                            Text(s.dbIdentifier)
                                            SourceBadge(source: s.source)
                                            StatusPill(status: s.status)
                                            RelativeTime(value: s.createdAt)
                                        }
                                    }
                                }
                            }
                        }
                        Panel("Recent activity") {
                            if activity.isEmpty {
                                EmptyState(title: "No activity yet", systemImage: "waveform.path.ecg")
                            } else {
                                ForEach(Array(activity.enumerated()), id: \.offset) { _, a in
                                    ActivityRow(activity: a, showMessage: false)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 16) {
                        Panel("Quick actions") {
                            ForEach(databases.prefix(5)) { db in
                                Button { model.open(.snapshot(accountId: account.id, db: db)) } label: {
                                    Label("Back up \(db.identifier)", systemImage: "camera")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .controlSize(.large)
                                .writeGuard(account.readOnly)
                            }
                            Button { model.go(accountId: account.id, tab: .databases) } label: {
                                Label("View all databases", systemImage: "cylinder.split.1x2")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .controlSize(.large)
                        }
                        Panel("Account") {
                            KV(rows: [("AWS profile", account.profile),
                                      ("Regions", Fmt.regions(account.regions)),
                                      ("Scheduled rules", "\(schedules.count)")])
                            if account.readOnly {
                                HStack { ReadOnlyBadge(); Text("Write actions are disabled.").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .frame(width: 300)
                }
            }
            .padding(20)
        }
    }
}

struct ActivityRow: View {
    let activity: Activity
    var showMessage = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusPill(status: activity.status)
            VStack(alignment: .leading, spacing: 2) {
                (Text(activity.db).bold() + Text(" — \(activity.action)"))
                if showMessage, !activity.message.isEmpty {
                    Text(activity.message).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            RelativeTime(value: activity.time).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    let account: Account

    var body: some View {
        let items = model.activityByAccount[account.id] ?? []
        if items.isEmpty {
            EmptyState(title: "No activity yet", systemImage: "waveform.path.ecg")
        } else {
            List(Array(items.enumerated()), id: \.offset) { _, a in
                ActivityRow(activity: a)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}
