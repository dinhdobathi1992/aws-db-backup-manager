// Lists the AWS profiles already configured on this Mac so the account form
// can offer them as a picker. Reads ~/.aws/config and ~/.aws/credentials
// (or AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE) for section names and a
// few non-secret keys only; key material is never read into the result.
import Foundation

public struct AWSProfile: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let region: String?
    public let ssoAccountId: String?
    public let isSSO: Bool

    public init(name: String, region: String? = nil, ssoAccountId: String? = nil, isSSO: Bool = false) {
        self.name = name; self.region = region; self.ssoAccountId = ssoAccountId; self.isSSO = isSSO
    }
}

public enum AWSProfiles {
    /// Profiles from the user's AWS config and credentials files, sorted by name.
    public static func load(env: [String: String] = ProcessInfo.processInfo.environment) -> [AWSProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = env["AWS_CONFIG_FILE"].map(expand) ?? "\(home)/.aws/config"
        let credsPath = env["AWS_SHARED_CREDENTIALS_FILE"].map(expand) ?? "\(home)/.aws/credentials"
        let config = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let creds = (try? String(contentsOfFile: credsPath, encoding: .utf8)) ?? ""
        return parse(config: config, credentials: creds)
    }

    /// Pure parser, exposed for tests.
    public static func parse(config: String, credentials: String) -> [AWSProfile] {
        var byName: [String: AWSProfile] = [:]
        for (section, keys) in sections(config) {
            let name: String
            if section == "default" { name = "default" }
            else if section.hasPrefix("profile ") { name = String(section.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            else { continue } // sso-session, services, plugins: not profiles
            guard !name.isEmpty else { continue }
            byName[name] = AWSProfile(name: name, region: keys["region"].flatMap(nonEmpty),
                                      ssoAccountId: keys["sso_account_id"].flatMap(nonEmpty),
                                      isSSO: keys["sso_session"] != nil || keys["sso_start_url"] != nil)
        }
        for (section, _) in sections(credentials) where byName[section] == nil && !section.isEmpty {
            byName[section] = AWSProfile(name: section)
        }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func sections(_ text: String) -> [(String, [String: String])] {
        var out: [(String, [String: String])] = []
        var current: String?
        var keys: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                if let c = current { out.append((c, keys)) }
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                keys = [:]
            } else if current != nil, let eq = line.firstIndex(of: "=") {
                let k = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                keys[k] = v
            }
        }
        if let c = current { out.append((c, keys)) }
        return out
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
    private static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }
}

public enum AWSRegions {
    /// Commercial regions where RDS and AWS Backup are available.
    public static let all: [(code: String, name: String)] = [
        ("us-east-1", "US East (N. Virginia)"), ("us-east-2", "US East (Ohio)"),
        ("us-west-1", "US West (N. California)"), ("us-west-2", "US West (Oregon)"),
        ("ca-central-1", "Canada (Central)"), ("ca-west-1", "Canada West (Calgary)"),
        ("sa-east-1", "South America (São Paulo)"), ("mx-central-1", "Mexico (Central)"),
        ("eu-central-1", "Europe (Frankfurt)"), ("eu-central-2", "Europe (Zurich)"),
        ("eu-west-1", "Europe (Ireland)"), ("eu-west-2", "Europe (London)"), ("eu-west-3", "Europe (Paris)"),
        ("eu-north-1", "Europe (Stockholm)"), ("eu-south-1", "Europe (Milan)"), ("eu-south-2", "Europe (Spain)"),
        ("ap-southeast-1", "Asia Pacific (Singapore)"), ("ap-southeast-2", "Asia Pacific (Sydney)"),
        ("ap-southeast-3", "Asia Pacific (Jakarta)"), ("ap-southeast-4", "Asia Pacific (Melbourne)"),
        ("ap-southeast-5", "Asia Pacific (Malaysia)"), ("ap-southeast-7", "Asia Pacific (Thailand)"),
        ("ap-northeast-1", "Asia Pacific (Tokyo)"), ("ap-northeast-2", "Asia Pacific (Seoul)"),
        ("ap-northeast-3", "Asia Pacific (Osaka)"), ("ap-east-1", "Asia Pacific (Hong Kong)"),
        ("ap-south-1", "Asia Pacific (Mumbai)"), ("ap-south-2", "Asia Pacific (Hyderabad)"),
        ("me-central-1", "Middle East (UAE)"), ("me-south-1", "Middle East (Bahrain)"),
        ("il-central-1", "Israel (Tel Aviv)"), ("af-south-1", "Africa (Cape Town)"),
    ]

    public static func name(_ code: String) -> String? { all.first { $0.code == code }?.name }
}
