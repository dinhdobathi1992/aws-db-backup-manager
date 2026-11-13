// The local audit log: a port of internal/audit/log.go. It records this
// app's own actions (never AWS's) to activity.jsonl next to settings.json,
// one JSON object per line with the same keys as v0.1.
import Foundation

public struct AuditEntry: Codable, Sendable, Equatable {
    public var time: String
    public var account: String
    public var profile: String
    public var arn: String
    public var action: String
    public var target: String
    public var result: String

    public init(time: String, account: String, profile: String, arn: String, action: String, target: String, result: String) {
        self.time = time; self.account = account; self.profile = profile; self.arn = arn
        self.action = action; self.target = target; self.result = result
    }

    // v0.1 lines always carry every key, but tolerate a missing one.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: k) ?? "" }
        time = try s(.time); account = try s(.account); profile = try s(.profile); arn = try s(.arn)
        action = try s(.action); target = try s(.target); result = try s(.result)
    }
}

public struct AuditError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public struct AuditLog: Sendable {
    public let directory: URL
    public init(directory: URL? = nil) { self.directory = directory ?? SettingsStore.defaultDirectory }
    public var fileURL: URL { directory.appendingPathComponent("activity.jsonl") }

    /// Appends one entry (O_APPEND|O_CREATE, mode 0600).
    public func append(_ e: AuditEntry) throws {
        _ = try SettingsStore(directory: directory).ensureDirectory()
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw AuditError(message: "open audit log: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard var data = try? GoJSON.encode(e, indent: false) else { throw AuditError(message: "encode audit entry") }
        data.append(UInt8(ascii: "\n"))
        let n = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n != data.count { throw AuditError(message: "write audit entry: \(String(cString: strerror(errno)))") }
    }

    /// Every recorded entry, oldest first. A missing file is not an error;
    /// a malformed line is skipped rather than failing the whole feed.
    public func readAll() throws -> [AuditEntry] {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { return [] }
        catch { throw AuditError(message: "open audit log: \(error.localizedDescription)") }
        let dec = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard !line.isEmpty, (try? JSONValue.parse(Data(line)))?.object != nil else { return nil }
            return try? dec.decode(AuditEntry.self, from: Data(line))
        }
    }
}
