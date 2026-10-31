import Observation

/// One counter shared by every window, bumped after each store write. A window that sees it change re-reads the store.
@MainActor @Observable
public final class StoreRevision {
    public private(set) var value: Int = 0

    public init() {}

    public func bump() { value += 1 }
}
