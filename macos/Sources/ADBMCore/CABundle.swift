// The AWS CLI (Python) does not read the macOS keychain: it trusts only its
// bundled CA list unless AWS_CA_BUNDLE or `ca_bundle` says otherwise. Behind
// a TLS-inspecting proxy (Zscaler and similar), whose root CA is installed in
// the keychain, every CLI call then fails with CERTIFICATE_VERIFY_FAILED.
// A terminal often fixes this with AWS_CA_BUNDLE in the shell profile, but an
// app launched from Finder never sees that. So, when neither the environment
// nor the AWS config names a bundle, the app writes the certificates macOS
// trusts (system roots plus admin/user trusted roots) to a PEM file and hands
// it to the CLI. URLSession already trusts the keychain, so only the CLI
// needs this.
import Foundation
import Security

public enum CABundle {
    /// Environment for the aws child process. An explicit AWS_CA_BUNDLE, or a
    /// `ca_bundle` line in the AWS config file, always wins; otherwise
    /// `makeBundle` is called and, if it yields a path, AWS_CA_BUNDLE is set.
    public static func childEnvironment(base: [String: String], awsConfigText: String?,
                                        makeBundle: () -> String?) -> [String: String] {
        if let v = base["AWS_CA_BUNDLE"], !v.isEmpty { return base }
        if let text = awsConfigText, configNamesBundle(text) { return base }
        var env = base
        if let path = makeBundle() { env["AWS_CA_BUNDLE"] = path }
        return env
    }

    /// True when any section of an AWS config file sets `ca_bundle`.
    public static func configNamesBundle(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), !t.hasPrefix(";"), let eq = t.firstIndex(of: "=") else { return false }
            return t[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "ca_bundle"
        }
    }

    /// PEM text for DER certificates, one block each.
    public static func pem(_ ders: [Data]) -> String {
        ders.map { der in
            let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            return "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
        }.joined()
    }

    /// DER bytes of every certificate macOS trusts as a root: the system
    /// anchors plus admin- and user-domain certificates with trust settings
    /// that are not an explicit deny.
    public static func trustedRootsDER() -> [Data] {
        var out: [Data] = []
        var seen = Set<Data>()
        func add(_ c: SecCertificate) {
            let d = SecCertificateCopyData(c) as Data
            if seen.insert(d).inserted { out.append(d) }
        }
        var anchors: CFArray?
        if SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess, let a = anchors as? [SecCertificate] {
            a.forEach(add)
        }
        for domain in [SecTrustSettingsDomain.admin, .user] {
            var certs: CFArray?
            guard SecTrustSettingsCopyCertificates(domain, &certs) == errSecSuccess,
                  let list = certs as? [SecCertificate] else { continue }
            for c in list where !isDenied(c, domain) { add(c) }
        }
        return out
    }

    static func isDenied(_ c: SecCertificate, _ domain: SecTrustSettingsDomain) -> Bool {
        var settings: CFArray?
        guard SecTrustSettingsCopyTrustSettings(c, domain, &settings) == errSecSuccess,
              let list = settings as? [[String: Any]] else { return false }
        let deny = Int(SecTrustSettingsResult.deny.rawValue)
        return list.contains { ($0[kSecTrustSettingsResult as String] as? Int) == deny }
    }

    /// Writes the trusted roots to `<settings dir>/ca-bundle.pem` once per
    /// launch and returns its path, or nil if nothing could be written.
    public static let generatedPath: String? = {
        let ders = trustedRootsDER()
        guard !ders.isEmpty else { return nil }
        do {
            let dir = try SettingsStore().ensureDirectory()
            let url = dir.appendingPathComponent("ca-bundle.pem")
            try Data(pem(ders).utf8).write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }()

    /// The environment the app gives every aws CLI process.
    public static func awsEnvironment() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = env["AWS_CONFIG_FILE"].map { ($0 as NSString).expandingTildeInPath } ?? "\(home)/.aws/config"
        let text = try? String(contentsOfFile: configPath, encoding: .utf8)
        return childEnvironment(base: env, awsConfigText: text, makeBundle: { generatedPath })
    }
}
