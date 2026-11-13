// The read-view TTL cache and region fan-out: a port of
// internal/inventory/cache.go. Values are mapped read models only, never
// credentials, and never survive a process restart.
import Foundation

/// A message-only error, used where v0.1 wrapped errors with fmt.Errorf.
public struct BackendError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    /// "prefix: underlying" (Go's fmt.Errorf("prefix: %w", err)).
    static func wrap(_ prefix: String, _ error: Error) -> BackendError {
        BackendError("\(prefix): \(error.localizedDescription)")
    }
}

/// Go's %q for the plain identifiers used in messages.
func goQuote(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default:
            if u.value < 0x20 || u.value == 0x7f { out += String(format: "\\x%02x", u.value) } else { out.unicodeScalars.append(u) }
        }
    }
    return out + "\""
}

private enum CacheLookup { case hit(any Sendable), load(Task<any Sendable, Error>) }

public final class TTLCache: @unchecked Sendable {
    /// Read views stay fresh for five minutes; Refresh and every write
    /// invalidate what they could have changed, so a longer TTL only saves
    /// repeat AWS calls when switching between accounts and screens.
    public static let defaultTTL: TimeInterval = 300
    private let lock = NSLock()
    private var entries: [String: (value: any Sendable, expires: Date)] = [:]
    /// Loads in progress: concurrent callers for one key share one AWS call.
    private var inflight: [String: Task<any Sendable, Error>] = [:]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    public init(ttl: TimeInterval = TTLCache.defaultTTL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl; self.now = now
    }

    func get<T>(_ key: String, as: T.Type) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[key], !(now() > e.expires) else { return nil }
        return e.value as? T
    }

    func set(_ key: String, _ value: any Sendable) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = (value, now().addingTimeInterval(ttl))
    }

    /// Drops every entry (and forgets every load in progress) whose key
    /// starts with `prefix`.
    public func invalidate(_ prefix: String) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
        inflight = inflight.filter { !$0.key.hasPrefix(prefix) }
    }

    /// The cached value if fresh; otherwise joins a load already in progress
    /// for `key`, or starts one. A success is cached; an error is never
    /// cached, so the next call retries.
    func cached<T: Sendable>(_ key: String, _ fn: @escaping @Sendable () async throws -> T) async throws -> T {
        // The fresh-value check and the in-flight lookup share one lock, so a
        // load finishing between them can't make this caller start another.
        let lookup: CacheLookup = lock.withLock {
            if let e = entries[key], !(now() > e.expires) { return .hit(e.value) }
            if let t = inflight[key] { return .load(t) }
            let t = Task<any Sendable, Error> { try await fn() }
            inflight[key] = t
            return .load(t)
        }
        let task: Task<any Sendable, Error>
        switch lookup {
        case .hit(let v):
            guard let typed = v as? T else { throw BackendError("cache type mismatch for \(key)") }
            return typed
        case .load(let t): task = t
        }
        do {
            let v = try await task.value
            lock.withLock {
                // Only the load that is still current may fill the cache:
                // an invalidate() while it ran means its answer is stale.
                if inflight[key] == task {
                    inflight[key] = nil
                    entries[key] = (v, now().addingTimeInterval(ttl))
                }
            }
            guard let typed = v as? T else { throw BackendError("cache type mismatch for \(key)") }
            return typed
        } catch {
            lock.withLock { if inflight[key] == task { inflight[key] = nil } }
            throw error
        }
    }
}

/// Runs `fn` for each region, at most 8 at a time. A failing region never
/// aborts the others. Results come back in the account's region order, so
/// output is deterministic (v0.1 appended in completion order).
func fanOutRegions<T: Sendable>(_ regions: [String], limit: Int = 8,
                                _ fn: @escaping @Sendable (String) async throws -> [T]) async -> (values: [T], errors: [String: Error]) {
    var results = [[T]?](repeating: nil, count: regions.count)
    var errors: [String: Error] = [:]
    await withTaskGroup(of: (Int, Result<[T], Error>).self) { group in
        var next = 0
        func launch() {
            let i = next, region = regions[i]
            next += 1
            group.addTask {
                do { return (i, .success(try await fn(region))) } catch { return (i, .failure(error)) }
            }
        }
        while next < regions.count && next < limit { launch() }
        while let (i, r) = await group.next() {
            switch r {
            case .success(let v): results[i] = v
            case .failure(let e): errors[regions[i]] = e
            }
            if next < regions.count { launch() }
        }
    }
    return (results.compactMap { $0 }.flatMap { $0 }, errors)
}

/// Renders a region error map as one deterministic message.
func joinErrs(_ errs: [String: Error]) -> String {
    errs.map { "\($0.key): \($0.value.localizedDescription)" }.sorted().joined(separator: "; ")
}
