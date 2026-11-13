// Action sheets: ports of AccountForm, SnapshotForm, BackupJobForm,
// BackupPlanForm and AutomatedBackupForm in frontend/src/App.tsx.
import ADBMCore
import SwiftUI

struct SheetRouter: View {
    let sheet: ActiveSheet

    var body: some View {
        switch sheet {
        case .account(let a): AccountSheet(initial: a)
        case .snapshot(let id, let db): SnapshotSheet(accountId: id, db: db)
        case .backupJob(let id, let db, let plan): BackupJobSheet(accountId: id, db: db, plan: plan)
        case .backupPlan(let id, let db, let plan): BackupPlanSheet(accountId: id, db: db, plan: plan)
        case .automatedBackup(let id, let db): AutomatedBackupSheet(accountId: id, db: db)
        case .restore(let id, let db, let snaps, let ids, let initial):
            RestoreWizard(accountId: id, db: db, snapshots: snaps, allIdentifiers: ids, initialSnapshotId: initial)
        }
    }
}

/// Common sheet chrome: title, form body, inline error, Cancel + primary button.
struct SheetScaffold<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let primary: String
    let busyLabel: String
    var busy: Bool
    var canSubmit: Bool = true
    var error: String?
    var width: CGFloat = 480
    let submit: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Form {
                content()
                if let error {
                    Section { InlineError(message: error) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(false)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? busyLabel : primary, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !canSubmit)
            }
            .padding(14)
        }
        .frame(width: width)
        .frame(minHeight: 200)
        .navigationTitle(title)
        .safeAreaInset(edge: .top) {
            Text(title).font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 18)
        }
    }
}

// MARK: Account

