// Chooses the backend: the in-memory fixtures when ADBM_FIXTURES=1,
// otherwise the real AWS service. This is the only place that decides.
import ADBMCore
import Foundation

enum ServiceFactory {
    static var usesFixtures: Bool { ProcessInfo.processInfo.environment["ADBM_FIXTURES"] == "1" }

    static func make() -> any BackendService {
        usesFixtures ? FixtureService() : AWSBackendService()
    }
}
