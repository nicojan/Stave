import Foundation
import GRDB

extension ArchivedTab {
    /// True for a row `archiveIdleTabs` wrote, false for one the user closed. No schema change carries it: a closed tab's row is written
    /// with `modifiedAt == closedAt` (every archive writer does that), while an idle archive keeps the tab's own last-modified time in
    /// `modifiedAt` and the archiving time in `closedAt`. Shift-Command-T skips these rows (Safari and Chrome reopen the last tab the user
    /// closed, and an idle archive is not something they closed); the archive sheet still lists them and restores them like any other.
    public var wasAutoArchived: Bool { modifiedAt < closedAt }
}

extension OrganizationStore {
    /// Stamps `lastActiveAt` (and `modifiedAt`) with the clock for each tab that still exists: "not viewed" counts from when the tab was last
    /// left, not when it was selected. A tab that is gone (closed meanwhile) is skipped, never an error.
    public func markLeft(tabIDs: [UUID]) throws {
        guard !tabIDs.isEmpty else { return }
        try database.writer.write { db in
            let stamp = now()
            for id in tabIDs {
                guard var tab = try Tab.fetchOne(db, key: id) else { continue }
                tab.lastActiveAt = stamp
                tab.modifiedAt = stamp
                try tab.update(db)
            }
        }
    }

    /// Sets "Archive idle tabs after". Going from Never to a limit also records when, so that the tabs already idle then get a full limit
    /// from now (`idleTabIDs` counts from `max(lastActiveAt, enabledAt)`). The time is written first: a failed second write leaves a
    /// harmless time and the setting unchanged.
    public func setAutoArchiveAfter(_ limit: AutoArchiveAfter) throws {
        if limit != .never, try setting(SettingKeys.autoArchiveAfter) == .never {
            try setSetting(SettingKeys.autoArchiveEnabledAt, now())
        }
        try setSetting(SettingKeys.autoArchiveAfter, limit)
    }

    /// The time the idle count starts at the earliest. With a limit set and no readable enable time (never written, or its value no longer
    /// decodes) the setting counts as turned on now, and that is written: falling back to each tab's `lastActiveAt` would archive every old
    /// tab at once.
    private func resolvedEnabledAt(limit: AutoArchiveAfter, now: Date) throws -> Date? {
        guard limit != .never else { return nil }
        if let stored = try setting(SettingKeys.autoArchiveEnabledAt) { return stored }
        try setSetting(SettingKeys.autoArchiveEnabledAt, now)
        return now
    }

    /// Reads both clocks through the guard. After a wall clock jump forward, every tab looks old, so the enable time is moved to the new
    /// reading: each tab then gets a full limit from now, however many checks follow. A failed write is logged; the check is skipped anyway.
    public func checkClock(_ clockGuard: inout ClockJumpGuard, wall: Date, instant: ContinuousClock.Instant) -> ClockJumpGuard.Verdict {
        let verdict = clockGuard.verdict(wall: wall, instant: instant)
        if verdict == .skip(.wallClockJumpedForward) {
            do { try setSetting(SettingKeys.autoArchiveEnabledAt, wall) } catch {
                NSLog("Stave: could not restart the idle count after a clock jump: \(error)")
            }
        }
        return verdict
    }

    /// A window moves from one tab to another: the tab left is stamped first, then the new one is marked active, in one write. The tab
    /// left may be gone already (skipped); a missing new tab is `StoreError.notFound`, after the stamp is kept.
    public func markSelected(_ tabID: UUID, leaving previous: UUID?) throws {
        let found = try database.writer.write { db -> Bool in
            let stamp = now()
            if let previous, var left = try Tab.fetchOne(db, key: previous) {
                left.lastActiveAt = stamp
                left.modifiedAt = stamp
                try left.update(db)
            }
            guard var tab = try Tab.fetchOne(db, key: tabID) else { return false }
            tab.lastActiveAt = stamp
            tab.modifiedAt = stamp
            try tab.update(db)
            return true
        }
        guard found else { throw StoreError.notFound }
    }

    /// The tabs `archiveIdleTabs` would archive for the profile, without archiving them. The app reads this first so each page can write its
    /// pending title (`tabWillClose`) before the archive keeps it.
    public func idleTabIDs(
        profileID: UUID, now: Date, limit: AutoArchiveAfter, shown: Set<UUID>, busy: Set<UUID>, among: Set<UUID>? = nil
    ) throws -> [UUID] {
        let enabledAt = try resolvedEnabledAt(limit: limit, now: now)
        return try database.writer.read { db in
            try idleTabIDs(profileID: profileID, now: now, limit: limit, shown: shown, busy: busy, among: among, enabledAt: enabledAt, in: db)
        }
    }

    /// Archives the profile's idle tabs through the same path as `closeTab`, so each is restorable from the archive exactly as a closed
    /// tab is. All in one transaction. Returns how many were archived.
    @discardableResult
    public func archiveIdleTabs(
        profileID: UUID, now: Date, limit: AutoArchiveAfter, shown: Set<UUID>, busy: Set<UUID>, among: Set<UUID>? = nil
    ) throws -> Int {
        try archiveIdleTabIDs(profileID: profileID, now: now, limit: limit, shown: shown, busy: busy, among: among).count
    }

    /// `archiveIdleTabs`, returning the archived tabs' ids (the app unloads each one's page). `among` limits the archive to tabs the caller
    /// has checked for busy pages: a tab outside it is kept even if it became idle meanwhile.
    public func archiveIdleTabIDs(
        profileID: UUID, now: Date, limit: AutoArchiveAfter, shown: Set<UUID>, busy: Set<UUID>, among: Set<UUID>? = nil
    ) throws -> [UUID] {
        let enabledAt = try resolvedEnabledAt(limit: limit, now: now)
        return try database.writer.write { db in
            let ids = try idleTabIDs(profileID: profileID, now: now, limit: limit, shown: shown, busy: busy, among: among, enabledAt: enabledAt, in: db)
            for id in ids {
                guard let tab = try Tab.fetchOne(db, key: id), let slot = try Slot.fetchOne(db, key: tab.slotID) else { continue }
                _ = try archiveRegularTab(tab: tab, slot: slot, closedAt: now, modifiedAt: tab.lastActiveAt, in: db)
            }
            return ids
        }
    }

    private func idleTabIDs(
        profileID: UUID, now: Date, limit: AutoArchiveAfter, shown: Set<UUID>, busy: Set<UUID>, among: Set<UUID>?, enabledAt: Date?,
        in db: Database
    ) throws -> [UUID] {
        guard limit != .never else { return [] }
        let slots = try Slot.filter(Column("profileID") == profileID).fetchAll(db)
        let slotByID = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        let tabs = try Tab.filter(slotByID.keys.contains(Column("slotID"))).fetchAll(db)
        let candidates = tabs.compactMap { tab -> AutoArchiveCandidate? in
            guard let slot = slotByID[tab.slotID] else { return nil }
            // The idle time starts when the setting was turned on at the earliest (first enable must not archive what was already old).
            let idleSince = enabledAt.map { max(tab.lastActiveAt, $0) } ?? tab.lastActiveAt
            return AutoArchiveCandidate(tabID: tab.id, section: slot.section, slotKind: slot.kind, lastActiveAt: idleSince)
        }
        let idle = AutoArchivePolicy.toArchive(candidates, now: now, limit: limit, shown: shown, busy: busy)
        guard let among else { return idle }
        return idle.filter { among.contains($0) }
    }
}