struct AccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initial: Account?

    @State private var name = ""
    @State private var profile = ""
    @State private var regions: [String] = []
    @State private var color = ""
    @State private var readOnly = false
    @State private var saving = false
    @State private var error: String?
    @State private var profiles: [AWSProfile] = []
    @State private var customProfile = false

    private static let otherTag = "\u{1}other"

    var body: some View {
        SheetScaffold(title: initial == nil ? "Add account" : "Edit account", primary: "Save account", busyLabel: "Saving…",
                      busy: saving, error: error, width: 540, submit: save) {
            Section {
                TextField("Display name", text: $name, prompt: Text("Production"))
                profileField
                regionField
                LabeledContent("Colour") {
                    HStack(spacing: 8) {
                        ForEach(Fmt.accountPalette, id: \.self) { c in
                            Button { color = c } label: {
                                Circle().fill(Color(hex: c)).frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: color == c ? 2 : 0).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(c)
                        }
                        Button("Auto") { color = "" }
                            .buttonStyle(.bordered).controlSize(.small)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary, lineWidth: color.isEmpty ? 1.5 : 0))
                    }
                }
            }
            Section {
                Toggle("Read-only — disable backups, plans and restores for this account", isOn: $readOnly)
                if readOnly {
                    Text("Write actions will be refused by the app and the backend for this account, even if the AWS profile allows them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            profiles = AWSProfiles.load()
            if let a = initial {
                name = a.name; profile = a.profile; regions = a.regions
                color = a.color; readOnly = a.readOnly
                customProfile = !a.profile.isEmpty && !profiles.contains { $0.name == a.profile }
            } else if profiles.isEmpty {
                customProfile = true
            }
        }
    }

    @ViewBuilder private var profileField: some View {
        let selection = Binding<String>(
            get: { customProfile ? Self.otherTag : profile },
            set: { v in
                if v == Self.otherTag { customProfile = true; profile = "" } else { customProfile = false; pickProfile(v) }
            })
        Picker("AWS profile", selection: selection) {
            if profile.isEmpty && !customProfile { Text("Choose a profile…").tag("") }
            ForEach(profiles) { p in
                Text(profileLabel(p)).tag(p.name)
            }
            Divider()
            Text("Other (type a name)…").tag(Self.otherTag)
        }
        .pickerStyle(.menu)
        if customProfile {
            TextField("Profile name", text: $profile, prompt: Text("prod"))
        }
        if profiles.isEmpty {
            Text("No profiles found in ~/.aws/config. Run `aws configure` or `aws configure sso` first, or type a name.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func profileLabel(_ p: AWSProfile) -> String {
        var parts = [p.name]
        if let acct = p.ssoAccountId { parts.append(acct) }
        if let r = p.region { parts.append(r) }
        return parts.count == 1 ? p.name : "\(p.name)  —  \(parts.dropFirst().joined(separator: " · "))"
    }

    /// Picking a profile fills in its region and a display name when those are still blank.
    private func pickProfile(_ name: String) {
        profile = name
        guard let p = profiles.first(where: { $0.name == name }) else { return }
        if regions.isEmpty, let r = p.region { regions = [r] }
        if self.name.trimmingCharacters(in: .whitespaces).isEmpty { self.name = name }
    }

    @ViewBuilder private var regionField: some View {
        LabeledContent("Regions") {
            Menu {
                let used = Set(regions)
                if let r = profiles.first(where: { $0.name == profile })?.region {
                    Section("From profile") { regionToggle(r, on: used.contains(r)) }
                }
                Section("All regions") {
                    ForEach(AWSRegions.all, id: \.code) { r in regionToggle(r.code, on: used.contains(r.code)) }
                }
            } label: {
                Text(regions.isEmpty ? "Choose regions…" : regions.joined(separator: ", "))
                    .lineLimit(1).truncationMode(.tail)
            }
            .menuStyle(.button)
            .fixedSize()
        }
        if !regions.isEmpty {
            HStack(spacing: 6) {
                ForEach(regions, id: \.self) { r in
                    HStack(spacing: 4) {
                        Text(r).font(.callout.monospaced())
                        Button { regions.removeAll { $0 == r } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Remove \(AWSRegions.name(r) ?? r)")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
                }
                Spacer()
            }
        }
    }

    private func regionToggle(_ code: String, on: Bool) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { v in
            if v { if !regions.contains(code) { regions.append(code) } } else { regions.removeAll { $0 == code } }
        })) {
            Text(AWSRegions.name(code).map { "\(code) — \($0)" } ?? code)
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces), p = profile.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !p.isEmpty, !regions.isEmpty else {
            error = "Name, AWS profile, and at least one region are required."
            return
        }
        error = nil; saving = true
        let id = initial?.id ?? Fmt.uniqueId(Fmt.slugify(n), taken: Set((model.accounts ?? []).map(\.id)))
        let account = Account(id: id, name: n, profile: p, regions: regions, color: color, readOnly: readOnly)
        Task {
            do { try await model.saveAccount(account); dismiss() } catch { self.error = errorMessage(error) }
            saving = false
        }
    }
}

// MARK: Snapshot

struct SnapshotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountId: String
    let db: Database
    @State private var snapshotName = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        SheetScaffold(title: "Back up \(db.identifier)", primary: "Create snapshot", busyLabel: "Starting…",
                      busy: saving, error: error, submit: submit) {
            Section {
                Text("Creates a manual snapshot of **\(db.identifier)** (\(Fmt.kind(db.kind))) in \(db.region).")
                    .foregroundStyle(.secondary)
                TextField("Snapshot name", text: $snapshotName)
            }
        }
        .onAppear { if snapshotName.isEmpty { snapshotName = Fmt.suggestSnapshotName(db.identifier) } }
    }

    private func submit() {
        let n = snapshotName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { error = "Snapshot name is required."; return }
        error = nil; saving = true
        Task {
            do {
                _ = try await model.service.createSnapshot(CreateSnapshotReq(accountId: accountId, region: db.region, kind: db.kind,
                                                                            dbIdentifier: db.identifier, snapshotName: n))
                model.toast(.success, "Snapshot “\(n)” is being created.")
                model.dataChanged(accountId, db.identifier)
                dismiss()
            } catch { self.error = errorMessage(error) }
            saving = false
        }
    }
}

// MARK: AWS Backup job

struct BackupJobSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountId: String
    let db: Database
    let plan: BackupPlanSummary?
    @State private var vaultName = ""
    @State private var iamRoleArn = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        SheetScaffold(title: "Start AWS Backup job for \(db.identifier)", primary: "Start backup job", busyLabel: "Starting…",
                      busy: saving, error: error, submit: submit) {
            Section {
                Text("Starts an on-demand AWS Backup job for **\(db.identifier)**.").foregroundStyle(.secondary)
                TextField("Backup vault", text: $vaultName)
                TextField("IAM role ARN", text: $iamRoleArn, prompt: Text("arn:aws:iam::123456789012:role/AWSBackupRole"))
            }
        }
        .onAppear { if vaultName.isEmpty { vaultName = plan?.awsBackup.first?.vault ?? "default" } }
    }

    private func submit() {
        let v = vaultName.trimmingCharacters(in: .whitespaces), r = iamRoleArn.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !r.isEmpty else { error = "Vault name and IAM role ARN are required."; return }
        error = nil; saving = true
        Task {
            do {
                _ = try await model.service.startBackupJob(StartBackupJobReq(accountId: accountId, region: db.region, kind: db.kind,
                                                                            dbIdentifier: db.identifier, vaultName: v, iamRoleArn: r))
                model.toast(.success, "AWS Backup job started.")
                model.dataChanged(accountId, db.identifier)
                dismiss()
            } catch { self.error = errorMessage(error) }
            saving = false
        }
    }
}

