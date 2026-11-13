// Port of internal/awsx/static_test.go: no Swift source in ADBMCore or the
// CLI may name a destructive AWS operation, as an AWSOperation case
// reference or as a string literal, independent of the runtime guard and of
// whether any test exercises that path.
import XCTest
@testable import ADBMCore

final class StaticScanTests: XCTestCase {
    /// Operation-shaped names only: a destructive verb followed by an AWS
    /// RDS/Backup resource noun, or one of the exact names. This is the Swift
    /// analogue of v0.1's "call targets only" scoping, so a field such as
    /// DeleteAfterDays or a stdlib call such as removeLast() is not flagged.
    static let nouns = "DB|Backup|Recovery|Global|Export|Restore|Copy|Report|Framework|Legal|Option|Event|Integration|Tenant|Custom|Blue|Shard|Activity|Source|Role|Tags|Index|Vault|Snapshot|Instance|Cluster"
    static let exact = ["UpdateBackupPlan", "PutBackupVaultAccessPolicy", "PutBackupVaultLockConfiguration",
                        "ModifyDBSnapshotAttribute", "ModifyDBClusterSnapshotAttribute"]

    static func patterns() throws -> (literal: NSRegularExpression, member: NSRegularExpression) {
        let upper = "(?:Delete|Remove|Stop|Reboot|Failover|Terminate)(?:\(nouns))[A-Za-z]*|" + exact.joined(separator: "|")
        let lower = "(?:delete|remove|stop|reboot|failover|terminate)(?:\(nouns))[A-Za-z]*|"
            + exact.map { $0.prefix(1).lowercased() + $0.dropFirst() }.joined(separator: "|")
        return (try NSRegularExpression(pattern: "\"(?:\(upper))\""),
                try NSRegularExpression(pattern: "\\.(?:\(lower))\\b"))
    }

    static func flagged(_ code: String) throws -> Bool {
        let (literal, member) = try patterns()
        let r = NSRange(code.startIndex..., in: code)
        return literal.firstMatch(in: code, range: r) != nil || member.firstMatch(in: code, range: r) != nil
    }

    func testNoDestructiveCallsAnywhereInSources() throws {
        var scanned = 0
        for dir in ["Sources/ADBMCore", "Sources/adbm-cli"] {
            let base = RepoPath.macos.appendingPathComponent(dir)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                for (n, line) in text.components(separatedBy: "\n").enumerated() {
                    let code = line.components(separatedBy: "//").first ?? line
                    if try Self.flagged(code) {
                        XCTFail("\(url.lastPathComponent):\(n + 1): forbidden destructive operation reference: \(line)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10)
    }

    /// The scanner itself must catch the shapes it claims to, and only those.
    func testScannerCatchesKnownShapes() throws {
        for s in [#"c.query("DeleteDBInstance")"#, #"op = "StopDBCluster""#, #""UpdateBackupPlan""#,
                  #"try await c.query(.deleteDBSnapshot, p)"#, #"c.backup(.deleteRecoveryPoint)"#, #"x(.failoverDBCluster)"#] {
            XCTAssertTrue(try Self.flagged(s), s)
        }
        for s in [#"l?["DeleteAfterDays"]?.int"#, #"base.removeLast()"#, #"e.removeFirst(5)"#, #"let p = "DeletionProtection""#] {
            XCTAssertFalse(try Self.flagged(s), s)
        }
    }
}
