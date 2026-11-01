import Foundation
import WebKit

/// Which website data store a page uses: a profile's or container's persistent store, or a private window's own.
public enum DataStoreKey: Hashable, Sendable {
    case persistent(UUID)
    case privateWindow(UUID)
}

/// Every page's data store comes from here. `WKWebsiteDataStore.default()` is never used (plan 3, decision 1).
@MainActor
public final class WebDataStores {
    private var cache: [DataStoreKey: WKWebsiteDataStore] = [:]

    public init() {}

    /// The same instance for the same key until a private window's store is released.
    public func store(for key: DataStoreKey) -> WKWebsiteDataStore {
        if let cached = cache[key] { return cached }
        let made: WKWebsiteDataStore = switch key {
        case .persistent(let id): WKWebsiteDataStore(forIdentifier: id)
        case .privateWindow: .nonPersistent()
        }
        cache[key] = made
        return made
    }

    /// Drops a closed private window's store, so a later window with the same ID starts empty.
    public func releasePrivate(_ windowID: UUID) {
        cache[.privateWindow(windowID)] = nil
    }
}