// MARK: AWS Backup plan

struct BackupPlanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountId: String
    let db: Database
    let plan: BackupPlanSummary?
    @State private var planName = ""
    @State private var ruleName = "daily-3am"
    @State private var cron = "cron(0 3 * * ? *)"
    @State private var vaultName = ""
    @State private var retentionDays = Fmt.minAWSBackupRetentionDays
    @State private var iamRoleArn = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        SheetScaffold(title: "Add a backup plan for \(db.identifier)", primary: "Create plan", busyLabel: "Creating…",
                      busy: saving, error: error, submit: submit) {
            Section {
                Text("Creates an AWS Backup plan and rule covering **\(db.identifier)**.").foregroundStyle(.secondary)
                TextField("Plan name", text: $planName)
                TextField("Rule name", text: $ruleName)
                TextField("Schedule (cron)", text: $cron).font(.body.monospaced())
                TextField("Backup vault", text: $vaultName)
                Stepper(value: $retentionDays, in: Fmt.minAWSBackupRetentionDays...36500) {
                    LabeledContent("Retention (days)") {
                        TextField("", value: $retentionDays, format: .number).labelsHidden().frame(width: 70).multilineTextAlignment(.trailing)
                    }
                }
                Text("AWS Backup plans must keep recovery points for at least \(Fmt.minAWSBackupRetentionDays) days.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("IAM role ARN", text: $iamRoleArn, prompt: Text("arn:aws:iam::123456789012:role/AWSBackupRole"))
            }
        }
        .onAppear {
            if planName.isEmpty { planName = "\(db.identifier)-plan" }
            if vaultName.isEmpty { vaultName = plan?.awsBackup.first?.vault ?? "default" }
        }
    }

    private func submit() {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        guard ![planName, ruleName, cron, vaultName, iamRoleArn].map(t).contains(where: \.isEmpty) else {
            error = "All fields are required."; return
        }
        guard retentionDays >= Fmt.minAWSBackupRetentionDays else {
            error = "Retention must be at least \(Fmt.minAWSBackupRetentionDays) days."; return
        }
        error = nil; saving = true
        let req = CreateBackupPlanReq(accountId: accountId, region: db.region, kind: db.kind, dbIdentifier: db.identifier,
                                      planName: t(planName), ruleName: t(ruleName), cron: t(cron), vaultName: t(vaultName),
                                      retentionDays: retentionDays, iamRoleArn: t(iamRoleArn))
        Task {
            do {
                _ = try await model.service.createBackupPlan(req)
                model.toast(.success, "Backup plan “\(req.planName)” created.")
                model.dataChanged(accountId, db.identifier)
                dismiss()
            } catch { self.error = errorMessage(error) }
            saving = false
        }
    }
}

// MARK: Automated backups

struct AutomatedBackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountId: String
    let db: Database
    @State private var window = ""
    @State private var retentionDays = 1
    @State private var saving = false
    @State private var error: String?

    /// Retention can only be raised, and never below 1 (same rule as v0.1).
    private var minRetention: Int { max(Fmt.minAutomatedRetentionDays, db.backupRetentionDays) }

    var body: some View {
        SheetScaffold(title: "Automated backups for \(db.identifier)", primary: "Save", busyLabel: "Saving…",
                      busy: saving, error: error, submit: submit) {
            Section {
                Text("Current retention is **\(db.backupRetentionDays) days**. It can be raised, but — to protect your data — never lowered or disabled from this app.")
                    .foregroundStyle(.secondary)
                TextField("Preferred backup window (UTC)", text: $window, prompt: Text("03:00-03:30"))
                Stepper(value: $retentionDays, in: minRetention...max(35, minRetention)) {
                    LabeledContent("Retention (days)") { Text("\(retentionDays)").monospacedDigit() }
                }
            }
        }
        .onAppear {
            window = db.preferredBackupWindow
            retentionDays = minRetention
        }
    }

    private func submit() {
        guard retentionDays >= minRetention else {
            error = "Retention can only be raised — it is currently \(db.backupRetentionDays) days and can never be lowered."
            return
        }
        error = nil; saving = true
        let w = window.trimmingCharacters(in: .whitespaces)
        let req = ModifyAutomatedBackupReq(accountId: accountId, region: db.region, kind: db.kind, dbIdentifier: db.identifier,
                                           window: w.isEmpty ? nil : w, retentionDays: retentionDays)
        Task {
            do {
                _ = try await model.service.modifyAutomatedBackup(req)
                model.toast(.success, "Automated backup settings updated.")
                model.dataChanged(accountId, db.identifier)
                dismiss()
            } catch { self.error = errorMessage(error) }
            saving = false
        }
    }
}
