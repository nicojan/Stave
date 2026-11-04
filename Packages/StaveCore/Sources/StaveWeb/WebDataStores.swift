import Foundation
import WebKit

/// Which website data store a page uses: a profile's or container's persistent store, or a private session's (shared by the private windows
/// of one profile while any is open; see `WebDataStores.joinPrivateSession`).
public enum DataStoreKey: Hashable, Sendable {
    case persistent(UUID)
    case privateSession(UUID)
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
