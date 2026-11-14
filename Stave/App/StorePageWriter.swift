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

    /// History is not shown in the sidebar, so a visit bumps no revision.
    func recordVisit(profileID: UUID, url: String, title: String, at date: Date) {
        do {
            try store.recordVisit(profileID: profileID, url: url, title: title, at: date)
        } catch {
            NSLog("Stave: could not save a visit to history: \(error)")
        }
    }

    func updateVisitTitle(profileID: UUID, url: String, title: String) {
        do {
            try store.updateVisitTitle(profileID: profileID, url: url, title: title)
        } catch {
            NSLog("Stave: could not save a visited page's title: \(error)")
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

    /// A row that can't be read is logged and treated as none, so the page falls back to the default (100 % zoom).
    func siteValue<V: Codable>(profileID: UUID, host: String, key: SiteValueKey, as type: V.Type) -> V? {
        do {
            return try store.siteValue(profileID: profileID, host: host, key: key, as: type)
        } catch {
            NSLog("Stave: could not read a site value: \(error)")
            return nil
        }
    }

    func setSiteValue<V: Codable>(profileID: UUID, host: String, key: SiteValueKey, _ value: V?) {
        do {
            try store.setSiteValue(profileID: profileID, host: host, key: key, value)
        } catch {
            NSLog("Stave: could not save a site value: \(error)")
        }
    }
}

/// The writer of pages that are no store tabs (pop-ups): nothing they do is written, so they leave no rows and are never restored.
@MainActor
final class DiscardingPageWriter: PageWriter {
    func writeNavigation(tabID: UUID, url: String, title: String, faviconURL: String?) {}
    func writeInteractionState(tabID: UUID, _ state: Data?) {}
    func recordVisit(profileID: UUID, url: String, title: String, at date: Date) {}
    func updateVisitTitle(profileID: UUID, url: String, title: String) {}
}
