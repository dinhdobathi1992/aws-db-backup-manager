// Port of internal/awsx/sso_test.go: locating the aws binary.
import XCTest
@testable import ADBMCore

final class SSOTests: XCTestCase {
    func testResolvePrefersPATH() throws {
        let dir = tempDir()
        let exe = dir.appendingPathComponent("aws")
        FileManager.default.createFile(atPath: exe.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let fallback = tempDir().appendingPathComponent("aws")
        FileManager.default.createFile(atPath: fallback.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(try AWSCLI.resolve(path: "/nonexistent:\(dir.path)", candidates: [fallback.path]), exe.path)
    }

    func testResolveFallsBackToKnownLocations() throws {
        let dir = tempDir()
        let missing = dir.appendingPathComponent("missing/aws").path
        let notExec = dir.appendingPathComponent("plain").path
        let exe = dir.appendingPathComponent("aws").path
        FileManager.default.createFile(atPath: notExec, contents: Data("x".utf8), attributes: [.posixPermissions: 0o644])
        FileManager.default.createFile(atPath: exe, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        // A directory is executable but is not a binary: it must be skipped.
        XCTAssertEqual(try AWSCLI.resolve(path: "", candidates: [missing, notExec, dir.path, exe]), exe)
    }

    func testResolveErrorsWhenAbsent() {
        XCTAssertThrowsError(try AWSCLI.resolve(path: tempDir().path, candidates: [tempDir().appendingPathComponent("aws").path]))
    }
}
