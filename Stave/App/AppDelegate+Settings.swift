import AppKit
import StaveCore
import StaveWeb

/// What Settings needs from the app: deleting a profile (its windows, private session and website data stores), and the backups folder.
extension AppDelegate {
    /// The Settings window's model. Deleting a profile follows `ProfileDeletion`'s order; removing a store waits for pages that held it.
    func makeSettingsModel(_ environment: AppEnvironment, removal: StoreRemoval) -> SettingsModel {
        let deletion = ProfileDeletion(
            store: environment.store,
            closePrivateSession: { [weak self] id in self?.closePrivateWindows(profileID: id) },
            switchWindows: { [weak self] id in self?.switchWindows(awayFrom: id) },
            removal: removal,
            session: environment.session,
            revision: environment.revision
        )
        return SettingsModel(store: environment.store, revision: environment.revision, profileDeletion: deletion, removal: removal)
    }

    /// The launch check of website data stores that deleted profiles and containers left behind (R2-H1): stores removed last time are checked
    /// against WebKit's listing and removed again if still there, and stores a busy page kept pending are retried. The IDs came from deleted
    /// rows, so no page is created for them whatever order this runs in. It takes its turn behind any deletion already removing stores
    /// (`StoreRemoval` runs one at a time) and reports nothing to the user: it recorded nothing.
    func retryPendingStoreRemovals(_ removal: StoreRemoval) {
        Task {
            do {
                try await removal.verifyAtLaunch(listing: { await WebDataStores.listedIdentifiers() })
            } catch {
                NSLog("Stave: some website data of deleted profiles or containers is still on disk: \(error)")
            }
        }
    }

    /// The app's one `StoreRemoval`: its runs are serialized, so every caller must share this instance.
    func makeStoreRemoval(_ environment: AppEnvironment) -> StoreRemoval {
        StoreRemoval(store: environment.store) { [weak self] ids in
            guard let self else { return Dictionary(uniqueKeysWithValues: ids.map { ($0, WebDataStoreError.inUse as any Error) }) }
            return await self.removeWebsiteStores(ids)
        }
    }

    /// The profile's private windows close, which ends its private session (their pages and non-persistent store go with them).
    private func closePrivateWindows(profileID: UUID) {
        for controller in privateControllers.filter({ $0.profileID == profileID }) { controller.window.close() }
    }

    /// Every browser window showing the profile moves to the first remaining profile, as the command bar's "Switch to profile" does.
    private func switchWindows(awayFrom profileID: UUID) {
        guard let target = (try? environment?.store.profiles())?.first(where: { $0.id != profileID }) else { return }
        for controller in controllers where controller.model.snapshot.profile.id == profileID {
            controller.model.switchProfile(to: target.id)
        }
    }

    /// Removes the website data stores of deleted profiles or containers. Their rows are gone by now. Pages that still hold a store (a tab no
    /// window shows, a pop-up) are closed first, and ones still tearing down are waited for, once for all stores; a store still in use after
    /// that is refused by `WebDataStores.remove`. Every store is tried; the failures are returned, by ID.
    private func removeWebsiteStores(_ ids: [UUID]) async -> [UUID: any Error] {
        guard let environment else { return Dictionary(uniqueKeysWithValues: ids.map { ($0, WebDataStoreError.inUse as any Error) }) }
        closePages(using: ids, in: environment)
        await waitUntilUnused(ids, in: environment.pageHost)
        var failures: [UUID: any Error] = [:]
        for id in ids {
            do {
                try await environment.webStores.remove(id, inUse: environment.pageHost.usesStore(id))
            } catch {
                failures[id] = error
            }
        }
        return failures
    }

    private func closePages(using storeIDs: [UUID], in environment: AppEnvironment) {
        let doomed = Set(storeIDs)
        for tabID in environment.pageHost.persistentTabIDs {
            guard let page = environment.pageHost.existingPage(tabID), case .persistent(let storeID) = page.store, doomed.contains(storeID) else { continue }
            environment.popups.closeAll(openedBy: tabID)
            if let popup = environment.popups.popup(tabID) { popup.close() } else { environment.pageHost.close(tabID) }
        }
    }

    /// An unloaded page keeps its web view until its snapshot is taken (a few seconds at most), so removal waits for it, up to the page host's
    /// own limit, which follows its snapshot timeout.
    private func waitUntilUnused(_ ids: [UUID], in host: PageHost) async {
        let deadline = ContinuousClock.now.advanced(by: host.teardownWaitLimit)
        while host.usesAnyStore(ids), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Settings ▸ Advanced ▸ "Show Backups in Finder". Creates the folder first, so the button works before the first copy is made, and opens
    /// the folder itself. A failure is shown, never swallowed.
    func showBackupsInFinder() {
        guard let folder = environment?.backups.folder else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            SettingsAlerts.inform(SettingsCopy.backupsFolderFailed(error.localizedDescription))
            return
        }
        if !NSWorkspace.shared.open(folder) { SettingsAlerts.inform(SettingsCopy.backupsFolderNotOpened) }
    }
}
