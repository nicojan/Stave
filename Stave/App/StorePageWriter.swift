import Foundation
import StaveCore
import StaveWeb

/// Where live pages write: their navigation and `interactionState`, and the per-site settings, all through `OrganizationStore`.
/// A navigation write bumps `StoreRevision`, so every window re-reads its sidebar; a state write does not (plan 3, decision 4).
/// A write for a tab that no longer exists (`StoreError.notFound`) is dropped silently. `AppEnvironment` keeps it for the app's life,
/// because `PageHost` and each page hold it weakly.
@MainActor
final class StorePageWriter: PageWriter, SiteSettingsSource {
    private let store: OrganizationStore
    private let revision: StoreRevision

    init(store: OrganizationStore, revision: StoreRevision) {
        self.store = store
        self.revision = revision
    }

    func writeNavigation(tabID: UUID, url: String, title: String, faviconURL: String?) {
        do {
            try store.updatePageNavigation(tabID: tabID, url: url, title: title, faviconURL: faviconURL)
            revision.bump()
        } catch StoreError.notFound {
            return
        } catch {
            NSLog("Stave: could not save a page's address: \(error)")
        }
    }

    func writeInteractionState(tabID: UUID, _ state: Data?) {
        do {
            try store.updateInteractionState(tabID: tabID, state)
        } catch StoreError.notFound {
            return
        } catch {
            NSLog("Stave: could not save a page's history: \(error)")
        }
    }

    func decision(profileID: UUID, host: String, key: SiteSettingKey) -> SiteDecision? {
        do {
            return try store.siteDecision(profileID: profileID, host: host, key: key)
        } catch {
            NSLog("Stave: could not read a site setting: \(error)")
            return nil
        }
    }

    func setDecision(profileID: UUID, host: String, key: SiteSettingKey, _ d: SiteDecision?) {
        do {
            try store.setSiteDecision(profileID: profileID, host: host, key: key, d)
        } catch {
            NSLog("Stave: could not save a site setting: \(error)")
        }
    }
}

/// The writer of pages that are no store tabs (pop-ups): nothing they do is written, so they leave no rows and are never restored.
@MainActor
final class DiscardingPageWriter: PageWriter {
    func writeNavigation(tabID: UUID, url: String, title: String, faviconURL: String?) {}
    func writeInteractionState(tabID: UUID, _ state: Data?) {}
}
