import XCTest
@testable import ADBMCore

final class AWSProfilesTests: XCTestCase {
    func testParsesConfigAndCredentialsProfiles() {
        let config = """
        [default]
        region = us-east-1

        # comment
        [profile prod]
        sso_session = corp
        sso_account_id = 123456789012
        region = ap-southeast-1
        [sso-session corp]
        sso_region = ap-southeast-1
        [profile  dev ]
        output = json
        """
        let creds = """
        [legacy]
        aws_access_key_id = AKIAEXAMPLE
        aws_secret_access_key = secret
        [prod]
        aws_access_key_id = AKIAOTHER
        """
        let p = AWSProfiles.parse(config: config, credentials: creds)
        XCTAssertEqual(p.map(\.name), ["default", "dev", "legacy", "prod"])
        let prod = p.first { $0.name == "prod" }!
        XCTAssertEqual(prod.region, "ap-southeast-1")
        XCTAssertEqual(prod.ssoAccountId, "123456789012")
        XCTAssertTrue(prod.isSSO)
        XCTAssertNil(p.first { $0.name == "dev" }!.region)
        XCTAssertFalse(p.contains { $0.name.contains("corp") })
    }

    func testMissingFilesGiveNoProfiles() {
        XCTAssertEqual(AWSProfiles.load(env: ["AWS_CONFIG_FILE": "/nonexistent/a", "AWS_SHARED_CREDENTIALS_FILE": "/nonexistent/b"]), [])
    }
}
