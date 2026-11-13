// Display helpers: a port of frontend/src/lib.ts so labels, tones and the
// production rule match v0.1 exactly.
import ADBMCore
import Foundation
import SwiftUI

enum Tone { case ok, warn, danger, neutral, info }

extension Tone {
    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .danger: .red
        case .info: .blue
        case .neutral: .secondary
        }
    }
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle"
        case .info, .neutral: "info.circle"
        case .warn: "exclamationmark.triangle"
        case .danger: "xmark.circle"
        }
    }
}

enum Fmt {
    static func parse(_ s: String?) -> Date? { s.flatMap { RFC3339.date($0) } }

    /// "17h ago" / "in 7h" / "—", the same buckets as lib.ts `ago`.
    static func ago(_ s: String?, now: Date = Date()) -> String {
        guard let d = parse(s) else { return "—" }
        let diff = now.timeIntervalSince(d)
        let future = diff < 0
        var value = abs(diff)
        var unit = "s"
        for (size, label) in [(60.0, "s"), (60.0, "m"), (24.0, "h"), (30.0, "d")] {
            if value < size { unit = label; break }
            value /= size
            unit = label
        }
        let n = max(1, Int(value.rounded()))
        return future ? "in \(n)\(unit)" : "\(n)\(unit) ago"
    }

    static func full(_ s: String?) -> String {
        guard let d = parse(s) else { return "—" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    static func size(_ gb: Int64) -> String {
        if gb == 0 { return "0 GB" }
        if gb >= 1024 {
            let tb = Double(gb) / 1024
            return (tb.rounded() == tb ? String(format: "%.0f", tb) : String(format: "%.1f", tb)) + " TB"
        }
        return "\(gb) GB"
    }

    static let engineLabels: [String: String] = [
        "aurora-postgresql": "Aurora PostgreSQL", "aurora-mysql": "Aurora MySQL",
        "postgres": "PostgreSQL", "mysql": "MySQL", "mariadb": "MariaDB",
        "oracle": "Oracle", "sqlserver": "SQL Server",
    ]
    static func engine(_ e: String) -> String { engineLabels[e] ?? e }

    static func kind(_ k: DBKind) -> String { k == .cluster ? "Cluster" : "Instance" }

    static func regions(_ r: [String]) -> String { r.isEmpty ? "—" : r.joined(separator: ", ") }

    static func source(_ s: SnapshotSource) -> String {
        switch s { case .manual: "Manual"; case .automated: "Automated"; case .awsBackup: "AWS Backup" }
    }
    static func sourceTone(_ s: SnapshotSource) -> Tone {
        switch s { case .manual: .neutral; case .automated: .info; case .awsBackup: .ok }
    }
    static func scheduleSource(_ s: ScheduleSource) -> String {
        switch s { case .automatedWindow: "Automated window"; case .awsBackupRule: "AWS Backup rule" }
    }
    static func restoreSource(_ s: RestoreSource) -> String {
        switch s { case .snapshot: "Snapshot"; case .pitr: "Point in time"; case .recoveryPoint: "AWS Backup recovery point" }
    }

    static func statusTone(_ status: String) -> Tone {
        let s = status.lowercased()
        if ["available", "completed", "active", "ok"].contains(s) { return .ok }
        if ["creating", "running", "backing-up", "pending", "modifying", "loading", "copying"].contains(s) { return .info }
        if ["failed", "error", "incompatible-restore"].contains(s) { return .danger }
        if ["stopped", "stopping"].contains(s) { return .warn }
        return .neutral
    }

    /// Same rule as lib.ts `isProd`: the `env` tag equals "prod" (case-insensitive).
    /// Search box match on name, engine, region, class and tag values.
    static func matches(_ db: Database, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        let hay = [db.identifier, db.engine, engine(db.engine), db.engineVersion, db.region, db.class, db.status]
            + (db.tags.map { Array($0.values) } ?? [])
        return hay.contains { $0.lowercased().contains(q) }
    }

    static func isProd(_ db: Database) -> Bool { (db.tags?["env"] ?? "").lowercased() == "prod" }

    static func suggestSnapshotName(_ dbId: String, now: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        return String(format: "%@-manual-%04d%02d%02d-%02d%02d", dbId, c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    static func slugify(_ name: String) -> String {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "account" : trimmed
    }

    static func uniqueId(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: \.isWhitespace)
        guard let first = parts.first?.first else { return "?" }
        let second = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (String(first) + second).uppercased()
    }

    static let accountPalette = ["#2563eb", "#16a34a", "#d97706", "#7c3aed", "#0891b2", "#db2777", "#64748b"]

    static func colorForName(_ name: String) -> String {
        var hash: UInt32 = 0
        for u in name.utf16 { hash = hash &* 31 &+ UInt32(u) }
        return accountPalette[Int(hash % UInt32(accountPalette.count))]
    }

    /// Mirrors the backend guard: AWS Backup rules keep recovery points at least this long.
    static let minAWSBackupRetentionDays = 7
    /// Automated-backup retention can never be set below 1 (i.e. never disabled).
    static let minAutomatedRetentionDays = 1

    static let readOnlyHelp = "Account is read-only"
}

extension Color {
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        let s = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        let v = UInt64(s, radix: 16) ?? 0x64748b
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    static func account(_ a: Account) -> Color { Color(hex: a.color.isEmpty ? Fmt.colorForName(a.name) : a.color) }
}
