// `adbm-cli measure-load --account <id>`: reads one account the way the app
// does when it opens (databases, then every database's snapshots and plan,
// plus schedules and activity) and prints how long it took and how many AWS
// requests it made. Read-only: it calls only list/get operations.
import ADBMCore
import Foundation

final class CountingTransport: AWSTransport, @unchecked Sendable {
    private let inner = URLSessionTransport()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
    var byOperation: [String: Int] { lock.withLock { counts } }
    func send(_ r: AWSRequest) async throws -> (status: Int, body: Data) {
        lock.withLock { counts[r.operation.rawValue, default: 0] += 1 }
        return try await inner.send(r)
    }
}

func measureLoad(accountId: String) async {
    let transport = CountingTransport()
    let svc = AWSBackendService(clients: AWSClients(transport: transport))
    let start = Date()
    do {
        let dbs = try await svc.listDatabases(accountId)
        await withTaskGroup(of: Void.self) { g in
            for db in dbs {
                g.addTask {
                    _ = try? await svc.listSnapshots(accountId, db: db.identifier)
                    _ = try? await svc.getBackupPlan(accountId, db: db.identifier)
                }
            }
            g.addTask { _ = try? await svc.listSchedules(accountId) }
            g.addTask { _ = try? await svc.listActivity(accountId, limit: 50) }
        }
        let secs = Date().timeIntervalSince(start)
        print(String(format: "databases=%d requests=%d seconds=%.1f", dbs.count, transport.total, secs))
        for (op, n) in transport.byOperation.sorted(by: { $0.value > $1.value }) { print("  \(op): \(n)") }
    } catch {
        fail("error: \(error.localizedDescription)", code: 1)
    }
}
