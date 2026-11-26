import Foundation

/// What deleting a profile removes, counted from the store just before the question is asked (decision 18).
public struct ProfileSummary: Equatable, Sendable {
    public var workspaces: Int
    public var tabs: Int
    public var archived: Int
    public var history: Int

    public init(workspaces: Int, tabs: Int, archived: Int, history: Int) {
        self.workspaces = workspaces; self.tabs = tabs; self.archived = archived; self.history = history
    }
}

/// Deleting a profile, in the one safe order (decision 18, Review Focus 3): the profile's private session closes, every window showing it
/// switches to another profile, the rows go (`deleteProfile`, which refuses the last profile and records the profile's store IDs as pending in
/// the same transaction), and only then are the website data stores removed, so a store is never removed while its rows exist or a page still
/// uses it. The caller asks the user first.
@MainActor
public struct ProfileDeletion {
    private let store: OrganizationStore
    private let closePrivateSession: (UUID) -> Void
    private let switchWindows: (UUID) -> Void
    private let removal: StoreRemoval
    private let session: WindowSession?
    private let revision: StoreRevision?

    /// `closePrivateSession` closes the private windows of the profile; `switchWindows` moves every live window showing it to the first
    /// remaining profile; `removal` removes the website data stores the deletion left pending. `session` (when given) forgets the saved
    /// window states that still name the profile, and `revision` is bumped as soon as the rows are gone, so lists stop showing the profile
    /// while its stores are still being removed.
    public init(
        store: OrganizationStore,
        closePrivateSession: @escaping (UUID) -> Void,
        switchWindows: @escaping (UUID) -> Void,
        removal: StoreRemoval,
        session: WindowSession? = nil,
        revision: StoreRevision? = nil
    ) {
        self.store = store
        self.closePrivateSession = closePrivateSession
        self.switchWindows = switchWindows
        self.removal = removal
        self.session = session
        self.revision = revision
    }

    /// Throws `.lastProfile` or `.notFound` before touching any window, and any database error as it is. Only a failure to remove stores
    /// after the rows are gone is a `StoreRemovalError`; the profile itself is already deleted by then and the stores stay pending.
    public func run(profileID: UUID) async throws {
        let profiles = try store.profiles()
        guard profiles.contains(where: { $0.id == profileID }) else { throw StoreError.notFound }
        guard profiles.count > 1 else { throw StoreError.lastProfile }
        closePrivateSession(profileID)
        switchWindows(profileID)
        let stores = try store.deleteProfile(profileID)
        session?.discardStates(forProfile: profileID)
        revision?.bump()
        try await removal.runPending(reporting: Set(stores))
    }
}
