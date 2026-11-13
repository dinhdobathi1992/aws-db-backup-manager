// Settings and audit log persistence: v0.1 files must load unchanged.
import XCTest
@testable import ADBMCore

final class SettingsTests: XCTestCase {
    func testV01SettingsLoadUnchanged() throws {
        let dir = tempDir()
        let v01 = """
        {
          "accounts": [
            {
              "id": "acct-3f2a9c1e-7b4d-4e8a-9c21-5d6e7f8a9b0c",
              "name": "Shared Services (read-only)",
              "profile": "shared-services",
              "regions": [
                "ap-southeast-1"
              ],
              "color": "",
              "readOnly": true
            }
          ]
        }
        """
        try Data(v01.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let s = try SettingsStore(directory: dir).load()
        XCTAssertEqual(s.accounts, [Account(id: "acct-3f2a9c1e-7b4d-4e8a-9c21-5d6e7f8a9b0c", name: "Shared Services (read-only)",
                                            profile: "shared-services", regions: ["ap-southeast-1"], readOnly: true)])
        // Saving writes back the identical bytes v0.1's MarshalIndent wrote.
        try SettingsStore(directory: dir).save(s)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8), v01)
    }

    func testMissingFileIsEmptyAndTolerantDecode() throws {
        let dir = tempDir()
        XCTAssertEqual(try SettingsStore(directory: dir).load(), Settings())
        try Data(#"{"accounts":[{"id":"a","name":"n","profile":"p","regions":null}]}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let a = try SettingsStore(directory: dir).load().accounts[0]
        XCTAssertEqual(a.regions, [])
        XCTAssertEqual(a.color, "")
        XCTAssertFalse(a.readOnly)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("settings.json"))
        XCTAssertEqual(try SettingsStore(directory: dir).load(), Settings())
        try Data("not json".utf8).write(to: dir.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try SettingsStore(directory: dir).load())
    }

    func testSaveRoundTripsWithMode0600() throws {
        let dir = tempDir()
        let store = SettingsStore(directory: dir)
        let s = Settings(accounts: [Account(id: "a", name: "A", profile: "p", regions: ["us-east-1", "eu-west-1"], color: "#fff")])
        try store.save(s)
        XCTAssertEqual(try store.load(), s)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json.tmp").path))
    }

    func testDiscoverProfiles() throws {
        let home = tempDir()
        let aws = home.appendingPathComponent(".aws")
        try FileManager.default.createDirectory(at: aws, withIntermediateDirectories: true)
        try Data("[default]\nregion=x\n[profile prod]\nsso_start_url=y\n[sso-session s]\n".utf8).write(to: aws.appendingPathComponent("config"))
        try Data("[default]\naws_secret_access_key=SECRET\n[legacy]\n".utf8).write(to: aws.appendingPathComponent("credentials"))
        let p = SettingsStore.discoverProfiles(home: home)
        XCTAssertEqual(p, ["default", "legacy", "prod"])
        XCTAssertFalse(p.contains { $0.contains("SECRET") })
    }
}

final class AuditTests: XCTestCase {
    func testAppendReadAllAndSkipMalformed() throws {
        let dir = tempDir()
        let log = AuditLog(directory: dir)
        XCTAssertEqual(try log.readAll(), [])
        let e1 = AuditEntry(time: "2026-01-15T10:30:00Z", account: "a", profile: "p", arn: "arn", action: "CreateSnapshot", target: "db", result: "creating")
        try log.append(e1)
        let h = try FileHandle(forWritingTo: log.fileURL)
        try h.seekToEnd(); try h.write(contentsOf: Data("not json\n[1]\n\n".utf8)); try h.close()
        let e2 = AuditEntry(time: "2026-01-15T10:31:00Z", account: "a", profile: "p", arn: "arn", action: "StartBackupJob", target: "db", result: "job-1")
        try log.append(e2)
        XCTAssertEqual(try log.readAll(), [e1, e2])
        let first = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n")[0]
        XCTAssertEqual(first, #"{"time":"2026-01-15T10:30:00Z","account":"a","profile":"p","arn":"arn","action":"CreateSnapshot","target":"db","result":"creating"}"#)
        let attrs = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
