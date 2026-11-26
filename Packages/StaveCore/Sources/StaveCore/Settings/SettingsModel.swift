import Foundation
import Observation

/// What the Settings window's Profiles, Containers, Websites and General panes read and do, as live state over the store. Every write bumps the
/// shared revision, so every window follows. A failed write sets `message` (shown by the window); nothing here is fatal.
@MainActor @Observable
public final class SettingsModel {
    /// What a container's Delete button should do.
    public enum ContainerDeletion: Equatable {
        /// Still used: show this refusal and delete nothing.
        case refused(String)
        /// Unused: ask this question first.
        case ask(String)
    }

    @ObservationIgnored private let store: OrganizationStore
    @ObservationIgnored private let revision: StoreRevision
    @ObservationIgnored private let profileDeletion: ProfileDeletion
    @ObservationIgnored private let removal: StoreRemoval

    /// Each pane's last failure, in words. A deletion that answers late lands on its own pane, never on the one the user moved to (R2-L2).
    public private(set) var messages: [SettingsPane: String] = [:]
    @ObservationIgnored private var latestPane: SettingsPane?

    /// The pane's own last failure; its view shows it.
    public func message(for pane: SettingsPane) -> String? { messages[pane] }

    /// The failure most recently set on any pane (nil after that pane's last success); for callers that don't care which pane it was.
    public var message: String? { latestPane.flatMap { messages[$0] } }

    private func show(_ text: String?, in pane: SettingsPane) {
        messages = messages.filter { $0.key != pane }.merging(text.map { [pane: $0] } ?? [:]) { _, new in new }
        latestPane = pane
    }

    public init(
        store: OrganizationStore, revision: StoreRevision, profileDeletion: ProfileDeletion, removal: StoreRemoval
    ) {
        self.store = store
        self.revision = revision
        self.profileDeletion = profileDeletion
        self.removal = removal
    }

    // MARK: Reading (each read follows the revision)

    public var profiles: [Profile] {
        _ = revision.value
        return (try? store.profiles()) ?? []
    }

    public func containers(profileID: UUID) -> [Container] {
        _ = revision.value
        return (try? store.containers(profileID: profileID)) ?? []
    }

    public func siteEntries(profileID: UUID) -> [SiteEntry] {
        _ = revision.value
        return (try? store.siteEntries(profileID: profileID)) ?? []
    }

    public var newTabEdge: NewTabEdge {
        _ = revision.value
        return (try? store.setting(SettingKeys.newTabEdge)) ?? SettingKeys.newTabEdge.defaultValue
    }

    // MARK: Profiles

    public func renameProfile(_ id: UUID, to name: String) {
        perform(.profiles) { try store.renameProfile(id, to: name) }
    }

    /// The question to ask before deleting, nil when the profile can't be deleted (the last one: `message` says why).
    public func profileDeletionQuestion(_ id: UUID) -> String? {
        do {
            let profiles = try store.profiles()
            guard profiles.count > 1 else { throw StoreError.lastProfile }
            guard let profile = profiles.first(where: { $0.id == id }) else { throw StoreError.notFound }
            return DeletionCopy.profileQuestion(try store.profileSummary(id), name: profile.name)
        } catch {
            show(StoreErrorText.message(for: error), in: .profiles)
            return nil
        }
    }

    /// Deletes the profile after the user confirmed (`ProfileDeletion` keeps the order). A failure of the store removal afterwards is shown.
    public func deleteProfile(_ id: UUID) async {
        do {
            try await profileDeletion.run(profileID: id)
            show(nil, in: .profiles)
        } catch {
            NSLog("Stave: could not delete a profile completely: \(error)")
            show(Self.deletionMessage(for: error), in: .profiles)
        }
        revision.bump()
    }

    // MARK: Containers

    public func createContainer(profileID: UUID, name: String, colorHex: String) {
        guard WorkspaceEditorRules.validate(name: name, icon: "", colorHex: colorHex) != nil else {
            show(StoreErrorText.message(for: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? StoreError.blankName : StoreError.invalidColour), in: .containers)
            return
        }
        perform(.containers) { _ = try store.createContainer(profileID: profileID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), colorHex: colorHex) }
    }

    public func updateContainer(_ id: UUID, name: String, colorHex: String) {
        perform(.containers) { _ = try store.updateContainer(id, name: name, colorHex: colorHex) }
    }

    /// Refused with the count while any open or archived tab uses the container; otherwise the question to ask first.
    public func containerDeletion(_ container: Container) -> ContainerDeletion? {
        do {
            let usage = try store.containerUsage(container.id)
            let used = usage.open + usage.archived
            return used > 0
                ? .refused(DeletionCopy.containerInUse(count: used, name: container.name))
                : .ask(DeletionCopy.containerQuestion(name: container.name))
        } catch {
            show(StoreErrorText.message(for: error), in: .containers)
            return nil
        }
    }

    /// Deletes the container's row after the user confirmed, then removes its data store (only after the row is gone).
    public func deleteContainer(_ container: Container) async {
        do {
            let storeID = try store.deleteContainer(container.id)
            show(nil, in: .containers)
            revision.bump()
            try await removal.runPending(reporting: [storeID])
        } catch StoreError.containerInUse {
            // A tab began using it after the question was asked.
            let usage = try? store.containerUsage(container.id)
            show(DeletionCopy.containerInUse(count: max(1, (usage?.open ?? 0) + (usage?.archived ?? 0)), name: container.name), in: .containers)
        } catch {
            NSLog("Stave: could not delete a container completely: \(error)")
            show(Self.deletionMessage(for: error), in: .containers)
        }
    }

    // MARK: Websites and General

    /// Makes the Websites list re-read the store. Pages write site values and answers without going through this model, so the pane
    /// calls it when it appears.
    public func refresh() { revision.bump() }

    /// Forgets the pane's failure; the Settings window calls it for the pane the user leaves, so a stale message never greets them on return.
    public func clearMessage(for pane: SettingsPane) { show(nil, in: pane) }

    public func remove(_ entry: SiteEntry) {
        perform(.websites) { try store.removeSiteEntry(entry) }
    }

    public func removeAllSiteEntries(profileID: UUID) {
        perform(.websites) { _ = try store.removeAllSiteEntries(profileID: profileID) }
    }

    public func setNewTabEdge(_ edge: NewTabEdge) {
        guard edge != newTabEdge else { return }
        perform(.general) { try store.setSetting(SettingKeys.newTabEdge, edge) }
    }

    // MARK: Helpers

    private func perform(_ pane: SettingsPane, _ work: () throws -> Void) {
        do {
            try work()
            show(nil, in: pane)
        } catch {
            show(StoreErrorText.message(for: error), in: pane)
        }
        revision.bump()
    }

    /// Only a failure of the stores themselves says "deleted, but…"; any other failure (the rows were not deleted) gets the store error text.
    private static func deletionMessage(for error: Error) -> String {
        guard let removal = error as? StoreRemovalError else { return StoreErrorText.message(for: error) }
        return removal.isBookkeepingOnly ? DeletionCopy.websiteDataRemovedButNotNoted : DeletionCopy.websiteDataNotRemoved
    }
}
