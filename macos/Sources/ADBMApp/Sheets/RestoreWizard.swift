// Restore wizard: a port of RestoreWizard in frontend/src/App.tsx.
// Three steps; a restore ALWAYS targets a brand-new identifier, and a
// production database (env tag "prod") needs its identifier typed back
// before "Start restore" enables.
import ADBMCore
import SwiftUI

struct RestoreWizard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountId: String
    let db: Database
    let snapshots: [Snapshot]
    let allIdentifiers: [String]
    let initialSnapshotId: String?

    @State private var step = 1
    @State private var source: RestoreSource = .snapshot
    @State private var snapshotId = ""
    @State private var restoreTime = Date()
    @State private var targetIdentifier = ""
    @State private var instanceClass = ""
    @State private var subnetGroup = ""
    @State private var securityGroups = ""
    @State private var publiclyAccessible = false
    @State private var confirmText = ""
    @State private var saving = false
    @State private var error: String?

    private var snapshotChoices: [Snapshot] { snapshots.filter { $0.source != .awsBackup } }
    private var recoveryPointChoices: [Snapshot] { snapshots.filter { $0.source == .awsBackup } }
    private var selectedSnapshot: Snapshot? { snapshots.first { $0.id == snapshotId } }
    private var prod: Bool { Fmt.isProd(db) }
    private var latestRestorable: Date? { Fmt.parse(db.latestRestorableTime) }
    private var earliestRestorable: Date? { Fmt.parse(model.plan(db)?.automated.earliest) }
    private var trimmedTarget: String { targetIdentifier.trimmingCharacters(in: .whitespaces) }

    private var step1Valid: Bool {
        switch source {
        case .snapshot: snapshotChoices.contains { $0.id == snapshotId }
        case .recoveryPoint: recoveryPointChoices.contains { $0.id == snapshotId }
        case .pitr: latestRestorable != nil
        }
    }

    private var step2Error: String? {
        if trimmedTarget.isEmpty { return "A target database identifier is required." }
        if trimmedTarget == db.identifier {
            return "The restore target must be a new identifier — it cannot overwrite the source database."
        }
        if Set(allIdentifiers).contains(trimmedTarget) { return "That identifier is already in use. Choose a different one." }
        return nil
    }

    private var step3Ready: Bool { !prod || confirmText.trimmingCharacters(in: .whitespaces) == db.identifier }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form { stepBody }
                .formStyle(.grouped)
            Divider()
            footer.padding(14)
        }
        .frame(width: 620, height: 560)
        .onAppear(perform: setup)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore \(db.identifier)").font(.title3.weight(.semibold))
            HStack(spacing: 18) {
                ForEach(Array(["Source", "Target settings", "Review"].enumerated()), id: \.offset) { i, label in
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(step == i + 1 ? Color.accentColor : step > i + 1 ? Color.green : Color.secondary.opacity(0.3))
                                .frame(width: 20, height: 20)
                            if step > i + 1 { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) }
                            else { Text("\(i + 1)").font(.caption.bold()).foregroundStyle(.white) }
                        }
                        Text(label).foregroundStyle(step == i + 1 ? .primary : .secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .top], 18)
    }

    @ViewBuilder private var stepBody: some View {
        switch step {
        case 1:
            Section {
                Text("Restoring always creates a brand-new database — **\(db.identifier)** itself is never changed.")
                    .foregroundStyle(.secondary)
                Picker("Restore from", selection: $source) {
                    if !snapshotChoices.isEmpty { Text("A snapshot").tag(RestoreSource.snapshot) }
                    Text("Point in time").tag(RestoreSource.pitr)
                    if !recoveryPointChoices.isEmpty { Text("AWS Backup recovery point").tag(RestoreSource.recoveryPoint) }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: source) { _, s in
                    if s == .snapshot, !snapshotChoices.contains(where: { $0.id == snapshotId }) { snapshotId = snapshotChoices.first?.id ?? "" }
                    if s == .recoveryPoint, !recoveryPointChoices.contains(where: { $0.id == snapshotId }) { snapshotId = recoveryPointChoices.first?.id ?? "" }
                }
            }
            Section {
                switch source {
                case .snapshot:
                    Picker("Snapshot", selection: $snapshotId) {
                        ForEach(snapshotChoices) { s in
                            Text("\(s.id) — \(Fmt.source(s.source)) — \(Fmt.full(s.createdAt))").tag(s.id)
                        }
                    }
                case .recoveryPoint:
                    Picker("Recovery point", selection: $snapshotId) {
                        ForEach(recoveryPointChoices) { s in
                            Text("\(s.id) — \(Fmt.full(s.createdAt)) (\(s.vaultName ?? "—"))").tag(s.id)
                        }
                    }
                case .pitr:
                    if let latest = latestRestorable {
                        DatePicker("Restore to", selection: $restoreTime,
                                   in: (earliestRestorable ?? .distantPast)...latest)
                    }
                    LabeledContent("Latest restorable time",
                                   value: db.latestRestorableTime == nil ? "unavailable" : Fmt.full(db.latestRestorableTime))
                }
            }
        case 2:
            Section {
                TextField("New database identifier", text: $targetIdentifier)
                TextField("Instance class", text: $instanceClass)
                TextField("Subnet group (optional)", text: $subnetGroup)
                TextField("Security groups (optional, comma-separated)", text: $securityGroups)
                Toggle("Publicly accessible", isOn: $publiclyAccessible)
            }
            if let e = step2Error, !trimmedTarget.isEmpty {
                Section { InlineError(message: e) }
            }
        default:
            Section("Review") {
                LabeledContent("Source database", value: db.identifier)
                LabeledContent("Restore source",
                               value: source == .pitr ? "Point in time — \(restoreTime.formatted(date: .abbreviated, time: .shortened))"
                                                      : (selectedSnapshot?.id ?? "—"))
                LabeledContent("New database identifier", value: trimmedTarget)
                LabeledContent("Instance class", value: instanceClass.isEmpty ? "—" : instanceClass)
                LabeledContent("Publicly accessible", value: publiclyAccessible ? "Yes" : "No")
            }
            if prod {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
                        Text("This is a production database. Type **\(db.identifier)** to confirm the restore.")
                    }
                    TextField("Confirmation", text: $confirmText, prompt: Text(db.identifier))
                        .labelsHidden()
                }
            }
            if let error { Section { InlineError(message: error) } }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if step == 1 {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Next") { step = 2 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!step1Valid)
            } else if step == 2 {
                Button("Back") { step = 1 }
                Button("Next") { step = 3 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(step2Error != nil)
            } else {
                Button("Back") { step = 2 }
                Button(saving ? "Starting restore…" : "Start restore", action: submit)
                    .buttonStyle(.borderedProminent)
                    .tint(prod ? .red : .accentColor)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!step3Ready || saving || step2Error != nil)
            }
        }
    }

    private func setup() {
        source = snapshotChoices.isEmpty ? (recoveryPointChoices.isEmpty ? .pitr : .recoveryPoint) : .snapshot
        if let initial = initialSnapshotId, let s = snapshots.first(where: { $0.id == initial }) {
            snapshotId = s.id
            source = s.source == .awsBackup ? .recoveryPoint : .snapshot
        } else {
            snapshotId = (source == .recoveryPoint ? recoveryPointChoices : snapshotChoices).first?.id ?? ""
        }
        restoreTime = latestRestorable ?? Date()
        targetIdentifier = "\(db.identifier)-restored"
        // A provisioned Aurora cluster has no class of its own; start from its writer's.
        let writer = db.members?.first(where: \.isWriter) ?? db.members?.first
        instanceClass = db.class.isEmpty ? (writer?.class ?? "") : db.class
    }

    private func submit() {
        guard step2Error == nil, step3Ready else { return }
        error = nil; saving = true
        let groups = securityGroups.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let ic = instanceClass.trimmingCharacters(in: .whitespaces), sg = subnetGroup.trimmingCharacters(in: .whitespaces)
        let req = RestoreReq(accountId: accountId, region: db.region, kind: db.kind, source: source,
                             sourceDbIdentifier: db.identifier,
                             snapshotId: source != .pitr ? snapshotId : nil,
                             recoveryPointArn: source == .recoveryPoint ? selectedSnapshot?.arn : nil,
                             restoreTime: source == .pitr ? RFC3339.string(restoreTime) : nil,
                             targetIdentifier: trimmedTarget,
                             instanceClass: ic.isEmpty ? nil : ic,
                             subnetGroup: sg.isEmpty ? nil : sg,
                             securityGroups: groups,
                             publiclyAccessible: publiclyAccessible)
        Task {
            do {
                let activity = try await model.service.restore(req)
                model.toast(.success, "Restore started: \(activity.action)")
                model.dataChanged(accountId, db.identifier)
                dismiss()
            } catch { self.error = errorMessage(error) }
            saving = false
        }
    }
}
