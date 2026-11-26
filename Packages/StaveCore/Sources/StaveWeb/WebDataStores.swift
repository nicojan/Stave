import Foundation
import WebKit

/// Which website data store a page uses: a profile's or container's persistent store, or a private session's (shared by the private windows
/// of one profile while any is open; see `WebDataStores.joinPrivateSession`).
public enum DataStoreKey: Hashable, Sendable {
    case persistent(UUID)
    case privateSession(UUID)
}

/// Why a website data store couldn't be removed.
public enum WebDataStoreError: Error, Equatable, Sendable {
    /// A page still holds the store; removing it would fail in WebKit, or pull the data out from under the page.
    case inUse
}

/// Every page's data store comes from here. `WKWebsiteDataStore.default()` is never used (plan 3, decision 1).
@MainActor
public final class WebDataStores {
    private var cache: [DataStoreKey: WKWebsiteDataStore] = [:]
    /// The open private session of each profile: its ID, and how many private windows use it.
    private var privateSessions: [UUID: (id: UUID, windows: Int)] = [:]

    public init() {}

    /// The same instance for the same key until the private session's last window closes.
    public func store(for key: DataStoreKey) -> WKWebsiteDataStore {
        if case .privateSession(let id) = key {
            assert(privateSessions.values.contains { $0.id == id }, "A private session's store is asked for only while a private window of it is open (joinPrivateSession)")
        }
        if let cached = cache[key] { return cached }
        let made: WKWebsiteDataStore = switch key {
        case .persistent(let id): WKWebsiteDataStore(forIdentifier: id)
        case .privateSession: .nonPersistent()
        }
        cache[key] = made
        return made
    }

    /// Whether a store for `key` is cached; for tests.
    func isCached(_ key: DataStoreKey) -> Bool { cache[key] != nil }

    /// The pause before each retry of a removal WebKit refused: about 8 s in all.
    nonisolated public static let removalRetryDelays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4)]

    /// Removes a profile's or container's persistent store from disk (decisions 18 and 19). `inUse` is `PageHost.usesStore(id)`: true while any
    /// page holds the store, which refuses the removal with `.inUse`. Otherwise the cached instance is dropped first, because a store this
    /// registry ever handed out stays alive in `cache` and WebKit refuses to remove a store that still has a live instance, which would leave
    /// the deleted profile's cookies and sign-ins on disk. WebKit also refuses for a moment right after a page closed ("in use", "Failed to
    /// delete files on disk"), so a refusal is retried with a backoff (`removalRetryDelays`) before it is reported (R2-H2).
    public func remove(_ id: UUID, inUse: Bool) async throws {
        guard !inUse else { throw WebDataStoreError.inUse }
        // An instance made here but never used has no files yet, and WebKit then fails the removal ("Failed to delete files on disk",
        // measured on macOS 27.2). Asking it for its records settles it first. The instance's scope ends before the removal.
        if let cached = cache.removeValue(forKey: .persistent(id)) { await Self.settle(cached) }
        try await Self.retrying(after: Self.removalRetryDelays) { try await WKWebsiteDataStore.remove(forIdentifier: id) }
    }

    /// Runs `attempt`; each failure is followed by the next delay and another attempt, and the last failure is thrown when the delays run out.
    /// A store held by a page (`.inUse`) is not transient and is thrown at once.
    static func retrying(after delays: [Duration], _ attempt: () async throws -> Void) async throws {
        var remaining = delays[...]
        while true {
            do {
                return try await attempt()
            } catch WebDataStoreError.inUse {
                throw WebDataStoreError.inUse
            } catch {
                guard let delay = remaining.popFirst() else { throw error }
                try await Task.sleep(for: delay)
            }
        }
    }

    /// The identifiers of the persistent stores WebKit has on disk; what the launch check compares the recorded removals against.
    public static func listedIdentifiers() async -> Set<UUID> {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: Set($0)) }
        }
    }

    private static func settle(_ store: WKWebsiteDataStore) async {
        _ = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
    }

    /// A private window of `profileID` opens: it joins the profile's open private session, or starts a new one when no private window of the
    /// profile is open. Returns the session's ID, the key of its one non-persistent store (nothing of it is written to disk).
    public func joinPrivateSession(profileID: UUID) -> UUID {
        let session = privateSessions[profileID] ?? (id: UUID(), windows: 0)
        privateSessions[profileID] = (session.id, session.windows + 1)
        return session.id
    }

    /// The ID of the profile's open private session, nil when none is open.
    func privateSessionID(profileID: UUID) -> UUID? { privateSessions[profileID]?.id }

    /// A private window of `profileID` closed. When it was the last, the session's store is dropped (a later private window starts a new
    /// session with no cookies) and this returns true, so the caller drops what else the session held. A profile with no open session
    /// counts as already ended.
    @discardableResult
    public func leavePrivateSession(profileID: UUID) -> Bool {
        guard let session = privateSessions[profileID] else { return true }
        guard session.windows <= 1 else {
            privateSessions[profileID] = (session.id, session.windows - 1)
            return false
        }
        privateSessions[profileID] = nil
        cache[.privateSession(session.id)] = nil
        return true
    }
}
