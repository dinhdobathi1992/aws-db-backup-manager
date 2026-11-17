import Foundation
import Testing
@testable import ADBMCore

@Suite struct CABundleTests {
    @Test func explicitEnvBundleWins() {
        var called = false
        let env = CABundle.childEnvironment(base: ["AWS_CA_BUNDLE": "/x.pem", "PATH": "/usr/bin"], awsConfigText: nil) {
            called = true; return "/gen.pem"
        }
        #expect(env["AWS_CA_BUNDLE"] == "/x.pem")
        #expect(!called)
    }

    @Test func configBundleWins() {
        let cfg = "[profile a]\nregion = us-east-1\n  ca_bundle = /corp.pem\n"
        let env = CABundle.childEnvironment(base: ["PATH": "/usr/bin"], awsConfigText: cfg) { "/gen.pem" }
        #expect(env["AWS_CA_BUNDLE"] == nil)
    }

    @Test func commentedConfigBundleIgnored() {
        #expect(!CABundle.configNamesBundle("# ca_bundle = /x\n; ca_bundle=/y\n[default]\nregion=x\n"))
        #expect(CABundle.configNamesBundle("[default]\nCA_BUNDLE=/y\n"))
    }

    @Test func generatedBundleSetWhenNoneConfigured() {
        let env = CABundle.childEnvironment(base: ["PATH": "/usr/bin", "HOME": "/h"], awsConfigText: "[default]\n") { "/gen.pem" }
        #expect(env["AWS_CA_BUNDLE"] == "/gen.pem")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["HOME"] == "/h")
    }

    @Test func noBundleLeavesEnvUnchanged() {
        let base = ["PATH": "/usr/bin"]
        #expect(CABundle.childEnvironment(base: base, awsConfigText: nil) { nil } == base)
    }

    @Test func systemRootsExportAsPEM() {
        let ders = CABundle.trustedRootsDER()
        #expect(ders.count > 50)
        let pem = CABundle.pem(Array(ders.prefix(2)))
        #expect(pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").count == 3)
        #expect(pem.hasSuffix("-----END CERTIFICATE-----\n"))
    }
}
