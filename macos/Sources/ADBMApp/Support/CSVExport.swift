// Saves a table as CSV through the standard Save panel. Values are what the
// screen already shows; nothing new is read from AWS.
import AppKit
import UniformTypeIdentifiers

enum CSVExport {
    /// RFC 4180 quoting; a leading = + - @ is prefixed with ' so a
    /// spreadsheet never runs a cell as a formula.
    static func field(_ s: String) -> String {
        var v = s
        if let f = v.first, "=+-@".contains(f) { v = "'" + v }
        if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }

    static func text(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Returns the saved file's name, or nil when the person cancelled.
    @MainActor static func save(suggestedName: String, header: [String], rows: [[String]]) throws -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try Data(text(header: header, rows: rows).utf8).write(to: url, options: .atomic)
        return url.lastPathComponent
    }

    static func stamp(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
