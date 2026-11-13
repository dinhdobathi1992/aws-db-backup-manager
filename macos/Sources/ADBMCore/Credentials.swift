// Credentials come from the user's own AWS CLI configuration, never from
// this app: `aws configure export-credentials --profile X --format process`
// resolves static keys, SSO, assume-role and credential_process exactly as
// the AWS CLI does. v0.1 already needed the AWS CLI for `aws sso login`.
import Foundation

public enum AWSCLI {
    /// A GUI app launched from Finder inherits launchd's minimal PATH, so the
    /// usual install locations are checked explicitly.
    public static let candidates = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/local/aws-cli/aws", "/usr/bin/aws"]

    public static func resolve() throws -> String {
        try resolve(path: ProcessInfo.processInfo.environment["PATH"] ?? "", candidates: candidates)
    }

    /// Injectable form of resolve(): the first executable regular file named
    /// `aws` on `path`, else the first executable regular file in `candidates`.
    public static func resolve(path: String, candidates: [String]) throws -> String {
        for dir in path.split(separator: ":") {
            let p = "\(dir)/aws"
            if isExecutableFile(p) { return p }
        }
        for c in candidates where isExecutableFile(c) { return c }
        throw AWSError.credentials("aws CLI not found on PATH or in \(candidates); install AWS CLI v2 to use local profiles and SSO sign-in")
    }

    static func isExecutableFile(_ p: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: p)
    }

    /// Runs the aws binary with an explicit argument array (no shell), so a
    /// profile name can never inject a command.
    static func run(_ args: [String]) async throws -> (status: Int32, out: Data, err: String) {
        let bin = try resolve()
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.terminationHandler = { proc in
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: (proc.terminationStatus, o, e))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// `aws sso login --profile=<profile>`: opens the browser for SSO.
    public static func ssoLogin(profile: String) async throws {
        guard !profile.isEmpty else { throw AWSError.invalid("aws profile is required") }
        let r = try await run(["sso", "login", "--profile=\(profile)"])
        if r.status != 0 { throw AWSError.credentials("aws sso login --profile \(profile): \(r.err)") }
    }
}

public protocol CredentialProvider: Sendable {
    func credentials(profile: String) async throws -> AWSCredentials
    func forget(profile: String) async
}

/// Resolves and caches credentials per profile until five minutes before
/// they expire.
public actor CLICredentialProvider: CredentialProvider {
    private var cache: [String: AWSCredentials] = [:]
    /// One `aws configure export-credentials` per profile at a time: every
    /// request made while it runs waits for it instead of starting its own
    /// AWS CLI process.
    private var inflight: [String: Task<AWSCredentials, Error>] = [:]
    public init() {}

    public func credentials(profile: String) async throws -> AWSCredentials {
        guard !profile.isEmpty else { throw AWSError.invalid("aws profile is required") }
        if let c = cache[profile], c.expiration.map({ $0.timeIntervalSinceNow > 300 }) ?? true { return c }
        if let t = inflight[profile] { return try await t.value }
        let t = Task { try await Self.export(profile: profile) }
        inflight[profile] = t
        do {
            let c = try await t.value
            if inflight[profile] == t { inflight[profile] = nil; cache[profile] = c }
            return c
        } catch {
            if inflight[profile] == t { inflight[profile] = nil }
            throw error
        }
    }

    static func export(profile: String) async throws -> AWSCredentials {
        let r = try await AWSCLI.run(["configure", "export-credentials", "--profile=\(profile)", "--format=process"])
        guard r.status == 0 else {
            let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = msg.lowercased()
            if lower.contains("expired") || lower.contains("sso") && (lower.contains("token") || lower.contains("login")) {
                throw AWSError.expired("SSO session for profile \(profile) has expired or is missing; sign in again. (\(msg))")
            }
            throw AWSError.credentials("load AWS credentials for profile \"\(profile)\": \(msg)")
        }
        let j = try JSONValue.parse(r.out)
        guard let ak = j["AccessKeyId"]?.string, let sk = j["SecretAccessKey"]?.string else {
            throw AWSError.credentials("aws configure export-credentials returned no keys for profile \(profile)")
        }
        return AWSCredentials(accessKeyId: ak, secretAccessKey: sk, sessionToken: j["SessionToken"]?.string,
                              expiration: j["Expiration"]?.string.flatMap(RFC3339.date))
    }

    public func forget(profile: String) { cache[profile] = nil; inflight[profile] = nil }
}
