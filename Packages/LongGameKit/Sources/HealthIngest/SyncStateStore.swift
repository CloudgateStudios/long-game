import Foundation

/// Where an ingesting device remembers how far it has read. This is per-device state,
/// so it is kept out of SwiftData and never syncs.
public protocol SyncStateStore: Sendable {
    func data(for key: SyncStateKey) -> Data?
    func date(for key: SyncStateKey) -> Date?
    func set(_ value: Data?, for key: SyncStateKey)
    func set(_ value: Date?, for key: SyncStateKey)
}

public enum SyncStateKey: String, Sendable, CaseIterable {
    case workoutAnchor = "health.workoutAnchor"
    /// Fixed at the first sync so the anchor always refers to the same query.
    case backfillStart = "health.backfillStart"
    case lastDailySync = "health.lastDailySync"
}

public struct UserDefaultsSyncStateStore: SyncStateStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String

    /// `prefix` keeps fixture and real sync state apart.
    public init(defaults: UserDefaults = .standard, prefix: String = "") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func data(for key: SyncStateKey) -> Data? { defaults.data(forKey: prefix + key.rawValue) }
    public func date(for key: SyncStateKey) -> Date? { defaults.object(forKey: prefix + key.rawValue) as? Date }
    public func set(_ value: Data?, for key: SyncStateKey) { defaults.set(value, forKey: prefix + key.rawValue) }
    public func set(_ value: Date?, for key: SyncStateKey) { defaults.set(value, forKey: prefix + key.rawValue) }

    public func reset() {
        for key in SyncStateKey.allCases { defaults.removeObject(forKey: prefix + key.rawValue) }
    }
}

/// For tests and previews.
public final class InMemorySyncStateStore: SyncStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SyncStateKey: Any] = [:]

    public init() {}

    public func data(for key: SyncStateKey) -> Data? { lock.withLock { values[key] as? Data } }
    public func date(for key: SyncStateKey) -> Date? { lock.withLock { values[key] as? Date } }
    public func set(_ value: Data?, for key: SyncStateKey) { lock.withLock { values[key] = value } }
    public func set(_ value: Date?, for key: SyncStateKey) { lock.withLock { values[key] = value } }
}
