// Settings persistence: a port of internal/settings/store.go. The same file
// (~/Library/Application Support/AWS DB Backup Manager/settings.json), the
// same {"accounts":[...]} document and the same atomic 0600 write, so v0.1
// and v0.2 read each other's settings unchanged. Credentials are never
// stored: an account only names a local AWS CLI profile.
import Foundation

/// The persisted root document.
public struct Settings: Codable, Sendable, Equatable {
    public var accounts: [Account]
    public init(accounts: [Account] = []) { self.accounts = accounts }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
    }
}

public struct SettingsError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct SettingsStore: Sendable {
    /// The settings directory. Injectable so tests never touch the real one.
    public let directory: URL

    public static var defaultDirectory: URL {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/AWS DB Backup Manager", isDirectory: true)
    }

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    public var fileURL: URL { directory.appendingPathComponent("settings.json") }

    /// Creates the directory (0700) if needed and returns it.
    public func ensureDirectory() throws -> URL {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw SettingsError("create settings directory: \(error.localizedDescription)")
        }
        return directory
    }

    /// Reads settings.json, returning empty settings if it does not exist yet.
    public func load() throws -> Settings {
        _ = try ensureDirectory()
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
            return Settings()
        } catch {
            throw SettingsError("read settings: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            throw SettingsError("parse settings: \(error.localizedDescription)")
        }
    }

    /// Atomically writes settings.json with 0600 permissions: write a temp
    /// file in the same directory, then rename it over the target.
    public func save(_ settings: Settings) throws {
        _ = try ensureDirectory()
        let data: Data
        do {
            data = try GoJSON.encode(settings)
        } catch {
            throw SettingsError("encode settings: \(error.localizedDescription)")
        }
        let tmp = directory.appendingPathComponent("settings.json.tmp")
        let fm = FileManager.default
        if !fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            throw SettingsError("write settings: cannot create \(tmp.path)")
        }
        // createFile keeps an existing file's mode; force 0600 regardless.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if rename(tmp.path, fileURL.path) != 0 {
            throw SettingsError("replace settings: \(String(cString: strerror(errno)))")
        }
    }

    /// Reads ~/.aws/config and ~/.aws/credentials section headers (never
    /// secret values) and returns the sorted, deduplicated profile names.
    public static func discoverProfiles(home: URL? = nil) -> [String] {
        let home = home ?? ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        var seen = Set<String>()
        func add(_ s: Substring) {
            let n = s.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { seen.insert(n) }
        }
        let profileHeader = #/^\[profile\s+(\S+)\]$/#
        let defaultHeader = #/^\[default\]$/#
        let credHeader = #/^\[(\S+)\]$/#
        for line in readLines(home.appendingPathComponent(".aws/config")) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if let m = l.wholeMatch(of: profileHeader) { add(m.1) }
            else if l.wholeMatch(of: defaultHeader) != nil { add("default") }
        }
        for line in readLines(home.appendingPathComponent(".aws/credentials")) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if let m = l.wholeMatch(of: credHeader) { add(m.1) }
        }
        return seen.sorted()
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
}
